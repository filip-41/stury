// `paths <scan|stop|query|build_query> <paths> <file> [batch]`: one read of `paths`, separated by `;`, and a checksum of
// the answers' spans. A timed sample is `batch` calls (1 by default), each releasing what it made, and ns is the
// median sample over two warm-ups and ten samples, divided by `batch`. `scan` runs `json.scan` over the text and
// judges all of it. `stop` reads under `.First` with `stop_early`, as a reader that leaves the rest unread does. `query`
// builds the document once outside the clock and times `core.query`. `build_query` times the build and the query, the job
// the other libraries' arms do from the text.
package paths

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import core "../../core"
import "../timing"
import json "../../json"

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

// One call of `scan` or `stop`. The answers are folded only where `want_check` is set, which is outside the clock.
scan_call :: proc(src: []byte, paths: []core.Path, read: core.Path_Options, want_check: bool) -> u64 {
	doc, err := json.scan(src, .Json, paths, read = read)
	if err != nil {
		fmt.eprintln("scan:", err)
		os.exit(1)
	}
	check := fold(&doc, doc.answers) if want_check else 0
	core.destroy(&doc)
	return check
}

// One call of `query` on `built`, or of `build_query`, which builds its own document when `built` is nil.
query_call :: proc(built: ^core.Document, src: []byte, paths: []core.Path, want_check: bool) -> u64 {
	doc := built
	own: core.Document
	if doc == nil {
		own = build_document(src)
		doc = &own
	}
	answers, err := core.query(doc, paths)
	if err != nil {
		fmt.eprintln("query:", err)
		os.exit(1)
	}
	check := fold(doc, answers) if want_check else 0
	delete(answers)
	if built == nil {
		core.destroy(&own)
	}
	return check
}

main :: proc() {
	if len(os.args) != 4 && len(os.args) != 5 {
		fmt.eprintln("usage: paths <scan|stop|query|build_query> <paths> <file> [batch]")
		os.exit(2)
	}
	lane := os.args[1]
	if lane != "scan" && lane != "stop" && lane != "query" && lane != "build_query" {
		fmt.eprintln("lane: scan, stop, query or build_query")
		os.exit(2)
	}
	src, read_err := os.read_entire_file_from_path(os.args[3], context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", os.args[3])
		os.exit(1)
	}
	batch := 1
	if len(os.args) == 5 {
		batch, _ = strconv.parse_int(os.args[4])
	}
	texts := strings.split(os.args[2], ";")
	paths := make([]core.Path, len(texts))
	for text, i in texts {
		p, err := core.parse_path(text)
		if err != nil {
			fmt.eprintln("bad path", text)
			os.exit(1)
		}
		paths[i] = p
	}
	read := core.Path_Options{dups = .First, stop_early = true} if lane == "stop" else {}
	built: core.Document
	prebuilt: ^core.Document
	if lane == "query" {
		built = build_document(src)
		prebuilt = &built
	}
	scanning := lane == "scan" || lane == "stop"
	check := scan_call(src, paths, read, true) if scanning else query_call(prebuilt, src, paths, true)
	times: [timing.TIMED]i64
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		start := time.tick_now()
		for _ in 0 ..< batch {
			if scanning {
				scan_call(src, paths, read, false)
			} else {
				query_call(prebuilt, src, paths, false)
			}
		}
		d := i64(time.tick_since(start))
		if i >= timing.WARMUP {
			times[i - timing.WARMUP] = d
		}
	}
	ns := timing.median(&times) / i64(batch)
	fmt.printf("gb_per_s=%.4f ns=%d check=%d\n", f64(len(src)) / f64(ns), ns, check)
}

build_document :: proc(src: []byte) -> core.Document {
	doc, err := json.build(src, .Json)
	if err != nil {
		fmt.eprintln("build:", err)
		os.exit(1)
	}
	return doc
}
