package scan

import "core:simd"
import "walk"
import lex "lex"

// The grammar a source is read in. `.Jsonc` is JSON with comments and trailing commas, `.Json5` is JSON5 1.0.0.
// A dialect is a set of grammar features (`GRAMMAR`), and its walk is the JSON walk specialized on that set
// through the cursor type (`Dialect_Cursor`): the strict cursors carry no grammar, so the strict walk compiles
// without any dialect code.
//
// Code asks what a dialect reads in one of three ways:
//
//	- In the walk, a feature is tested at compile time with `when .Feature in G`.
//	- A runtime `Dialect` reaches a compiled walk through one exhaustive `switch` over `Dialect`, `.Json` first,
//	  each dialect's arm passing only its constant. The strict arm is empty where the strict walk takes
//	  arguments a dialect walk does not, and the code after the switch is that walk. A dialect the site's
//	  predicate refuses has an empty arm, and the code after the switch answers it.
//	- Any other question is a predicate below, which asks the grammar (`grammar_of`). A capability is a
//	  grammar's containment in the grammar the code reads (`EDIT_GRAMMAR`), so a new dialect whose features
//	  are covered gets it without an edit at the site. A dialect is never compared with `==` or `!=`.
//
// A dialect is named outside a dispatch arm only as the target of a transcode or a validation that is that
// dialect. A predicate is not asked per row or per value: ask it once for the document or the call.
Dialect :: enum u8 {
	Json,
	Jsonc,
	Json5,
}

// What a dialect adds to JSON's grammar. Each feature has one owner in the walk:
//
//	.Comments         `dialect_skip`: `//` and `/* */` wherever whitespace may stand
//	.Trailing_Commas  the comma arm of `walk_frames`: a comma before `]` or `}`
//	.Json5_Space      `dialect_skip`: VT, FF, NBSP, BOM, U+2028, U+2029 and the Zs spaces
//	.Json5_Keys       `object_key`: a key unquoted (an IdentifierName) or single-quoted (`json5_key`)
//	.Json5_Scalars    the value dispatch of `walk_frames`: single quotes, JSON5 escapes, hex, `.5`, `5.`, `+1`,
//	                  `Infinity` and `NaN` (`json5_string`, `json5_number`)
Grammar_Feature :: enum u8 {
	Comments,
	Trailing_Commas,
	Json5_Space,
	Json5_Keys,
	Json5_Scalars,
}

Grammar :: bit_set[Grammar_Feature; u8]

GRAMMAR :: [Dialect]Grammar {
	.Json  = {},
	.Jsonc = {.Comments, .Trailing_Commas},
	.Json5 = {.Comments, .Trailing_Commas, .Json5_Space, .Json5_Keys, .Json5_Scalars},
}

// The grammar of a dialect named at run time; a new dialect is a compile error here until it is listed.
grammar_of :: proc "contextless" (dialect: Dialect) -> Grammar {
	switch dialect {
	case .Json:
		return GRAMMAR[.Json]
	case .Jsonc:
		return GRAMMAR[.Jsonc]
	case .Json5:
		return GRAMMAR[.Json5]
	}
	unreachable()
}

// The grammar the edits read (`edits_read`), the record walk (`records_read`) and the typed shape walk
// (`shape_reads`): JSON's with comments and trailing commas.
EDIT_GRAMMAR :: Grammar{.Comments, .Trailing_Commas}
RECORD_GRAMMAR :: Grammar{.Comments, .Trailing_Commas}
SHAPE_GRAMMAR :: Grammar{.Comments, .Trailing_Commas}

// The features that spell a token other than as JSON does.
OWN_SPELLING :: Grammar{.Json5_Keys, .Json5_Scalars}

// Whether `d` reads exactly RFC 8259's grammar.
plain_json :: #force_inline proc "contextless" (d: Dialect) -> bool {
	return grammar_of(d) == {}
}

// Whether `d` reads comments, so that a `/` may begin one.
has_comments :: #force_inline proc "contextless" (d: Dialect) -> bool {
	return .Comments in grammar_of(d)
}

// Whether `d` spells a string, key or number in a way JSON does not, so a token of it is decoded by its own
// escapes and written out in JSON's spelling.
own_spelling :: #force_inline proc "contextless" (d: Dialect) -> bool {
	return grammar_of(d) & OWN_SPELLING != {}
}

// Whether the path edits and `splice` read `d`; they refuse any other as `.Bad_Option`.
edits_read :: #force_inline proc "contextless" (d: Dialect) -> bool {
	return grammar_of(d) <= EDIT_GRAMMAR
}

// Whether the record walk (`Record_Read`) reads `d` natively.
records_read :: #force_inline proc "contextless" (d: Dialect) -> bool {
	return grammar_of(d) <= RECORD_GRAMMAR
}

// Whether the typed shape walk reads `d` natively; a text of another dialect is read through its JSON spelling.
shape_reads :: #force_inline proc "contextless" (d: Dialect) -> bool {
	return grammar_of(d) <= SHAPE_GRAMMAR
}

// The cursor of a dialect walk: whitespace is `dialect_skip`, and `G` is the grammar the walk compiles in. A
// walk over a `Dialect_Cursor` is a complete `.Values` walk that never skips and never stops. `facts` receives
// each comment, attached to nothing yet. `json` reads JSON's grammar on this cursor instead (`walk_deep` reads
// strict JSON on the JSONC cursor, so its frames compile once for both).
Dialect_Cursor :: struct($G: Grammar) {
	facts: ^[dynamic]Fact,
	fault: Maybe(Error),
	oom:   bool,
	json:  bool,
}

Jsonc_Cursor :: Dialect_Cursor(GRAMMAR[.Jsonc])

// The grammar of cursor type `C`, as a constant: write it at the top of a procedure generic over the cursor.
//
//	G :: intrinsics.type_polymorphic_record_parameter_value(C, 0) when intrinsics.type_is_specialization_of(C, Dialect_Cursor) else Grammar{}
//
// Odin has no constant procedure call, so the line is spelled where it is used; `when .Feature in G` then
// deletes the feature's code from every other walk.

dialect_cursor_advance :: #force_inline proc(_: ^Dialect_Cursor($G)) {}

dialect_cursor_scalar_known :: #force_inline proc(_: ^Scanner, _: ^Dialect_Cursor($G), $Q: bit_set[Walk_Kind]) -> bool {
	return false
}

dialect_cursor_string_known :: #force_inline proc(
	_: ^Scanner,
	_: ^Dialect_Cursor($G),
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	_: bool,
) -> bool {
	return false
}

// Skip whitespace, the dialect's comments and its extra whitespace. A comment is only recognised where
// whitespace is, so a `//` or `/*` inside a string is never one. An unclosed block comment is `.Truncated`. A
// comment's bytes are checked as a string's raw bytes are: wire UTF-8, and no control byte but a tab, a line
// comment's line break, or a block comment's CR and LF.
dialect_skip :: proc(s: ^Scanner, cur: ^Dialect_Cursor($G)) {
	if cur.fault != nil {
		return
	}
	for {
		lex.skip_ws(s)
		when .Json5_Space in G {
			if json5_space(s) {
				continue
			}
		}
		when .Comments in G {
			n := u64(len(s.src))
			if s.pos >= n || s.src[s.pos] != '/' || cur.json {
				return
			}
			if s.pos+1 >= n {
				cur.fault = Error{kind = .Bad_Char, offset = s.pos}
				return
			}
			lo := s.pos
			switch s.src[s.pos+1] {
			case '/':
				// CR is JSON whitespace, so it ends a line as LF does.
				s.pos += 2
				for s.pos < n {
					comment_run(s, n, false)
					if s.pos >= n {
						break
					}
					b := s.src[s.pos]
					if b - 0x20 < 0x60 {
						s.pos += 1
					} else if b == '\n' || b == '\r' {
						break
					} else if !comment_char(s, cur) {
						return
					}
				}
				comment_note(cur, lo, s.pos)
			case '*':
				s.pos += 2
				closed := false
				for s.pos < n {
					comment_run(s, n, true)
					if s.pos >= n {
						break
					}
					b := s.src[s.pos]
					if b - 0x20 < 0x60 {
						if b == '*' && s.pos+1 < n && s.src[s.pos+1] == '/' {
							s.pos += 2
							closed = true
							break
						}
						s.pos += 1
					} else if b == '\n' || b == '\r' {
						s.pos += 1
					} else if !comment_char(s, cur) {
						return
					}
				}
				if !closed {
					cur.fault = Error{kind = .Truncated, offset = n}
					s.pos = n
					return
				}
				comment_note(cur, lo, s.pos)
			case:
				cur.fault = Error{kind = .Bad_Char, offset = s.pos}
				return
			}
			continue
		}
		return
	}
}

// Steps over a comment's bytes 16 at a time while they are printable ASCII, and under `block` no `*`. It
// stops on the first other byte, or where fewer than 16 bytes are left, for the byte loop to check.
@(private = "file")
comment_run :: #force_inline proc(s: ^Scanner, n: u64, $block: bool) {
	when !SCAN_FORCE_SLOW {
		for s.pos + 16 <= n {
			v := lex.load16(s.src, s.pos)
			stop := simd.lanes_ge(v - 0x20, 0x60)
			when block {
				stop |= simd.lanes_eq(v, '*')
			}
			if lex.any_lane(stop) {
				s.pos += lex.first_stop_lane(stop)
				return
			}
			s.pos += 16
		}
	}
}

// A comment's byte at `s.pos` that is neither printable ASCII nor a line break, checked as a string's raw
// byte is: a tab passes, another control byte is `.Bad_Char`, and a UTF-8 sequence is stepped over or
// refused as `utf8_step_checked` refuses it. False, with the fault on `cur` and `s.pos` on its byte, when
// refused.
@(private = "file", cold)
comment_char :: proc(s: ^Scanner, cur: ^Dialect_Cursor($G)) -> bool {
	b := s.src[s.pos]
	if b == '\t' {
		s.pos += 1
		return true
	}
	if b < 0x80 {
		cur.fault = Error{kind = .Bad_Char, offset = s.pos}
		return false
	}
	if err := lex.utf8_step_checked(s); err != nil {
		cur.fault = err
		return false
	}
	return true
}

@(private = "file")
comment_note :: proc(cur: ^Dialect_Cursor($G), lo, hi: u64) {
	if cur.facts != nil {
		if _, err := append(cur.facts, Fact{lo = lo, hi = hi, node = NO_NODE}); err != nil {
			cur.oom = true
		}
	}
}

// The dialect walk of the value at `s.pos`, which a `dialect_skip` has already reached: a complete `.Values`
// walk for the kinds in `$Q`, never skipping and never stopping. A comment's fault outranks the walk's, which
// only met the byte the comment left it on. `s` holds a cap of at most MAX_DEPTH (`dialect_walk_deep` takes a
// larger one).
dialect_walk :: #force_no_inline proc(s: ^Scanner, q: ^Query_Ctx, $Q: bit_set[Walk_Kind], cur: ^Dialect_Cursor($G)) -> Maybe(Error) {
	err := walk_value_q(s, q, s.limits.max_depth, .Values, Q, cur, false, false)
	if cur.fault != nil {
		return cur.fault
	}
	return err
}

// `dialect_walk` under a cap past MAX_DEPTH, on `walk_deep`.
dialect_walk_deep :: proc(s: ^Scanner, q: ^Query_Ctx, $Q: bit_set[Walk_Kind], cur: ^Dialect_Cursor($G)) -> Maybe(Error) {
	err := walk_deep(s, q, s.limits.max_depth, .Values, Q, cur, false, nil)
	if cur.fault != nil {
		return cur.fault
	}
	return err
}

// `finish` for a dialect: comments and the dialect's whitespace may follow the value.
dialect_finish :: proc(s: ^Scanner, cur: ^Dialect_Cursor($G)) -> Maybe(Error) {
	dialect_skip(s, cur)
	if cur.fault != nil {
		return cur.fault
	}
	if s.pos != u64(len(s.src)) {
		return Error{offset = s.pos, kind = .Trailing}
	}
	return nil
}

// Check `src` in dialect `G`, every value as `.Strict` checks it. `facts` receives each comment, attached to
// nothing, and nil records none.
dialect_validate :: proc(src: []byte, facts: ^[dynamic]Fact, limits: Limits, $G: Grammar) -> Maybe(Error) {
	s := enter_document(src, limits, DEPTH_CEILING)
	cur := Dialect_Cursor(G){facts = facts}
	dialect_skip(&s, &cur)
	err: Maybe(Error)
	if s.limits.max_depth > MAX_DEPTH {
		err = dialect_walk_deep(&s, nil, {}, &cur)
	} else {
		err = dialect_walk(&s, nil, {}, &cur)
	}
	if err == nil {
		err = dialect_finish(&s, &cur)
	}
	if err == nil && cur.oom {
		return Error{kind = .Out_Of_Memory}
	}
	return err
}

// `dialect_validate` for a dialect named at run time.
validate_dialect :: proc(src: []byte, dialect: Dialect, facts: ^[dynamic]Fact, limits: Limits) -> Maybe(Error) {
	switch dialect {
	case .Json:
	case .Jsonc:
		return dialect_validate(src, facts, limits, GRAMMAR[.Jsonc])
	case .Json5:
		return dialect_validate(src, facts, limits, GRAMMAR[.Json5])
	}
	if limits.max_depth > MAX_DEPTH {
		return scan_plain_deep(src, .Strict, limits)
	}
	return scan_plain(src, .Strict, limits)
}

// The hook table of dialect `d` (walk/hooks.odin): a path re-entry re-reads its array on the dialect's walk,
// and an escaped token decodes by the dialect's escapes.
hooks_of :: proc(d: Dialect) -> ^walk.Format_Hooks {
	switch d {
	case .Json:
	case .Jsonc:
		return &FORMAT_HOOKS_JSONC
	case .Json5:
		return &FORMAT_HOOKS_JSON5
	}
	return &FORMAT_HOOKS
}

@(rodata, private = "file")
FORMAT_HOOKS_JSONC := walk.Format_Hooks{
	escaped_key_equals = name_equals,
	path_subwalk = path_subwalk_jsonc,
	dom_unescape_into = dom_unescape_into,
}

@(rodata, private = "file")
FORMAT_HOOKS_JSON5 := walk.Format_Hooks{
	escaped_key_equals = json5_name_equals,
	path_subwalk = path_subwalk_json5,
	dom_unescape_into = json5_unescape_into,
}

@(private = "file")
path_subwalk_jsonc :: proc(s: ^walk.Scanner, ctx: ^walk.Query_Ctx, max_depth: u64, halted: ^bool) -> Maybe(Error) {
	return path_subwalk_dialect(s, ctx, max_depth, halted, GRAMMAR[.Jsonc])
}

@(private = "file")
path_subwalk_json5 :: proc(s: ^walk.Scanner, ctx: ^walk.Query_Ctx, max_depth: u64, halted: ^bool) -> Maybe(Error) {
	return path_subwalk_dialect(s, ctx, max_depth, halted, GRAMMAR[.Json5])
}

@(private = "file")
path_subwalk_dialect :: #force_inline proc(s: ^walk.Scanner, ctx: ^walk.Query_Ctx, max_depth: u64, halted: ^bool, $G: Grammar) -> Maybe(Error) {
	if max_depth > MAX_DEPTH {
		return walk_deep(s, ctx, max_depth, .Values, {.Path}, &Dialect_Cursor(G){}, true, halted)
	}
	return walk_value_q(s, ctx, max_depth, .Values, {.Path}, &Dialect_Cursor(G){}, false, true, halted)
}
