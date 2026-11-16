package core

import "base:runtime"
import "core:io"

// What a format gives core: its handle, the readers a value read needs, and the services a call that chooses its
// format at run time reaches, an edit's among them.

// What a format offers, which each format exports as `CAPABILITIES`. `writes` holds the options its document writer
// honours, `framings` those its records are read in and `specs` is its `Spec` type. `follows` reports whether the fault
// of a build of a whole text is the start of a second text, so that the text is a stream of them read one after
// another, and is nil for a format with one text to an input.
Capabilities :: struct {
	writes:   bit_set[Write_Option; u8],
	framings: bit_set[Framing; u8],
	specs:    typeid,
	follows:  proc "contextless" (f: Fault) -> bool,
}

// The handle of a format: its readers, and the spec, depth, tolerance and option bytes a text is read or written with. A
// format's `as` procedure makes one, and a document holds the one it was read with.
As :: struct {
	readers:   ^Readers,
	// The deepest nesting a read takes, 0 for `MAX_DEPTH`. An edit reads a value text at this depth.
	max_depth: u32,
	// The format's spec, which its services dispatch on.
	spec:      u8,
	// The rules a text read in the format may break.
	tolerate:  bit_set[Tolerance; u8],
	// The format's own bytes, opaque to core.
	opts:      [10]u8,
}

#assert(size_of(As) == 24)

// `Readers` holds what a read of a value needs of its format, in rodata. `text` decodes a node's text into `buf` and
// returns false when `buf` is too short, so a read never allocates. A node whose `SPELLING_DECODE` bit is clear is its
// span without the quotes that surround it. `key_equals` compares a key without allocating. `number` reads a number
// token, and returns false for a token that is no number of the format's. `number_f32` reads a number token whose kind
// is above `NUMBER_DECIMAL` into an f32 with one rounding, and returns false when narrowing `number`'s binary64 already
// rounds once. It is nil for a format with no such kinds. `resolve` returns what a `Plain` node is, and `resolves`
// whether it can return anything but `.String` for a node with bytes under handle `as`, nil for a format with no
// `Plain` nodes, so a writer asks once per text. `close_end` returns the byte just past a container's closing bytes,
// found from its last descendant or its open, over the whitespace and comments the format allows there, the root's
// close is `Document.root_close`, so a service may return it without a scan. `format` is the format's identity: one
// procedure for every spec of a format, which returns its fault table, so two tables compare equal when they read one
// format. `tag_key` is the format's own struct tag key, and `key_open` and `key_close` are what a key is written
// between, empty for a format whose keys a typed read does not compare as text. `flat` says a text has no brackets, so
// no container has bytes of its own, a delimited text's root and its records alike: it is one answer for the format,
// which a plan reads with no document, and no format answers it per container. `services` points at the run-time
// services of a handle, nil in a table that serves a read only. `attribute` gives an `Attribute` fact's name as a `Key`
// and its value as a `Value` token, each read through `text` and `key_equals` as a node's is: a value with references
// or one the format normalizes sets `SPELLING_DECODE`, and a valueless attribute's value is an empty `String`. It is
// nil for a format with no attributes, and `attribute_next` reads attributes with it. `fact` returns a named fact that the
// node's spelling carries instead of a span, such as a scalar's style or a TOML datetime's tag, and is nil for a format
// with none, see `fact_value`. `number_text` writes the decimal digits of a number token whose span is not its text, a
// binary format's integer, bignum or decimal fraction, or a `Plain` token the format resolves to a number, into `buf`
// and returns false when `buf` is too short. An infinity or a NaN has no digits and gives an empty text. It is nil for
// a format whose number span is the text, see `doc_number_text`. `key_bytes` returns the bytes a member named `name`
// is written with, a key head and the name, in `buf` of `len(name) + 16` bytes, which a typed plan compares as a
// key's text is compared. It is nil for a format whose keys are written between `key_open` and `key_close`. `binary`
// says the format holds a byte string kind, so a `String` token is text and never bytes. `fold_names` says a selector
// compares the format's element and attribute names ASCII case-insensitively, as HTML's are. `floats_apart` says an
// integer and a float of equal value are two values of the format, as TOML's, YAML's and CBOR's are. `holds` names the
// facts a text of the format can hold, which a writer and an edit read to know where a fact may go. `key_is` compares
// the key at node `i` to a name that needs the key's place in the document, an expanded XML name whose namespace an
// ancestor declares, and is nil for a format whose `key_equals` needs no more. `room` returns the bytes that hold the
// decode of a token of `n` source bytes at `lo`, for a format whose decode may outgrow its span past what its spelling
// bits say, as an XML entity reference does. It is nil for a format whose decodes `text_room` sizes from the bits.
// `tag_fits` says whether a value `v` put in place of a node tagged `tag` keeps a tag, and which, for a format whose
// tags state a type, see `kept_tag`. It is nil for a format whose tags stay on any value. `tag_meaning` gives the
// meaning of node `i`'s tag `tag` that a span holds as text, see `Tag_Meaning`. It is nil for a format whose `fact`
// gives the meaning with the tag, and for one whose tags have none.
Readers :: struct {
	text:         proc(v: ^Token_View, t: Token, buf: []u8) -> (s: string, ok: bool),
	key_equals:   proc "contextless" (v: ^Token_View, t: Token, name: string) -> bool,
	number:       proc(v: ^Token_View, t: Token) -> (Number, bool),
	number_f32:   proc(v: ^Token_View, t: Token) -> (f32, bool),
	resolve:      proc(doc: ^Document, i: Node_Index) -> Kind,
	resolves:     proc "contextless" (as: As) -> bool,
	close_end:    proc(doc: ^Document, i: Node_Index) -> u64,
	format:       proc "contextless" () -> ^Rules,
	tag_key:      string,
	key_open:     string,
	key_close:    string,
	flat:         bool,
	binary:       bool,
	fold_names:   bool,
	floats_apart: bool,
	holds:        bit_set[Fact_Kind],
	services:     ^Services,
	attribute:    proc "contextless" (doc: ^Document, f: Fact) -> (name, value: Token),
	fact:         proc(doc: ^Document, i: Node_Index, name: Fact_Kind) -> (Fact_Value, bool),
	number_text:  proc(v: ^Token_View, t: Token, buf: []u8) -> (s: string, ok: bool),
	key_bytes:    proc(name: string, buf: []u8) -> []u8,
	key_is:       proc "contextless" (doc: ^Document, i: Node_Index, name: string) -> bool,
	room:         proc(v: ^Token_View, lo: u64, n: u32) -> int,
	tag_fits:     proc(tag: string, v: Value) -> (kept: string, fits: bool),
	tag_meaning:  proc(doc: ^Document, i: Node_Index, tag: string) -> Tag_Meaning,
}

// `r` with `services`: the readers of a handle, which reach the format's services.
with_services :: proc "contextless" (r: Readers, services: ^Services) -> Readers {
	r := r
	r.services = services
	return r
}

// The run-time services of a handle, which a call that chooses its format at run time reaches through
// `Readers.services`. `build` reads a text into a document and `validate` judges one without building, each as the
// handle says, see `core.build` and `core.validate`. `scan` reads paths over a text as the handle says into a partial
// document, or gives each answer to `on` when it is set, see `core/build`'s `scan` and `each_answer`. `edit` points at
// the format's edit services, nil for a format that accepts no edits. `write` writes a node of the document as text of
// the format `as` names, into a buffer from `allocator` or to `stream`, and counts the facts of the node's subtree the
// text holds, nil for a format with no document writer, see `core.write`. `plans` is the format's `typed.Plan_Make`,
// nil for a format whose plans need nothing past `typed.plan_build`. `reads` is the format's `^typed.Format_Reads`, nil
// for a format with no typed read. `tokens` is the format's `^write.Token_Spelling`, nil for a format with no token
// writer. `records` is the format's `^records.Services`, nil for a format with no record reader. Each pointer is a
// `rawptr` since `core/write`, `core/records` and `core/typed` import `core`, and each is cast back to that type
// unchecked, so a format sets them to exactly that type or leaves them nil.
Services :: struct {
	build:    proc(src: []u8, as: As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (Document, Document_Error),
	validate: proc "contextless" (src: []u8, as: As) -> Maybe(Fault),
	scan:     proc(src: []u8, as: As, paths: []Path, read: Path_Options, state: rawptr, on: proc(state: rawptr, a: Token_Answer) -> bool, allocator: runtime.Allocator) -> (Document, Path_Error),
	write:    proc(doc: ^Document, opts: Write_Options, as: As, node: Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, int, Typed_Refusal),
	edit:     ^Edit_Services,
	plans:    rawptr,
	reads:    rawptr,
	tokens:   rawptr,
	records:  rawptr, // ^records.Framing_Services
	docs:     rawptr, // ^records.Record_Docs
	words:    Write_Words,
}

// The reasons a format's writer gives a refusal that names none: for a value it cannot spell, `.Unwritable`, and for
// an option or operation it lacks, `.Unsupported`.
Write_Words :: struct {
	unwritable, unsupported: string,
}

// `e` with the reason `words` give its kind where it names none.
worded :: proc "contextless" (e: Typed_Refusal, words: Write_Words) -> Typed_Refusal {
	e := e
	if e.want.text == "" {
		#partial switch e.kind {
		case .Unwritable:
			e.want.text = words.unwritable
		case .Unsupported:
			e.want.text = words.unsupported
		}
	}
	return e
}

// An `Edit_Services` holds a format's edit services. A document's `Services` points at one table, and the services
// dispatch on the document's `spec` and `opts`. `value` checks a text as exactly one value of the format and spec, and
// `key_text` writes a decoded member name in the format's own spelling, quotes and escapes included. A member insert's
// key and a key set take a decoded name, so no service judges a key. Each service receives the document, so it reads
// the run-time options the document holds. A text that is no value answers `.Bad_Value`, with the walk's fault in
// `inner` where there is one, and `.No_Memory` when the service could not allocate.
//
// `member_sep` is what is written between two members of container `c`, a flat text's root included, and `key_sep`
// between a member's key and its value. `comment` says how the output spells a comment under `spec` and is nil for a
// format that accepts no comment. `insert_check` holds a format's rules on what a container takes.
//
// A flat format also supplies the rest. `interior` returns the bytes a container's members lie in, `fact_slot` says
// whether the output holds a fact of a role on a node, and `emptied` whether a list removes every member of the root.
// `plan` runs first on a commit and may turn the whole list into plain edits, which `out` receives with their texts
// borrowed or allocated with `allocator`, and it returns false to keep the list as it is.
Edit_Services :: struct {
	value:         proc(v: ^Token_View, src: []u8, allocator: runtime.Allocator) -> Document_Error,
	key_text:      proc(doc: ^Document, name: []u8, text: ^[dynamic]u8) -> bool,
	comment:       proc(doc: ^Document, spec: u8) -> Comment_Syntax,
	// Whether `name` may be written bare under `spec`, as an insert writes it into a container whose first key is bare.
	// Nil for a format whose `key_text` chooses the spelling itself.
	bare_key:      proc(spec: u8, name: []u8) -> bool,
	separators:    proc(doc: ^Document, spec: u8) -> bool, // `spec` ends a line comment at U+2028 and U+2029, which `doc.as` does not
	member_sep:    proc(doc: ^Document, c: Node_Index) -> string,
	key_sep:       string,
	insert_check:  proc(doc: ^Document, container: Node_Index, text: string, allocator: runtime.Allocator) -> Document_Error,
	interior:      proc(doc: ^Document, c: Node_Index) -> (lo, hi: u64),
	fact_slot:     proc(doc: ^Document, node: Node_Index, role: Role, emptied: bool) -> bool,
	emptied:       proc(doc: ^Document, list: ^Edit_List) -> bool,
	plan:          proc(doc: ^Document, list: ^Edit_List, out: ^[dynamic]Edit, allocator: runtime.Allocator) -> (changed: bool, err: Document_Error),
	// Judges a text of the list's own spec, as a commit checks its output and the document's source.
	validate:      proc "contextless" (src: []u8, as: As) -> Maybe(Fault),
	// Reads a text of the list's own spec into a document, as a commit reads its output back against the edits.
	build:         proc(src: []u8, as: As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (Document, Document_Error),
	// Reads paths over a text of the list's own spec, as a commit reads the values its edits wrote back from its output.
	// It is nil for a format whose commit reads its output back whole.
	scan:          proc(src: []u8, as: As, paths: []Path, read: Path_Options, state: rawptr, on: proc(state: rawptr, a: Token_Answer) -> bool, allocator: runtime.Allocator) -> (Document, Path_Error),
	// The scan reads the text whole before its first answer, so it judges every byte as the validate does.
	whole_scan:    bool,
	// Walks a flat text of the list's own spec with `rows_hook`, as a commit reads its output back row by row, see
	// `reads_rows`, and returns the walk's fault. It is nil for a format whose commit reads its output back otherwise.
	walk_rows:     proc(src: []u8, as: As, r: ^Row_Read) -> Maybe(Fault),
	// Walks a text of the list's own spec with `written_hook`, as a commit of many edits reads the values they wrote
	// back from its output, see `reads_written`, and returns the walk's fault. It is nil for a format whose commit reads
	// its output back otherwise.
	walk_written:  proc(src: []u8, as: As, w: ^Written_Read) -> Maybe(Fault),
	// Spells a built value as text of the document's format and spec, in a buffer from `allocator`. `opts` and `colon`
	// are the layout, `colon` the bytes between a member's key and its value when they are not the format's own. `at`
	// is the byte the text goes in at. A flat format spells a cell, or with `record` the cells of an array or object as
	// one record without its line end, and refuses a cell it cannot spell as a `Document_Error` that names the cell by
	// `reason`.
	spell:         proc(doc: ^Document, v: Value, opts: Write_Options, colon: string, record: bool, at: u64, allocator: runtime.Allocator) -> ([]u8, Error),
	// Spells a `Tag`, `Anchor` or `Alias` fact of `body` as the text that stands before its node, a marker and the body,
	// nil for a format that holds none.
	prefix:        proc(doc: ^Document, role: Role, body: []u8, text: ^[dynamic]u8) -> bool,
	// Returns the bytes node `node` has at `site`, in a buffer from `allocator`, for a value an edit takes from the
	// document and writes at another place, and `ok` false when the format cannot spell the node there. It is nil for a
	// format whose nodes keep their bytes anywhere.
	relocate:      proc(doc: ^Document, node: Node_Index, site: Site, allocator: runtime.Allocator) -> (text: []u8, ok: bool),
	// Says why an edit may not touch `node`, as the `rules` and the `detail` of a message in them, and returns nil
	// `rules` for a node an edit may touch. It is nil for a format whose nodes are all editable.
	frozen:        proc(doc: ^Document, node: Node_Index) -> (rules: ^Rules, detail: u8),
	// Returns the source bytes `list`'s edits make, as the spec byte `spec`, in place of `core/compose`'s commit, for a
	// format whose containers are not one range of bytes to compose around, as a table written in sections or a text of
	// lines at an indentation. It places each edit's text at its site itself, so a value `spell` writes is recorded as it
	// is, in the list's base layout, and it counts in `dropped` the facts the output cannot hold. It is nil for a format
	// whose edits `core/compose` commits.
	commit:        proc(list: ^Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: Document_Error),
}

// Where a value is written: the column its first byte stands at, whether the container around it is a flow collection
// (bracketed, and a block's lines do not continue in it), and whether it follows a key. A format's writer reads it to
// indent and style what it writes, and `Edit_Services.relocate` to move a node's bytes. `placed` says the text is one
// value among a document's, which an edit writes, where the zero site is a whole text.
Site :: struct {
	column: u32,
	flow:   bool,
	member: bool,
	placed: bool,
}

// The site of a value an edit writes at byte `at` of `src`: placed, at the column `at` has in its line.
site_at :: proc "contextless" (src: []u8, at: u64) -> Site {
	end := min(at, u64(len(src)))
	lo := end
	for lo > 0 && src[lo - 1] != '\n' && src[lo - 1] != '\r' {
		lo -= 1
	}
	return {column = u32(end - lo), placed = true}
}

// Whether `a` and `b` read one format. Two tables of one format differ by spec, so their addresses are no evidence.
same_format :: #force_inline proc "contextless" (a, b: ^Readers) -> bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.format == b.format
}

// Returns the run-time services of `as`'s format, nil for a handle with none: a zero handle, and a table that serves a
// read only.
services_of :: #force_inline proc "contextless" (as: As) -> ^Services {
	return as.readers.services if as.readers != nil else nil
}
