package main

// The duplicate-key, fault, refusal, tiny-document and early-stop path lanes (`substrate_dups_*`,
// `substrate_fault`, `query_dom_fault`, `query_dom_records_ndjson`, `substrate_tiny`, `path_ab_*`).

import json "stury:json"
import "core:fmt"
import "core:time"

// The two duplicate-key lanes walk the same bytes and differ in what they may skip. `.Last_Wins` resolves
// each repeated key by comparing decoded text and keeps the last; `.Skip` locates members without resolving
// a winner.
Dup_Mode :: enum { Last_Wins, Skip }

// The repeated keys of the dups fixture that `.Last_Wins` asks for. Asking for all 4096 would make the
// harness's own compare loop dominate the cost of resolving a key.
DUP_KEYS :: []string{"k0000", "k0001", "k0002", "k0003", "k0004", "k0005", "k0006", "k0007"}

DUP_REQ: json.Request({.Path})
DUP_STEPS: [8]json.Step
DUP_PATHS: [8]json.Path

// Fills `paths`, with their steps in `steps`, with one single-name path per key.
name_paths :: proc(keys: []string, steps: []json.Step, paths: []json.Path) {
	for k, i in keys {
		steps[i] = json.Name(k)
		paths[i] = json.Path{steps = steps[i:i + 1]}
	}
}

// Returns how many path answers found a value.
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
		// One `.Structural` scan with a path per key gives the verdict and the answers in one walk.
		name_paths(DUP_KEYS, DUP_STEPS[:], DUP_PATHS[:])
		DUP_REQ.strictness = .Structural
		DUP_REQ.paths = DUP_PATHS[:]
		return scan_ok(data, &DUP_REQ)
	}
	// `.Skip`: a `.Structural` validate walks every member without resolving a key, so it compares no
	// decoded text.
	return json.validate(data, {strictness = .Structural}) == nil
}

bench_dups :: proc(data: []byte, mode: Dup_Mode) -> bool {
	defer json.destroy(&DUP_REQ)
	median_ns, timed := time_median(data, mode, dup_read)
	if !timed {
		return false
	}
	// Last-wins must find every repeated key, or the fixture does not exercise duplicates.
	found := found_answers(DUP_REQ.answers[:])
	if mode == .Last_Wins && found != len(DUP_KEYS) {
		return false
	}
	gb_per_s := f64(len(data)) / f64(median_ns)
	fmt.printf("gb_per_s=%.4g found=%d rss_bytes=%d\n", gb_per_s, found, rss_growth(RSS_MARK))
	return true
}

// Times the refusal of a document whose one invalid wire byte is 10 bytes from the end, so almost the whole
// document is validated first. Every iteration asserts the verdict and the offset, so a scan that accepts
// the document fails the lane.
bench_fault :: proc(data: []byte) -> bool {
	fault_once :: proc(data: []byte, _: struct{}) -> bool {
		err, has := json.validate(data, {strictness = .Strict}).?
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

// Times `.Dom` over a fixture it must refuse, reported as `refusals`, not GB/s; bench_query would fail the
// lane on the refusal. `scan` empties the rows before it walks, so no teardown runs between iterations.
bench_dom_refusal :: proc(data: []byte, level: json.Strictness) -> bool {
	req: json.Request({.Dom})
	req.strictness = level
	defer json.destroy(&req)

	// Returns false, failing the lane, when the scan does not refuse.
	refused :: proc(data: []byte, req: ^json.Request({.Dom})) -> bool {
		// Either refusal counts: a request refusal or a syntax `Error`
		// for a fault in the document.
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

// Times a strict validate of a ~2 KB document, reported in ns, not GB/s. At this
// size per-call setup (frame array, entry checks, fixture touch) is a visible
// share of the time.
bench_tiny :: proc(data: []byte) -> bool {
	median_ns, timed := time_median(data, json.Strictness.Strict, validates_clean)
	if !timed {
		return false
	}
	gb_per_s := f64(len(data)) / f64(median_ns)
	fmt.printf("ns_per_scan=%d gb_per_s=%.4g rss_bytes=%d\n", median_ns, gb_per_s, rss_growth(RSS_MARK))
	return true
}

// Query-path A/B on one key: `.Lazy` + `.First` (early stop) against `.Strict` + `.First` (constant
// baseline). The arm order alternates each round so a load swing cannot favour one arm. Compare the bytes
// read, not GB/s, which per-call setup dominates for a stopped walk. `.Strict` reads the whole fixture;
// `.Lazy` reads to the answer's close, and an absent key settles only at the item's end. `lazy_ns` and
// `strict_ns` are per call (a sample's PATH_BATCH scans divided by the count). `emit` ("lazy" or "strict")
// names the arm whose per-call time is also printed as `ns`, the token bench/compare.py reads.
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

// Scans per timed sample, since one early stop takes only a few timer ticks. The other libraries' GetOne
// arms (bench/peers) use the same count.
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

	// Both arms must give the same answer, or the early stop changed it.
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
