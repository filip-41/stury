// `kernel` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
// The walk of a delimited text, in passes of 64-byte blocks (pass.odin). A block is reduced to masks of its delimiter,
// LF, CR and quote bytes, `prefix_xor` of the quote mask marks the bytes inside quoted fields, and every later test is
// a bit test on a mask, for quote placement, a CR that no LF follows, the delimiters and LFs that are the text's rather
// than a cell's, and the delimiters between two LFs that count a record's cells for the width check. UTF-8 is judged a
// block at a time, and only for a block that is not all ASCII.
//
// A hooked read turns the same masks into positions (records.odin). The block's separators in order, each ending a cell
// or a record, give every token's span. `validate` compiles the pass with `$EMIT` false, which leaves out the position
// code and the key buffer. The bytes the masks cannot judge are read one at a time in text.odin, on the blocks whose
// masks say they are needed.
package dsv

import "base:runtime"
import core "../core"
import kernel "../core/kernel"
import engine "../core/build"
import typed "../core/typed"
import write "../core/write"

// The grammar a text follows, chosen at compile time. Each spec instantiates its own pass, so a CSV build holds no TSV
// code.
Spec :: enum u8 {
	Csv, // RFC 4180, a field whose first byte is a quote is quoted, and `""` inside it reads as `"`
	Tsv, // a quote is text, and a backslash escapes `t`, `n`, `r`, `0` or `\\`
	Plain, // no quotes and no escapes, a quote is text, and a cell cannot hold the delimiter, CR or LF
}

// Run-time options for a walk. The zero value reads a header, uses the spec's delimiter and sets no comment byte.
Options :: struct {
	no_header: bool, // the first record is data, not column names
	// The byte between cells, 0 for the spec's own, which is `,` for CSV and Plain and a tab for TSV. A walk whose
	// spec cannot read the byte returns `.Bad_Option` before reading the text.
	delimiter: byte,
	// A line whose first byte is this is no record, 0 for none. At any other byte, or inside a quoted field, it is
	// cell text. A byte the spec cannot read is refused as `.Bad_Option`, like the delimiter.
	comment:   byte,
	// The rules a text may break, each with a fixed reading. Empty by default.
	tolerate:  bit_set[core.Tolerance; u8],
	crlf:      bool, // a write ends each record with CR LF, where a read takes either
	// A document's unquoted cell that is `true`, `false` or exactly a JSON number is True, False or Number, as `core.kind`
	// and a JSON write read it. Off, every value cell is a String but an empty one, which is Null either way.
	infer:     bool,
}

// The `core.Fault.detail` values a delimited text's faults use.
Detail :: enum u8 {
	None,
	Too_Many, // `Bad_Width`, a record wider than the first, at the delimiter that starts its extra cell
	Too_Few, // `Bad_Width`, a record narrower than the first, at its line end
	Bare_Quote, // `Bad_Char`, a quote inside an unquoted CSV cell
	Invalid_Utf8, // `Bad_Char`, at the lead byte of an ill-formed sequence
	Lone_Cr, // `Bad_Char`, a CR with no LF after it
	After_Quote, // `Bad_Char`, a byte after a closing quote that is not a quote, the delimiter or a line end
	Open_Quote, // `Truncated`, at the opening quote of a quoted cell the text never closes
	Cut_Utf8, // `Truncated`, at `len(src)`, where the text ends inside a UTF-8 sequence
}

// A delimited text's rules, indexed by `Detail`. Every fault the walk returns points to this table.
@(rodata)
RULES := core.Rules{"dsv", {{}, {"too_many_fields", "Record has more fields than the first record"}, {"too_few_fields", "Record has fewer fields than the first record"}, {"bare_quote", "Quote inside an unquoted field"}, {"invalid_utf8", "Invalid UTF-8"}, {"lone_cr", "Carriage return not before a line feed"}, {"after_quote", "Character after a closing quote"}, {"open_quote", "Unfinished quoted field"}, {"cut_utf8", "Unfinished UTF-8 sequence"}}}

// The delimiter byte of `spec` when `delimiter` is 0: `,` for CSV and Plain and a tab for TSV. A walk reads it once
// into a register and compares each block against it.
@(private)
spec_delimiter :: #force_inline proc "contextless" (spec: Spec, delimiter: u8) -> u8 {
	return delimiter if delimiter != 0 else '\t' if spec == .Tsv else ','
}

// The `.Bad_Option` fault at byte 0 for options `S` cannot read, or nil. A delimiter is refused when it is CR, LF,
// non-ASCII or, under CSV, a quote, and under TSV also a backslash or one of `t`, `n`, `r`, `0`. A comment byte is refused
// when it is CR, LF, the delimiter, non-ASCII or, under CSV, a quote, and under TSV also a backslash.
@(private)
option_fault :: #force_inline proc "contextless" ($S: Spec, opts: Options) -> Maybe(core.Fault) {
	delim, c := spec_delimiter(S, opts.delimiter), opts.comment
	bad := delim == '\r' || delim == '\n' || delim >= 0x80 || c != 0 && (c == '\r' || c == '\n' || c == delim || c >= 0x80)
	when S == .Csv {
		bad ||= delim == '"' || c == '"'
	} else when S == .Tsv {
		bad ||= delim == '\\' || delim == 't' || delim == 'n' || delim == 'r' || delim == '0' || c == '\\'
	}
	if bad {
		return core.Fault{rules = &RULES, kind = .Bad_Option}
	}
	return nil
}

// Reads a text of spec `S` from `lo`, past one BOM at its first byte, with hook `on`. Returns `hi`, one past the last
// byte read, or the fault. A BOM at a later byte is a cell byte. A `lo` past `len(src)` reads an empty text. When the
// hook stops the walk, `hi` is one past the token it stopped on and the text past it is unread, so `hi` is no document
// boundary.
// The tokens are an `Array` for the text, then for each record an `Object` (an `Array` when `opts.no_header`), each cell as
// its column's header cell (`Plain`, role `Key`) and the cell itself (`Plain`, role `Value`), and an `End` over the
// record's line end, 1 byte for LF and 2 for CR LF. The text's `End` is at its end, with `n` 0. A cell's span keeps its
// quotes and leaves out the CR of a CR LF. The header makes no tokens, and an empty line or a line holding only a CR is
// no record. `regs` nil starts from zero registers and keeps none. `opts` is `Options{}` by default.
// With a `cursor`, a stop on a record's `End` is saved there for `walk_resume`, and the header's cells are written to
// `cursor.keys`. The two are separate procedures so that a walk without a cursor links no saving pass.
walk :: proc {walk_plain, walk_saving}

@(private)
walk_plain :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	return walk_keys(src, lo, S, opts, h, regs, on, nil)
}

// `Cursor` holds where a walk a hook stopped on a record's `End` stands, for `walk_resume` to continue it from the next
// record: that record's first byte, the first record's cell count the others are checked against, the hook's
// registers, and the text's address and length. `keys` is the caller's storage for the header's cells, one token a
// cell, which a resumed walk names its cells with. A walk refuses a header of more cells with `.No_Memory`. A stop on
// any other token ends the walk for good.
Cursor :: struct {
	keys:  []core.Token,
	src:   [^]u8,
	n:     u64,
	at:    u64,
	width: int,
	regs:  core.Hook_Regs,
	held:  bool,
}

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended, faulted or stopped
// on a token that is no record's `End`.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.held
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the record after the one it stopped at the
// end of. `regs` is passed to the first token in place of the registers the stop saved, unless it is nil. The results
// are `walk`'s. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	if !cursor.held || cursor.src != raw_data(src) || cursor.n != u64(len(src)) {
		return 0, core.Fault{rules = &RULES, kind = .Bad_Option}
	}
	if regs != nil {
		cursor.regs = regs^
	}
	return resume_saving(src, S, opts, h, regs, on, cursor, true)
}

// A walk that tracks the record depth of the tokens it passes on, so that a stop knows whether it is on a record's
// `End`. `resumed` swallows the opening `Array` a walk from a record's first byte makes, which the stopped walk made.
@(private)
Saving :: struct($H: typeid) {
	h:       ^H,
	cursor:  ^Cursor,
	depth:   int,
	resumed: bool,
}

@(private)
walk_saving :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor) -> (hi: u64, fault: Maybe(core.Fault)) {
	cursor.src, cursor.n, cursor.held = raw_data(src), u64(len(src)), false
	if f, bad := option_fault(S, opts).?; bad {
		return 0, f
	}
	start := int(core.text_start(src, min(lo, u64(len(src)))))
	cursor.width = header_cells(src, start, S, opts)
	if !opts.no_header && len(cursor.keys) < cursor.width {
		return 0, core.Fault{rules = &RULES, kind = .No_Memory}
	}
	cursor.regs = regs^ if regs != nil else {}
	cursor.at = lo
	return resume_saving(src, S, opts, h, regs, on, cursor, false)
}

// Walks from `cursor.at` with the hook wrapped in `Saving`, and saves a stop on a record's `End`.
@(private)
resume_saving :: proc "contextless" (src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor, resumed: bool) -> (hi: u64, fault: Maybe(core.Fault)) {
	saving_hook :: proc "contextless" (s: ^Saving(H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		if s.resumed {
			s.resumed = false
			return regs, .Next
		}
		r, a := on(s.h, regs, t)
		#partial switch t.kind {
		case .Array, .Object:
			s.depth += int(a != .Skip)
		case .End:
			s.depth -= 1
		}
		if a == .Stop {
			s.cursor.held = t.kind == .End && s.depth == 1
			s.cursor.at = t.lo + u64(t.n)
		}
		return r, a
	}
	cursor.held = false
	w := Saving(H){h, cursor, 1 if resumed else 0, resumed}
	width := cursor.width if resumed else 0
	keys := cursor.keys[:cursor.width] if !opts.no_header else nil
	r := run(src, min(cursor.at, u64(len(src))), S, opts, &w, &cursor.regs, saving_hook, true, keys, width)
	if regs != nil {
		regs^ = cursor.regs
	}
	hi, fault, _ = core.result_of(r, &RULES)
	return
}

// The walk behind `build`: a caller that holds a buffer of one token per header cell passes it as `keys`, and the walk
// writes the header's cells there and allocates none. With nil, the walk allocates the buffer.
@(private)
walk_keys :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), keys: []core.Token) -> (hi: u64, fault: Maybe(core.Fault)) {
	if f, bad := option_fault(S, opts).?; bad {
		return 0, f
	}
	// The nil test runs once per walk, not per token.
	zero: core.Hook_Regs
	reg := regs
	if reg == nil {
		reg = &zero
	}
	// With no `keys` buffer and a header, allocates one 16-byte token per header cell for the walk to write the
	// header's cells into. Data cells read their column's key from it by index. The buffer is scratch freed before
	// the walk returns, so it comes from the default heap, which keeps the walk callable from a hook. If the
	// allocation fails the walk returns `No_Memory` before reading a byte. `validate` allocates nothing.
	from := min(lo, u64(len(src)))
	key_buf := keys
	owned: []core.Token
	if key_buf == nil && !opts.no_header {
		context = runtime.default_context()
		err: runtime.Allocator_Error
		key_buf, err = make([]core.Token, header_cells(src, int(core.text_start(src, from)), S, opts))
		if err != nil {
			return 0, core.Fault{rules = &RULES, kind = .No_Memory}
		}
		owned = key_buf
	}
	r := run(src, from, S, opts, h, reg, on, true, key_buf)
	if owned != nil {
		context = runtime.default_context()
		delete(owned)
	}
	hi, fault, _ = core.result_of(r, &RULES)
	return
}

// The walk's verdict on `src` for spec `S`, with no hook and after one leading BOM. Whether the first record is a
// header changes the verdict only under `.Ragged`. A constant `spec` links the pass of that spec alone. A `spec`
// chosen at run time is `core.validate` with `as(spec, opts)` and links every spec's pass. The same holds for the other
// entry points below, and the forms that take a `Document` give it the readers of the spec.
validate :: proc {validate_bound, validate_chosen}

@(private)
validate_bound :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> core.Error {
	return core.error_of(validate_spec(src, S, opts))
}

@(private)
validate_chosen :: #force_inline proc "contextless" (src: []u8, spec: Spec, opts := Options{}) -> core.Error {
	return core.validate(src, as(spec, opts))
}

// Reads a delimited text as spec `spec` into a document, allocating its nodes with `allocator`. `opts.no_header` makes the
// first record data. `.Refuse` returns an error at a header name that repeats another in the header row. The
// document borrows `src`, which must outlive it, and `core.destroy` frees the document.
build :: proc {build_bound, build_chosen}

@(private)
build_bound :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := build_spec(src, S, readers_of(S), opts, dups == .Refuse, allocator)
	return doc, core.error_of(err)
}

@(private)
build_chosen :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	return core.build(src, as(spec, opts), dups, allocator)
}

// The path reads of `core/build`. `scan`, `each_answer`, `find` and `set` take `spec` and `opts`.
scan :: proc {scan_bound_one, scan_bound_many, scan_chosen_one, scan_chosen_many}

@(private)
scan_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_bound_many(src, S, []core.Path{path}, opts, read, allocator)
}

@(private)
scan_bound_many :: proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	if read.dups == .Refuse {
		built, e := build_bound(src, S, opts, .Refuse, allocator)
		return engine.query_built(&built, e, paths, read)
	}
	doc, err := scan_spec(src, S, bound_as(S, opts), paths, read, nil, nil, allocator)
	return doc, core.error_of(err)
}

@(private)
scan_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return engine.scan_one(src, as(spec, opts), path, read, allocator)
}

@(private)
scan_chosen_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return engine.scan_many(src, as(spec, opts), paths, read, allocator)
}

each_answer :: proc {each_answer_bound_one, each_answer_bound_many, each_answer_chosen_one, each_answer_chosen_many}

@(private)
each_answer_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_bound_many(src, S, []core.Path{path}, state, on, opts, read, allocator)
}

@(private)
each_answer_bound_many :: proc(src: []u8, $S: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	if read.dups == .Refuse {
		built, e := build_bound(src, S, opts, .Refuse, allocator)
		core.destroy(&built)
		if e != nil {
			return e
		}
	}
	doc, err := scan_spec(src, S, bound_as(S, opts), paths, read, state, on, allocator)
	core.destroy(&doc)
	return core.error_of(err)
}

@(private)
each_answer_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return engine.each_answer_one(src, as(spec, opts), path, state, on, read, allocator)
}

@(private)
each_answer_chosen_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return engine.each_answer_many(src, as(spec, opts), paths, state, on, read, allocator)
}

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in dsv.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `paths` is read at the first `next`.
answers :: proc {answers_bound_one, answers_bound_many, answers_chosen_one, answers_chosen_many}

@(private)
answers_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(S, opts), nil, path, read, allocator, answers_fill(S))
}

@(private)
answers_bound_many :: #force_inline proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(S, opts), paths, {}, read, allocator, answers_fill(S))
}

@(private)
answers_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, as(spec, opts), nil, path, read, allocator, answers_fill_of(spec))
}

@(private)
answers_chosen_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, as(spec, opts), paths, {}, read, allocator, answers_fill_of(spec))
}

find :: proc {find_bound, find_chosen}

@(private)
find_bound :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = scan_bound_one(src, S, one, opts, read, allocator)
	answer = doc.answers[0] if len(doc.answers) > 0 else {core.NO_NODE, core.NO_NODE, 0, .Missing}
	return
}

@(private)
find_chosen :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	return engine.find(src, as(spec, opts), path, read, allocator)
}

// Makes `v` the value at every answer of `path` over `src`, in one call, and returns the new text, which the caller frees
// with `allocator`. A `typed.Raw` is the text of a value, a struct, a slice or a map is built by `plan`, and any other
// value is spelled by the format. A `Name` the path ends in that its container lacks is inserted after the container's
// last member. `read.dups` picks among a repeated key as `query` does, and sets each repeat under `.All`.
set :: proc {set_bound, set_chosen}

@(private)
set_bound :: proc(src: []u8, $S: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	scratch: write.Scratch
	defer write.scratch_destroy(&scratch)
	in_ := write.edit_input(v, plan, &scratch) or_return
	doc, berr := build_bound(src, S, opts, read.dups, allocator)
	defer core.destroy(&doc)
	if berr != nil {
		return nil, berr
	}
	list := edit_list_init_bound(&doc, S, allocator)
	defer core.edit_list_destroy(&list)
	return engine.set_answers(&list, path, in_, read, allocator)
}

@(private)
set_chosen :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	scratch: write.Scratch
	defer write.scratch_destroy(&scratch)
	in_ := write.edit_input(v, plan, &scratch) or_return
	return engine.set(src, as(spec, opts), path, in_, read, allocator)
}

// Answers `path` or `paths` over a document built whole. A document read as a constant spec holds no services, so
// `core.query` does not answer for it.
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
edit_list_init :: proc {edit_list_init_bound, edit_list_init_chosen}

@(private)
edit_list_init_bound :: proc(doc: ^core.Document, $S: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = edit_of(S)
	return list
}

@(private)
edit_list_init_chosen :: proc(doc: ^core.Document, spec: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = core.services_of(as(spec)).edit
	return list
}

// Writes node `node` of `doc` as spec `spec`, as `core.write` does with `as(spec)`.
write :: proc {write_bound, write_chosen}

@(private)
write_bound :: proc(doc: ^core.Document, $S: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	if int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	out, cut, refusal := document_write(doc, opts, bound_as(S), node, {}, allocator)
	return out, cut, core.error_of(refusal)
}

@(private)
write_chosen :: #force_inline proc(doc: ^core.Document, spec: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	return core.write(doc, opts, as(spec), node, allocator)
}

@(private)
validate_spec :: proc "contextless" (src: []u8, $S: Spec, opts: Options, lo: u64 = 0, width := 0) -> Maybe(core.Fault) {
	if f, bad := option_fault(S, opts).?; bad {
		return f
	}
	_, fault, _ := core.result_of(judge(src, lo, S, opts, width), &RULES)
	return fault
}

// The walk's verdict on the text from `lo`, with no hook, checking records against `width` when it is above 0. A cell can exceed `Token.n` only in a text longer than
// `max(u32)` bytes, and only the hooked lane checks cell width, so such a text runs with `$EMIT` true and
// `core.no_hook`. A shorter text runs with `$EMIT` false. `field_count_fault` then places a width fault.
@(private)
judge :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, width := 0) -> u64 {
	h: core.No_Hooks
	regs: core.Hook_Regs
	r: u64
	if u64(len(src)) - lo > u64(max(u32)) {
		r = run(src, lo, S, opts, &h, &regs, core.no_hook, true, nil, width)
	} else {
		r = run(src, lo, S, opts, &h, &regs, core.no_hook, false, nil, width)
	}
	return field_count_fault(src, lo, S, opts, r, width)
}

// The position of a width fault is the delimiter that opens the cell past the width in a wide record, or the line end's
// first byte in a narrow one. A width fault at or before a byte fault wins. A walk with no fault returns `r` unchanged,
// and a faulting one rescans the records with `scan_record`. A `width` above 0 is the width a walk from a row start
// checked rows against, and 0 reads it from the first record. `.Ragged` has no width fault to place.
@(private, cold)
field_count_fault :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, r: u64, width := 0) -> u64 {
	_, fault, _ := core.result_of(r, &RULES)
	f, faulted := fault.?
	if !faulted || .Ragged in opts.tolerate {
		return r
	}
	width_fault := f.detail == u8(Detail.Too_Many) || f.detail == u8(Detail.Too_Few)
	end := len(src)
	pos := record_start(src, int(core.text_start(src, min(lo, u64(end)))), opts.comment)
	if pos >= end {
		return r
	}
	delim := spec_delimiter(S, opts.delimiter)
	width := width
	if width == 0 {
		width = header_cells(src, pos, S, opts) if !opts.no_header else scan_record(src, pos, 0, S, delim).cells
	}
	for pos < end {
		if f.at < u64(pos) {
			return r
		}
		s := scan_record(src, pos, width, S, delim)
		if f.at <= u64(s.line_end) {
			if s.fault_at >= 0 {
				if width_fault || u64(s.fault_at) < f.at {
					return core.fault_at(u64(s.fault_at), .Bad_Width, u8(Detail.Too_Many))
				}
			} else if width_fault && s.cells < width {
				return core.fault_at(u64(s.line_end_lo), .Bad_Width, u8(Detail.Too_Few))
			}
			return r
		}
		pos = record_start(src, s.line_end + 1, opts.comment)
	}
	return r
}

// Runs the pass for the CPU's vector tier (`kernel.tier()`), or for the tier `-define:TIER=<n>` forces in a test
// build. A text with no comment byte runs the pass instance with `$COMMENTS` false, which holds no comment code.
@(private)
run :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, keys: []core.Token, width := 0) -> u64 {
	// A document build or a record batch with the default options runs its own pass instance with literal options,
	// which fold the option tests and leave the instance for other options out of its registers.
	when H == engine.Builder || H == Batch || H == Cells {
		if opts == {} {
			return run_tier(src, lo, S, opts, h, regs, on, EMIT, false, true, keys, width)
		}
	}
	if opts.comment != 0 {
		return run_tier(src, lo, S, opts, h, regs, on, EMIT, true, false, keys, width)
	}
	return run_tier(src, lo, S, opts, h, regs, on, EMIT, false, false, keys, width)
}

@(private)
run_tier :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
	when ODIN_ARCH == .amd64 {
		switch kernel.tier() {
		case .V4:
			return pass_v4(src, lo, S, opts, h, regs, on, EMIT, COMMENTS, DEFAULT, keys, width)
		case .V3:
			return pass_v3(src, lo, S, opts, h, regs, on, EMIT, COMMENTS, DEFAULT, keys, width)
		case .V2:
		}
		return pass_v2(src, lo, S, opts, h, regs, on, EMIT, COMMENTS, DEFAULT, keys, width)
	} else {
		return pass_base(src, lo, S, opts, h, regs, on, EMIT, COMMENTS, DEFAULT, keys, width)
	}
}

// A pass procedure per vector tier, each with its tier's target features and its own copy of the loop, as kernel.md
// asks. A loop that calls a kernel generic over `$T` is instantiated per tier, so a v4 build holds v4 compares and a v2
// build holds SSE ones. `#force_no_inline` keeps each a separate procedure.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	pass_v2 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
		return pass(.V2, S, EMIT, COMMENTS, src, lo, Options{} when DEFAULT else opts, h, regs, on, keys, width)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	pass_v3 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
		return pass(.V3, S, EMIT, COMMENTS, src, lo, Options{} when DEFAULT else opts, h, regs, on, keys, width)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	pass_v4 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
		return pass(.V4, S, EMIT, COMMENTS, src, lo, Options{} when DEFAULT else opts, h, regs, on, keys, width)
	}
} else {
	@(private)
	pass_base :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
		return pass(.Base, S, EMIT, COMMENTS, src, lo, Options{} when DEFAULT else opts, h, regs, on, keys, width)
	}
}

// Passes a token to the hook and stores the returned registers in `hs`. The token is built here from the call's words,
// so a call site gives no `Token` an address or a second copy.
@(private)
emit :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, lo: u64, n: u32, kind: core.Kind, role: core.Role, spelling: u16) -> core.Action {
	a: core.Action
	hs^, a = on(h, hs^, core.Token{lo, n, kind, role, spelling})
	return a
}

// The walk's result when the hook stopped on the token at `lo` of `n` bytes. Its position is `lo + n`, its kind 0, and
// its detail `STOPPED`.
@(private)
stopped :: #force_inline proc "contextless" (lo: u64, n: u32) -> u64 {
	return core.fault_at(lo + u64(n), .None, core.STOPPED)
}
