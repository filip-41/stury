package html

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

Plan :: typed.Plan
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "html"

@(require_results)
plan_make :: proc($T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (Plan, tape.Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

marshal :: proc(value: ^$T, spec := Spec.Html, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (text: []u8, err: Write_Error) {
	w: Writer
	if err = writer_start(&w, spec, opts, {}, allocator); err != nil {
		return nil, err
	}
	if err = marshal_into(&w, value, T, plan, allocator); err != nil {
		writer_drop(&w)
		return nil, err
	}
	return writer_end(&w)
}

marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Html, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	w: Writer
	if err := writer_start(&w, spec, opts, sink, allocator); err != nil {
		return err
	}
	if err := marshal_into(&w, value, T, plan, allocator); err != nil {
		writer_drop(&w)
		return err
	}
	_, err := writer_end(&w)
	return err
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
