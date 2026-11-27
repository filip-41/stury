package yaml

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed writes: an Odin value written as YAML by the plan `plan_make` makes, matching `unmarshal` tags (`yaml`, else `stury`).

marshal :: proc(value: ^$T, spec := Spec.Yaml_1_2, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (text: []u8, err: Write_Error) {
	w: Writer
	if err = writer_start(&w, spec, opts, {}, allocator); err != nil {
		return nil, err
	}
	if err = marshal_into_writer(&w, value, T, plan, allocator); err != nil {
		writer_drop(&w)
		return nil, err
	}
	return writer_end(&w)
}

marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Yaml_1_2, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	w: Writer
	if err := writer_start(&w, spec, opts, sink, allocator); err != nil {
		return err
	}
	if err := marshal_into_writer(&w, value, T, plan, allocator); err != nil {
		writer_drop(&w)
		return err
	}
	_, err := writer_end(&w)
	return err
}

@(private = "file")
marshal_into_writer :: proc(w: ^Writer, value: rawptr, T: typeid, plan: ^Plan, allocator: runtime.Allocator) -> Write_Error {
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
