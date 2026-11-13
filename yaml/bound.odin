#+private
package yaml

import "base:runtime"
import core "../core"
import typed "../core/typed"
import records "../core/records"

// The tables the entry points bind. Each is its own rodata table, so a program links the passes it names. Nothing
// reachable from here may name `as`, `HANDLES` or `SERVICES`, which reach every pass.

// The readers of a document the entry points build. It holds no services.
@(rodata)
READERS := core.Readers {
	text        = text,
	key_equals  = spelling_key_equals,
	number      = number,
	resolve     = spelling_resolve,
	resolves    = proc "contextless" (as: core.As) -> bool {return true},
	close_end   = close_end,
	format      = rules_of,
	tag_key     = "yaml",
	fact        = spelling_fact,
	number_text = number_text,
}

// The handle of `spec` read with `opts`, over `READERS`.
bound_as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&READERS, spec, opts)
}

// The leaves of a plan and a typed read, with no `close_end` and no services. Every plan holds this table, and the spec
// and the option bytes in `As`.
@(rodata)
PLAN_READERS := core.Readers {
	text        = text,
	key_equals  = spelling_key_equals,
	number      = number,
	resolve     = spelling_resolve,
	resolves    = proc "contextless" (as: core.As) -> bool {return true},
	format      = rules_of,
	tag_key     = "yaml",
	fact        = spelling_fact,
	number_text = number_text,
}

// The edit services of a list over a document. YAML commits its edits itself, since a block collection has no bytes of
// its own for `core/compose` to compose around.
@(rodata)
EDIT := core.Edit_Services {
	value    = edit_value,
	key_text = edit_key_text,
	comment  = proc(_: ^core.Document, _: u8) -> (core.Comment_Spelling, u8) {return .Byte, '#'},
	validate = validate_as,
	spell    = edit_spell,
	prefix   = edit_prefix,
	relocate = edit_relocate,
	commit   = edit_commit,
}

// The typed reads of a plan: a text is built and read as its document is.
@(rodata)
READS := typed.Format_Reads {
	read      = text_read,
	node_read = node_read,
	build     = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_as(src, as, false, allocator)},
	plan      = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, .Yaml_1_2, {}, opts, &READS, allocator)},
}

// The reads of a plan made from a description or from a model: `READS` with the check of a text and of a document. A
// program that only unmarshals does not name it, so it does not link the check.
@(rodata)
CHECKS := typed.Format_Reads {
	read       = text_read,
	check      = text_check,
	node_read  = node_read,
	node_check = node_check,
	build      = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_as(src, as, false, allocator)},
	plan       = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, .Yaml_1_2, {}, opts, &CHECKS, allocator)},
}

// The framing of records, one per document of a stream. A `---` or `...` line at column 0 stands inside no node, so
// the cuts at one are documents' starts in any text the walk takes. It holds no record reads, which `record_docs` gives.
@(rodata)
FRAMING := records.Framing_Services {
	next  = #partial {.Concatenated = next_document},
	judge = judge_document,
	guess = guess_document,
	piece = piece_documents,
	whole = whole_stream,
	cut   = cut_document,
}
