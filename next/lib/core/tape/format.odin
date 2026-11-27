package tape

import "base:intrinsics"
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
	// A format whose texts are bytes, not lines of text: a number node's text is its value in decimal, as `decode` gives
	// it, and `error_message` places a fault by its byte offset.
	Binary,
}

Caps :: bit_set[Cap; u32]

// The stable id of one spec of a format, stored in saved documents. Unique across the linked formats.
Format_Id :: distinct u16

// Central base `Format_Id` assignments for built-in format families. Each format claims `len(Spec)` consecutive IDs
// from its base so specs cannot silently collide across packages.
FORMAT_ID_JSON    :: Format_Id(1)  // 1..3: Json, Jsonc, Json5
FORMAT_ID_DSV     :: Format_Id(4)  // 4..6: Csv, Tsv, Plain
FORMAT_ID_CBOR    :: Format_Id(7)  // 7..10: Cbor, Preferred, Deterministic, Length_First
FORMAT_ID_TOML    :: Format_Id(11) // 11..12: Toml_1_0, Toml_1_1
FORMAT_ID_XML     :: Format_Id(13) // 13: Xml
FORMAT_ID_YAML    :: Format_Id(14) // 14..15: Yaml_1_2, Yaml_Merge
FORMAT_ID_HTML    :: Format_Id(16) // 16..17: Html, Fragment
FORMAT_ID_MSGPACK :: Format_Id(18) // 18..19: Msgpack, Compact

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
	// Where short-lived scratch memory freed before a read returns comes from (as a TOML read's table tree). Zero
	// takes the runtime's default heap, so a read into an arena keeps only its result, or the read's allocator on a
	// build with no heap (a freestanding target). Pass the read's allocator here to keep every block in it. Counted
	// against `Budget.memory` with the read's own blocks.
	scratch:  runtime.Allocator,
}

// The options of a read that one format family alone has, an arm per family. The union is closed and frozen before the C
// API, so a family with no options has no arm, and an arm is added with its first option.
Format_Options :: union {
	Dsv_Options,
	Xml_Options,
	Yaml_Options,
}

// The family of `Format_Options` a format's reads take, `.None` for a format with no options of its own.
@(private)
Options_Family :: enum u8 {
	None,
	Dsv,
	Xml,
	Yaml,
}

// `Bad_Option{"format"}` when `opts.format` holds the options of a family other than `f`'s, and
// `Bad_Option{"tolerate"}` for a rule `f` refuses, else nil. Every read of a format passes it, so a format cannot take
// another family's options.
@(require_results)
options_refused :: #force_inline proc "contextless" (f: ^Format, opts: Options) -> Error {
	if opts.tolerate & f.refuses != {} {
		return Bad_Option{"tolerate"}
	}
	switch o in opts.format {
	case nil:
		return nil
	case Dsv_Options:
		if f.options == .Dsv {
			return nil
		}
	case Xml_Options:
		if f.options == .Xml && o.arrays <= max(Xml_Arrays) {
			return nil
		}
	case Yaml_Options:
		if f.options == .Yaml && o.dialect <= max(Yaml_Dialect) {
			return nil
		}
	}
	return Bad_Option{"format"}
}

// The options of a delimited text. A delimited document keeps those it was built with in its `Tabular_Ext`.
Dsv_Options :: struct {
	delimiter: u8, // the byte between cells, 0 for the spec's own
	comment:   u8, // a line whose first byte is this is no record, 0 for none
	no_header: bool, // the first record is data, and each record an array of cells
	// An unquoted cell that is `true`, `false` or a JSON number reads as that value, not as a string.
	infer:     bool,
	crlf:      bool, // a write ends each line with CR LF, where a read takes either line end
}

// How child elements of an XML document are represented as arrays.
Xml_Arrays :: enum u8 {
	Auto,   // default: single element as value, 2+ siblings as grouped array
	Always, // every child element (depth >= 1) as an array, even when single
	Schema, // child elements whose schema expects an array become arrays even when single
}

// The options of an XML text. They change what the reads give, so a document records none of them.
Xml_Options :: struct {
	// An element's text that is `true`, `false` or a JSON number, with no reference or markup in it, reads as that
	// value, where any other text is a string.
	infer:  bool,
	// How child elements are represented as arrays. Zero value `.Auto` preserves default XML semantics.
	arrays: Xml_Arrays,
}

// Which YAML 1.2 standard schema resolves untagged plain scalars and validates explicit schema tags:
// - `.Core` (default, YAML 1.2 §10.3): full Core Schema (`null`/`Null`/`NULL`/`~`/empty -> `.Null`;
//   `true`/`True`/`TRUE`/`false`/`False`/`FALSE` -> `.True`/`.False`; decimal, `+`-prefixed, leading-zero,
//   `.5`/`5.`, `0o` octal, `0x` hex, `.inf`/`.nan` -> `.Number`; everything else -> `.String`).
// - `.Json` (YAML 1.2 §10.2 practical JSON Schema): only lowercase `null`, lowercase `true`/`false`, and strict
//   RFC 8259 JSON numbers (`-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` — no leading `+`, no leading zeros,
//   no `0x`/`0o`, no `.inf`/`.nan`, no `.5` or `5.`) resolve to non-string scalars; `~`, `Null`, `NULL`, `True`,
//   `False`, `0x10`, `0o10`, `+1`, `.5`, `.inf`, `.nan`, empty plain scalars, and any other plain scalar stay
//   `.String`. Explicit `!!null`, `!!bool`, `!!int`, and `!!float` tags validate strictly against JSON Schema
//   lexical rules.
// - `.Failsafe` (YAML 1.2 §10.1 Failsafe Schema): every untagged scalar (including `null`, `~`, `true`, `false`,
//   numbers, and empty plain scalars) resolves to `.String`; explicit `!!str` is accepted and non-failsafe tags
//   are kept as generic tags with `.String` values (zero implicit coercion).
Yaml_Dialect :: enum u8 {
	Core,
	Json,
	Failsafe,
}

// The options of a YAML text. They change how scalars resolve during reads, so a document records none of them.
Yaml_Options :: struct {
	dialect: Yaml_Dialect,
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
	// The rules of `Options.tolerate` its texts may break and its reads do not read past, which every read refuses as
	// `Bad_Option{"tolerate"}`. A rule its grammar has no place for changes nothing, and is taken.
	refuses: Tolerances,
	// The bytes of a scalar token's authored span before and after the token's own, as a string's quotes.
	bounds: proc "contextless" (src: []u8, t: Token) -> (head, tail: u8),
	// The text of a scalar node whose spelling has `SPELLING_DECODE`, decoded into `buf` with no memory of its own, read
	// with the format data `ext` of the document holding it, nil for a node of no document. False when `buf` is
	// shorter than `room` gives, or when the decode needs what only the document holds, as an XML entity's DTD. A
	// scalar with no `SPELLING_DECODE` reads as its bytes in the text.
	decode: proc "contextless" (src: []u8, t: Node, buf: []u8, ext: ^Format_Ext) -> (s: string, ok: bool),
	// The bytes that always hold the decode of scalar `t`, read with `ext` as `decode` is, which may pass its span (a
	// CBOR integer key's digits, an entity, a tolerated byte read as U+FFFD).
	room: proc "contextless" (src: []u8, t: Node, ext: ^Format_Ext) -> int,
	// The format data that `decode` and `room` read a node of no document of the text `src` with, read from the text in
	// `allocator`, which `free` frees, nil for a text that needs none. False when memory is refused. Nil for a format
	// whose decodes need no document.
	text_ext: proc(src: []u8, allocator: runtime.Allocator) -> (ext: ^Doc_Ext, ok: bool),
	// The value of a number node.
	number: proc "contextless" (src: []u8, t: Node) -> spell.Number,
	// Whether key `t` of `src` and key `o` of `other` read as the same text, whatever their kinds. It needs no memory.
	same_text: proc "contextless" (src: []u8, t: Token, other: []u8, o: Token) -> bool,
	// A hash of the text key `t` of `src` reads as, `text_hash` of that text, so two keys `same_text` holds for hash
	// alike. A key with no `SPELLING_DECODE` hashes as its bytes in the text. It needs no memory.
	key_hash: proc "contextless" (src: []u8, t: Token) -> u32,
	// The byte just past the close of the container node `at` of `doc`, which a document stores no node for. False for
	// one other than the root of a `.Held` document, which holds no byte between its nodes.
	close_end: proc "contextless" (doc: ^Document, at: Node_Index) -> (end: u64, ok: bool),
	// The name of the fact of kind `kind` that node `at` of `doc` holds in its spelling, nil for a format whose nodes
	// spell none. False for a node that holds none.
	fact_name: proc "contextless" (doc: ^Document, at: Node_Index, kind: Fact_Kind) -> (name: string, ok: bool),
	// Whether key node `key` of `doc` is the expanded name `name`, written `{uri}local`: `.Found`, `.Missing`, or
	// `.Not_Loaded` when `doc` did not keep the declarations that decide it. Nil for a format whose names have no
	// namespace, which reads such a name as written.
	expanded: proc "contextless" (doc: ^Document, key: Node_Index, name: string) -> Presence,
	// The name and value tokens of attribute fact `f` of `doc`, nil for a format with no attributes.
	attribute: proc "contextless" (doc: ^Document, f: Fact) -> (name, value: Token),
	// The namespace URI of the element at `at` of `doc`, `.Missing` for none, `.Not_Loaded` when `doc` lacks its
	// declarations. Nil for a format with no namespaces.
	namespace: proc "contextless" (doc: ^Document, at: Node_Index) -> (uri: string, p: Presence),
}

// The reads of one spec of a format, for a caller that picks the format at run time. They are not on `Format`: the
// handle holds what reading a document needs, so a program that reads no text through it links no read of any spec.
Reads :: struct {
	validate: proc(f: ^Format, src: []u8, opts: Options, allocator: runtime.Allocator) -> Error,
	build: proc(f: ^Format, src: []u8, opts: Options, allocator: runtime.Allocator) -> (Document, Error),
	find: proc(f: ^Format, src: []u8, path: []Step, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Span_Answer, Error),
	scan: proc(f: ^Format, src: []u8, demand: ^Demand, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Document, Error),
	// Makes the records of `src` framed as `framing`, in the container `path` reaches, in `allocator`, which
	// `destroy_records` frees.
	records: proc(f: ^Format, src: []u8, framing: Framing, opts: Options, path: []Step, allocator: runtime.Allocator) -> (^Records, runtime.Allocator_Error),
}

// The `Reads` of a format whose entry procs take its `Spec`, the spec of a handle being its id less `first`. `R` is the
// format's records, which hold `Records` as their first field `records`, and every spec shares the one table. Records
// that keep memory past a batch have a field `close: proc(r: ^R)` too, which frees it when the records are destroyed.
format_reads :: proc "contextless" ($Spec: typeid, $first: Format_Id, $validate: proc(src: []u8, spec: Spec, opts: Options, allocator: runtime.Allocator) -> Error, $build: proc(src: []u8, spec: Spec, opts: Options, allocator: runtime.Allocator) -> (Document, Error), $find: proc(src: []u8, path: []Step, spec: Spec, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Span_Answer, Error), $scan: proc(src: []u8, demand: ^Demand, spec: Spec, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Document, Error), $R: typeid, $records_open: proc(src: []u8, framing: Framing, spec: Spec, opts: Options, path: []Step) -> R, $records_validate: proc(r: ^R, out: []Record, allocator: runtime.Allocator) -> int, $records_find: proc(r: ^R, path: []Step, out: []Record, answers: []Span_Answer, read: Read_Options, allocator: runtime.Allocator) -> int, $records_scan: proc(r: ^R, demand: ^Demand, out: []Record, docs: []Document, read: Read_Options, allocator: runtime.Allocator) -> int) -> ^Reads {
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
		records = proc(f: ^Format, src: []u8, framing: Framing, opts: Options, path: []Step, allocator: runtime.Allocator) -> (records: ^Records, err: runtime.Allocator_Error) {
			@(static, rodata) rreads := Records_Reads {
				validate = proc(r: ^Records, out: []Record, allocator: runtime.Allocator) -> int {
					return records_validate((^R)(r), out, allocator)
				},
				find = proc(r: ^Records, path: []Step, out: []Record, answers: []Span_Answer, read: Read_Options, allocator: runtime.Allocator) -> int {
					return records_find((^R)(r), path, out, answers, read, allocator)
				},
				scan = proc(r: ^Records, demand: ^Demand, out: []Record, docs: []Document, read: Read_Options, allocator: runtime.Allocator) -> int {
					return records_scan((^R)(r), demand, out, docs, read, allocator)
				},
			}
			r := new(R, allocator) or_return
			if r == nil {
				return nil, .Out_Of_Memory
			}
			context.allocator = allocator
			r^ = records_open(src, framing, spec_of(f), opts, path)
			r.reads, r.allocator = &rreads, allocator
			return r, nil
		},
	}
	return &reads
}

// Threads a caller lends to a read, which starts none of its own. A nil `^Runner` means the caller's thread alone.
// `host.Pool` supplies one.
//
//	- `start` runs `task(arg)` as a separate call on each of up to `n` of the `threads`. A call may start late or
//	  not at all. `start` happens-before every started call's `task(arg)`.
//	- `finish` returns once no further call will start and every started call has returned; every started `task(arg)`
//	  happens-before `finish` returns.
//	- `start` and `finish` alternate, and both run on the calling thread. A runner runs one call at a time; callers
//	  must not share one concurrently across threads.
Runner :: struct {
	data:    rawptr,
	threads: int,
	start:   proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr),
	finish:  proc(data: rawptr),
}

// What `fan_each` shares: the next index to claim, the count of them and the argument given to each task.
@(private = "file")
Fan_Each :: struct {
	next, count: uint,
	arg:         rawptr,
}

// Runs `task(arg, k)` once for each `k` below `count`, on the calling thread and on the threads of `runner`, each thread
// claiming the next index while any is left. The calls share the work through `arg`. Specializing on `$task` gives each
// workload a distinct trampoline address so `host.Pool` tracks per-task adaptive widths independently.
fan_each :: proc(runner: ^Runner, count: int, $task: proc(arg: rawptr, k: int), arg: rawptr) {
	if count <= 1 || runner == nil || runner.threads <= 0 || runner.start == nil || runner.finish == nil {
		for k in 0 ..< count {
			task(arg, k)
		}
		return
	}
	each := Fan_Each{count = uint(count), arg = arg}
	run :: proc(arg: rawptr) {
		e := (^Fan_Each)(arg)
		for {
			k := intrinsics.atomic_add(&e.next, 1)
			if k >= e.count {
				return
			}
			task(e.arg, int(k))
		}
	}
	runner.start(runner.data, min(runner.threads, count - 1), run, &each)
	run(&each)
	runner.finish(runner.data)
}

// Runs `task(arg)` on the calling thread and on the threads of `runner`, and returns once every call has. The calls
// share the work through `arg`, as only the caller's call is certain to run.
fan :: proc(runner: ^Runner, task: proc(arg: rawptr), arg: rawptr) {
	if runner == nil || runner.threads <= 0 || runner.start == nil || runner.finish == nil {
		task(arg)
		return
	}
	runner.start(runner.data, runner.threads, task, arg)
	task(arg)
	runner.finish(runner.data)
}
