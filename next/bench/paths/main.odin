// `paths <scan|stop|query> <paths> <file>`: one read of `paths`, separated by `;`, gb_per_s from the median of ten timed
// calls after two warm-ups, and a checksum of the answers' spans. `scan` runs `json.scan` over the text and judges all of
// it. `stop` reads under `.First` with `stop_early`, as a reader that leaves the rest unread does. `query` builds the
// document once outside the clock and times `core.query`.
package paths

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import core "../../core"
import json "../../json"

WARMUP :: 2
TIMED :: 10

CHECK_OFFSET :: u64(14695981039346656037)
CHECK_PRIME :: u64(1099511628211)

fold :: proc(doc: ^core.Document, answers: []core.Answer) -> u64 {
	h := CHECK_OFFSET
	for a in answers {
		if a.outcome == .Found {
			for b in core.span(doc, a.node) {
				h = (h ~ u64(b)) * CHECK_PRIME
			}
		}
	}
	return h
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: paths <scan|stop|query> <paths> <file>")
		os.exit(2)
	}
	src, read_err := os.read_entire_file_from_path(os.args[3], context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", os.args[3])
		os.exit(1)
	}
	texts := strings.split(os.args[2], ";")
	paths := make([]core.Path, len(texts))
	for text, i in texts {
		p, err := core.parse_path(text)
		if err.kind != .None {
			fmt.eprintln("bad path", text)
			os.exit(1)
		}
		paths[i] = p
	}
	times: [TIMED]i64
	check: u64
	switch os.args[1] {
	case "scan", "stop":
		read := core.Path_Options{dups = .First, stop_early = true} if os.args[1] == "stop" else {}
		for i in 0 ..< WARMUP + TIMED {
			start := time.tick_now()
			doc, err := json.scan(src, .Json, paths, read = read)
			d := i64(time.tick_since(start))
			if err.kind != .None {
				fmt.eprintln("scan:", err)
				os.exit(1)
			}
			if i >= WARMUP {
				times[i - WARMUP] = d
			}
			check = fold(&doc, doc.answers)
			core.destroy(&doc)
		}
	case "query":
		doc, err := json.build(src, .Json)
		if err.kind != .None {
			fmt.eprintln("build:", err)
			os.exit(1)
		}
		for i in 0 ..< WARMUP + TIMED {
			start := time.tick_now()
			answers, qerr := core.query(&doc, paths)
			d := i64(time.tick_since(start))
			if qerr.kind != .None {
				fmt.eprintln("query:", qerr)
				os.exit(1)
			}
			if i >= WARMUP {
				times[i - WARMUP] = d
			}
			check = fold(&doc, answers)
			delete(answers)
		}
	case:
		fmt.eprintln("lane: scan, stop or query")
		os.exit(2)
	}
	slice.sort(times[:])
	ns := (times[(TIMED - 1) / 2] + times[TIMED / 2]) / 2
	fmt.printf("gb_per_s=%.4f ns=%d check=%d\n", f64(len(src)) / f64(ns), ns, check)
}
