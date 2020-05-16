(*
   Code generator for the AST.ml file.

   This produces code similar to what's found in ../../run/lib/Sample.ml
*)

open Printf
open AST_grammar
open Indent.Types

let preamble = [ Line "\
(* Generated by ocaml-tree-sitter. *)

(* Disable warnings against unused variables *)
[@@@warning \"-26-27\"]

open Tree_sitter_output_t
let get_loc x = Loc.({ start = x.startPosition; end_ = x.endPosition})

let parse input_file =
  let input = Input_file.load input_file in
  let get_token x =
    Input_file.get_token input x.startPosition x.endPosition in

    let _parse_rule type_ parse_children =
      Combine.parse_node (fun x ->
        if x.type_ = type_ then
          parse_children x.children
        else
          None
      )
    in

    (* childless rule, from which we extract location and token. *)
    let _parse_leaf_rule type_ =
      Combine.parse_node (fun x ->
        if x.type_ = type_ then
          Some (get_loc x, get_token x)
        else
          None
      )
    in
"
]

let gen_parser_name name = "parse_" ^ name

let paren x =
  [
    Line "(";
    Block x;
    Line ")";
  ]

let format_cases cases =
  List.map (fun (pat, e) ->
    [
      Line (sprintf "| %s ->" pat);
      Block [Block e];
    ]
  ) cases
  |> List.flatten

let match_with e cases =
  paren [
    Line "match";
    Block e;
    Line "with";
    Inline (format_cases cases);
  ]

(*
   For some functions it's shorter to produce the function's body,
   for others it's shorter to produce the whole function expression.
   Each can be wrapped to convert to the other form.
*)
type code =
  | Fun of Indent.t (* takes one argument of type 'node list' *)
  | Body of Indent.t (* assumes one argument, 'nodes' *)

let as_fun = function
  | Fun code -> code
  | Body code ->
      [
        Line "(fun nodes ->";
        Block code;
        Line ")";
      ]

let as_body = function
  | Fun code ->
      [
        Line "(";
        Block code;
        Line ") nodes";
      ]
  | Body code -> code

let gen_lazy_or num_cases =
  assert (num_cases > 0);
  let rec gen i =
    if i = num_cases - 1 then
      [ Line (sprintf "parse_case%i nodes" i) ]
    else
      [
        Line (sprintf "match parse_case%i nodes with" i);
        Line "| Some _ as res -> res";
        Line "| None ->";
        Block [Block (gen (i + 1))];
      ]
  in
  gen 0

let as_sequence body =
  match body with
  | Seq bodies -> bodies
  | body -> [body]

let gen_match_end parser_code =
  [
    Line "Combine.parse_last (";
    Block (parser_code |> as_fun);
    Line ")";
  ]

(*
   Produce, for num_elts = num_avail = 3:
    "(e0, (e1, e2))"

   For num_elts = 2 and num_avail = 5:
    "(e0, (e1, tail))"
*)
let gen_nested_pairs num_elts num_avail =
  assert (num_elts <= num_avail);
  assert (num_elts >= 0);
  match num_elts with
  | 0 -> "()"
  | _ ->
      let buf = Buffer.create 50 in
      let has_tail = (num_elts = num_avail) in
      let rec gen buf pos =
        if pos < num_elts - 1 then
          bprintf buf "(e%i, %a)" pos gen (pos + 1)
        else if pos = num_elts - 1 then
          if has_tail then
            bprintf buf "(e%i, tail)" pos
          else
            bprintf buf "e%i" pos
        else
          assert false
      in
      gen buf 0;
      Buffer.contents buf

(*
   Produce, for num_elts = num_avail = 3:
    "(e0, e1, e2)"

   For num_elts = 2 and num_avail = 5:
    "((e0, e1), tail))"
*)
let gen_flat_tuple num_elts num_avail wrap_tuple =
  assert (num_elts >= 0);
  let elts =
    sprintf "(%s)"
      (Codegen_util.enum num_elts
       |> List.map (fun pos -> sprintf "e%i" pos)
       |> String.concat ", ")
    |> wrap_tuple
  in
  if num_elts = num_avail then
    elts
  else
    sprintf "(%s, tail)" elts

(* A function expression that matches the rest of the sequence,
   with the depth of generated tuple and the number of elements we want to
   keep:

     (0, 0, None) : nothing needs to be matched or captured
     (1, 1, Some [Line "parse_something"]) : one element needs to be matched,
                                             captured, and returned

   It's possible to ignore the last element(s), such as a parser for checking
   the end of the sequence which returns unit. This is achieved by reducing
   the number of captured elements:

     (1, 0, Some [Line "parse_end"]) : one element needs to be matched but
                                       is ignored (giving a tuple of length 0)
     (2, 1, Some <parse an element, then match end>) :
                                       two elements are matched, captured,
                                       but the last element is discarded,
                                       giving a tuple of length 1.
*)
type next =
  | Nothing
  | Next of (int * int * code)

let flatten_next = function
  | Next x -> x
  | Nothing -> (0, 0, Fun [Line "Combine.parse_success"])

let force_next next =
  let _, _, code = flatten_next next in
  code

let map_next f next =
  match next with
  | Nothing -> Nothing
  | Next (num_captured, num_keep, code) ->
      Next (num_captured, num_keep, f code)

let match_end = Fun [Line "Combine.parse_end"]

let next_match_end = Next (0, 0, match_end)

let prepend_one next prepend_matcher =
  match next with
  | Nothing ->
      (* discard the () returned by match_end *)
      Next (2, 1, prepend_matcher match_end)
  | Next (num_captured, num_keep, tail_matcher) ->
      Next (num_captured + 1, num_keep + 1, prepend_matcher tail_matcher)

(* Put a matcher in front a sequence of matchers. *)
let prepend_next match_elt next =
  let prepend_matcher tail_matcher =
    Fun [
      Line "Combine.parse_seq";
      Block (paren (as_fun match_elt));
      Block (paren (as_fun tail_matcher));
    ]
  in
  prepend_one next prepend_matcher

(* Flatten the first n elements of a nested sequence, returning the tail
   unchanged.

   Generated code looks like this for n=2:

     match parse_sequence nodes with
     | None -> None
     | Some ((e1, (e2, tail)), nodes) -> Some (((e1, e2), tail), nodes)
                                                ^^^^^^^^^^^^^^ result pair

   If the tail is empty, leave it undefined and return a single result
   rather than a pair:

     match parse_sequence nodes with
     | None -> None
     | Some ((e1, e2), nodes) -> Some ((e1, e2), nodes)
                                       ^^^^^^^^ single result
*)
let flatten_seq_head ?(wrap_tuple = fun x -> x) num_elts next =
  let num_captured, num_keep, match_seq = flatten_next next in
  let nested_tuple_pat = gen_nested_pairs num_elts num_keep in
  let wrapped_result = gen_flat_tuple num_elts num_keep wrap_tuple in
  let cases = [
    sprintf "Some (%s, nodes)" nested_tuple_pat, [
      Line (sprintf "Some (%s, nodes)" wrapped_result)
    ];
    "None", [Line "None"];
  ] in
  let match_seq =
    Body (
      match_with
        (as_body match_seq)
        cases
    )
  in
  (* reflect the collapse of num_elts results into one. *)
  let num_captured = num_captured - num_elts + 1 in
  let num_keep = num_keep - num_elts + 1 in
  assert (num_captured >= 0);
  if num_captured = 0 then
    Nothing
  else
    Next (num_captured, num_keep, match_seq)

(*
   Flatten the full sequence.
*)
let flatten_seq ?wrap_tuple next =
  let num_elts =
    match next with
    | Nothing -> 0
    | Next (_num_captured, num_keep, _code) -> num_keep
  in
  let next = flatten_seq_head ?wrap_tuple num_elts next in
  force_next next

let wrap_matcher_result opt_wrap_result matcher_code =
  match opt_wrap_result with
  | None -> matcher_code
  | Some wrap_result ->
      Fun [
        Line "Combine.map";
        Block (paren wrap_result);
        Block (paren (as_fun matcher_code));
      ]

(* Transform the result of the first element of a pair. *)
let wrap_left_matcher_result opt_wrap_result matcher_code =
  match opt_wrap_result with
  | None -> matcher_code
  | Some wrap_result ->
      Fun [
        Line "Combine.map_fst";
        Block (paren wrap_result);
        Block (paren (as_fun matcher_code));
      ]

let rec gen_seq body (next : next) : next =
  match body with
  | Symbol s ->
      prepend_next (Fun [
        Line (sprintf "parse_%s" s)
      ]) next

  | String s ->
      prepend_next (Fun [
        Line (sprintf "_parse_leaf_rule %S" s)
      ]) next

  | Pattern s ->
      prepend_next (Fun [
        Line (sprintf "_parse_leaf_rule %S" s) (* does this happen? *)
      ]) next

  | Blank ->
      prepend_next (Fun [
        Line (sprintf "_parse_token %S" "blank" (* ? *))
      ]) next

  | Repeat body ->
      let prepend_matcher tail_matcher = Fun [
        Line "Combine.parse_repeat";
        Block (paren (flatten_seq (gen_seq body Nothing) |> as_fun));
        Block (paren (as_fun tail_matcher));
      ] in
      prepend_one next prepend_matcher

  | Repeat1 body ->
      let prepend_matcher tail_matcher = Fun [
        Line "Combine.parse_repeat1";
        Block (paren (flatten_seq (gen_seq body Nothing) |> as_fun));
        Block (paren (as_fun tail_matcher));
      ] in
      prepend_one next prepend_matcher

  | Choice bodies ->
      gen_choice bodies next

  | Seq bodies ->
      gen_seqn bodies next

(* A sequence to be turned into a flat tuple, followed by something else.
   e.g. for matching the sequence AB present in (AB|C)D,
   the argument to this function would and "parse_AB" and "parse_D".

   Generated code should look like this:

     match parse_seqn nodes next with
     | None -> None
     | Some ((e1, (e2, (e3, tail))), nodes) ->
         Some (((e1, e2, e3), tail), nodes)
*)
and gen_seqn ?wrap_tuple bodies (next : next) : next =
  (* the length of the tuple to extract before the rest of the sequence *)
  let num_elts = List.length bodies in
  let rec gen bodies =
    match bodies with
    | [] -> assert false
    | [body] -> gen_seq body next
    | body :: bodies -> gen_seq body (gen bodies)
  in
  let next = gen bodies in
  flatten_seq_head ?wrap_tuple num_elts next

and gen_choice cases next0 =
  (* Ensure we don't duplicate an unbounded amount of code for each case,
     by defining a parse_tail function. *)
  let next = map_next (fun _code -> Fun [Line "_parse_tail"]) next0 in
  let choice_matcher =
    Body [
      Line "let _parse_tail =";
      Block (force_next next0 |> as_fun);
      Line "in";
      Inline (List.mapi (fun i case ->
        Inline (gen_parse_case i case next)
      ) cases);
      Inline (gen_lazy_or (List.length cases));
    ]
  in
  prepend_next choice_matcher next

(*
   A case is a sequence, which in addition:
   - must match the end of input
   - wraps its result in a constructor like `Case0 rather than a plain tuple.
*)
and gen_parse_case i body next =
  let bodies = as_sequence body in
  let wrap_tuple tuple = sprintf "`Case%i %s" i tuple in
  [
    Line (sprintf "let _parse_case%i nodes =" i);
    Block (gen_seqn ~wrap_tuple bodies next |> force_next |> as_body);
    Line "in";
  ]

let is_leaf = function
  | Symbol _
  | String _
  | Pattern _
  | Blank -> true
  | Repeat _
  | Repeat1 _
  | Choice _
  | Seq _ -> false

let gen_rule_parser pos rule =
  let is_first = (pos = 0) in
  let let_ =
    (* TODO: minimize recursive calls with topological sort of strongly
       connected components. See https://github.com/dmbaturin/ocaml-tsort *)
    match is_first with
    | true -> "let rec"
    | false -> "and"
  in
  let ident, rule_body = rule in
  if is_leaf rule_body then
    [
      Line (sprintf "%s %s = _parse_leaf_rule %S"
              let_ (gen_parser_name ident) ident);
    ]
  else
    [
      Line (sprintf "%s %s = _parse_rule %S ("
              let_ (gen_parser_name ident) ident);
      Block (gen_seq rule_body next_match_end |> force_next |> as_fun);
      Line ")";
    ]

let gen grammar =
  let entrypoint = grammar.entrypoint in
  let rule_parsers =
    List.mapi (fun i rule -> Inline (gen_rule_parser i rule)) grammar.rules in
  [
    Inline preamble;
    Block [
      Inline rule_parsers;
      Line "in";
      Line (sprintf "Combine.parse_root %s" (gen_parser_name entrypoint));
    ]
  ]

let generate grammar =
  let tree = gen grammar in
  Indent.to_string tree
