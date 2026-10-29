// The walk's verdict against the current tree's `json.validate`, on seeded texts and mutations of them and of
// JSONTestSuite. `make test-oracle` builds it from a copy of next/ with its packages renamed, since both trees name
// packages `core` and `json`.
package json_oracle

import "core:fmt"
import "core:math/rand"
import "core:testing"
import cur "stury:json"
import json "../.."
import gen "../gen"

SEED :: #config(SEED, 1)
ROUNDS :: #config(ROUNDS, 100_000)

@(test)
agrees_with_current_tree :: proc(t: ^testing.T) {
	state := rand.create(SEED)
	context.random_generator = rand.default_random_generator(&state)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	compared, skipped: int
	check :: proc(t: ^testing.T, src: []u8, compared, skipped: ^int) -> bool {
		want, refused := cur.validate(src).?
		got, bad := json.validate(src, .Strict).?
		// Digit and exponent caps are the layers' above the walk.
		if refused && (want.kind == .Limit_Digits || want.kind == .Limit_Scale) {
			skipped^ += 1
			return true
		}
		compared^ += 1
		same := refused == bad && (!bad || fmt.tprint(want.kind) == fmt.tprint(got.kind) && want.offset == got.offset && want.detail == got.detail)
		return testing.expectf(t, same, "%q: %v, current tree %v", src, got, want)
	}
	suite := #load_directory("../conformance/JSONTestSuite/test_parsing")
	for file in suite {
		if !check(t, file.data, &compared, &skipped) {
			return
		}
		for _ in 0 ..< 20 {
			gen.mutate(&broken, file.data)
			if !check(t, broken[:], &compared, &skipped) {
				return
			}
		}
	}
	for round in 0 ..< ROUNDS {
		clear(&text)
		if round % 3 == 2 {
			gen.pretty(&text, 1 + round % 6)
		} else {
			gen.text(&text, 1 + round % 6)
		}
		gen.mutate(&broken, text[:])
		if !check(t, text[:], &compared, &skipped) || !check(t, broken[:], &compared, &skipped) {
			return
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("seed %d: %d compared, %d skipped for digit caps", SEED, compared, skipped)
}
