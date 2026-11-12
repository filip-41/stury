package html

import "base:runtime"
import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import write "../core/write"
import schema "../core/schema"

// The typed read of HTML, as XML's is. A text is built whole and its document is read by `core/typed`'s read of a
// markup document: an element at a struct is an object whose members are its attributes, its child elements and its
// text as the member `#text`, a list member collects the siblings of its name, and a text read into a number or a
// boolean is read by that type.

// Reads `src`, an HTML text, into `target`. A document's one member is the `html` element and a fragment's members are
// its nodes, so a target is a struct with a member of that name, or a map. An absent member keeps what `target` holds.
// The form with no plan builds one with `context.allocator` and frees it before it returns, and a plan built once with
// `plan_make` is the form for many reads. The target of the form with a spec chosen at run time is any pointer, and a
// target that is no pointer is `.Plan_Mismatch`.
unmarshal :: proc {unmarshal_bound, unmarshal_bound_plan, unmarshal_chosen, unmarshal_chosen_plan}

// Writes `value` as HTML into new bytes from `allocator`, as `write` writes a document: a struct or a map as an element's
// children, a list as elements of its member's name, and a struct of one member `html` as a document. The form with no
// plan builds and frees one for the call, and a plan from `plan_make` is the form for many writes.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Document, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	if value.id == nil || value.data == nil {
		return nil, core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	plan, refusal := plan_built(value.id, spec, opts, {}, nil, context.allocator)
	if refusal.kind != .None {
		return nil, core.error_of(refusal)
	}
	defer typed.plan_destroy(&plan)
	text, err := plan.marshal(&plan, value.data, write, {}, allocator, nil)
	return text, core.error_of(err)
}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc {check_bound, check_chosen}

// The number a `Plain` element value spells, exactly a JSON number, as `core.markup_number` reads it.
number :: core.markup_number

// Returns the typed reads of spec `S`, which a plan `plan_make` builds for that spec holds.
reads :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	return reads_of(S)
}

// Returns the checks of spec `S` read with `opts`, which `model.compile` and `schema.bind` take: the reads, which check a
// text or a document by a plan made from a description or a model, and the handle its plans read by, which reaches no
// service. A struct's member takes its name from the tag key `html`.
checks :: proc "contextless" ($S: Spec, opts := Options{}) -> typed.Format_Checks {
	return {reads_of(S), bound_as(S, opts)}
}

// Binds `s` to texts of `spec` read with `opts`, which the checks of the spec judge.
bind_schema :: proc(s: ^Schema, spec: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	switch spec {
	case .Document: return schema.bind(s, {checks(.Document).reads, as(spec, opts)}, allocator)
	case .Fragment: return schema.bind(s, {checks(.Fragment).reads, as(spec, opts)}, allocator)
	}
	return {}, core.error_of(core.Typed_Refusal{kind = .Bad_Option})
}

// Builds the plan of `T` for HTML, as `typed.plan_make` does. It reads a text only with `reads`, and with none it reads
// through `unmarshal`.
plan_make :: proc(T: typeid, spec := Spec.Document, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_built(T, spec, opts, plan, reads, allocator)
	return made, core.error_of(err)
}

// Builds the plan that reads values of description `d` as `spec`, as `typed.plan_of` does. The reads are the plan's with
// `reads`, as for `plan_make`.
plan_of :: proc(d: ^rules.Description, spec := Spec.Document, opts := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := typed.plan_of(d, as_of(readers_of(.Document), spec, {}), reads, opts, allocator)
	if err == nil {
		plan_bind(&made)
	}
	return made, err
}

// The plan of `T` with HTML's document read, and the reads `reads` holds.
@(private)
plan_built :: proc(T: typeid, spec: Spec, opts: Options, plan: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as_of(readers_of(.Document), spec, opts), plan, allocator)
	plan_bind(&p)
	typed.plan_reads(&p, reads)
	return p, err
}

// Gives a plan HTML's writer, token writer and document read.
@(private)
plan_bind :: proc(p: ^typed.Plan) {
	p.marshal, p.tokens, p.value_text = marshal_text, &TOKENS, write.value_text
	p.node_read, p.node_check = typed.read_nodes, typed.check_nodes
}

// The handle's `plans`: the plan takes its reads and the token writer from the handle's services.
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
		read       = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return typed.read_markup_text(src, as, build_of(S), target, T, plan, read, allocator)},
		check      = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return check_text(src, S, as, target, T, plan, read, allocator)},
		node_read  = typed.read_nodes,
		node_check = typed.check_nodes,
		build      = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_spec(src, S, as, false, allocator)},
		plan       = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, S, {}, opts, reads_of(S), allocator)},
	}
	return &r
}

// Checks the text `src` of spec `S` by `plan`, building its document whole, a handle with no readers read as `S` with
// the default options.
@(private)
check_text :: proc(src: []u8, $S: Spec, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	handle := as
	if handle.readers == nil {
		handle = bound_as(S)
	}
	return typed.check_markup_text(src, handle, build_of(S), target, T, plan, read, allocator)
}

// The handle of spec `S` with the options `plan` reads by.
@(private)
plan_handle :: proc "contextless" ($S: Spec, plan: ^typed.Plan) -> core.As {
	handle := plan.as
	handle.readers, handle.spec = readers_of(S), u8(S)
	return handle
}

@(private)
unmarshal_bound :: proc(src: []u8, $S: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, S, opts)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := typed.read_markup_text(src, bound_as(S, opts), build_of(S), target, T, &plan, read, allocator)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_bound_plan :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(typed.read_markup_text(src, bound_as(S, opts), build_of(S), target, T, plan, read, allocator))
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
	err := chosen_read(src, spec, opts, data, T, &plan, read, allocator)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_chosen_plan :: proc(src: []u8, spec: Spec, target: any, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	data, T, pointer := typed.pointer_target(target)
	if !pointer {
		return core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	return core.error_of(chosen_read(src, spec, opts, data, T, plan, read, allocator))
}

// The read of a text of `spec` chosen at run time.
@(private)
chosen_read :: proc(src: []u8, spec: Spec, opts: Options, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	switch spec {
	case .Document: return typed.read_markup_text(src, bound_as(.Document, opts), build_of(.Document), target, T, plan, read, allocator)
	case .Fragment: return typed.read_markup_text(src, bound_as(.Fragment, opts), build_of(.Fragment), target, T, plan, read, allocator)
	}
	return {kind = .Bad_Option}
}

@(private)
check_bound :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return check_ordered(src, S, plan_handle(S, plan), target, T, plan, read, allocator)
}

@(private)
check_chosen :: proc(src: []u8, spec: Spec, target: any, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	data, T, pointer := typed.pointer_target(target)
	if !pointer {
		return core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	switch spec {
	case .Document: return check_ordered(src, .Document, plan_handle(.Document, plan), data, T, plan, read, allocator)
	case .Fragment: return check_ordered(src, .Fragment, plan_handle(.Fragment, plan), data, T, plan, read, allocator)
	}
	return core.error_of(core.Typed_Refusal{kind = .Bad_Option})
}

// `check_text` with the entries it adds in the order `typed.check_text` gives them.
@(private)
check_ordered :: proc(src: []u8, $S: Spec, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Error {
	from := len(read.sink.entries) if read.sink != nil else 0
	refused := check_text(src, S, as, target, T, plan, read, allocator)
	typed.order_entries(read.sink, from)
	return core.error_of(refused)
}
