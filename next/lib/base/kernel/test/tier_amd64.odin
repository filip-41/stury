#+build amd64
package kernel_tests

import "base:intrinsics"
import "core:sync"
import "core:sys/info"
import "core:testing"
import "core:thread"
import k "stury:lib/base/kernel"
import "stury:testkit"

// The tier a build without `-define:TIER` picks is the one the CPU supports, cross-checked independently against
// `core:sys/info` on OSes where `core:sys/info` probes `xgetbv` and leaf 7.
@(test)
tier_matches_the_cpu :: proc(t: ^testing.T) {
	testkit.deadline(t)
	forced :: #config(TIER, -1)
	got := k.tier()
	when forced >= 0 {
		_ = info.cpu_features
		testing.expect_value(t, got, k.Tier(forced))
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .Windows {
		v3 :: info.CPU_Features{.ssse3, .sse41, .sse42, .avx, .avx2, .bmi1, .bmi2, .popcnt, .pclmulqdq}
		want: k.Tier = .V3 if v3 <= info.cpu_features() else .V2
		testing.expect_value(t, got, want)
	} else {
		_ = info.cpu_features
		testing.expect(t, got == .V2 || got == .V3)
	}
	testing.expect_value(t, k.tier(), got)
}

// Concurrent calls to `tier()` race safely on the relaxed-atomic cache and agree across threads.
@(test)
tier_concurrent_calls :: proc(t: ^testing.T) {
	testkit.deadline(t)
	WORKERS :: 8
	CALLS :: 1024
	State :: struct {
		ready: int,
		go:    bool,
	}
	Worker :: struct {
		state: ^State,
		got:   k.Tier,
		same:  bool,
	}
	run :: proc(w: ^Worker) {
		sync.atomic_add(&w.state.ready, 1)
		for !sync.atomic_load(&w.state.go) {
			intrinsics.cpu_relax()
		}
		first := k.tier()
		same := true
		for _ in 1 ..< CALLS {
			if k.tier() != first {
				same = false
			}
		}
		w.got = first
		w.same = same
	}
	state: State
	workers: [WORKERS]Worker
	threads: [WORKERS]^thread.Thread
	for &w, i in workers {
		w.state = &state
		threads[i] = thread.create_and_start_with_poly_data(&w, run)
	}
	for sync.atomic_load(&state.ready) < WORKERS {
		intrinsics.cpu_relax()
	}
	sync.atomic_store(&state.go, true)
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	want := k.tier()
	for w in workers {
		testing.expect(t, w.same)
		testing.expect_value(t, w.got, want)
	}
}

// `caps()` reports individual non-monotonic capabilities, respects `-define:TIER`, agrees with `tier()`, and
// cross-checks against `core:sys/info` on supported OSes.
@(test)
caps_matches_cpu_and_tier :: proc(t: ^testing.T) {
	testkit.deadline(t)
	forced :: #config(TIER, -1)
	got := k.caps()
	v2_caps :: k.Caps{.Ssse3, .Sse41, .Sse42, .Popcnt}
	v3_caps :: k.Caps{.Ssse3, .Sse41, .Sse42, .Popcnt, .Pclmul, .Avx, .Avx2, .Bmi1, .Bmi2}
	when forced == 0 {
		_ = info.cpu_features
		testing.expect_value(t, got, v2_caps)
		testing.expect(t, .Avx2 not_in got && .Pclmul not_in got)
	} else when forced == 1 {
		_ = info.cpu_features
		testing.expect_value(t, got, v3_caps)
		testing.expect(t, .Avx2 in got && .Pclmul in got)
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .Windows {
		f := info.cpu_features()
		testing.expect_value(t, .Ssse3 in got, .ssse3 in f)
		testing.expect_value(t, .Sse41 in got, .sse41 in f)
		testing.expect_value(t, .Sse42 in got, .sse42 in f)
		testing.expect_value(t, .Popcnt in got, .popcnt in f)
		testing.expect_value(t, .Pclmul in got, .pclmulqdq in f)
		testing.expect_value(t, .Avx in got, .avx in f)
		testing.expect_value(t, .Avx2 in got, .avx2 in f)
		testing.expect_value(t, .Bmi1 in got, .bmi1 in f)
		testing.expect_value(t, .Bmi2 in got, .bmi2 in f)
	} else {
		_ = info.cpu_features
	}
	testing.expect_value(t, k.tier() == .V3, v3_caps <= got)
	testing.expect_value(t, k.caps(), got)
}

// Concurrent calls to `caps()` race safely on the relaxed-atomic cache and agree across threads.
@(test)
caps_concurrent_calls :: proc(t: ^testing.T) {
	testkit.deadline(t)
	WORKERS :: 8
	CALLS :: 1024
	State :: struct {
		ready: int,
		go:    bool,
	}
	Worker :: struct {
		state: ^State,
		got:   k.Caps,
		same:  bool,
	}
	run :: proc(w: ^Worker) {
		sync.atomic_add(&w.state.ready, 1)
		for !sync.atomic_load(&w.state.go) {
			intrinsics.cpu_relax()
		}
		first := k.caps()
		same := true
		for _ in 1 ..< CALLS {
			if k.caps() != first {
				same = false
			}
		}
		w.got = first
		w.same = same
	}
	state: State
	workers: [WORKERS]Worker
	threads: [WORKERS]^thread.Thread
	for &w, i in workers {
		w.state = &state
		threads[i] = thread.create_and_start_with_poly_data(&w, run)
	}
	for sync.atomic_load(&state.ready) < WORKERS {
		intrinsics.cpu_relax()
	}
	sync.atomic_store(&state.go, true)
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	want := k.caps()
	for w in workers {
		testing.expect(t, w.same)
		testing.expect_value(t, w.got, want)
	}
}
