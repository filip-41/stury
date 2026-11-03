package marshal_oracle

import "core:fmt"
import core "next:core"
import json "next:json"

read_logs :: proc(src: []u8, v: ^Logs) {assert(json.unmarshal(src, .Json, v).kind == .None)}
read_twitter :: proc(src: []u8, v: ^Twitter) {assert(json.unmarshal(src, .Json, v).kind == .None)}
read_citm :: proc(src: []u8, v: ^Citm) {assert(json.unmarshal(src, .Json, v).kind == .None)}
read_canada :: proc(src: []u8, v: ^Canada) {assert(json.unmarshal(src, .Json, v).kind == .None)}

arm :: proc(name: string, value: any) {
	text, err := json.marshal(value)
	assert(err.kind == .None, fmt.tprint(name, err))
	write_text(fmt.tprintf("%s.json", name), text)
	pretty, perr := json.marshal(value, core.Write_Options{pretty = true, indent = 2})
	assert(perr.kind == .None, fmt.tprint(name, perr))
	write_text(fmt.tprintf("%s.pretty.json", name), pretty)
}

main :: proc() {
	marshal_values("", arm)
}
