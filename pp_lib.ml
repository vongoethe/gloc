open Printf

module Env = Map.Make(struct type t = string let compare = compare end)

type base = Oct | Dec | Hex
type behavior = Require | Enable | Warn | Disable

type src_loc = { src: int; input: int }
type loc = { file : src_loc; line: src_loc; col: int }
type span = { a: loc; z: loc }
type 't pptok = { span: span;
		  scan: loc -> loc * string;
                  comments: comments * comments ref;
                  v: 't }
and comments = string pptok list pptok list
and pptok_type =
  | Int of (base * int) pptok
  | Float of float pptok
  | Word of (string * unit Env.t) pptok
  | Call of string pptok
  | Punc of Punc.tok pptok
  | Comma of Punc.tok pptok
  | Leftp of Punc.tok pptok
  | Rightp of Punc.tok pptok
and stream = pptok_type list
and macro = { name: string option;
	      args: string list option;
	      stream: loc -> stream }

type env = { macros: macro Env.t; extensions: behavior Env.t }

exception ParserError of string
exception UnterminatedConditional of unit pptok
exception UnknownBehavior of string pptok
exception HolyVersion of unit pptok
exception UnsupportedVersion of int pptok
exception InvalidVersionBase of base pptok
exception InvalidVersionArg of unit pptok
exception InvalidLineBase of base pptok
exception InvalidLineArg of unit pptok

exception MacroArgUnclosed of unit pptok
exception MacroArgInnerParenUnclosed of unit pptok
exception MacroArgTooFew of unit pptok * int * int
exception MacroArgTooMany of unit pptok * int * int
exception ReservedKeyword of string pptok
exception ReservedMacro of string pptok
exception ErrorDirective of stream pptok
exception UnsupportedPPOp of Punc.tok pptok
exception FloatUnsupported of float pptok

type cond_expr_result = Deferred | Result of Int32.t

type cond_expr =
  | Group of cond_expr pptok
  | Opaque of stream pptok
  | Constant of int pptok
  | Defined of string pptok pptok
  | Pos of cond_expr pptok
  | Neg of cond_expr pptok
  | BitNot of cond_expr pptok
  | Not of cond_expr pptok
  | Mul of (cond_expr * cond_expr) pptok
  | Div of (cond_expr * cond_expr) pptok
  | Mod of (cond_expr * cond_expr) pptok
  | Add of (cond_expr * cond_expr) pptok
  | Sub of (cond_expr * cond_expr) pptok
  | BitLeft of (cond_expr * cond_expr) pptok
  | BitRight of (cond_expr * cond_expr) pptok
  | Lt of (cond_expr * cond_expr) pptok
  | Gt of (cond_expr * cond_expr) pptok
  | Lte of (cond_expr * cond_expr) pptok
  | Gte of (cond_expr * cond_expr) pptok
  | Eq of (cond_expr * cond_expr) pptok
  | Neq of (cond_expr * cond_expr) pptok
  | BitAnd of (cond_expr * cond_expr) pptok
  | BitXor of (cond_expr * cond_expr) pptok
  | BitOr of (cond_expr * cond_expr) pptok
  | And of (cond_expr * cond_expr) pptok
  | Or of (cond_expr * cond_expr) pptok

type line_dir = int pptok option * int pptok

type pptok_expr =
  | Comments of comments pptok
  | Chunk of stream pptok
  | If of (cond_expr * pptok_expr * (pptok_expr option)) pptok
  | Def of (string pptok * stream) pptok
  | Fun of (string pptok * (string pptok list) * stream) pptok
  | Undef of string pptok pptok
  | Err of stream pptok
  | Pragma of stream pptok
  | Version of int pptok pptok
  | Extension of (string pptok * behavior pptok) pptok
  | Line of line_dir pptok
  | List of pptok_expr list pptok

let proj : 'a pptok -> unit pptok = fun t -> { t with v=() }

let proj_pptok_type = function
  | Int t -> proj t
  | Float t -> proj t
  | Word t -> proj t
  | Call t -> proj t
  | Punc t -> proj t
  | Comma t -> proj t
  | Leftp t -> proj t
  | Rightp t -> proj t

let proj_cond_expr = function
  | Group t -> proj t
  | Opaque t -> proj t
  | Constant t -> proj t
  | Defined t -> proj t
  | Pos t -> proj t
  | Neg t -> proj t
  | BitNot t -> proj t
  | Not t -> proj t
  | Mul t -> proj t
  | Div t -> proj t
  | Mod t -> proj t
  | Add t -> proj t
  | Sub t -> proj t
  | BitLeft t -> proj t
  | BitRight t -> proj t
  | Lt t -> proj t
  | Gt t -> proj t
  | Lte t -> proj t
  | Gte t -> proj t
  | Eq t -> proj t
  | Neq t -> proj t
  | BitAnd t -> proj t
  | BitXor t -> proj t
  | BitOr t -> proj t
  | And t -> proj t
  | Or t -> proj t

let proj_pptok_expr = function
  | Comments t -> proj t
  | Chunk t -> proj t
  | If t -> proj t
  | Def t -> proj t
  | Fun t -> proj t
  | Undef t -> proj t
  | Err t -> proj t
  | Pragma t -> proj t
  | Version t -> proj t
  | Extension t -> proj t
  | Line t -> proj t
  | List t -> proj t

let span_of_list : 'a pptok list -> span = function
  | [] -> raise (ParserError "spanning empty pptok list")
  | (h::_) as ptl -> {a=(proj h).span.a;
		      z=(proj (List.hd (List.rev ptl))).span.z}

let emit_newline = ref true
let file = ref {src=0; input=0}
let line = ref {src=1; input=1}
let errors : exn list ref = ref []
let error exc = errors := exc::!errors

let check_version_base t =
  match fst t.v with
    | Hex | Oct -> error (InvalidVersionBase {t with v=fst t.v})
    | Dec -> ()

let check_line_base t =
  match fst t.v with
    | Hex | Oct -> error (InvalidLineBase {t with v=fst t.v})
    | Dec -> ()

let scan_of_comments cs start =
  let ({a}) = (List.hd cs).span in
  let start, pre = if (a.line.src - start.line.src) > 0 && !emit_newline
  then {start with line=a.line; col=0},
    String.make (a.line.src - start.line.src) '\n'
  else start,"" in
  let start, pre = List.fold_left
    (fun (start,pre) t ->
       let loc,s = t.scan start in
	 (loc,pre^s)
    ) ({start with col=start.col+2},pre^"/*") cs
  in ({start with col=start.col+2},pre^"*/")

let scan_of_string ({a;z}) (prec,postc) s = fun start ->
  let start,pre = match prec with
    | [] ->
      if !emit_newline
	&& (a.file.src <> start.file.src || (a.line.src - start.line.src) < 0)
      then {a with col=0},
	sprintf "\n#line %d %d\n" a.line.src a.file.src
      else if a.line.src - start.line.src > 0 && !emit_newline
      then {start with line=a.line; col=0},
	String.make (a.line.src - start.line.src) '\n'
      else start,""
    | cs -> scan_of_comments cs start
  in
  let cerr,cfix =
    if start.col <= a.col
    then 0,String.make (a.col - start.col) ' '
    else (start.col - a.col + 1)," "
  in let fin = {z with col=z.col+cerr} in
  let fin,post = match List.rev !postc with
    | [] -> fin,""
    | cs -> scan_of_comments cs fin
  in (fin, sprintf "%s%s%s%s" pre cfix s post)

let fuse_pptok ?(nl=true) = function
  | [] -> raise (ParserError "fusing empty pptok list")
  | (h::_) as tokl ->
      {span=span_of_list tokl;
       scan=(fun start ->
	       let oenl = !emit_newline in
	       let () = emit_newline := nl in
	       let loc,rs = List.fold_left
		 (fun (loc,str) tok ->
		    let nloc,nstr = tok.scan loc in
		      (nloc,str^nstr))
		 (start,"") tokl
	       in emit_newline := oenl; (loc,rs)
	    );
       comments=(fst h.comments,snd (List.hd (List.rev tokl)).comments);
       v=()}

let fuse_pptok_expr = function
  | [] -> raise (ParserError "fusing empty pptok_expr list")
  | (h::_) as el ->
    List {(fuse_pptok (List.map proj_pptok_expr el)) with v=el}

let cexpr cs = let t = {(fuse_pptok cs) with v=cs} in
  Comments {t with scan=fun loc ->
            let loc,s = t.scan {loc with col=loc.col+2} in
	      {loc with col=loc.col+2}, "/*"^s^"*/"}
    
let pptok_expr_of_body bl def = match bl with
  | [] -> List { def with v=[] }
  | l -> fuse_pptok_expr l

let synth_int (base,i) = fun loc ->
  let is = string_of_int i in
  let il = String.length is in
  let span = { a=loc; z={ loc with col=loc.col+il+2 } } in
    [Int {span; scan=scan_of_string span ([],ref []) is;
	  comments=([],ref []); v=(base,i)}]