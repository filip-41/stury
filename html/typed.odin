// The entries are generic, which the unused-import check does not read.
#+vet !unused-imports
package html

import "base:runtime"
import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import write "../core/write"
import schema "../core/schema"

// The typed read of HTML, as XML's is. A text is built whole and read by `core/typed`'s read of a markup document. An
// element at a struct is an object whose members are its attributes, its child elements and its text as `#text`. A list
// member collects the siblings of its name. A text read into a number or a boolean is read by that type.

// Writes `value` as HTML into new bytes from `allocator`, as `write` writes a document. A struct or a map is an
// element's children, a list is elements of its member's name, and a struct of one member `html` is a document. Without
// a plan, `marshal` builds and frees one per call. Pass a plan from `plan_make` for many writes.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Document, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	nothing: any
	v := typed.marshal_target(value, &nothing)
	plan, refusal := plan_built(v.id, spec, opts, {}, nil, context.allocator)
	return typed.marshal_planned(&plan, core.error_of(refusal), v.data, write, allocator)
}

@(private)
reads :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	return reads_of(.Fragment) if S == .Fragment else reads_of(.Document)
}

// Returns the checks of `spec` read with `opts`, for `model.compile` and `schema.bind`: the reads, which check a text or
// a document by a plan made from a description or a model, and the handle its plans read by, which reaches no service.
// A struct's member takes its name from the tag key `html`.
checks :: proc "contextless" ($S: Spec, opts := Options{}) -> typed.Format_Checks {
	return {reads(S), bound_as(S, opts)}
}

// Reads and compiles the schema `text`, a text of spec `S` read with `opts` that outlives the result, with `load`: where
// file references lead, the draft of a schema with no `$schema`, whether `format` asserts and how a repeated key is judged.
load_schema :: proc(text: []u8, $S: Spec, opts := Options{}, load := Schema_Options{}, allocator := context.allocator) -> (^Schema, core.Error) {
	return schema.compile(text, as(S, opts), load, allocator)
}

// Binds `s` to texts of spec `S` read with `opts`, which the checks of the spec judge.
bind_schema :: proc(s: ^Schema, $S: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	return schema.bind(s, checks(S, opts), allocator)
}

// Builds the plan of `T` for HTML, as `typed.plan_make` does.
plan_make :: proc(T: typeid, spec := Spec.Document, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_built(T, spec, opts, plan, reads, allocator)
	return made, core.error_of(err)
}

// Builds the plan that reads values of description `d` as `spec`, as `typed.plan_of` does. The reads are the plan's with
// `reads`, as for `plan_make`.
plan_of :: proc(d: ^rules.Description, spec := Spec.Document, opts := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := typed.plan_of(d, as_of(&READERS, spec, {}), reads, opts, allocator)
	if err == nil {
		plan_bind(&made)
	}
	return made, err
}

// Builds the plan of `T` with HTML's writer and document read, and `reads` as its reads.
@(private)
plan_built :: proc(T: typeid, spec: Spec, opts: Options, plan: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as_of(&READERS, spec, opts), plan, allocator)
	plan_bind(&p)
	typed.plan_reads(&p, reads)
	return p, err
}

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

// The typed reads of a plan read as spec `S`. A text is built and its nodes are read. A document's nodes are read by
// the generic route, which compares a key by its decoded text.
@(private)
reads_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		read       = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return typed.read_built_text(src, as, build_handle, target, T, plan, read, allocator)},
		check      = check_text,
		node_read  = typed.read_nodes,
		node_check = typed.check_nodes,
		build      = proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {return build_spec(src, S, as, false, allocator)},
		plan       = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, S, {}, opts, reads_of(S), allocator)},
	}
	return &r
}

// Checks `src` by `plan`, building its document whole.
@(private)
check_text :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return typed.check_built_text(src, as, build_handle, target, T, plan, read, allocator)
}

@(private)
plan_handle :: proc "contextless" (spec: Spec, plan: ^typed.Plan) -> core.As {
	handle := typed.handle_of(plan)
	handle.readers, handle.spec = &READERS, u8(spec)
	return handle
}

// Reads `src`, an HTML text, into `target`. A document's one member is the `html` element and a fragment's members are
// its nodes, so a target is a struct with a member of that name, or a map. An absent member keeps what `target` holds.
// The read builds a plan with `context.allocator` and frees it before it returns.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

@(private)
unmarshal_once :: proc(src: []u8, $S: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, S, opts)
	return typed.unmarshal_planned(&plan, refusal, src, bound_as(S, opts), build_handle, target, T, read, allocator)
}

@(private)
unmarshal_plan :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(typed.read_built_text(src, bound_as(S, opts), build_handle, target, T, plan, read, allocator))
}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return typed.check_by(src, plan_handle(S, plan), target, T, plan, read, allocator, check_text)
}
