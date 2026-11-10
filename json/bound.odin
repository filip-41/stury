// `compose` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
#+private
package json

import "base:runtime"
import core "../core"
import compose "../core/compose"
import typed "../core/typed"
import records "../core/records"

// The tables a constant-spec entry point binds to its spec. Each factory returns the address of a `@(static, rodata)`
// local of its instance, so a program links the walks of the specs it names. Nothing reachable from here may name `as`,
// `HANDLE` or `SERVICES`, which reach every spec's walk.

// The readers of a document built as spec `S`: the leaves, and the spec's own `close_end`. It holds no services.
readers_of :: proc "contextless" ($S: Spec) -> ^core.Readers {
	@(static, rodata) r := core.Readers {
		text = text, key_equals = key_equals_decode, number = number, number_f32 = number_f32,
		resolve = spelling_resolve, format = rules_of,
		close_end = proc(doc: ^core.Document, i: core.Node_Index) -> u64 {return close_end_spec(doc, i, S)},
		tag_key = "json", key_open = "\"", key_close = "\":",
	}
	return &r
}

// The edit services of a list over a document of spec `S`: its value check and its commit's check are the walk of `S`.
edit_of :: proc "contextless" ($S: Spec) -> ^core.Edit_Services {
	@(static, rodata) e := core.Edit_Services {
		value      = proc(v: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {return edit_value(src, allocator, v.max_depth, S)},
		key_text   = edit_key_text,
		comment    = edit_comment,
		separators = edit_separators,
		member_sep = proc(_: ^core.Document, _: core.Node_Index) -> string {return ","},
		key_sep    = ":",
		spell      = edit_spell,
		validate   = proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {
			h: core.No_Hooks
			regs: core.Hook_Regs
			return walk_text(src, 0, S, options_of(as), &h, &regs, core.no_hook)
		},
	}
	return &e
}

// The typed reads of a plan read as spec `S`.
reads_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		read  = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {return read_text(src, S, options_of(as), target, T, plan, read, allocator, false)},
		check = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {return read_text(src, S, options_of(as), target, T, plan, read, allocator, true)},
		build = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_spec(src, S, as, false, allocator)},
	}
	return &r
}

// The reads of a plan that `unmarshal` of spec `S` makes for one call, which holds the build of a `core.Value` member and
// no read or check, so the call links the walks it uses.
build_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		build = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_spec(src, S, as, false, allocator)},
	}
	return &r
}

// The framing of records read as spec `S`: the walks that frame and judge a record are the walk of `S`. It holds no record
// reads, which `record_docs(S)` gives.
framing_of :: proc "contextless" ($S: Spec) -> ^records.Framing_Services {
	@(static, rodata) f := records.Framing_Services {
		ends  = {.Lines = '\n', .Seq = 0x1e, .Concatenated = 0, .Entries = 0},
		next  = {
			.Lines        = frame_line,
			.Seq          = frame_line,
			.Concatenated = proc(it: ^records.Reader) -> (records.Record, bool) {return next_walked_spec(it, S)},
			.Entries      = proc(it: ^records.Reader) -> (records.Record, bool) {return next_walked_spec(it, S)},
		},
		judge = proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) {return judge_spec(it, rec, S)},
		guess = guess_start,
		exact = exact_cut,
		piece = piece_of,
		whole = proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64) {return whole_spec(src, as, S)},
	}
	return &f
}

// The handle of spec `S` read with `opts`, over `readers_of(S)`.
bound_as :: proc "contextless" ($S: Spec, opts := Options{}) -> core.As {
	return {readers = readers_of(S), max_depth = opts.max_depth, spec = u8(S), tolerate = opts.tolerate, opts = {0 = u8(opts.refuse_non_finite)}}
}

// The leaves of a plan and a typed read, with no `close_end` and no services. Every plan holds this table, and the spec
// and the option bytes in `As`.
@(rodata)
PLAN_READERS := core.Readers {
	text = text, key_equals = key_equals_decode, number = number, number_f32 = number_f32,
	format = rules_of, tag_key = "json", key_open = "\"", key_close = "\":",
}

// A plan's check of a `Raw` member's text, which is JSON's value check.
raw_check :: proc(v: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	return edit_value(src, allocator, v.max_depth, .Json)
}
