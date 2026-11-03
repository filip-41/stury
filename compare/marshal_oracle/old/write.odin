package marshal_oracle

import "core:fmt"
import json "stury:json"

read_logs :: proc(src: []u8, v: ^Logs) {assert(json.unmarshal(src, v, {borrow_strings = false}, nil, context.allocator) == nil)}
read_twitter :: proc(src: []u8, v: ^Twitter) {assert(json.unmarshal(src, v, {borrow_strings = false}, nil, context.allocator) == nil)}
read_citm :: proc(src: []u8, v: ^Citm) {assert(json.unmarshal(src, v, {borrow_strings = false}, nil, context.allocator) == nil)}
read_canada :: proc(src: []u8, v: ^Canada) {assert(json.unmarshal(src, v, {borrow_strings = false}, nil, context.allocator) == nil)}

arm :: proc(name: string, value: any) {
	buf := make([dynamic]u8)
	err := json.marshal_append(&buf, value)
	assert(err == nil, fmt.tprint(name, err))
	write_text(fmt.tprintf("%s.json", name), buf[:])
	clear(&buf)
	perr := json.marshal_append(&buf, value, json.Marshal_Opts{pretty = true, indent = 2})
	assert(perr == nil, fmt.tprint(name, perr))
	write_text(fmt.tprintf("%s.pretty.json", name), buf[:])
}

main :: proc() {
	marshal_values("", arm)
}
