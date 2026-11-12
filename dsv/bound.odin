// `compose` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
#+private
package dsv

import "base:runtime"
import core "../core"
import compose "../core/compose"
import typed "../core/typed"

// The tables a constant-spec entry point binds to its spec. Each factory returns the address of a `@(static, rodata)`
// local of its instance, so a program links the passes of the specs it names. Nothing reachable from here may name `as`,
// `HANDLES` or `SERVICES`, which reach every spec's passes.

// The readers of a document built as spec `S`: the leaves, and the spec's own `close_end`. It holds no services.
readers_of :: proc "contextless" ($S: Spec) -> ^core.Readers {
	@(static, rodata) r := core.Readers {
		text       = proc(v: ^core.Token_View, n: core.Node, buf: []u8) -> (s: string, ok: bool) {return cell_text(v.src, n, S, buf)},
		key_equals = spelling_key_equals,
		number     = number,
		resolve    = spelling_resolve,
		resolves   = proc "contextless" (as: core.As) -> bool {return options_of(as).infer},
		close_end  = proc(doc: ^core.Document, i: core.Node_Index) -> u64 {return close_end_spec(doc, i, S)},
		format     = rules_of,
		tag_key    = "csv",
		flat       = true,
	}
	return &r
}

// The handle of spec `S` read with `opts`, over `readers_of(S)`.
bound_as :: proc "contextless" ($S: Spec, opts := Options{}) -> core.As {
	return as_of(readers_of(S), S, opts)
}

// The leaves of a plan and a typed read, with no `close_end` and no services. Every plan holds this table, and the spec
// and the option bytes in `As`.
@(rodata)
PLAN_READERS := core.Readers {
	text       = text,
	key_equals = spelling_key_equals,
	number     = number,
	resolve    = spelling_resolve,
	resolves   = proc "contextless" (as: core.As) -> bool {return options_of(as).infer},
	format     = rules_of,
	tag_key    = "csv",
	flat       = true,
}

// A record check of the text `src` read as spec `S`.
record_check :: proc "contextless" ($S: Spec) -> Record_Check {
	return proc(doc: ^core.Token_View, src: []u8) -> (cells: int, err: core.Document_Error) {return edit_record(doc, src, S)}
}

// The edit services of a list over a document of spec `S`: its value check and its commit's check are the passes of `S`.
edit_of :: proc "contextless" ($S: Spec) -> ^core.Edit_Services {
	@(static, rodata) e := core.Edit_Services {
		value        = proc(doc: ^core.Token_View, src: []u8, _: runtime.Allocator) -> core.Document_Error {return edit_cells(doc, src, false, record_check(S))},
		key_text     = edit_key_text,
		comment      = proc(doc: ^core.Document, _: u8) -> (core.Comment_Spelling, u8) {return (.Byte if doc.as.opts[1] != 0 else .None), doc.as.opts[1]},
		member_sep   = proc(doc: ^core.Document, c: core.Node_Index) -> string {return edit_record_sep(doc) if c == core.ROOT else string(doc.as.opts[:1])},
		insert_check = proc(doc: ^core.Document, c: core.Node_Index, text: string, _: runtime.Allocator) -> core.Document_Error {return edit_cells(doc, transmute([]u8)text, c == core.ROOT, record_check(S))},
		interior     = edit_interior,
		fact_slot    = edit_fact_slot,
		emptied      = edit_emptied,
		plan         = proc(doc: ^core.Document, list: ^core.Edit_List, out: ^[dynamic]core.Edit, allocator: runtime.Allocator) -> (bool, core.Document_Error) {return edit_plan(doc, list, out, allocator, record_check(S))},
		spell        = edit_spell,
		validate     = proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {return validate_spec(src, S, options_of(as))},
	}
	return &e
}

// The typed reads of a plan read as spec `S`.
reads_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		read      = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return read_text(src, S, T, target, plan, options_of(as), read, allocator, false, typed.Reader)},
		check     = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return read_text(src, S, T, target, plan, options_of(as), read, allocator, true, typed.Reader)},
		node_read = document_read,
		build     = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_spec(src, S, as.readers, options_of(as), false, allocator)},
		plan      = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, S, {}, opts, reads_of(S), allocator)},
	}
	return &r
}

// The reads of a plan made from a description or from a model, read as spec `S`: `reads_of` with the check of a text and of
// a document by the description or the model. A program that only unmarshals does not name it, so it does not link the
// check.
checks_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		read       = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return read_text(src, S, T, target, plan, options_of(as), read, allocator, false, typed.Reader)},
		check      = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return check_one(src, S, T, target, plan, options_of(as), read, allocator)},
		node_read  = document_read,
		node_check = document_check,
		build      = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_spec(src, S, as.readers, options_of(as), false, allocator)},
		plan       = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, S, {}, opts, checks_of(S), allocator)},
		docs       = proc "contextless" () -> rawptr {return check_docs(S)},
		replace    = replace_cell,
	}
	return &r
}
