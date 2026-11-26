package msgpack

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed serialization directly from an Odin value into MessagePack bytes via `Writer` and `typed.marshal`.
// Supports `NaN`/`Inf`/`-Inf`/`-0.0`, `time.Time` (encoded as MessagePack Timestamp `ext -1`), enums, bit_sets,
// unions, `Maybe`, `opts.sort_keys`, `omitempty`/`omitunset`, and streaming sinks.

marshal :: proc(value: ^$T, spec := Spec.Msgpack, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (item: []u8, err: Write_Error) {
	if err = check_write_opts(u8(spec), opts); err != nil {
		return nil, err
	}
	if opts.node != 0 {
		return nil, tape.Bad_Option{"node"}
	}
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

marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Msgpack, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	if err := check_write_opts(u8(spec), opts); err != nil {
		return err
	}
	if opts.node != 0 {
		return tape.Bad_Option{"node"}
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

@(private)
marshal_into_writer :: proc(w: ^Writer, value: rawptr, T: typeid, plan: ^Plan, allocator: runtime.Allocator) -> Write_Error {
	werr, err := typed.marshal(value, T, TAG, plan, w, token, allocator, tag)
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
