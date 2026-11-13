// `write` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
// JSON's walk: each grammar state is a procedure that tail-calls the next with `#must_tail` (states.odin). A state
// reads the first byte of its token and branches on it. Strings (strings.odin), numbers and literals (scalars.odin)
// and whitespace (whitespace.odin) are read by leaf procedures.
package json

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"
import engine "../core/build"
import typed "../core/typed"
import write "../core/write"

// `Spec` is the grammar a text follows, a compile-time parameter, so a build compiles only the specs it names.
Spec :: enum u8 {
	Json, // RFC 8259
	Jsonc, // RFC 8259 with `//` and `/* */` comments wherever whitespace may stand, and a comma before a close bracket
	Json5, // JSON5 1.0.0
}

// A `Feature` names a rule set a spec adds to RFC 8259. States test features with `when`, so a spec's walk compiles
// only its own rules.
@(private)
Feature :: enum u8 {
	Comments,
	Trailing_Commas,
	Es5, // JSON5's ECMAScript forms: its numbers, strings, unquoted keys and whitespace (json5.odin)
}

// `FEATURES` holds the features of each spec. Both specs with comments also have trailing commas: a close bracket
// after a comment run is read without checking whether an open bracket or a comma came before the run.
@(private)
FEATURES :: [Spec]bit_set[Feature] {
	.Json  = {},
	.Jsonc = {.Comments, .Trailing_Commas},
	.Json5 = {.Comments, .Trailing_Commas, .Es5},
}

// `Options` holds a walk's run-time options. The zero value is the default.
Options :: struct {
	// The deepest nesting a text may have, 0 for `MAX_DEPTH`. A depth up to `MAX_DEPTH` keeps the stack in
	// `walk_document`'s frame, and a larger one allocates one byte per level on the default heap.
	max_depth: u32,
	// The rules a text may break, each with a fixed reading. Empty by default.
	tolerate:          bit_set[core.Tolerance; u8],
	// Refuse JSON5's `Infinity` and `NaN` as `.Bad_Char` with `Detail.Non_Finite`, for a reader that has no value for
	// them.
	refuse_non_finite: bool,
}

// `Detail` holds JSON's detail for a `core.Fault_Kind`, in `core.Fault.detail`. The walk's states and `describe`
// choose it once a fault is found, from the byte and the state that refused it.
Detail :: enum u8 {
	None,
	Literal, // `Bad_Char`: a byte breaking `true`, `false` or `null`, or a word that is none of them
	Identifier, // `Bad_Char`: JSON5 only, a byte that starts no key, quoted or not, where an object's key must start
	Colon, // `Bad_Char`: a byte where a member's colon must be
	Trailing, // `Bad_Char`: the first byte after the document that is no whitespace or comment
	Unframed, // `Bad_Char`: under `.Seq` records, the first byte before the first 0x1E that is no whitespace
	Cut_Number, // `Bad_Number`: under `.Seq` records, a record that is a number with no whitespace after it, at its end
	Non_Finite, // `Bad_Char`: JSON5's `Infinity` or `NaN`, under `Options.refuse_non_finite`, or either word in JSON, `Bad_Number` after a minus
	Array_Separator, // `Bad_Char`: a byte after an array's element that is no comma and no `]`
	Member_Separator, // `Bad_Char`: a byte after an object's member that is no comma and no `}`
	Trailing_Comma, // `Bad_Char`: a container's close right after a comma
	Lone_Comma, // `Bad_Char`: a comma where a value or a key must start
	Unmatched_Bracket, // `Bad_Char`: a `]` that closes no array
	Unmatched_Brace, // `Bad_Char`: a `}` that closes no object
	Single_Quote, // `Bad_Char`: a `'` where a string must start
	Control_Char, // `Bad_Char`: a byte below 0x20 that is no whitespace there, as in a string
	Invalid_Utf8, // `Bad_Char`: at the lead byte of an ill-formed UTF-8 sequence
	Leading_Zero, // `Bad_Number`: a digit after a number's leading zero
	Leading_Dot, // `Bad_Char`: a `.` where a value must start
	Leading_Plus, // `Bad_Char`: a `+` where a value must start
	Key_Not_String, // `Bad_Char`: a byte that opens no string where an object's key must start
	Expected_Value, // `Bad_Char`: any other byte where a value must start
}

// `RULES` is JSON's `core.Rules`, one per `Detail` value, which every fault the walk returns points to.
@(rodata)
RULES := core.Rules{"json", {{}, {"literal", "Invalid literal"}, {"identifier", "Invalid unquoted key"}, {"colon", "Missing colon after key"}, {"trailing", "Unexpected text after the value"}, {"unframed", "Text before the first RS"}, {"cut_number", "Potentially truncated top-level numeric value"}, {"non_finite", "Infinity and NaN have no JSON value"}, {"array_separator", "Expected ',' or ']' after an array element"}, {"member_separator", "Expected ',' or '}' after an object member"}, {"trailing_comma", "Trailing comma before the closing bracket"}, {"lone_comma", "Expected value before ','"}, {"unmatched_bracket", "Unmatched ']'"}, {"unmatched_brace", "Unmatched '}'"}, {"single_quote", "Invalid string literal; expected \", but got '"}, {"control_char", "Unescaped control character"}, {"invalid_utf8", "Invalid UTF-8"}, {"leading_zero", "Leading zero in a number"}, {"leading_dot", "A number cannot start with '.'"}, {"leading_plus", "A number cannot start with '+'"}, {"key_not_string", "Object keys must be strings"}, {"expected_value", "Expected a value"}}}

// The detail for the byte at `p` where a value must start and none does, in container `d` (the states' `d`). A close
// of its own array there follows a comma, since an empty container's close is read where it opens, and an object's
// value follows its colon.
@(private, cold)
value_detail :: proc "contextless" (p, end: [^]u8, d: u64) -> Detail {
	b := p[0]
	switch b {
	case ']', '}':
		if d < 2 || b != ']' | u8(d & 1) << 5 {
			return .Unmatched_Bracket if b == ']' else .Unmatched_Brace
		}
		return .Expected_Value if d & 1 != 0 else .Trailing_Comma
	case ',':
		return .Lone_Comma
	case '\'':
		return .Single_Quote
	case '.':
		return .Leading_Dot
	case '+':
		return .Leading_Plus
	case 'N', 'I':
		if non_finite_word(p, end) {
			return .Non_Finite
		}
	}
	if 'a' <= b | 0x20 && b | 0x20 <= 'z' {
		return .Literal
	}
	return byte_detail(p, end, .Expected_Value)
}

// The detail for the byte at `p` where an object's key must start and no string does. A close of the object there
// follows a comma, since an empty object's close is read where it opens.
@(private, cold)
key_detail :: proc "contextless" (p, end: [^]u8) -> Detail {
	switch p[0] {
	case '}':
		return .Trailing_Comma
	case ']':
		return .Unmatched_Bracket
	case ',':
		return .Lone_Comma
	case '\'':
		return .Single_Quote
	}
	return byte_detail(p, end, .Key_Not_String)
}

// The detail for the byte at `p` after a value of container `d`, which is no comma and no close of that container.
@(private, cold)
after_detail :: proc "contextless" (p: [^]u8, d: u64) -> Detail {
	switch p[0] {
	case ']':
		return .Unmatched_Bracket
	case '}':
		return .Unmatched_Brace
	}
	return .Member_Separator if d & 1 != 0 else .Array_Separator
}

// `.Control_Char` for a control byte at `p`, `.Invalid_Utf8` for the lead of an ill-formed UTF-8 sequence, else `other`.
@(private, cold)
byte_detail :: proc "contextless" (p, end: [^]u8, other: Detail) -> Detail {
	if p[0] < 0x20 {
		return .Control_Char
	}
	if p[0] >= 0x80 {
		if _, kind := spell.utf8_char(p, end); kind == .Bad_Char {
			return .Invalid_Utf8
		}
	}
	return other
}

// The byte before src[at] and the whitespace before it, or 0 at the text's start.
@(private, cold)
byte_before :: proc "contextless" (src: []u8, at: u64) -> u8 {
	for i := at; i > 0; i -= 1 {
		if b := src[i - 1]; b != ' ' && b != '\t' && b != '\n' && b != '\r' {
			return b
		}
	}
	return 0
}

// Whether `p` starts the word `NaN` or `Infinity`.
@(private, cold)
non_finite_word :: proc "contextless" (p, end: [^]u8) -> bool {
	n := intrinsics.ptr_sub(end, p)
	for word in ([]string{"NaN", "Infinity"}) {
		if n >= len(word) && string(p[:len(word)]) == word {
			return true
		}
	}
	return false
}

// `f` with the detail a string's or a number's fault names, which their readers return as a kind alone: a control
// byte or an ill-formed UTF-8 sequence in a string, a leading zero, or a minus before `Infinity` or `NaN`, and the
// detail of a key RFC 8259's `st_key` refuses. A `}` after a colon is a missing value, wherever the walk read it.
@(private, cold)
describe :: #force_no_inline proc "contextless" (src: []u8, f: core.Fault, $S: Spec) -> core.Fault {
	f := f
	// A skipped member's value is read as a root, where a `}` is unmatched.
	if f.detail == u8(Detail.Unmatched_Brace) && byte_before(src, f.at) == ':' {
		f.detail = u8(Detail.Expected_Value)
	}
	if f.detail != 0 || f.at >= u64(len(src)) {
		return f
	}
	p := raw_data(src)
	end := p[len(src):]
	q := p[f.at:]
	#partial switch f.kind {
	case .Bad_Char:
		f.detail = u8(byte_detail(q, end, .None))
		if b := byte_before(src, f.at); f.detail == 0 && (b == '{' || b == ',') {
			f.detail = u8(key_detail(q, end))
		}
	case .Bad_Number:
		when S != .Json5 {
			lo := f.at
			for lo > 0 && (src[lo - 1] - '0' < 10 || src[lo - 1] == '-') {
				lo -= 1
			}
			digits := lo + 1 if src[lo] == '-' else lo
			if f.at == digits && f.at > lo && non_finite_word(q, end) {
				f.detail = u8(Detail.Non_Finite)
			} else if f.at == digits + 1 && src[digits] == '0' && src[f.at] - '0' < 10 {
				f.detail = u8(Detail.Leading_Zero)
			}
		}
	}
	return f
}

// Checks that `src` holds exactly one document: an optional leading BOM, the document, then whitespace and, in a
// spec with comments, comments up to the text's end. Returns the fault, or nil. A constant `spec` links the walk of that
// spec alone. A `spec` chosen at run time is `core.validate` with `as(spec, opts)` and links every spec's walk. The same
// holds for the other entry points below, and the forms that take a `Document` give it the readers of the spec.
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> core.Error {
	h: core.No_Hooks
	regs: core.Hook_Regs
	return core.error_of(walk_text(src, 0, S, opts, &h, &regs, core.no_hook))
}

// Reads `src` as spec `spec` into a document, as `core.build` does with `as(spec, opts)`.
build :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := build_spec(src, S, bound_as(S, opts), dups == .Refuse, allocator)
	return doc, core.error_of(err)
}

// The path reads of `core/build`. `scan`, `each_answer`, `find` and `set` take `spec` and `opts`.
scan :: proc {scan_one, scan_many}

@(private)
scan_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_many(src, S, []core.Path{path}, opts, read, allocator)
}

@(private)
scan_many :: proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	if read.dups == .Refuse {
		built, e := build(src, S, opts, .Refuse, allocator)
		return engine.query_built(&built, e, paths, read)
	}
	doc, err := scan_spec(src, S, bound_as(S, opts), paths, read, nil, nil, allocator)
	return doc, core.error_of(err)
}

each_answer :: proc {each_answer_one, each_answer_many}

@(private)
each_answer_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_many(src, S, []core.Path{path}, state, on, opts, read, allocator)
}

@(private)
each_answer_many :: proc(src: []u8, $S: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	if read.dups == .Refuse {
		built, e := build(src, S, opts, .Refuse, allocator)
		core.destroy(&built)
		if e != nil {
			return e
		}
	}
	doc, err := scan_spec(src, S, bound_as(S, opts), paths, read, state, on, allocator)
	core.destroy(&doc)
	return core.error_of(err)
}

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in json.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `paths` is read at the first `next`.
answers :: proc {answers_one, answers_many}

@(private)
answers_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(S, opts), nil, path, read, allocator, answers_fill(S))
}

@(private)
answers_many :: #force_inline proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(S, opts), paths, {}, read, allocator, answers_fill(S))
}

find :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = scan_one(src, S, one, opts, read, allocator)
	answer = doc.answers[0] if len(doc.answers) > 0 else {core.NO_NODE, core.NO_NODE, 0, .Missing}
	return
}

// Makes `v` the value at every answer of `path` over `src`, in one call, and returns the new text, which the caller frees
// with `allocator`. A `typed.Raw` is the text of a value, a struct, a slice or a map is built by `plan`, and any other
// value is spelled by the format. A `Name` the path ends in that its container lacks is inserted after the container's
// last member. `read.dups` picks among a repeated key as `query` does, and sets each repeat under `.All`.
set :: proc(src: []u8, $S: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	scratch: write.Scratch
	defer write.scratch_destroy(&scratch)
	in_ := write.edit_input(v, plan, &scratch) or_return
	doc, berr := build(src, S, opts, read.dups, allocator)
	defer core.destroy(&doc)
	if berr != nil {
		return nil, berr
	}
	list := edit_list_init(&doc, S, allocator)
	defer core.edit_list_destroy(&list)
	return engine.set_answers(&list, path, in_, read, allocator)
}

// Answers `path` or `paths` over a document built whole, as `core.query` does. A document read as a constant spec holds
// no services, so `core.query` does not answer for it.
query :: proc {query_one, query_many}

@(private)
query_one :: proc(doc: ^core.Document, path: core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error) {
	return query_many(doc, []core.Path{path}, read, allocator)
}

@(private)
query_many :: proc(doc: ^core.Document, paths: []core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error) {
	if doc == nil || doc.readers == nil {
		return nil, core.error_of(core.Path_Error{kind = .Unsupported})
	}
	found, refusal := engine.query(doc, paths, read, allocator)
	return found, core.error_of(refusal)
}

// Returns an edit list over `doc`. A document read as a constant spec holds no edit services, so the list takes the
// spec's.
edit_list_init :: proc(doc: ^core.Document, $S: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = edit_of(S)
	return list
}

// Writes node `node` of `doc` as spec `spec`, as `core.write` does with `as(spec)`.
write :: proc(doc: ^core.Document, $S: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	if int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	out, cut, refusal := write_text(doc, opts, bound_as(S), node, {}, allocator)
	return out, cut, core.error_of(refusal)
}

// Whether `src` holds no document: past an optional leading BOM, only the spec's whitespace and, in a spec with
// comments, comments that end. `validate` refuses such a text with `Truncated`, as it does a document cut short.
blank :: proc "contextless" (src: []u8, spec: Spec) -> bool {
	p := raw_data(src)
	end := p[len(src):]
	q := p[core.text_start(src, 0):]
	switch spec {
	case .Json:  return gap_end(q, end, .Json) == end
	case .Jsonc: return gap_end(q, end, .Jsonc) == end
	case .Json5: return gap_end(q, end, .Json5) == end
	}
	return false
}

// Reads `src` from `lo` as exactly one document through the hook, as `validate` checks it. A BOM is passed over only
// at the text's first byte. A hook that stops the walk ends the read with no fault. Returns the fault, or nil.
@(private)
walk_text :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> Maybe(core.Fault) {
	p := raw_data(src)
	end := p[len(src):]
	r := walk_document(src, skip_ws(p[core.text_start(src, lo):], end), S, opts, h, regs, on)
	hi, fault, stopped := core.result_of(r, &RULES)
	if f, bad := fault.?; bad {
		return describe(src, f, S)
	}
	if stopped {
		return nil
	}
	return tail_fault(src, hi, S)
}

// Returns the fault for the bytes after a document that ends at `hi`, or nil when only whitespace and, in a spec
// with comments, comments up to the text's end follow it. Any other byte faults `Bad_Char` with `Detail.Trailing`.
@(private)
tail_fault :: proc "contextless" (src: []u8, hi: u64, $S: Spec) -> Maybe(core.Fault) {
	p := raw_data(src)
	end := p[len(src):]
	q := p[hi:]
	when .Comments in FEATURES[S] {
		kind: core.Fault_Kind
		q, _, kind = comment_run(q, end, false, S)
		if kind != .None {
			return describe(src, core.Fault{at = u64(intrinsics.ptr_sub(q, p)), rules = &RULES, kind = kind, detail = u8(Detail.Trailing) if stray_slash(q, kind) else 0}, S)
		}
	} else {
		q = skip_ws(q, end)
	}
	if q != end {
		return core.Fault{at = u64(intrinsics.ptr_sub(q, p)), rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Trailing)}
	}
	return nil
}

// Reads one document starting at `lo`. Returns one past its last byte and the fault, or nil. Before the document it
// passes over one BOM at the text's first byte, whitespace, record separators 0x1E, and comments that no document
// follows before the text's end or a 0x1E, so a stream of documents (NDJSON, RFC 7464, jq's input) is a loop of
// walks from where the last one ended. Outside a string a later BOM faults `Bad_Char` in JSON and JSONC and is
// whitespace in JSON5. When only those bytes remain, or `lo` is past the text's end, no token is made and the text's
// end is returned with no fault. When a hook stops the walk, `hi` is one past the token it stopped on and no later
// byte was read, so `hi` is no document boundary. `regs` is passed to the first token and holds what the hook
// returned last, and a nil `regs` starts from zero registers and keeps none. `opts` is `Options{}` by default. With a
// `cursor`, the walk keeps its depth stack in `cursor.stack`, and a stop saves where it stood there for `walk_resume`.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault)) {
	// The nil test runs once per walk, not per token.
	zero: core.Hook_Regs
	r := regs
	if r == nil {
		r = &zero
	}
	q, _ := document_start(src, lo, S)
	if cursor != nil {
		return walk_saving(src, q, S, opts, h, r, on, cursor)
	}
	h2, f2, _ := walk_from(src, q, S, opts, h, r, on)
	return h2, f2
}

// `Cursor` holds where a walk a hook stopped stands, for `walk_resume` to continue it: the token's end, the depth and
// indent there, the hook's registers, the state that follows, and the text's address and length. A walk given a cursor
// keeps its depth stack in `stack`, the caller's storage of one byte a level, so the deepest a text may nest is
// `len(stack)` when that is below `Options.max_depth`. A stop inside a run of comments also holds the run's end, the
// role its other comments take, whether the next one is still on the line of the value before the run, and whether
// the run crossed a comma. A cursor is for a walk whose hook holds its own state, a scan's or a caller's.
Cursor :: struct {
	stack:   []u8,
	src:     [^]u8,
	n:       u64,
	pos:     u64,
	d:       u64,
	ind:     u64,
	held:    u64, // the depth the stacks hold, which the walk checks an open bracket against
	regs:    core.Hook_Regs,
	run_end: u64,
	next:    Follow,
	role:    core.Role,
	inline:  bool,
	crossed: bool,
}

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended or faulted.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.next != .None
}

// The state a resumed walk enters, `.None` when the cursor holds no stop.
@(private)
Follow :: enum u8 {
	None,
	After, // `st_after`: past a value, at depth `d`
	Open, // `st_open`: past an open bracket, `d` the container's
	Colon, // `st_colon`: past a key
	Comments_Value, // the rest of a comment run before a value, then `st_value`
	Comments_Key, // the rest of a comment run before a key, then `st_key`
	Comments_Colon, // the rest of a comment run before a colon, then `st_colon`
	Comments_After, // the rest of a comment run after a value, then what follows the run
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the state after the token it stopped on.
// `regs` is passed to the first token in place of the registers the stop saved, unless it is nil. The results are
// `walk`'s. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	if cursor.next == .None || cursor.src != raw_data(src) || cursor.n != u64(len(src)) {
		return 0, core.Fault{rules = &RULES, kind = .Bad_Option}
	}
	if regs != nil {
		cursor.regs = regs^
	}
	next := cursor.next
	cursor.next = .None
	r := resume_document(src, cursor, next, S, opts, h, on)
	if regs != nil {
		regs^ = cursor.regs
	}
	hi, fault, _ = core.result_of(r, &RULES)
	if f, bad := fault.?; bad {
		fault = describe(src, f, S)
	}
	return
}

// `walk_from` for a walk with a cursor, whose stack and registers are the cursor's.
@(private)
walk_saving :: proc "contextless" (src: []u8, q: [^]u8, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor) -> (hi: u64, fault: Maybe(core.Fault)) {
	cursor.src, cursor.n, cursor.next, cursor.regs = raw_data(src), u64(len(src)), .None, regs^
	if q == raw_data(src)[len(src):] {
		return u64(len(src)), nil
	}
	w := cursor_walk(src, cursor, S, opts, h)
	w.depth = depth_held(h, &cursor.regs, w.limit, w.limit)
	r := st_value(q, w.base[len(src):], 0, INDENT_START, &w, cursor.regs.a, cursor.regs.b, cursor.regs.c, on)
	regs^ = cursor.regs
	hi, fault, _ = core.result_of(r, &RULES)
	if f, bad := fault.?; bad {
		fault = describe(src, f, S)
	}
	return
}

// A walk of `src` whose stack and registers are `cursor`'s. The deepest a text may nest is the limit `opts` sets or the
// stack's length, whichever is less. The caller sets the depth it checks first.
@(private)
cursor_walk :: #force_inline proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts: Options, h: ^$H) -> Walk(S, H) {
	limit := min(u64(opts.max_depth) if opts.max_depth != 0 else core.MAX_DEPTH, u64(len(cursor.stack)))
	return Walk(S, H){raw_data(src), h, raw_data(cursor.stack), &cursor.regs, 0, kernel.tier(), false, opts.tolerate, opts.refuse_non_finite, false, true, nil, 0, limit}
}

// Enters state `next` at the place `cursor` saved, in a walk whose stack and registers are the cursor's.
@(private)
resume_document :: proc "contextless" (src: []u8, cursor: ^Cursor, next: Follow, $S: Spec, opts: Options, h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	w := cursor_walk(src, cursor, S, opts, h)
	w.depth = min(cursor.held, w.limit)
	p, end := w.base[cursor.pos:], w.base[len(src):]
	d, ind := cursor.d, cursor.ind
	hs := cursor.regs
	switch next {
	case .None:
	case .After:
		return st_after(p, end, d, ind, &w, hs.a, hs.b, hs.c, on)
	case .Open:
		return st_open(p, end, d, ind, &w, hs.a, hs.b, hs.c, on)
	case .Colon:
		return st_colon(p, end, d, ind, &w, hs.a, hs.b, hs.c, on)
	case .Comments_Value, .Comments_Key, .Comments_Colon, .Comments_After:
		q := w.base[cursor.run_end:]
		r, stop, wide, inline := emit_comments(&w, on, &hs, p, q, cursor.inline, cursor.role)
		if wide != .None {
			return fault(&w, hs, r, wide)
		}
		if stop {
			return stopped_in_run(&w, hs, r, q, d, ind, next, cursor.role, inline, cursor.crossed)
		}
		#partial switch next {
		case .Comments_Value:
			return st_value(q, end, d, ind, &w, hs.a, hs.b, hs.c, on)
		case .Comments_Key:
			return st_key(q, end, d, ind, &w, hs.a, hs.b, hs.c, on)
		case .Comments_Colon:
			return st_colon(q, end, d, ind, &w, hs.a, hs.b, hs.c, on)
		}
		// The root's walk ends past its last comment emitted, and the rest of the run is the next document's.
		if d < 2 {
			return fault(&w, hs, r, .None)
		}
		// The run is read, so `st_comments_after` reads none of it again and goes on to what follows it.
		w.resume, w.crossed = q, cursor.crossed
		return st_comments_after(q, end, d, ind, &w, hs.a, hs.b, hs.c, on)
	}
	return core.fault_at(0, .Bad_Option)
}

// Whether `text`, at offset `at` of the input, starts with a BOM that is not the input's, which a walk in place refuses
// with `Bad_Char` in a spec where it is no whitespace, and which `build` of `text` would pass over.
@(private)
stray_bom :: #force_inline proc "contextless" (text: []u8, at: u64, spec: Spec) -> bool {
	return at > 0 && spec != .Json5 && core.text_start(text, 0) > 0
}

// Reads the run before a document, for `walk` and `build`: one BOM at the text's first byte, whitespace, record
// separators 0x1E, and comments that no document follows before the text's end or a 0x1E. Returns the document's
// first byte or the text's end, and the first 0x1E crossed, which a stream passes over and `build` refuses.
@(private)
document_start :: proc "contextless" (src: []u8, lo: u64, $S: Spec) -> (q: [^]u8, sep: [^]u8) {
	p := raw_data(src)
	end := p[len(src):]
	q = skip_ws(p[core.text_start(src, min(lo, u64(len(src)))):], end)
	for q < end {
		if q[0] == 0x1e {
			if sep == nil {
				sep = q
			}
			q = skip_ws(q[1:], end)
			continue
		}
		// A comment before the text's end or a 0x1E is the foot of the document before it, or of no document.
		when .Comments in FEATURES[S] {
			if gap(q, end, S) {
				if r, _, kind := comment_run(q, end, false, S); kind == .None && (r == end || r[0] == 0x1e) {
					q = r
					continue
				}
			}
		}
		break
	}
	return
}

// Reads the document at `q`, where `document_start` left it. Returns one past its last byte, the fault or nil, and
// whether a hook stopped the walk.
@(private)
walk_from :: #force_inline proc "contextless" (src: []u8, q: [^]u8, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault), stopped: bool) {
	if q == raw_data(src)[len(src):] {
		return u64(len(src)), nil, false
	}
	hi, fault, stopped = core.result_of(walk_document(src, q, S, opts, h, regs, on), &RULES)
	if f, bad := fault.?; bad {
		fault = describe(src, f, S)
	}
	return
}

// `Walk` holds the state a walk carries besides its registers. `stack[i]` bit 0 is set when the container at depth
// `i` is an object. The open that pushes past depth `i` writes `stack[i]`, and `depth` slots are allocated, so no slot
// is read before it is written. `tier` selects the string reader built for this CPU.
@(private)
Walk :: struct($S: Spec, $H: typeid) {
	base:     [^]u8,
	hooks:    ^H,
	stack:    [^]u8,
	regs:     ^core.Hook_Regs,
	depth:    u64,
	tier:     kernel.Tier,
	// Whether the state that passed a comment run to `st_comments_after` read the comma before it. It fills the
	// padding after `tier`, so a spec without comments builds the same `Walk` size.
	crossed:  bool,
	// `Options.tolerate`, read only where a string faults.
	tolerate: bit_set[core.Tolerance; u8],
	// `Options.refuse_non_finite`, read only where a JSON5 number is read.
	finite:   bool,
	// Whether `stack` is this walk's own, grown on the default heap by `deepen`, which the walk's end frees.
	owned:    bool,
	// Whether `stack` and `regs` are a `Cursor`'s, which a stop fills. The stack does not move, since it holds
	// `limit` levels.
	saving:   bool,
	// Where the next state continues: for `string_escaped`, the block holding the string's first backslash, for
	// `st_comments_after`, the run's first comment, which the previous state has read up to.
	resume:   [^]u8,
	// The length of the last string `st_skip_member` read whole, its guess at the next one's.
	skip_len: int,
	// The deepest nesting the text may have from this walk's root. `depth` is less while the stacks hold fewer
	// levels, and `deepen` grows them as the text nests.
	limit:    u64,
}

// Reads the document whose first byte is `p`. Keeps the depth stack in this frame, which `deepen` grows on the default
// heap for a text that nests past it, freed before returning, so a hook can call the walk.
@(private)
walk_document :: #force_inline proc "contextless" (src: []u8, p: [^]u8, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	// `= ---` leaves the array unwritten, where a struct would be zeroed. Every slot is written before it is read.
	stack: [core.MAX_DEPTH]u8 = ---
	depth := u64(opts.max_depth) if opts.max_depth != 0 else core.MAX_DEPTH
	w := Walk(S, H){raw_data(src), h, raw_data(stack[:]), regs, depth_held(h, regs, depth, core.MAX_DEPTH), kernel.tier(), false, opts.tolerate, opts.refuse_non_finite, false, false, nil, 0, depth}
	r := st_value(p, w.base[len(src):], 0, INDENT_START, &w, regs.a, regs.b, regs.c, on)
	if w.owned {
		drop_stack(w.stack)
	}
	return r
}

// `STATE_TIER` is the CPU tier every state is built for, the lowest: `V2` on x86-64, `Base` elsewhere.
@(private)
STATE_TIER :: kernel.Tier(0)

@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// Runs the walk without hooks from `p` as a document's root, whose stack starts at slot `slot` of this walk's, until
// that root value ends, so its depths count past `slot` and its close back to depth 0 ends it. It starts in `st_open`
// with `d` the container's, or in `st_value` with `d` 0. It is a call because `#must_tail` cannot jump between two
// instances of the walk.
@(private)
pass_over :: #force_inline proc "contextless" (w: ^Walk($S, $H), p, end: [^]u8, slot, d, ind: u64, $open: bool) -> u64 {
	h: core.No_Hooks
	regs: core.Hook_Regs
	v := Walk(S, core.No_Hooks){w.base, &h, w.stack[slot:], &regs, w.depth - slot, w.tier, false, w.tolerate, w.finite, false, false, nil, 0, w.limit - slot}
	when open {
		r := st_open(p, end, d, ind, &v, 0, 0, 0, core.no_hook)
	} else {
		r := st_value(p, end, d, ind, &v, 0, 0, 0, core.no_hook)
	}
	if v.owned {
		drop_stack(v.stack)
	}
	return r
}

// Passes the token over `p..q` to the hook and returns its `Action`. The readers refuse a token wider than `Token.n`
// holds before they call `emit`.
@(private)
emit :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, kind: core.Kind, role: core.Role, p, q: [^]u8, spelling: u16) -> core.Action {
	a: core.Action
	hs^, a = on(w.hooks, hs^, core.Token{at(w, p), u32(intrinsics.ptr_sub(q, p)), kind, role, spelling})
	return a
}

// `emit_string` is `emit` for a quoted string, whose token spans the bytes between the quotes. `SPELLING_QUOTED` marks
// the pair as outside the span, so a read does not probe `src` for it and `span` adds it back.
@(private)
emit_string :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, kind: core.Kind, role: core.Role, p, q: [^]u8, spelling: u16) -> core.Action {
	return emit(w, on, hs, kind, role, p[1:], q[-1:], spelling | core.SPELLING_QUOTED)
}

@(private)
at :: #force_inline proc "contextless" (w: ^Walk($S, $H), p: [^]u8) -> u64 {
	return u64(intrinsics.ptr_sub(p, w.base))
}

// The depth a walk with hooks `h` and registers `regs` checks first under the limit `limit`: at most the `room`
// levels its byte stack starts with, and the levels the hooks' own stacks hold past the depth they start at, which a
// typed read's caller gives as many as its text can nest when that is fewer. `deepen` grows them all.
@(private)
depth_held :: #force_inline proc "contextless" (h: ^$H, regs: ^core.Hook_Regs, limit, room: u64) -> u64 {
	when H == typed.Reader || H == typed.Check {
		return min(limit, room, u64(len(h.src)) + 16)
	} else when H == engine.Builder {
		return min(limit, room, u64(len(h.stack)) - regs.c)
	} else when H == engine.Scan {
		return min(limit, room, u64(engine.scan_room(h)) - regs.c)
	} else {
		return min(limit, room)
	}
}

// The fault of an open bracket at the depth the walk checks, `.None` once the check is raised past it: the byte stack
// and the hooks' stacks grow to twice the levels, up to the limit, so they take the room the text's nesting needs.
@(private, cold)
deepen :: #force_no_inline proc "contextless" (w: ^Walk($S, $H)) -> core.Fault_Kind {
	if w.depth >= w.limit {
		return .Too_Deep
	}
	want := min(w.limit, max(2 * w.depth, w.depth + 1))
	when H == typed.Reader || H == typed.Check {
		room, grown := typed.grow_frames(w.hooks, int(w.depth) + 2, int(want) + 2)
		if !grown {
			return .No_Memory
		}
		want = min(w.limit, u64(room) - 2)
	} else when H == engine.Builder {
		if !engine.builder_deepen(w.hooks, int(want - w.depth)) {
			return .No_Memory
		}
	} else when H == engine.Scan {
		if !engine.scan_deepen(w.hooks, int(want - w.depth)) {
			return .No_Memory
		}
	}
	if w.saving {
		w.depth = want
		return .None
	}
	stack := runtime.heap_resize(w.stack, int(want)) if w.owned else runtime.heap_alloc(int(want), false)
	if stack == nil {
		return .No_Memory
	}
	if !w.owned {
		intrinsics.mem_copy_non_overlapping(stack, w.stack, w.depth)
	}
	w.stack, w.owned, w.depth = ([^]u8)(stack), true, want
	return .None
}

// Frees the byte stack a walk run inside another grew.
@(private, cold)
drop_stack :: #force_no_inline proc "contextless" (stack: [^]u8) {
	runtime.heap_free(stack)
}

@(private)
fault :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8, kind: core.Fault_Kind, detail := Detail.None) -> u64 {
	w.regs^ = hs
	return core.fault_at(at(w, p), kind, u8(detail))
}

// Returns the fault value for a hook that stopped the walk at the token ending at `p`, with `core.STOPPED` in the
// detail. A walk with a cursor saves there that state `next` follows at `p`, at depth `d` and indent `ind`. A typed read
// and a build keep their frames on the stack of the call and take no cursor.
@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8, d, ind: u64, next: Follow) -> u64 {
	w.regs^ = hs
	when H != core.No_Hooks && H != typed.Reader && H != typed.Check && H != engine.Builder && H != engine.Count {
		if w.saving {
			save(w, p, d, ind, next)
		}
	}
	return core.fault_at(at(w, p), .None, core.STOPPED)
}

// `stopped` for a stop inside a run of comments that ends at `q`, whose other comments take role `role`. `inline`
// says the next is on the line of the value before the run, and `crossed` that the run crossed a comma.
@(private)
stopped_in_run :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p, q: [^]u8, d, ind: u64, next: Follow, role: core.Role, inline, crossed: bool) -> u64 {
	w.regs^ = hs
	when H != core.No_Hooks && H != typed.Reader && H != typed.Check && H != engine.Builder && H != engine.Count {
		if w.saving {
			save(w, p, d, ind, next)
			c := cursor_of(w)
			c.run_end, c.role, c.inline, c.crossed = at(w, q), role, inline, crossed
		}
	}
	return core.fault_at(at(w, p), .None, core.STOPPED)
}

// The cursor whose registers `w.regs` points to.
@(private)
cursor_of :: #force_inline proc "contextless" (w: ^Walk($S, $H)) -> ^Cursor {
	return (^Cursor)(uintptr(w.regs) - offset_of(Cursor, regs))
}

// Saves a stop at `p` into the walk's cursor, out of line, so the states' stop paths hold one call.
@(private, cold)
save :: #force_no_inline proc "contextless" (w: ^Walk($S, $H), p: [^]u8, d, ind: u64, next: Follow) {
	c := cursor_of(w)
	c.pos, c.d, c.ind, c.held, c.next = at(w, p), d, ind, w.depth, next
}
