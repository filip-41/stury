package xml

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

Plan :: typed.Plan
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "xml"

// The plan of `T` for XML writes, as `typed.plan_make` makes it, which `marshal` and `marshal_to` take.
@(require_results)
plan_make :: proc($T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (Plan, tape.Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Typed writes: an Odin value written as an XML text by the plan `plan_make` makes, so the names, enums and `-` of
// the tags are the ones `marshal` writes by. The plan of a call is made and freed with it when none is given. The
// value must write as an object of one member, the root element, as `write` takes it.

// Writes `value`, of a type the plan takes, as an XML text of `spec` under `opts` in a buffer from `allocator` that
// the caller owns. `plan` is the plan of `T` that `plan_make` made, which a call that writes many values of one type
// makes once, else nil. A `Raw` member or a `time.Time` outside years 0 to 9999 is `Bad_Option` naming it, and a value
// with no XML spelling, a non-finite float or an invalid element name, is `Refused`.
marshal :: proc(value: ^$T, spec := Spec.Xml, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (text: []u8, err: Write_Error) {
	return marshal_run({}, value, T, spec, opts, plan, allocator)
}

// `marshal` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. On a refusal or a failed sink the
// sink may hold a prefix of the text.
marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Xml, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	_, err := marshal_run(sink, value, T, spec, opts, plan, allocator)
	return err
}

@(private)
marshal_run :: proc(sink: io.Writer, value: rawptr, T: typeid, spec: Spec, opts: Write_Options, plan: ^Plan, allocator: runtime.Allocator) -> (text: []u8, err: Write_Error) {
	w: Writer
	if err = writer_start(&w, spec, opts, sink, allocator); err != nil {
		return nil, err
	}
	if err = marshal_into(&w, value, T, plan, allocator); err != nil {
		writer_drop(&w)
		return nil, err
	}
	return writer_end(&w)
}

@(private)
marshal_into :: proc(w: ^Writer, value: rawptr, T: typeid, plan: ^Plan, allocator: runtime.Allocator) -> Write_Error {
	werr, err := typed.marshal(value, T, TAG, plan, w, token, allocator)
	if werr != nil {
		return werr
	}
	if err != nil {
		if memory, ok := err.(runtime.Allocator_Error); ok {
			return memory
		}
		bad, _ := err.(tape.Bad_Option)
		return bad
	}
	return nil
}
