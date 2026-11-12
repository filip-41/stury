package toml

// The typed read and write of TOML: `unmarshal` reads the table tree into a value, through the document route of
// `core/typed`, and `marshal` writes a value by the token write. A key is compared by its decoded text.

import "base:runtime"
import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import write "../core/write"

// Reads `src`, a TOML text of `spec`, into `target`. An absent member keeps what `target` holds. A datetime is read into a
// string as its text. The form with no plan builds one with `context.allocator` and frees it before it returns, and a plan
// built once with `plan_make` is the form for many reads. A refusal leaves everything the read allocated reachable from
// `target`. Both specs share one read, so a `spec` chosen at run time links no more than a constant one. The target of
// that form is any pointer, and a target that is no pointer is `.Plan_Mismatch`.
unmarshal :: proc {unmarshal_bound, unmarshal_bound_plan, unmarshal_chosen, unmarshal_chosen_plan}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc {check_bound, check_chosen}

// Writes `value` as TOML into new bytes from `allocator`, as `write` says: a struct or map as a table, a nested one as a
// section, a list of them as an array of tables. The form with no plan builds and frees one for the call, and a plan from
// `plan_make` is the form for many writes.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Toml_1_0, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	if value.id == nil || value.data == nil {
		return nil, core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	plan, refusal := plan_make(value.id, spec, opts)
	if refusal != nil {
		return nil, refusal
	}
	defer typed.plan_destroy(&plan)
	text, err := plan.marshal(&plan, value.data, write, {}, allocator, nil)
	return text, core.error_of(err)
}

// Returns the typed reads of spec `S`, which a plan `plan_make` builds for that spec holds.
reads :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	return reads_of(S)
}

// Returns the checks of spec `S` read with `opts`, which `model.compile` and `schema.bind` take: the reads, which check a
// text or a document by a plan made from a description or a model, and the handle its plans read by, which reaches no
// service.
checks :: proc "contextless" ($S: Spec, opts := Options{}) -> typed.Format_Checks {
	return {reads_of(S), bound_as(S, opts)}
}

// Builds the plan of `T` for TOML, as `typed.plan_make` does. A plan of either spec writes TOML 1.0 forms, and reads a
// document through `typed.unmarshal`. It reads a text only with `reads`, and with none it reads through `unmarshal`.
plan_make :: proc(T: typeid, spec := Spec.Toml_1_0, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_built(T, spec, opts, plan, reads, allocator)
	return made, core.error_of(err)
}

// Builds the plan that reads values of description `d` as `spec`, as `typed.plan_of` does. The reads are the plan's with
// `reads`, as for `plan_make`.
plan_of :: proc(d: ^rules.Description, spec := Spec.Toml_1_0, opts := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := typed.plan_of(d, bound_as(spec, {}), reads, opts, allocator)
	if err == nil {
		plan_bind(&made)
	}
	return made, err
}

// The plan of `T` over `READERS`, with TOML's writer and document read, and the reads `reads` holds.
@(private)
plan_built :: proc(T: typeid, spec: Spec, opts: Options, plan: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, bound_as(spec, opts), plan, allocator)
	plan_bind(&p)
	typed.plan_reads(&p, reads)
	return p, err
}

// Gives a plan TOML's writer, token writer, check of a `Raw` member's text and document read.
@(private)
plan_bind :: proc(p: ^typed.Plan) {
	p.marshal, p.raw, p.tokens, p.value_text = marshal_text, edit_value, &TOKENS, write.value_text
	p.node_read, p.node_check = typed.read_nodes, typed.check_nodes
}

// The handle's `plans`: the plan takes its reads, the check of a `Raw` member and the token writer from the handle's
// services.
@(private)
plan_as :: proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as, opts, allocator)
	p.marshal, p.value_text = marshal_text, write.value_text
	return p, err
}

// The typed reads of a plan read as spec `S`: a text is built and its nodes are read, and a document's nodes are read by
// the generic route, which compares a key by its decoded text.
@(private)
reads_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		read       = text_read,
		check      = text_check,
		node_read  = typed.read_nodes,
		node_check = typed.check_nodes,
		build      = build_text,
		plan       = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, S, {}, opts, reads_of(S), allocator)},
	}
	return &r
}

// The plan's `read`: the text is built whole, since a table's members may be written apart, and the document is read.
@(private)
text_read :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	doc, built := build_text(src, as, context.allocator)
	defer core.destroy(&doc)
	#partial switch built.kind {
	case .None:
	case .Walk:
		err := core.Typed_Refusal{kind = .Walk, at = built.at, inner = built.inner}
		if read.sink != nil {
			read.sink.fatal = err
			typed.sink_error(read.sink, err)
		}
		return err
	case:
		return {kind = .No_Memory}
	}
	return typed.read_nodes(&doc, core.ROOT, T, target, plan, read, allocator)
}

// The plan's `check`: `text_read` with every refusal in `read.sink.entries`. A text the walk refuses is the one entry of
// a check that met the fault before any token.
@(private)
text_check :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	doc, built := build_text(src, as, context.allocator)
	defer core.destroy(&doc)
	#partial switch built.kind {
	case .None:
	case .Walk:
		// No refusal holds the check or its frames, which the stack escape check cannot see through a `Check`'s base
		// `Reader`.
		frames: [4]typed.Frame = ---
		held := ([^]typed.Frame)(uintptr(raw_data(frames[:])))[:len(frames)]
		h: typed.Check
		regs, err := typed.check_start(&h, src, plan, as, T, target, read, held, allocator)
		if err.kind != .None {
			return err
		}
		defer typed.read_release(&h, held)
		return typed.read_end(&h, regs, built.inner)
	case:
		return {kind = .No_Memory}
	}
	return typed.check_nodes(&doc, core.ROOT, T, target, plan, read, allocator)
}

@(private)
unmarshal_bound :: proc(src: []u8, $S: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, S, opts)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := text_read(src, bound_as(S, opts), target, T, &plan, read, allocator)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_bound_plan :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(text_read(src, bound_as(S, opts), target, T, plan, read, allocator))
}

@(private)
unmarshal_chosen :: proc(src: []u8, spec: Spec, target: any, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	data, T, pointer := typed.pointer_target(target)
	if !pointer {
		return core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	plan, refusal := plan_make(T, spec, opts)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := text_read(src, bound_as(spec, opts), data, T, &plan, read, allocator)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_chosen_plan :: proc(src: []u8, spec: Spec, target: any, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	data, T, pointer := typed.pointer_target(target)
	if !pointer {
		return core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	return core.error_of(text_read(src, bound_as(spec, opts), data, T, plan, read, allocator))
}

@(private)
check_bound :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return check_ordered(src, bound_as(S, options_of(plan.as)), target, T, plan, read, allocator)
}

@(private)
check_chosen :: proc(src: []u8, spec: Spec, target: any, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	data, T, pointer := typed.pointer_target(target)
	if !pointer {
		return core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	return check_ordered(src, bound_as(spec, options_of(plan.as)), data, T, plan, read, allocator)
}

// `text_check` with the entries it adds in the order `typed.check_text` gives them.
@(private)
check_ordered :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Error {
	from := len(read.sink.entries) if read.sink != nil else 0
	refused := text_check(src, as, target, T, plan, read, allocator)
	typed.order_entries(read.sink, from)
	return core.error_of(refused)
}
