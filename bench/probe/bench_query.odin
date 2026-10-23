package main

// Query lanes (`query_nodes`, `query_dom`): one reused request, as a program that scans many documents
// keeps one. The warmup passes grow its output, so the timed scans append into capacity they already hold.
// `scan` empties its output before it walks, so a rescan needs no teardown between iterations.

import json "stury:json"
import "core:fmt"
import "core:os"
import "core:time"

// One scan; false for a configuration fault or a fault in the document.
scan_ok :: proc(data: []byte, req: ^json.Request($Q)) -> bool {
	return json.scan(data, req) == nil
}

// A fold of every value of `doc`, read through the public readers: `get_number` on a number, `get_string` on a
// string, `kind` alone on the rest. `.Dom` checks a number's grammar when it builds and converts it only here,
// and borrows an unescaped string; this is the work a parser that converts while it parses has done by the time
// its tree is built, and no more. Nodes count up from `ROOT` in document order to the first one `kind` refuses,
// so one pass reads them all; a recursive walk would also time the CPU's return prediction, which on a deep
// document costs more than the reads.
read_every_value :: proc(doc: ^json.Document) -> (acc: u64, ok: bool) {
	for n := json.ROOT; ; n += 1 {
		kd := json.kind(doc, n) or_break
		switch kd {
		case .Number:
			num := json.get_number(doc, n) or_return
			acc += transmute(u64)num.value
		case .String:
			s := json.get_string(doc, n) or_return
			acc += u64(len(s))
		case .Object, .Array:
		case .True, .False, .Null:
			acc += u64(kd)
		}
	}
	return acc, true
}

// One query lane: build the request, warm up, time TIMED_ITERS scans, print the tokens. With `read_all` (a
// `.Dom` lane) each timed sample also reads every value of the built document.
bench_query :: proc(data: []byte, level: json.Strictness, $Q: bit_set[json.Query], read_all := false) -> bool {
	req: json.Request(Q)
	req.strictness = level
	defer json.destroy(&req)
	for _ in 0 ..< WARMUP_ITERS {
		if !scan_ok(data, &req) {
			return false
		}
	}
	times: [TIMED_ITERS]i64
	regrew := false
	read_acc: u64
	for i in 0 ..< TIMED_ITERS {
		cap_before := cap(req.doc.rows)
		t := time.tick_now()
		if !scan_ok(data, &req) {
			return false
		}
		when .Dom in Q {
			if read_all {
				acc, read := read_every_value(&req.doc)
				if !read {
					return false
				}
				read_acc += acc
			}
		}
		times[i] = i64(time.tick_since(t))
		regrew ||= cap(req.doc.rows) != cap_before
	}
	gb_per_s := f64(len(data)) / f64(median(times))
	fmt.printf("gb_per_s=%.4g nodes=%d read_acc=%d rss_bytes=%d\n", gb_per_s, len(req.doc.rows), read_acc, rss_growth(RSS_MARK))
	if regrew {
		fmt.fprintf(os.stderr, "probe: row arrays regrew inside the timed region: gb_per_s timed malloc, not the scanner\n")
		return false
	}
	return true
}
