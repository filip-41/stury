// Exported calls of every read that `make lint` builds for WebAssembly, so the object contains each spec's walk.
package wasm_exports

import "base:runtime"
import "stury:json"
import "stury:lib/core/tape"

TOLERANT :: json.Options{tolerate = {.Invalid_Utf8, .Non_Finite, .Lone_Surrogate}}

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
