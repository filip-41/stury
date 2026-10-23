package main

// The duplicate-key, fault, refusal, tiny-document and early-stop path lanes (`substrate_dups_*`,
// `substrate_fault`, `query_dom_fault`, `query_dom_records_ndjson`, `substrate_tiny`, `path_ab_*`).

import json "stury:json"
import "core:fmt"
import "core:time"

// The duplicates pair: both readings walk the same bytes and differ in what they may skip. `.Last_Wins`
// resolves each repeated key by comparing decoded text and keeps the last; `.Skip` locates members
// without resolving a winner. Neither is "the" number, and collapsing the gap would be a semantics change.
Dup_Mode :: enum { Last_Wins, Skip }

// The keys the dups fixture repeats. Kept small on purpose: the lane measures
// the COST of resolving a repeated key, and asking for 4096 keys would make the
// harness's own compare loop the dominant term.
DUP_KEYS :: []string{"k0000", "k0001", "k0002", "k0003", "k0004", "k0005", "k0006", "k0007"}

DUP_REQ: json.Request({.Path})
DUP_STEPS: [8]json.Step
DUP_PATHS: [8]json.Path

// One single-name path per key, in the caller's storage: the paths a keys list asks for.
name_paths :: proc(keys: []string, steps: []json.Step, paths: []json.Path) {
	for k, i in keys {
		steps[i] = json.Name(k)
		paths[i] = json.Path{steps = steps[i:i + 1]}
	}
}

// How many of a request's path answers landed on a value.
found_answers :: proc(answers: []json.Path_Answer) -> int {
	n := 0
	for a in answers {
		if a.outcome == .Found {
			n += 1
		}
	}
	return n
}

dup_read :: proc(data: []byte, mode: Dup_Mode) -> bool {
	if mode == .Last_Wins {
		// The verdict and the answers in one walk: a `.Structural` scan whose paths name the keys.
		name_paths(DUP_KEYS, DUP_STEPS[:], DUP_PATHS[:])
		DUP_REQ.strictness = .Structural
		DUP_REQ.paths = DUP_PATHS[:]
		return scan_ok(data, &DUP_REQ)
	}
	// The skip reading: a `.Structural` validate walks every member without resolving a key, so no
	// decoded-text compare happens at all. That compare is the work last-wins does not get to skip.
	return json.validate(data, .Json, .Structural) == nil
}

bench_dups :: proc(data: []byte, mode: Dup_Mode) -> bool {
	defer json.destroy(&DUP_REQ)
	median_ns, timed := time_median(data, mode, dup_read)
	if !timed {
		return false
	}
	// Last-wins must find every repeated key, or the fixture is not exercising
	// duplicates and the lane is measuring nothing.
	found := found_answers(DUP_REQ.answers[:])
	if mode == .Last_Wins && found != len(DUP_KEYS) {
		return false
	}
	gb_per_s := f64(len(data)) / f64(median_ns)
	fmt.printf("gb_per_s=%.4g found=%d rss_bytes=%d\n", gb_per_s, found, rss_growth(RSS_MARK))
	return true
}

// The reject path: one invalid wire byte 10 from the end of an otherwise
// valid document. The walk judges ~the whole document before refusing, so this
// measures full-walk-then-reject, not an early exit. The verdict AND the
// offset are asserted every iteration: a lane that stopped timing rejects
// would report a fast number for a document it accepted.
bench_fault :: proc(data: []byte) -> bool {
	fault_once :: proc(data: []byte, _: struct{}) -> bool {
		err, has := json.validate(data, .Json, .Strict).?
		if !has {
			return false // must refuse: the fixture is invalid by construction
		}
		want := u64(len(data)) - 10
		return err.offset == want
	}
	median_ns, timed := time_median(data, struct{}{}, fault_once)
	if !timed {
		return false
	}
	gb_per_s := f64(len(data)) / f64(median_ns)
	fmt.printf("gb_per_s=%.4g fault_offset=%d rss_bytes=%d\n", gb_per_s, len(data) - 10, rss_growth(RSS_MARK))
	return true
}

// `.Dom` over a fixture it must refuse; counted on `refusals`, not GB/s. Not bench_query, which fails the
// lane on refusal. `scan` empties the rows before it walks, so no teardown runs between iterations.
bench_dom_refusal :: proc(data: []byte, level: json.Strictness) -> bool {
	req: json.Request({.Dom})
	req.strictness = level
	defer json.destroy(&req)

	// `false` means the scan did NOT refuse, which is the failure this lane exists to catch.
	refused :: proc(data: []byte, req: ^json.Request({.Dom})) -> bool {
		// Two distinct refusals count equally: the request being refused by
		// name (`Request_Error`), and the document being refused as a fault (`Error`).
		return json.scan(data, req) != nil
	}

	median_ns, timed := time_median(data, &req, refused)
	if !timed {
		return false
	}
	refusals := TIMED_ITERS
	gb_per_s := f64(len(data)) / f64(median_ns)
	fmt.printf(
		"refusals=%d ns_per_scan=%d gb_per_s=%.4g rss_bytes=%d\n",
		refusals,
		median_ns,
		gb_per_s,
		rss_growth(RSS_MARK),
	)
	return true
}

// The small-document lane: a ~2 KB scan reported in ns, not GB/s. At this
// size per-call setup (frame array, entry checks, fixture touch) is a visible
// share of the measurement and GB/s arithmetic would flatter or condemn on
// division rather than on the walk.
bench_tiny :: proc(data: []byte) -> bool {
	median_ns, timed := time_median(data, json.Strictness.Strict, validates_clean)
	if !timed {
		return false
	}
	gb_per_s := f64(len(data)) / f64(median_ns)
	fmt.printf("ns_per_scan=%d gb_per_s=%.4g rss_bytes=%d\n", median_ns, gb_per_s, rss_growth(RSS_MARK))
	return true
}

// Query-path A/B: `.Lazy` + `.First` (early stop) against `.Strict` + `.First` (constant baseline) on one
// key, interleaved round by round with the order alternating so a load swing cannot favour one arm. The
// byte column is the result: a stopped walk's GB/s is dominated by per-call setup. `.Strict` reads the
// whole fixture; `.Lazy` reads to the answer's close, and an absent key settles only at the item's end.
// `lazy_ns` and `strict_ns` are per call (a sample's PATH_BATCH scans divided by the count). `emit` names
// the arm, "lazy" or "strict", whose per-call time is also printed as `ns`, the token bench/compare.py reads.
PATH_REQ: json.Request({.Path})
PATH_QUERY: [1]json.Path

path_request :: proc(steps: []json.Step, level: json.Strictness) {
	PATH_QUERY[0] = json.Path{steps = steps}
	PATH_REQ.paths = PATH_QUERY[:]
	PATH_REQ.strictness = level
	PATH_REQ.duplicates = .First
}

path_run :: proc(data: []byte, steps: []json.Step, level: json.Strictness, stop: ^Maybe(u64)) -> bool {
	path_request(steps, level)
	err := json.scan(data, &PATH_REQ)
	stop^ = PATH_REQ.stop
	return err == nil
}

// One timed sample is PATH_BATCH scans back to back: an early stop takes a few timer ticks alone. The
// other libraries' get-one arms (bench/peers) batch by the same count, so a sample is the same number of calls.
PATH_BATCH :: 256

path_time :: proc(data: []byte, steps: []json.Step, level: json.Strictness, out: ^i64) -> bool {
	path_request(steps, level)
	ok := true
	t := time.tick_now()
	for _ in 0 ..< PATH_BATCH {
		ok &&= json.scan(data, &PATH_REQ) == nil
	}
	out^ = i64(time.tick_since(t))
	return ok
}

path_bytes_read :: proc(stop: Maybe(u64), data: []byte) -> u64 {
	if at, has := stop.?; has {
		return at
	}
	return u64(len(data))
}

bench_path_ab :: proc(data: []byte, key, emit: string) -> bool {
	defer json.destroy(&PATH_REQ)
	steps := []json.Step{json.Name(key)}
	stop: Maybe(u64)

	// Both arms must answer the same thing, or the stop changed the answer and
	// the timing is beside the point.
	lazy_answers := make([dynamic]json.Path_Answer, 0, 4, context.temp_allocator)
	defer delete(lazy_answers)
	if !path_run(data, steps, .Lazy, &stop) {
		return false
	}
	lazy_bytes := path_bytes_read(stop, data)
	append(&lazy_answers, ..PATH_REQ.answers[:])
	if !path_run(data, steps, .Strict, &stop) {
		return false
	}
	strict_bytes := u64(len(data))
	if len(PATH_REQ.answers) != len(lazy_answers) {
		return false
	}
	for a, i in PATH_REQ.answers {
		if a.kind != lazy_answers[i].kind || a.lo != lazy_answers[i].lo || a.hi != lazy_answers[i].hi {
			return false
		}
	}

	for _ in 0 ..< WARMUP_ITERS {
		if !path_run(data, steps, .Lazy, &stop) {
			return false
		}
		if !path_run(data, steps, .Strict, &stop) {
			return false
		}
	}
	lazy_ns: [TIMED_ITERS]i64
	strict_ns: [TIMED_ITERS]i64
	for i := 0; i < TIMED_ITERS; i += 1 {
		if i % 2 == 0 {
			if !path_time(data, steps, .Lazy, &lazy_ns[i]) {
				return false
			}
			if !path_time(data, steps, .Strict, &strict_ns[i]) {
				return false
			}
		} else {
			if !path_time(data, steps, .Strict, &strict_ns[i]) {
				return false
			}
			if !path_time(data, steps, .Lazy, &lazy_ns[i]) {
				return false
			}
		}
	}
	lazy_median := f64(median(lazy_ns)) / PATH_BATCH
	strict_median := f64(median(strict_ns)) / PATH_BATCH
	lazy_gbs := f64(lazy_bytes) / lazy_median
	strict_gbs := f64(strict_bytes) / strict_median
	switch emit {
	case "lazy":
		fmt.printf("ns=%.1f ", lazy_median)
	case "strict":
		fmt.printf("ns=%.1f ", strict_median)
	}
	fmt.printf(
		"key=%s lazy_ns=%.1f lazy_bytes=%d lazy_gb_per_s=%.4g strict_ns=%.1f strict_bytes=%d strict_gb_per_s=%.4g answers=%d\n",
		key,
		lazy_median,
		lazy_bytes,
		lazy_gbs,
		strict_median,
		strict_bytes,
		strict_gbs,
		found_answers(PATH_REQ.answers[:]),
	)
	return true
}
