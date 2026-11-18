// `paths <scan|stop|query|build_query|each|iter> <file> <paths> [batch] [largest|dups]`: one read of `paths`, separated by
// `;`, and a checksum of the answers' spans. A `.yaml`, `.toml`, `.xml`, `.html` or `.cbor` file is read through `core`
// as that format by every lane but `each` and `iter`, and its checksum is of the answers' values as text (see
// `fold_text`). `dups` is `first` or `last` for those lanes: the repeat of a key the paths answer. A timed sample is `batch` calls (1 by default), each releasing what it made,
// and ns is the median sample over two warm-ups and ten samples, divided by `batch`. `scan` runs `json.scan` over the
// text and judges all of it. `stop` reads under `.First` with `stop_early`, as a reader that leaves the rest unread
// does. `query` builds the document once outside the clock and times `core.query`. `build_query` times the build and
// the query, the job the other libraries' arms do from the text. `each` takes the answers from `json.each_answer` and
// `iter` from `json.answers`, whose largest batch is `largest` (`ANSWER_BATCH` by default).
package paths

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import core "../../../../core"
import engine "../../../../core/build"
import "../../../formats"
import "../../../timing"
import json "../../../../json"

// The handle of a file that is not JSON, which `scan`, `stop`, `query` and `build_query` read through `core`. `each` and
// `iter` read JSON only.
generic: bool
handle: core.As

// Which of a repeated key a path answers, where the row names one: `first` or `last`. A markup name that repeats among
// its siblings, as every `log` of logs.xml does, is answered by position only through this.
dups: core.Duplicates

// The check of a file that is not JSON: each answer found, in text order, as its value's text followed by a newline.
// A string is its decoded text, a number its decimal digits, and a true, false or null its word, so a library that reads
// the value can hash the same bytes.
fold_text :: proc(doc: ^core.Document, answers: []core.Answer) -> u64 {
	h := timing.CHECK_OFFSET
	buf: [4096]u8
	for a in answers {
		if a.outcome != .Found {
			continue
		}
		text: string
		ok := true
		#partial switch core.kind(doc, a.node) {
		case .String, .Bytes:
			text, ok = core.text(doc, a.node, buf[:])
		case .Number:
			text, ok = core.doc_number_text(doc, a.node, buf[:])
		case .True:
			text = "true"
		case .False:
			text = "false"
		case .Null:
			text = "null"
		case:
			ok = false
		}
		if !ok {
			fmt.eprintln("answer is not a scalar of at most 4096 bytes")
			os.exit(1)
		}
		h = timing.fnv(timing.fnv_bytes(h, transmute([]u8)text), '\n')
	}
	return h
}

fold :: proc(doc: ^core.Document, answers: []core.Answer) -> u64 {
	h := timing.CHECK_OFFSET
	for a in answers {
		if a.outcome == .Found {
			for b in core.span(doc, a.node) {
				h = timing.fnv(h, b)
			}
		}
	}
	return h
}

// One call of `scan` or `stop`. The answers are folded only where `want_check` is set, which is outside the clock.
scan_call :: proc(src: []byte, paths: []core.Path, read: core.Path_Options, want_check: bool) -> u64 {
	doc: core.Document
	err: core.Error
	if generic {
		doc, err = engine.scan(src, handle, paths, read)
	} else {
		doc, err = json.scan(src, .Json, paths, read = read)
	}
	if err != nil {
		core.render(os.to_writer(os.stderr), src, err)
		fmt.eprintln()
		os.exit(1)
	}
	check: u64
	if want_check {
		check = fold_text(&doc, doc.answers) if generic else fold(&doc, doc.answers)
	}
	core.destroy(&doc)
	return check
}

Stream_Check :: struct {
	src:  []byte,
	hash: u64,
}

fold_answer :: #force_inline proc(c: ^Stream_Check, a: core.Token_Answer) {
	if a.outcome == .Found {
		for b in c.src[a.lo:a.hi] {
			c.hash = timing.fnv(c.hash, b)
		}
	}
}

// One call of `each` or `iter`. Both fold every answer as it comes, so the work past the read is the same in each.
stream_call :: proc(src: []byte, paths: []core.Path, iterate: bool, largest: int) -> u64 {
	c := Stream_Check{src, timing.CHECK_OFFSET}
	err: core.Error
	if iterate {
		it := json.answers(src, .Json, paths)
		it.max_batch = largest
		for a in json.next(&it) {
			fold_answer(&c, a)
		}
		err = it.err
	} else {
		err = json.each_answer(src, .Json, paths, &c, proc(state: rawptr, a: core.Token_Answer) -> bool {
			fold_answer((^Stream_Check)(state), a)
			return true
		})
	}
	if err != nil {
		fmt.eprintln("answers:", err)
		os.exit(1)
	}
	return c.hash
}

// One call of `query` on `built`, or of `build_query`, which builds its own document when `built` is nil.
query_call :: proc(built: ^core.Document, src: []byte, paths: []core.Path, want_check: bool) -> u64 {
	doc := built
	own: core.Document
	if doc == nil {
		own = build_document(src)
		doc = &own
	}
	answers, err := json.query(doc, paths, core.Query_Options{dups = dups})
	if err != nil {
		fmt.eprintln("query:", err)
		os.exit(1)
	}
	check: u64
	if want_check {
		check = fold_text(doc, answers) if generic else fold(doc, answers)
	}
	delete(answers)
	if built == nil {
		core.destroy(&own)
	}
	return check
}

main :: proc() {
	if len(os.args) < 4 || len(os.args) > 6 {
		fmt.eprintln("usage: paths <scan|stop|query|build_query|each|iter> <file> <paths> [batch] [largest]")
		os.exit(2)
	}
	lane := os.args[1]
	if lane != "scan" && lane != "stop" && lane != "query" && lane != "build_query" && lane != "each" && lane != "iter" {
		fmt.eprintln("lane: scan, stop, query, build_query, each or iter")
		os.exit(2)
	}
	if kind := formats.of_path(os.args[2]); kind >= .Yaml {
		if lane == "each" || lane == "iter" {
			fmt.eprintln("each and iter read JSON only")
			os.exit(2)
		}
		generic = true
		handle = formats.handle(kind)
	}
	src, read_err := os.read_entire_file_from_path(os.args[2], context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", os.args[2])
		os.exit(1)
	}
	batch := 1
	if len(os.args) >= 5 {
		batch, _ = strconv.parse_int(os.args[4])
	}
	largest := engine.ANSWER_BATCH
	if len(os.args) == 6 && (lane == "each" || lane == "iter") {
		largest, _ = strconv.parse_int(os.args[5])
	}
	if len(os.args) == 6 && lane != "each" && lane != "iter" {
		switch os.args[5] {
		case "first": dups = .First
		case "last": dups = .Last
		case:
			fmt.eprintln("dups: first or last")
			os.exit(2)
		}
	}
	texts := strings.split(os.args[3], ";")
	paths := make([]core.Path, len(texts))
	for text, i in texts {
		p, err := core.parse_path(text)
		if err != nil {
			fmt.eprintln("bad path", text)
			os.exit(1)
		}
		paths[i] = p
	}
	read := core.Path_Options{dups = .First, stop_early = true} if lane == "stop" else {dups = dups}
	built: core.Document
	prebuilt: ^core.Document
	if lane == "query" {
		built = build_document(src)
		prebuilt = &built
	}
	scanning := lane == "scan" || lane == "stop"
	streaming := lane == "each" || lane == "iter"
	check: u64
	switch {
	case streaming: check = stream_call(src, paths, lane == "iter", largest)
	case scanning:  check = scan_call(src, paths, read, true)
	case:           check = query_call(prebuilt, src, paths, true)
	}
	times: [timing.TIMED]i64
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		start := time.tick_now()
		for _ in 0 ..< batch {
			if streaming {
				stream_call(src, paths, lane == "iter", largest)
			} else if scanning {
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
	doc: core.Document
	err: core.Error
	if generic {
		doc, err = core.build(src, handle)
	} else {
		doc, err = json.build(src, .Json)
	}
	if err != nil {
		fmt.eprintln("build:", err)
		os.exit(1)
	}
	return doc
}
