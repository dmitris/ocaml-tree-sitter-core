(*
   Various helper functions called directly by the generated code.
*)

type matcher_token =
  Tree_sitter_bindings.Tree_sitter_output_t.node_kind * matcher_token_body

and matcher_token_body =
    Children of matcher_token Matcher.capture
  | Leaf of (Loc.t * string)

type exp =
  Tree_sitter_bindings.Tree_sitter_output_t.node_kind
    Matcher.exp

type capture = matcher_token Matcher.capture

val match_tree :
  (string * exp option) list ->
  Src_file.t ->
  Tree_sitter_bindings.Tree_sitter_output_t.node -> matcher_token option

val matcher_token : capture -> matcher_token

val trans_token : 'a * matcher_token_body -> Token.t

val repeat : (capture -> 'b) -> capture -> 'b list

val repeat1 : (capture -> 'b) -> capture -> 'b list

val opt : (capture -> 'b) -> capture -> 'b option

val nothing : capture -> unit

val extract_errors :
  Src_file.t ->
  Tree_sitter_bindings.Tree_sitter_output_t.node ->
  Tree_sitter_error.t list

val remove_extras :
  extras:string list ->
  Tree_sitter_bindings.Tree_sitter_output_t.node ->
  Tree_sitter_bindings.Tree_sitter_output_t.node
