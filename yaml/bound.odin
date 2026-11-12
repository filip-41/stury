#+private
package yaml

import "base:runtime"
import core "../core"
import typed "../core/typed"
import records "../core/records"

// The tables a constant-spec entry point binds to its spec. Each factory returns the address of a `@(static, rodata)`
// local of its instance, so a program links the passes it names. Nothing reachable from here may name `as`, `HANDLES`
// or `SERVICES`, which reach every pass.

// The readers of a document built as spec `S`. It holds no services.
readers_of :: proc "contextless" ($S: Spec) -> ^core.Readers {
	@(static, rodata) r := core.Readers {
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

// The edit services of a list over a document of spec `S`. YAML commits its edits itself, since a block collection has
// no bytes of its own for `core/compose` to compose around.
edit_of :: proc "contextless" ($S: Spec) -> ^core.Edit_Services {
	@(static, rodata) e := core.Edit_Services {
		value    = edit_value,
		key_text = edit_key_text,
		comment  = proc(_: ^core.Document, _: u8) -> (core.Comment_Spelling, u8) {return .Byte, '#'},
		validate = validate_as,
		spell    = edit_spell,
		prefix   = edit_prefix,
		relocate = edit_relocate,
		commit   = edit_commit,
	}
	return &e
}

// The typed reads of a plan read as spec `S`: a text is built and read as its document is.
reads_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		read      = text_read,
		node_read = node_read,
		build     = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_as(src, as, false, allocator)},
		plan      = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, S, {}, opts, reads_of(S), allocator)},
	}
	return &r
}

// The reads of a plan made from a description or from a model, read as spec `S`: `reads_of` with the check of a text
// and of a document. A program that only unmarshals does not name it, so it does not link the check.
checks_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		read       = text_read,
		check      = text_check,
		node_read  = node_read,
		node_check = node_check,
		build      = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_as(src, as, false, allocator)},
		plan       = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, S, {}, opts, checks_of(S), allocator)},
	}
	return &r
}

// The framing of records read as spec `S`, one per document of a stream. A `---` or `...` line at column 0 stands inside
// no node, so the cuts at one are documents' starts in any text the walk takes. It holds no record reads, which
// `record_docs(S)` gives.
framing_of :: proc "contextless" ($S: Spec) -> ^records.Framing_Services {
	@(static, rodata) f := records.Framing_Services {
		next  = #partial {.Concatenated = next_document},
		judge = judge_document,
		guess = guess_document,
		piece = piece_documents,
		whole = whole_stream,
		cut   = cut_document,
	}
	return &f
}
