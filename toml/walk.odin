// `runtime` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
// The walk of a TOML text. A text names a member where it is written and a table's members may be written apart, so the
// walk reads the whole text into a table tree (tree.odin, parse.odin), which judges every byte and the rules on keys
// and tables, and then replays the tree to the hook in document order. The tokens are the same for `validate`, which
// stops after the tree. A walk allocates the tree on the default heap.
package toml

import "base:runtime"
import core "../core"
import engine "../core/build"

// The version of the language a text is read as. 1.1 adds forms and removes none, so a text of 1.0 reads alike under both.
// The additions are the `\e` and `\xHH` escapes, optional seconds in a time, and line ends, comments and a trailing comma
// inside an inline table.
Spec :: enum u8 {
	Toml_1_0,
	Toml_1_1,
}

// Run-time options for a walk.
Options :: struct {
	// The deepest nesting a text may have, 0 for `MAX_DEPTH`. Tables a header names count as nested, as do arrays and
	// inline tables.
	max_depth: u32,
}

// The `core.Fault.detail` values a TOML text's faults use.
Detail :: enum u8 {
	None,
	Cut_Utf8, // `Truncated`, where the text ends inside a UTF-8 sequence
	Invalid_Utf8, // `Bad_Char`, at the lead byte of an ill-formed sequence
	Control_Char, // `Bad_Char`, a control character other than a tab in a string or comment
	Lone_Cr, // `Bad_Char`, a carriage return no line feed follows
	Open_String, // `Truncated`, a string the text never closes
	Line_End_In_String, // `Bad_Char`, a line end inside a string on one line
	Bad_Quotes, // `Bad_Char`, more than two quotes before the close of a multi-line string
	Bad_Codepoint, // `Bad_Escape`, an escape of a surrogate or a value past U+10FFFF
	Leading_Zero, // `Bad_Number`, a zero before more digits
	Bad_Underscore, // `Bad_Number`, an underscore not between two digits
	Out_Of_Range, // `Bad_Number`, an integer outside 64 bits
	Bad_Datetime, // `Bad_Char`, a date or time of a field out of range or a missing part
	Expected_Key, // `Bad_Char`, a key was expected
	Expected_Equals, // `Bad_Char`, `=` was expected after a key
	Expected_Value, // `Bad_Char`, a value was expected
	Expected_Line_End, // `Bad_Char`, text after a statement
	After_Value, // `Bad_Char`, text right after a value
	Expected_Comma, // `Bad_Char`, a comma or the close of an array or inline table
	Expected_Close, // `Bad_Char`, a closing bracket was expected
	Trailing_Comma, // `Bad_Char`, a comma before the close of an inline table, which 1.0 refuses
	Redefined_Table, // `Bad_Char`, a table defined twice, or a header over a table a dotted key made
	Duplicate_Key, // `Bad_Char`, a key written twice
	Extends_Inline, // `Bad_Char`, a key or header into an inline table
	Extends_Array, // `Bad_Char`, a header into an array that no header made
	Not_Table, // `Bad_Char`, a header through a value that is no table
}

// A TOML text's rules, indexed by `Detail`. Every fault the walk returns points to this table.
@(rodata)
RULES := core.Rules{"toml", {
	{},
	{"cut_utf8", "Unfinished UTF-8 sequence"},
	{"invalid_utf8", "Invalid UTF-8"},
	{"control_char", "Control character"},
	{"lone_cr", "Carriage return not before a line feed"},
	{"open_string", "Unfinished string"},
	{"line_end_in_string", "Line end inside a string"},
	{"bad_quotes", "Too many quotes before the end of a multi-line string"},
	{"bad_codepoint", "Escape of a value that is no Unicode scalar"},
	{"leading_zero", "Leading zero in a number"},
	{"bad_underscore", "Underscore not between two digits"},
	{"out_of_range", "Integer does not fit 64 bits"},
	{"bad_datetime", "Invalid date or time"},
	{"expected_key", "Expected a key"},
	{"expected_equals", "Expected ="},
	{"expected_value", "Expected a value"},
	{"expected_line_end", "Expected the end of the line"},
	{"after_value", "Unexpected text after a value"},
	{"expected_comma", "Expected a comma or a close"},
	{"expected_close", "Expected a closing bracket"},
	{"trailing_comma", "Trailing comma in an inline table"},
	{"redefined_table", "Table defined twice"},
	{"duplicate_key", "Key defined twice"},
	{"extends_inline", "Inline table cannot be extended"},
	{"extends_array", "Array cannot be extended by a header"},
	{"not_table", "Header through a value that is no table"},
}}

@(private)
depth_limit :: #force_inline proc "contextless" (opts: Options) -> u32 {
	return opts.max_depth if opts.max_depth != 0 else core.MAX_DEPTH
}

// Reads a text of spec `S` from `lo`, past one BOM at its first byte, with hook `on`. Returns `hi`, one past the last
// byte read, or the fault. When the hook stops the walk, `hi` is one past the token it stopped on.
// The tokens are an `Object` for the text, then for each member a `Key` (`String`, role `Key`, its span with its quotes)
// and its value, in the order the text first names them, and an `End` at the text's end with `n` 0. A table is an
// `Object` token at its header, its first key or its brace, an array an `Array`, and each closes with an `End`. A
// string is a `String` whose span holds its quotes, a datetime a `String` whose span is its text and whose spelling
// names its type, a number a `Number` of its text, and `true` and `false` their kinds. A comment is a `Plain` of its
// span with the role the position gives it. A `lo` past `len(src)` reads an empty text. `regs` nil starts from zero
// registers and keeps none. With a `cursor`, a stop saves where the walk stood there for `walk_resume`.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault)) {
	if cursor != nil {
		cursor_destroy(cursor)
		cursor.src, cursor.n = raw_data(src), u64(len(src))
	}
	held: Held
	p := &held.parser
	if !parser_init(p, src, S == .Toml_1_1, depth_limit(opts)) {
		parser_destroy(p)
		return 0, core.Fault{rules = &RULES, kind = .No_Memory}
	}
	if !parse(p, lo) {
		parser_destroy(p)
		hi, fault, _ = core.result_of(p.fail, &RULES)
		return
	}
	if regs != nil {
		held.regs = regs^
	}
	return held_run(cursor, &held, h, regs, on)
}

// `Cursor` holds where a walk a hook stopped stands, for `walk_resume` to continue it: the text's address and length,
// and on the default heap the walk's table tree and the place its replay stopped at. The text is judged whole before
// the first token, so a cursor resumes after any token and no fault comes after one. A walk that ends frees what its
// cursor holds, and `cursor_destroy` frees a cursor no resume ended.
Cursor :: struct {
	src:  [^]u8,
	n:    u64,
	held: ^Held,
}

// What a cursor holds past a stop: the parsed text, the replay's place and the hook's registers.
@(private)
Held :: struct {
	parser: Parser,
	replay: Replay,
	regs:   core.Hook_Regs,
}

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.held != nil
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the token after the one it stopped on.
// `regs` is passed to the first token in place of the registers the stop saved, unless it is nil. The results are
// `walk`'s. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	held := cursor.held
	if held == nil || cursor.src != raw_data(src) || cursor.n != u64(len(src)) {
		return 0, core.Fault{rules = &RULES, kind = .Bad_Option}
	}
	if regs != nil {
		held.regs = regs^
	}
	return held_run(cursor, held, h, regs, on)
}

// Frees what `cursor` holds, a stop no resume ended. It is a member of `destroy`.
@(private)
cursor_destroy :: proc "contextless" (cursor: ^Cursor) {
	if cursor.held != nil {
		held_free(cursor, cursor.held)
	}
}

// Replays the tree `held` holds from where it stands. A stop with a `cursor` saves the walk there, and any other end
// frees it.
@(private)
held_run :: proc "contextless" (cursor: ^Cursor, held: ^Held, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	verdict := replay(&held.parser, &held.replay, h, &held.regs, on)
	if regs != nil {
		regs^ = held.regs
	}
	stopped: bool
	hi, fault, stopped = core.result_of(verdict, &RULES)
	if !stopped || cursor == nil {
		held_free(cursor, held)
		return
	}
	if cursor.held == nil {
		context = runtime.default_context()
		if cursor.held = new_clone(held^); cursor.held == nil {
			held_free(cursor, held)
			return 0, core.Fault{rules = &RULES, kind = .No_Memory}
		}
	}
	return
}

// Frees the walk `held` holds, and `cursor`'s copy of it.
@(private)
held_free :: proc "contextless" (cursor: ^Cursor, held: ^Held) {
	context = runtime.default_context()
	parser_destroy(&held.parser)
	delete(held.replay.frames)
	if cursor != nil && cursor.held == held {
		free(held)
		cursor.held = nil
	}
}

// The walk's verdict on `src` for `spec`, after one leading BOM: nil for a text that reads, else its fault. It reads the
// text into a tree on the default heap, as `walk` does, and makes no tokens. It links the walk alone, and `core.validate`
// with `as(spec, opts)` links every service of the format. The same holds for the other entry points below. A document
// an entry point builds holds no services, so `query`,
// `edit_list_init` and `write` of this package serve it where the same names of `core` serve a handle's.
validate :: proc "contextless" (src: []u8, spec: Spec, opts := Options{}) -> core.Error {
	return core.error_of(validate_text(src, spec, opts))
}

@(private)
validate_text :: proc "contextless" (src: []u8, spec: Spec, opts: Options) -> Maybe(core.Fault) {
	p: Parser
	if !parser_init(&p, src, spec == .Toml_1_1, depth_limit(opts)) {
		parser_destroy(&p)
		return core.Fault{rules = &RULES, kind = .No_Memory}
	}
	defer parser_destroy(&p)
	if !parse(&p, 0) {
		_, fault, _ := core.result_of(p.fail, &RULES)
		return fault
	}
	return nil
}

@(private)
Frame :: struct {
	node, next: u32,
}

// The next token a replay gives: the text's `Object`, a member's comments, key, value and the comment on its line, and
// a container's foot comments, `End` and the comment on the line it closes.
@(private)
Phase :: enum u8 {
	Open,
	Pick, // the next member of the open container, or its close
	Head,
	Key,
	Value,
	Inline,
	Foot,
	End,
	Closed,
	Done,
}

// Where a replay stands: the open containers, the member or container `id` the phase is at, and the comments of its
// run given so far. A zero `Replay` starts at the text's `Object`.
@(private)
Replay :: struct {
	frames: [dynamic]Frame,
	id:     u32,
	k:      u32,
	phase:  Phase,
}

@(private)
Run :: struct {
	stopped: bool,
	at:      u64,
}

@(private)
emit :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, r: ^Run, t: core.Token) -> core.Action {
	a: core.Action
	hs^, a = on(h, hs^, t)
	if a == .Stop {
		r.stopped, r.at = true, t.lo + u64(t.n)
	}
	return a
}

@(private)
comment_token :: #force_inline proc "contextless" (c: Comment, role: core.Role) -> core.Token {
	return {c.lo, c.n, .Plain, role, core.comment_spelling(1, 0)}
}

// Passes the tree to the hook in document order, from where `s` stands: a table's members in the order the text first
// names them. A stop leaves `s` at the token after the one the hook stopped on, and the result is the stop's.
@(private)
replay :: proc "contextless" (p: ^Parser, s: ^Replay, h: ^$H, hs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	context = runtime.default_context()
	nodes := p.tree.nodes[:]
	r: Run
	for {
		switch s.phase {
		case .Open:
			if _, e := append(&s.frames, Frame{0, nodes[0].first}); e != nil {
				return core.fault_at(0, .No_Memory)
			}
			s.phase = .Pick
			emit(h, on, hs, &r, core.Token{0, 0, .Object, .Value, 0})
		case .Pick:
			if len(s.frames) == 0 {
				s.phase = .Done
				continue
			}
			f := &s.frames[len(s.frames) - 1]
			s.k = 0
			if f.next == NIL {
				s.id, s.phase = f.node, .Foot
				pop(&s.frames)
			} else {
				s.id, s.phase = f.next, .Head
				f.next = nodes[f.next].next
			}
			continue
		case .Head:
			x := &nodes[s.id]
			if s.k == x.heads {
				s.phase = .Key
				continue
			}
			s.k += 1
			emit(h, on, hs, &r, comment_token(p.tree.comments[x.head + s.k - 1], .Comment))
		case .Key:
			x := &nodes[s.id]
			s.phase = .Value
			if nodes[x.parent].kind != .Table {
				continue
			}
			if emit(h, on, hs, &r, x.key) == .Skip {
				s.phase = .Inline
			}
		case .Value:
			x := &nodes[s.id]
			s.phase = .Inline
			if x.kind == .Scalar {
				emit(h, on, hs, &r, x.value)
			} else if emit(h, on, hs, &r, core.Token{x.value.lo, 0, .Object if x.kind == .Table else .Array, .Value, 0}) != .Skip {
				if _, e := append(&s.frames, Frame{s.id, x.first}); e != nil {
					return core.fault_at(x.value.lo, .No_Memory)
				}
				s.phase = .Pick
			}
		case .Inline:
			s.phase = .Pick
			if c := nodes[s.id].inline; c.n != 0 {
				emit(h, on, hs, &r, comment_token(c, .Comment_Inline))
			}
		case .Foot:
			x := &nodes[s.id]
			if s.k == x.foots {
				s.phase = .End
				continue
			}
			s.k += 1
			emit(h, on, hs, &r, comment_token(p.tree.comments[x.foot + s.k - 1], .Comment_Foot))
		case .End:
			s.phase = .Closed if s.id != 0 else .Pick
			emit(h, on, hs, &r, core.Token{u64(len(p.src)) if s.id == 0 else 0, 0, .End, .Value, 0})
		case .Closed:
			s.phase = .Pick
			if c := nodes[s.id].inline; c.n != 0 {
				emit(h, on, hs, &r, comment_token(c, .Comment_Inline))
			}
		case .Done:
			return core.fault_at(u64(len(p.src)), .None)
		}
		if r.stopped {
			return core.fault_at(r.at, .None, core.STOPPED)
		}
	}
}

// Reads a text as spec `spec` into a document, allocating its nodes with `allocator`. The document borrows `src`, which
// must outlive it, and `destroy` frees it. A table is one `Object` whose members are in the order the text first names
// them, wherever the text writes them. `dups` has no effect, since a repeated key is a fault.
build :: proc(src: []u8, spec: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := build_text(src, bound_as(spec, opts), allocator)
	return doc, core.error_of(err)
}

// The path reads of `core/build`. `scan`, `each_answer`, `find` and `set` take `spec` and `opts`. A read builds the whole
// document and answers from it, since a table's members may be written apart.
scan :: proc {scan_one, scan_many}

@(private)
scan_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_many(src, spec, []core.Path{path}, opts, read, allocator)
}

@(private)
scan_many :: proc(src: []u8, spec: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := scan_text(src, bound_as(spec, opts), paths, read, nil, nil, allocator)
	return doc, core.error_of(err)
}

each_answer :: proc {each_answer_one, each_answer_many}

@(private)
each_answer_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_many(src, spec, []core.Path{path}, state, on, opts, read, allocator)
}

@(private)
each_answer_many :: proc(src: []u8, spec: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	doc, err := scan_text(src, bound_as(spec, opts), paths, read, state, on, allocator)
	core.destroy(&doc)
	return core.error_of(err)
}

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in toml.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `path` is read at the first `next`, which
// builds the whole text, as every path read of TOML does.
answers :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(spec, opts), nil, path, read, allocator)
}

find :: proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	doc, err = scan_one(src, spec, engine.first_path(path), opts, read, allocator)
	return doc, engine.first_answer(&doc), err
}
