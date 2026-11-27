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
	return marshal_run(value, T, spec, opts, plan, {}, allocator)
}

// `marshal` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. On a refusal or a failed sink the
// sink may hold a prefix of the text.
marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Csv, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	_, err := marshal_run(value, T, spec, opts, plan, sink, allocator)
	return err
}

@(private)
marshal_run :: proc(value: rawptr, T: typeid, spec: Spec, opts: Write_Options, plan: ^Plan, sink: io.Writer, allocator: runtime.Allocator) -> (text: []u8, err: Write_Error) {
	w: Writer
	writer_start(&w, spec, opts, sink, allocator) or_return
	werr, perr := typed.marshal(value, T, TAG, plan, &w, token, allocator)
	if werr != nil || perr != nil {
		writer_drop(&w)
		if werr != nil {
			return nil, werr
		}
		if memory, ok := perr.(runtime.Allocator_Error); ok {
			return nil, memory
		}
		bad, _ := perr.(tape.Bad_Option)
		return nil, bad
	}
	return writer_end(&w)
}
