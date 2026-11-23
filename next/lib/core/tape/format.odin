package tape

import "base:runtime"
import "stury:lib/base/spell"

// A format is a text format stury reads, with a `Format` per spec. Its facts say which fact kinds it holds beyond
// plain values, its caps what else it can do, and its readers turn a node into an Odin value.

// A format capability other than a fact it holds.
Cap :: enum u8 {
	// A value of its text walks alone from its first byte, as it walks inside the text, so a read can pass an element
	// and walk it again once its array's count picks it. A format without it, whose values read by what came before
	// them (a YAML block value, an HTML element in its insertion mode, a TOML table's body), keeps the nodes instead.
	Rewalk,
	// The names a value is read by are known before the walk reaches the values, a table's header, so every read
	// judges `.Refuse` on them, not a build alone.
	Names_Ahead,
}

Caps :: bit_set[Cap; u32]

// The stable id of one spec of a format, stored in saved documents. Unique across the linked formats.
Format_Id :: distinct u16

// Options of a read of any format.
Options :: struct {
	budget:   Budget,
	// The policy for the members of an object that repeat a key, which every read honours or refuses. A build keeps one
	// member of each key under `.First` and `.Last`, fails on a repeat under `.Refuse`, and keeps every member under
	// the others. A path read takes the member `.First`, `.Last` or `.Group` says, the format's own for `.Default`, and
	// refuses `.All` and `.Refuse`, as it takes one member of a key. Under `.Last` an answer through a key is known only
	// at the close of the object holding it, so a path read that should stop at the first matching key uses `.First`.
	// A validate refuses `.Refuse`, as it does not compare keys, and so does a path read, unless the format has
	// `.Names_Ahead`.
	dups:     Duplicates,
	// The rules a text may break, each read as `Tolerance` says. A spec whose grammar holds a rule has it already.
	tolerate: Tolerances,
	// A text that arrives in pieces, of which the read takes the next window, nil for a whole text.
	pieces:   ^Pieces,
	// Threads a build of a whole text may run on beside the caller's, nil for the caller's alone. The document is the
	// one a build on one thread gives, and so is its error, except under `Budget.memory`, which the parts count for
	// their own blocks.
	runner:   ^Runner,
	// The options only one format family has, which every other family's reads refuse as `Bad_Option{"format"}`. Nil
	// takes the family's defaults.
	format:   Format_Options,
}

// The options of a read that one format family alone has, an arm per family.
Format_Options :: union {
	Dsv_Options,
}

// The family of `Format_Options` a format's reads take, `.None` for a format with no options of its own.
Options_Family :: enum u8 {
	None,
	Dsv,
}

// `Bad_Option{"format"}` when `opts.format` holds the options of a family other than `f`'s, else nil. Every read of a
// format passes it, so a format cannot take another family's options.
options_refused :: #force_inline proc "contextless" (f: ^Format, opts: Options) -> Error {
	family := Options_Family.None
	switch _ in opts.format {
	case Dsv_Options:
		family = .Dsv
	case nil:
		return nil
	}
	return nil if family == f.options else Bad_Option{"format"}
}

// The options of a delimited text. A delimited document keeps those it was built with in its `Tabular_Ext`.
Dsv_Options :: struct {
	delimiter: u8, // the byte between cells, 0 for the spec's own
	comment:   u8, // a line whose first byte is this is no record, 0 for none
	no_header: bool, // the first record is data, and each record an array of cells
	// An unquoted cell that is `true`, `false` or a JSON number reads as that value, not as a string.
	infer:     bool,
}

// A spec of a format (e.g. JSON, JSONC and JSON5 are three), in rodata, holding what a document of it needs to be
// read. `Reads` holds the reads of its texts.
Format :: struct {
	name:  string,
	id:    Format_Id,
	facts:  Facts, // the fact kinds it holds
	caps:   Caps,
	options: Options_Family, // the options of `Options.format` its reads take
	dups:   Duplicates, // its own policy for repeated keys, which `.Default` takes, never `.Default`
	// The bytes of a scalar token's authored span before and after the token's own, as a string's quotes.
	bounds: proc "contextless" (src: []u8, t: Token) -> (head, tail: u8),
	// The text of a scalar node whose spelling has `SPELLING_DECODE`, decoded into `buf`, false only when `buf` is
	// shorter than `room` gives. A scalar with no `SPELLING_DECODE` reads as its bytes in the text.
	decode: proc "contextless" (src: []u8, t: Node, buf: []u8) -> (s: string, ok: bool),
	// The bytes that always hold the decode of scalar `t`, which may pass its span (a CBOR integer key's digits, an
	// entity, a tolerated byte read as U+FFFD).
	room: proc "contextless" (src: []u8, t: Node) -> int,
	// The value of a number node.
	number: proc "contextless" (src: []u8, t: Node) -> spell.Number,
	// Whether scalar `t` of `src` and scalar `o` of `other` read as the same text, whatever their kinds.
	same_text: proc "contextless" (src: []u8, t: Token, other: []u8, o: Token) -> bool,
	// A hash of the text scalar `t` of `src` reads as, `text_hash` of that text, so two scalars `same_text` holds for
	// hash alike. A scalar with no `SPELLING_DECODE` hashes as its bytes in the text.
	key_hash: proc "contextless" (src: []u8, t: Token) -> u32,
	// The byte just past the close of the container node `at` of `doc`, which a document stores no node for. False for
	// one other than the root of a `.Held` document, which holds no byte between its nodes.
	close_end: proc "contextless" (doc: ^Document, at: Node_Index) -> (end: u64, ok: bool),
}

// The reads of one spec of a format, for a caller that picks the format at run time. They are not on `Format`: the
// handle holds what reading a document needs, so a program that reads no text through it links no read of any spec.
Reads :: struct {
	validate: proc(f: ^Format, src: []u8, opts: Options, allocator: runtime.Allocator) -> Error,
	build: proc(f: ^Format, src: []u8, opts: Options, allocator: runtime.Allocator) -> (Document, Error),
	find: proc(f: ^Format, src: []u8, path: []Step, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Span_Answer, Error),
	scan: proc(f: ^Format, src: []u8, demand: ^Demand, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Document, Error),
	// Makes the records of `src` framed as `framing`, in `allocator`, which `destroy_records` frees.
	records: proc(f: ^Format, src: []u8, framing: Framing, opts: Options, allocator: runtime.Allocator) -> (^Records, runtime.Allocator_Error),
}

// The `Reads` of a format whose entry procs take its `Spec`, the spec of a handle being its id less `first`. `R` is the
// format's records, which hold `Records` as their first field `records`, and every spec shares the one table.
format_reads :: proc "contextless" ($Spec: typeid, $first: Format_Id, $validate: proc(src: []u8, spec: Spec, opts: Options, allocator: runtime.Allocator) -> Error, $build: proc(src: []u8, spec: Spec, opts: Options, allocator: runtime.Allocator) -> (Document, Error), $find: proc(src: []u8, path: []Step, spec: Spec, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Span_Answer, Error), $scan: proc(src: []u8, demand: ^Demand, spec: Spec, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Document, Error), $R: typeid, $records_open: proc(src: []u8, framing: Framing, spec: Spec, opts: Options) -> R, $records_validate: proc(r: ^R, out: []Record, allocator: runtime.Allocator) -> int, $records_find: proc(r: ^R, path: []Step, out: []Record, answers: []Span_Answer, read: Read_Options, allocator: runtime.Allocator) -> int, $records_scan: proc(r: ^R, demand: ^Demand, out: []Record, docs: []Document, read: Read_Options, allocator: runtime.Allocator) -> int) -> ^Reads {
	#assert(offset_of(R, records) == 0)
	spec_of :: #force_inline proc "contextless" (f: ^Format) -> Spec {
		return Spec(f.id - first)
	}
	@(static, rodata) reads := Reads {
		validate = proc(f: ^Format, src: []u8, opts: Options, allocator: runtime.Allocator) -> Error {
			return validate(src, spec_of(f), opts, allocator)
		},
		build = proc(f: ^Format, src: []u8, opts: Options, allocator: runtime.Allocator) -> (Document, Error) {
			return build(src, spec_of(f), opts, allocator)
		},
		find = proc(f: ^Format, src: []u8, path: []Step, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Span_Answer, Error) {
			return find(src, path, spec_of(f), read, opts, allocator)
		},
		scan = proc(f: ^Format, src: []u8, demand: ^Demand, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Document, Error) {
			return scan(src, demand, spec_of(f), read, opts, allocator)
		},
		records = proc(f: ^Format, src: []u8, framing: Framing, opts: Options, allocator: runtime.Allocator) -> (records: ^Records, err: runtime.Allocator_Error) {
			r := new(R, allocator) or_return
			context.allocator = allocator
			r^ = records_open(src, framing, spec_of(f), opts)
			r.reads, r.allocator = records_reads(R, records_validate, records_find, records_scan), allocator
			r.release = proc(r: ^Records) {
				free((^R)(r), r.allocator)
			}
			return r, nil
		},
	}
	return &reads
}

// The batch reads of records `R`, which hold `Records` as their first field.
@(private)
records_reads :: proc "contextless" ($R: typeid, $validate: proc(r: ^R, out: []Record, allocator: runtime.Allocator) -> int, $find: proc(r: ^R, path: []Step, out: []Record, answers: []Span_Answer, read: Read_Options, allocator: runtime.Allocator) -> int, $scan: proc(r: ^R, demand: ^Demand, out: []Record, docs: []Document, read: Read_Options, allocator: runtime.Allocator) -> int) -> ^Records_Reads {
	@(static, rodata) reads := Records_Reads {
		validate = proc(r: ^Records, out: []Record, allocator: runtime.Allocator) -> int {
			return validate((^R)(r), out, allocator)
		},
		find = proc(r: ^Records, path: []Step, out: []Record, answers: []Span_Answer, read: Read_Options, allocator: runtime.Allocator) -> int {
			return find((^R)(r), path, out, answers, read, allocator)
		},
		scan = proc(r: ^Records, demand: ^Demand, out: []Record, docs: []Document, read: Read_Options, allocator: runtime.Allocator) -> int {
			return scan((^R)(r), demand, out, docs, read, allocator)
		},
	}
	return &reads
}
