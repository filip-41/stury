package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// XML 1.0 Fifth Edition with Namespaces in XML 1.0, in UTF-8, its internal subset read and no external entity. A
// document is an `Object` of one member, the root element. An element is a member under its name: its value is its
// text, a string or a null for none, or an `Object` of its child elements and its `#text` runs between them, and its
// attributes are `Attribute` facts of that value. A name an element's children repeat reads as an array of each in
// document order, `.Group` being XML's policy for repeated keys, so a path read takes the first of them that answers.

// The grammar a text follows.
Spec :: enum u8 {
	Xml,
}

// Options of an XML read. `budget` sets `depth` (an element is a level), `nodes`, `memory`, `steps` (a step is an
// element with a child element, and the document) and `expansion`, which the entity references of a text count
// against. `format` takes `tape.Xml_Options`, and a read refuses another format's. Of `tolerate` XML takes
// `.Unread_Entity`, and refuses `.Invalid_Utf8` as `Bad_Option{"tolerate"}`, as it reads no ill-formed UTF-8. The
// others name rules of tokens XML has none of, so they change nothing. A runner builds a long text with no document
// type declaration on its threads.
Options :: tape.Options

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Xml = {name = "xml", id = ID, facts = FACTS, options = .Xml, dups = .Group, refuses = {.Invalid_Utf8}, bounds = bounds, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, text_ext = prolog_ext, close_end = close_end, expanded = expanded_names, attribute = attribute, namespace = namespace},
}

// The facts an XML document holds.
@(private)
FACTS :: tape.COMMENTS + {.Attribute, .Instruction, .Instruction_Foot, .Doctype, .Directive}

// The format id of `.Xml`.
@(private)
ID :: tape.FORMAT_ID_XML

// The format handle of `spec`, to read nodes of a text of `spec` with `tape.node_text` and `tape.node_number`, and to
// pass a document's format to a call that takes one. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

// Returns the error in `src`, or nil when `src` is one well-formed XML document. Only a text nesting past
// `WALK_LEVELS`, a DTD and a namespace declaration whose URI needs decoding allocate.
@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Xml, opts := Options{}, allocator := context.allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Xml:
		if opts.pieces != nil {
			return validate_pieces(src, .Xml, opts, allocator)
		}
		if build.read_lax(opts) {
			return validate_as(src, .Xml, true, opts, allocator)
		}
		return validate_as(src, .Xml, false, opts, allocator)
	}
	runtime.panic_contextless("xml: spec out of range")
}

// Builds a document of `src`, with its comments, instructions, declarations and attributes as facts. Its nodes point
// into `src`. Under `.Refuse` a name an element's children repeat fails the build, under `.First` and `.Last` the
// build keeps one element of each name, and under the others every element. A long text with no document type
// declaration is built on the threads of `opts.runner`, into the document one thread builds.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Xml, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Xml:
		if xo, ok := opts.format.(tape.Xml_Options); ok && xo.arrays == .Schema {
			return {}, tape.Bad_Option{"format"}
		}
		doc: tape.Document
		err: tape.Error
		if opts.pieces != nil {
			doc, err = build_pieces(src, .Xml, opts, allocator)
		} else if opts.runner != nil && opts.runner.threads > 0 && len(src) >= build.PARALLEL_FROM && tape.options_refused(&FORMATS[spec], opts) == nil {
			doc, err = build_parallel(src, .Xml, opts, allocator)
		} else if build.read_lax(opts) {
			doc, err = build_as(src, .Xml, true, opts, allocator)
		} else {
			doc, err = build_as(src, .Xml, false, opts, allocator)
		}
		if err == nil {
			if xo, ok := opts.format.(tape.Xml_Options); ok && xo.arrays == .Always {
				if nerr := normalize_arrays(&doc, .Always, nil, nil, allocator, opts.budget); nerr != nil {
					tape.destroy(&doc)
					return {}, nerr
				}
			}
		}
		return doc, err
	}
	panic("xml: spec out of range")
}

// The first value `path` reaches in `src`, read with no document, or why none was reached. A name step matches an
// element by its name as written, prefix included, and under `.Default` the first element of a repeated name. A name in
// `{uri}local` form, which the readers of a document take, is `Bad_Option{"path"}`: an element's namespace may be
// declared past its name. Allocates only as `json.find` does.
@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Xml, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	hook.probe_stack(READ_STACK)
	if expanded_step(path) {
		return {}, tape.Bad_Option{"path"}
	}
	if xo, ok := opts.format.(tape.Xml_Options); ok && xo.arrays != .Auto {
		return {}, tape.Bad_Option{"format"}
	}
	switch spec {
	case .Xml:
		if opts.pieces != nil {
			return find_pieces(src, path, .Xml, read, opts, allocator)
		}
		if build.read_lax(opts) {
			return find_as(src, path, .Xml, true, read, opts, allocator)
		}
		return find_as(src, path, .Xml, false, read, opts, allocator)
	}
	panic("xml: spec out of range")
}

// Builds a document of the nodes of `src` that the paths of `demand` reach, as `json.scan` does, with `Demand.facts`
// the facts of its nodes. A name in `{uri}local` form is `Bad_Option{"path"}`, as for `find`.
@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Xml, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	if expanded_demand(demand) {
		return {}, tape.Bad_Option{"path"}
	}
	if xo, ok := opts.format.(tape.Xml_Options); ok && xo.arrays != .Auto {
		return {}, tape.Bad_Option{"format"}
	}
	switch spec {
	case .Xml:
		if opts.pieces != nil {
			return scan_pieces(src, demand, .Xml, read, opts, allocator)
		}
		if build.read_lax(opts) {
			return scan_as(src, demand, .Xml, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Xml, false, read, opts, allocator)
	}
	panic("xml: spec out of range")
}

// Walks `src` as `S` for hook `h` from its registers `regs`, the walk the reads above run. Returns where the text ends
// or the error, and whether the walk read a reference to an entity whose text is not read. A stop of the hook is no
// error. A text in pieces is walked a window of `opts.pieces` at a time, as the reads in pieces walk it. The hook keeps
// the protocol `hook.check` checks, and has no `.Walk`.
walk :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), allocator := context.allocator) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	#assert(.Walk not_in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0))
	hook.probe_stack(READ_STACK)
	if err = tape.options_refused(&FORMATS[S], opts); err != nil {
		return
	}
	ctx := context
	if opts.pieces != nil {
		return piece_read(src, S, opts, h, regs, allocator, &ctx, on)
	}
	if build.read_lax(opts) {
		return walk_text(src, S, true, opts, h, regs, allocator, &ctx, on)
	}
	return walk_text(src, S, false, opts, h, regs, allocator, &ctx, on)
}

@(private)
validate_as :: #force_no_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, hook.no_hook)
	}
	// A DTD or a namespace declaration takes memory from the read's allocator, so the walk is always given the context.
	return build.read_validate(src, &FORMATS[S], opts, allocator, -1, walk)
}

@(private)
build_as :: #force_no_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.builder_hook_facts)
	}
	return build.read_build(src, &FORMATS[S], &RULES, opts, caller, node_bound, walk, build_finish)
}

// The `finish` of a build: the repeated names as `opts.dups` says, then the elements that declare a namespace.
@(private)
build_finish :: proc(doc: ^tape.Document, opts: Options, rules: ^tape.Rules) -> tape.Error {
	build.builder_dups(doc, opts.dups, rules) or_return
	return keep_scopes(doc, true)
}

@(private)
scan_as :: #force_no_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.scanner_key_skip_hook)
	}
	doc, err := build.read_scan(src, demand, &FORMATS[S], read, opts, caller, nil, node_bound, walk)
	if err == nil {
		err = keep_scopes(&doc, demand.facts)
	}
	return doc, err
}

@(private)
find_as :: #force_no_inline proc(src: []u8, path: []tape.Step, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.read_find(src, path, &FORMATS[S], read, opts, caller, respell, nil, walk)
}

// The spelling of the number answer from `lo` to `hi` of `src`, an element's text an inferring read took as a number.
@(private)
respell :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 {
	return tape.infer_token(raw_data(src), lo, u32(hi - lo)).spelling
}

// The most nodes a text of `src` can make: a node per byte, plus 16 of slack, and past a DTD the most its entities
// may expand to, as an entity whose text holds markup is walked at each reference to it.
@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, depth: u64) -> u64 {
	n := u64(len(src)) + 16
	if prolog_doctype(src) {
		n += tape.default_expansion(u64(len(src)))
	}
	return n
}

// The walk of `src` from its first byte, with its result as the reads take it, and whether the walk read a reference
// to an entity whose text is not read. An empty text holds no root element.
@(private)
walk_text :: #force_inline proc "contextless" (src: []u8, $S: Spec, $LAX: bool, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	r, took := walk_document(src, 0, LAX, opts, build.read_depth(opts), build.read_steps(opts), h, regs, allocator, ctx, on)
	at, e, _ := hook.walk_error(r, &RULES)
	return at, e, took
}

