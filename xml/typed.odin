package xml

import "base:runtime"
import core "../core"
import typed "../core/typed"
import write "../core/write"
import schema "../core/schema"

// The typed read of XML. A text is built whole and its document is read by `core/typed`'s read of a markup
// document: an element at a struct is an object whose members are its attributes, its child elements and its text as
// the member `#text`, a list member collects the siblings of its name, and a text read into a number or a boolean is
// read by that type.

// Writes `value` as XML into new bytes from `allocator`, as `write` says: a struct or a map as an element's children, a
// list as elements of its member's name, and the value as the one member that is the root element. An empty list, text
// or struct is `.Unwritable`, as for `write`, and `omitempty` leaves it out. The form with no plan builds and frees one
// for the call, and a plan from `plan_make` is the form for many writes.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Xml, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
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

// The number a `Plain` element value spells, exactly a JSON number, as `core.markup_number` reads it.
number :: core.markup_number

// Returns the checks of `spec` read with `opts`, which `model.compile` and `schema.bind` take: the reads, which check a
// text or a document by a plan made from a description or a model, and the handle its plans read by, which reaches no
// service. A struct's member takes its name from the tag key `xml`.
checks :: proc "contextless" (spec: Spec, opts := Options{}) -> typed.Format_Checks {
	return {&READS, bound_as(spec, opts)}
}

// Binds `s` to texts of `spec` read with `opts`, which the checks of the spec judge.
bind_schema :: proc(s: ^Schema, spec: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	switch spec {
	case .Xml: return schema.bind(s, {checks(.Xml).reads, as(spec, opts)}, allocator)
	}
	return {}, core.error_of(core.Typed_Refusal{kind = .Bad_Option})
}

// Builds the plan of `T` for XML, as `typed.plan_make` does.
plan_make :: proc(T: typeid, spec := Spec.Xml, opts := Options{}, plan := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_built(T, spec, opts, plan, nil, allocator)
	return made, core.error_of(err)
}

// The plan of `T` with XML's writer and document read, and the reads `reads` holds.
@(private)
plan_built :: proc(T: typeid, spec: Spec, opts: Options, plan: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as_of(&READERS, spec, opts), plan, allocator)
	plan_bind(&p)
	typed.plan_reads(&p, reads)
	return p, err
}

// Gives a plan XML's writer, token writer and document read.
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

// The typed reads of a plan: a text is built and its nodes are read, and a document's nodes are read by
// the generic route, which compares a key by its decoded text.
@(private, rodata)
READS := typed.Format_Reads {
	read       = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return text_read(src, .Xml, as, target, T, plan, read, allocator)},
	check      = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return check_text(src, .Xml, as, target, T, plan, read, allocator)},
	node_read  = typed.read_nodes,
	node_check = typed.check_nodes,
	build      = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_spec(src, .Xml, as, false, allocator)},
	plan       = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, .Xml, {}, opts, &READS, allocator)},
}

// The plan's `read`: the text is built whole, under `.Refuse` refusing a repeated element, and its root is read.
@(private)
text_read :: proc(src: []u8, spec: Spec, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return typed.read_built_text(src, as, build_handle, target, T, plan, read, allocator)
}

// Checks the text `src` of `spec` by `plan`, building its document whole, a handle with no readers read as `spec` with
// the default options.
@(private)
check_text :: proc(src: []u8, spec: Spec, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	handle := as
	if handle.readers == nil {
		handle = bound_as(spec)
	}
	return typed.check_built_text(src, handle, build_handle, target, T, plan, read, allocator)
}

// Reads `src`, an XML text, into `target`. The document's one member is the root element, so a target is a struct with
// a member of the root's name, or a map. An absent member keeps what `target` holds. The read builds a plan with
// `context.allocator` and frees it before it returns.
unmarshal :: proc(src: []u8, spec: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, spec, opts)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := text_read(src, spec, bound_as(spec, opts), target, T, &plan, read, allocator)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc(src: []u8, spec: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return check_ordered(src, spec, bound_as(spec, options_of(plan.as)), target, T, plan, read, allocator)
}

// `check_text` with the entries it adds in the order `typed.check_text` gives them.
@(private)
check_ordered :: proc(src: []u8, spec: Spec, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Error {
	from := len(read.sink.entries) if read.sink != nil else 0
	refused := check_text(src, spec, as, target, T, plan, read, allocator)
	typed.order_entries(read.sink, from)
	return core.error_of(refused)
}
