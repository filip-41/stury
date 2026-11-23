package dsv

import "base:runtime"
import "stury:lib/core/tape"

// The reads and records of the delimited specs that `dsv.reads` returns to a caller picking the format at run time.

// The spec of a delimited format handle.
@(private)
spec_of :: #force_inline proc "contextless" (f: ^tape.Format) -> Spec {
	return Spec(f.id - 4)
}

@(private)
validate_of :: proc(f: ^tape.Format, src: []u8, opts: tape.Options, allocator: runtime.Allocator) -> tape.Error {
	return validate(src, spec_of(f), opts, allocator)
}

@(private)
build_of :: proc(f: ^tape.Format, src: []u8, opts: tape.Options, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	return build(src, spec_of(f), opts, allocator)
}

@(private)
find_of :: proc(f: ^tape.Format, src: []u8, path: []tape.Step, read: tape.Read_Options, opts: tape.Options, allocator: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	return find(src, path, spec_of(f), read, opts, allocator)
}

@(private)
scan_of :: proc(f: ^tape.Format, src: []u8, demand: ^tape.Demand, read: tape.Read_Options, opts: tape.Options, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	return scan(src, demand, spec_of(f), read, opts, allocator)
}

@(private)
records_of :: proc(f: ^tape.Format, src: []u8, framing: tape.Framing, opts: tape.Options, allocator: runtime.Allocator) -> (records: ^tape.Records, err: runtime.Allocator_Error) {
	r := new(Records, allocator) or_return
	r^ = records_open(src, framing, spec_of(f), opts)
	r.reads, r.release, r.allocator = &RECORDS_READS, records_free, allocator
	return r, nil
}

@(private)
records_free :: proc(r: ^tape.Records) {
	free(container_of(r, Records, "records"), r.allocator)
}

@(private, rodata)
RECORDS_READS := tape.Records_Reads {
	validate = proc(r: ^tape.Records, out: []tape.Record, allocator: runtime.Allocator) -> int {
		return records_validate(container_of(r, Records, "records"), out, allocator)
	},
	find = proc(r: ^tape.Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read: tape.Read_Options, allocator: runtime.Allocator) -> int {
		return records_find(container_of(r, Records, "records"), path, out, answers, read, allocator)
	},
	scan = proc(r: ^tape.Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read: tape.Read_Options, allocator: runtime.Allocator) -> int {
		return records_scan(container_of(r, Records, "records"), demand, out, docs, read, allocator)
	},
}
