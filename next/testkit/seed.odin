package testkit

import "base:runtime"
import "core:log"
import "core:math/rand"
import "core:testing"
import "core:time"

// The seed every test's random choices start from, a test adding its own `salt`. A failing test reports it, and
// `-define:SEED=n` runs the suite again from the same one.
SEED: u64 : #config(SEED, 0)

// The factor on the rounds of a randomized test, which `rounds` applies. `-define:ROUNDS=n` raises the confidence of
// a run, and a failure of a longer run reproduces with the same `SEED` and `ROUNDS`.
ROUNDS: int : #config(ROUNDS, 1)

// The seconds after which a test that has not returned fails, with its name, as the runner reports it.
TIMEOUT_SECONDS: int : #config(TEST_TIMEOUT_SECONDS, 600)

// Fails the running test at the timeout. Every test calls it first, so a hang ends as a failure of that test.
deadline :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Duration(TIMEOUT_SECONDS) * time.Second)
}

// Whether a run reads a point of a sweep that is too long to read in full: one point in `of` by default, every point
// at `ROUNDS` of `of`, chosen from the test's seeded generator.
sampled :: proc(of: int) -> bool {
	return ROUNDS >= of || rand.int_max(of) < ROUNDS
}

// The rounds of a randomized test that has `n` by default.
rounds :: proc "contextless" (n: int) -> int {
	return n * ROUNDS
}

// A generator of the test's random choices, which the test sets as `context.random_generator`, over `state`, which
// it keeps for as long as it uses the generator. A failed test logs the seed.
seeded :: proc(t: ^testing.T, state: ^rand.Default_Random_State, salt: u64 = 0) -> runtime.Random_Generator {
	state^ = rand.create(SEED + salt)
	testing.cleanup(t, report_seed, t)
	return rand.default_random_generator(state)
}

@(private)
report_seed :: proc(data: rawptr) {
	if t := (^testing.T)(data); testing.failed(t) {
		log.errorf("random choices from -define:SEED=%d with -define:ROUNDS=%d", SEED, ROUNDS)
	}
}
