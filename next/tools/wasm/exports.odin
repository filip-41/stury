// Exported calls of every read that `make lint` builds for WebAssembly, so the object contains each spec's walk.
package wasm_exports

import "base:runtime"
import "core:mem"
import "stury:jq"
import "stury:json"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/query"

// Every tolerance and a step budget, which a walk with `LAX` counts, so the object holds those walks too.
TOLERANT :: json.Options{tolerate = {.Invalid_Utf8, .Non_Finite, .Lone_Surrogate}, budget = {steps = 1 << 40}}

PATH := [?]tape.Step{tape.Name("a"), tape.Index(0)}

validate_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> bool {
	return json.validate(src, S, opts) == nil
}

build_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> int {
	doc, err := json.build(src, S, opts)
	return len(doc.nodes) if err == nil else -1
}

find_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> u64 {
	answer, err := json.find(src, PATH[:], S, opts = opts)
	return answer.lo if err == nil else max(u64)
}

scan_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> int {
	paths := [][]tape.Step{PATH[:]}
	demand, derr := tape.demand_of(paths)
	if derr != nil {
		return -1
	}
	defer tape.destroy_demand(&demand)
	doc, err := json.scan(src, &demand, S, opts = opts)
	return len(doc.nodes) if err == nil else -1
}

// A value of any shape, which a typed read takes from any text.
Value :: union {
	bool,
	f64,
	string,
	[dynamic]Value,
	map[string]Value,
}

unmarshal_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> bool {
	// The arena is on the heap, as the compiler takes the read's error for a reference to what it allocated.
	arena := new(mem.Dynamic_Arena)
	defer free(arena)
	mem.dynamic_arena_init(arena, context.allocator, context.allocator)
	defer mem.dynamic_arena_destroy(arena)
	v: Value
	return json.unmarshal(src, &v, S, opts = opts, allocator = mem.dynamic_arena_allocator(arena)) == nil
}

@(export)
validate_json :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Json)
}

@(export)
validate_jsonc :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Jsonc)
}

@(export)
validate_json5 :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Json5)
}

@(export)
build_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Json)
}

@(export)
build_jsonc :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Jsonc)
}

@(export)
build_json5 :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Json5)
}

@(export)
find_json :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Json)
}

@(export)
find_jsonc :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Jsonc)
}

@(export)
find_json5 :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Json5)
}

@(export)
scan_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Json)
}

@(export)
scan_jsonc :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Jsonc)
}

@(export)
scan_json5 :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Json5)
}

@(export)
validate_tolerant_json :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Json, TOLERANT)
}

@(export)
validate_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
validate_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Json5, TOLERANT)
}

@(export)
build_tolerant_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Json, TOLERANT)
}

@(export)
build_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
build_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Json5, TOLERANT)
}

@(export)
find_tolerant_json :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Json, TOLERANT)
}

@(export)
find_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
find_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Json5, TOLERANT)
}

@(export)
scan_tolerant_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Json, TOLERANT)
}

@(export)
scan_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
scan_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Json5, TOLERANT)
}

@(export)
unmarshal_json :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Json)
}

@(export)
unmarshal_jsonc :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Jsonc)
}

@(export)
unmarshal_json5 :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Json5)
}

@(export)
unmarshal_tolerant_json :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Json, TOLERANT)
}

@(export)
unmarshal_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
unmarshal_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Json5, TOLERANT)
}

// Whether an ECMA pattern matches a text, -1 for a pattern or a search that fails, so the object holds the regex
// engine.
@(export)
regex_matches :: proc "c" (pattern: [^]u8, n: int, text: [^]u8, m: int) -> int {
	context = runtime.default_context()
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	re, err := regex.compile(string(pattern[:n]), .Ecma, {}, allocator, allocator)
	if err.kind != .None {
		return -1
	}
	scratch, scratch_err := regex.scratch_make(allocator)
	if scratch_err.kind != .None {
		return -1
	}
	found, search_err := regex.search(&re, string(text[:m]), 0, nil, &scratch)
	return -1 if search_err.kind != .None else int(found)
}

@(export)
query_digest_len :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	v, s := query.digest_hex(&h, string(p[:n]), .Sha256)
	if s != .Ok {
		return -1
	}
	defer query.release(&h, v)
	return len(query.text_of(v))
}

@(export)
css_select_count :: proc "c" (sel_p: [^]u8, sel_n: int, doc_p: [^]u8, doc_n: int) -> int {
	context = runtime.default_context()
	sel, err := css.compile(string(sel_p[:sel_n]), context.allocator)
	if err != nil {
		return -1
	}
	defer css.destroy(&sel)
	doc, derr := json.build(doc_p[:doc_n], .Json, {}, context.allocator)
	if derr != nil {
		return -1
	}
	defer tape.destroy(&doc)
	found, serr := css.select(&doc, tape.ROOT, &sel, {}, context.allocator)
	if serr != nil {
		return -1
	}
	defer css.destroy_found(&found)
	return len(found.matches)
}

@(export)
jq_eval_count :: proc "c" (prog_p: [^]u8, prog_n: int, in_p: [^]u8, in_n: int) -> int {
	context = runtime.default_context()
	prog, errors := jq.compile(string(prog_p[:prog_n]))
	defer jq.destroy_program(prog)
	if len(errors) > 0 {
		return -1
	}
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	doc, derr := json.build(in_p[:in_n], .Json, {}, context.allocator)
	if derr != nil {
		return -1
	}
	input, s := query.document_value(&h, doc, true)
	if s != .Ok {
		return -1
	}
	count := 0
	sink :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
		(^int)(data)^ += 1
		query.release(h, v)
		return true
	}
	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	end := jq.run_value(&run, input, sink, &count)
	return count if end == .Done else -1
}
