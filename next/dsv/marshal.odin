package dsv

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed writes: an Odin value written as a delimited text by the plan a typed read of its type is made by, so the names,
// enums and `-` of the tags are the ones a read takes and `unmarshal` returns the value. The plan of a call is made and
// freed with it when none is given. The value must write as a table, a struct or a map, as a table's rows are.

// Writes `value`, of a type the plan takes, as a delimited text of `spec` under `opts` in a buffer from `allocator` that the
// caller owns. `plan` is the plan of `T` that `plan_make` made, which a call that writes many values of one type makes
// once, else nil. A `Raw` member or a `time.Time` outside years 0 to 9999 is `Bad_Option` naming it, and a value with no
// delimited spelling, a null or a non-finite float, is `Refused`.
marshal :: proc(value: ^$T, spec := Spec.Csv, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (text: []u8, err: Write_Error) {
	w: Writer
	if err = writer_start(&w, spec, opts, {}, allocator); err != nil {
		return nil, err
	}
	if err = marshal_into(&w, value, T, plan, allocator); err != nil {
		_, _ = writer_end(&w)
		return nil, err
	}
	return writer_end(&w)
}

// `marshal` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. On a refusal or a failed sink the
// sink may hold a prefix of the text.
marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Csv, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	w: Writer
	if err := writer_start(&w, spec, opts, sink, allocator); err != nil {
		return err
	}
	if err := marshal_into(&w, value, T, plan, allocator); err != nil {
		_, _ = writer_end(&w)
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
