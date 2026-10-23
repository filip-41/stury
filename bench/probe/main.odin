package main

// Bench probe. `probe --lane <name> [--fixture <name or path>] [--key <key>] [--emit lazy|strict]` times one
// lane and prints key=value tokens. Exits 2 on a usage error or an unknown lane, and 1 when the fixture is
// missing or the lane fails.
// Timing: warm, -o:speed, serial, median of TIMED_ITERS timed iterations after WARMUP_ITERS untimed ones.

import host "stury:host"
import json "stury:json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// bench/compare.py's `cycles` also builds the probe with `-define:TIMED_ITERS=50` and takes one iteration's
// cost from the difference between the two builds' whole-process counters.
TIMED_ITERS :: #config(TIMED_ITERS, 10)
#assert(TIMED_ITERS % 2 == 0, "median averages the two middle samples")
WARMUP_ITERS :: 2

// Peak RSS after the fixture is loaded. A lane reports its growth past this mark.
RSS_MARK: u64

// Fixture and strictness of each lane that `lane_fixture`'s naming rules do not cover.
LANE_FIXTURES := [?]struct {
	lane, file: string,
	level:      json.Strictness,
}{
	{"substrate", "nested.json", .Strict},
	{"records_scan", "records.ndjson", .Strict},
	{"ndjson_records", "records.ndjson", .Strict},
	{"substrate_dups_lastwins", "dups.json", .Structural},
	{"substrate_dups_skip", "dups.json", .Structural},
	// Query-path A/B: `.Lazy` + `.First` against `.Strict` + `.First` on the
	// same key, so the only difference is the early stop.
	{"path_ab_early", "config.json", .Structural},
	{"path_ab_middle", "config.json", .Structural},
	{"path_ab_late", "config.json", .Structural},
	{"path_ab_absent", "config.json", .Structural},
	// Query lanes, each timing one query kind alone.
	{"query_nodes", "nested.json", .Strict},
	{"query_dom", "nested.json", .Strict},
	{"dom_read", "nested.json", .Strict},
	// `.Dom` refuses this fixture. The lane counts refusals, not bytes per second.
	{"query_dom_records_ndjson", "records.ndjson", .Strict},
	// Both files hold the same 32,768 records, one per line or in one array. The time difference is the cost
	// of per-line framing.
	{"records_scan_manysmall", "manysmall.ndjson", .Strict},
	{"records_scan_onebig", "onebig.ndjson", .Strict},
	{"streaming_records", "records.ndjson", .Strict},
	// Wildcard paths over logs.json, both on the path automaton. `.logs[].id` matches by name, one answer
	// per record; `.logs[][]` answers every member value.
	{"path_wild_logs_id", "logs.json", .Structural},
	{"path_wild_logs_all", "logs.json", .Structural},
	// Negative indices on a non-root array, `.logs[-1]` and `.logs[-20]`. Each is answered by re-reading the
	// array's tail once its length is known, so both cost about as much as a forward index.
	{"path_logs_last", "logs.json", .Strict},
	{"path_logs_back", "logs.json", .Strict},
	// Encode lanes. The document lanes accept `--fixture`. The number lanes generate their values and load
	// only tiny.json.
	{"encode_doc", "logs.json", .Strict},
	{"encode_doc_pretty", "logs.json", .Strict},
	{"encode_doc_indent2", "logs.json", .Strict},
	{"encode_doc_indent4", "logs.json", .Strict},
	{"encode_doc_writer", "logs.json", .Strict},
	{"encode_doc_ascii", "escape.json", .Strict},
	{"encode_doc_html", "escape.json", .Strict},
	{"marshal_logs", "logs.json", .Strict},
	{"marshal_logs_enums", "logs.json", .Strict},
	{"marshal_logs_writer", "logs.json", .Strict},
	{"set_logs", "logs.json", .Strict},
	{"remove_logs", "logs.json", .Strict},
	{"insert_logs", "logs.json", .Strict},
	{"splice_logs", "logs.json", .Strict},
	{"encode_string", "longtext.json", .Strict},
	{"encode_f64", "tiny.json", .Strict},
	{"encode_i64", "tiny.json", .Strict},
	// Unmarshal lanes; the tape arms are their baselines.
	{"unmarshal_nested", "nested.json", .Strict},
	{"tape_unmarshal_nested", "nested.json", .Strict},
	{"unmarshal_logs", "logs.json", .Strict},
	{"tape_unmarshal_logs", "logs.json", .Strict},
	{"unmarshal_logs_subset", "logs.json", .Strict},
	{"tape_unmarshal_logs_subset", "logs.json", .Strict},
	{"unmarshal_logs_subset_lazy", "logs.json", .Strict},
	{"check_logs", "logs.json", .Strict},
	{"check_nested", "nested.json", .Strict},
	{"set_config", "config.json", .Strict},
	{"unmarshal_config", "config.json", .Strict},
	{"unmarshal_config_lazy", "config.json", .Strict},
	{"unmarshal_nested_arena", "nested.json", .Strict},
	{"unmarshal_logs_arena", "logs.json", .Strict},
	{"unmarshal_logs_subset_arena", "logs.json", .Strict},
	{"unmarshal_config_arena", "config.json", .Strict},
	{"tape_unmarshal_config", "config.json", .Strict},
	// CSV lanes (bench_csv.odin); `--fixture` reads another file.
	{"csv_validate", "table.csv", .Strict},
	{"csv_records", "table.csv", .Strict},
	{"csv_document", "table.csv", .Strict},
	{"csv_document_read", "table.csv", .Strict},
	{"csv_unmarshal_table", "table.csv", .Strict},
	{"csv_unmarshal_table_borrow", "table.csv", .Strict},
	{"csv_unmarshal_text", "text.csv", .Strict},
	{"csv_unmarshal_text_borrow", "text.csv", .Strict},
	{"csv_marshal_table", "table.csv", .Strict},
	{"csv_marshal_text", "text.csv", .Strict},
}

// Returns a lane's fixture and strictness. A lane in `LANE_FIXTURES` takes its entry; `<lane>_structural` is
// `<lane>` at `.Structural`. `query_dom_<f>`, `query_nodes_<f>`, `dom_read_<f>` and `substrate_<f>` read
// `<f>.json` at `.Strict`, because a `.Structural` scan refuses `.Nodes` and `.Dom` (`Nodes_Need_Strict`) and
// accepts documents stury must refuse.
lane_fixture :: proc(lane: string) -> (file: string, level: json.Strictness, ok: bool) {
	for e in LANE_FIXTURES {
		if e.lane == lane {
			return e.file, e.level, true
		}
	}
	if strings.has_suffix(lane, "_structural") {
		file, _, ok = lane_fixture(strings.trim_suffix(lane, "_structural"))
		return file, .Structural, ok
	}
	for prefix in ([?]string{"query_dom_", "query_nodes_", "substrate_", "dom_read_"}) {
		if strings.has_prefix(lane, prefix) {
			return fmt.tprintf("%s.json", lane[len(prefix):]), .Strict, true
		}
	}
	return "", .Strict, false
}

// Resolves a fixture name and reports whether the file exists. A name containing `/` is a path; any other
// name is a file in bench/fixtures.
fixture_path :: proc(name: string) -> (string, bool) {
	path := strings.contains_rune(name, '/') ? name : fmt.tprintf("bench/fixtures/%s", name)
	return path, os.exists(path)
}

find_fixture :: proc(name: string) -> ([]byte, bool) {
	path, found := fixture_path(name)
	if !found {
		return nil, false
	}
	data, err := os.read_entire_file(path, context.allocator)
	return data, err == nil
}

median :: proc(xs: [TIMED_ITERS]i64) -> i64 {
	sorted := xs
	for i in 1 ..< TIMED_ITERS {
		j := i
		for j > 0 && sorted[j] < sorted[j - 1] {
			sorted[j], sorted[j - 1] = sorted[j - 1], sorted[j]
			j -= 1
		}
	}
	return (sorted[TIMED_ITERS / 2 - 1] + sorted[TIMED_ITERS / 2]) / 2
}

// Stores the time `d` of iteration `i` of a WARMUP_ITERS + TIMED_ITERS loop, skipping the warm-up iterations.
keep_timed :: proc(times: ^[TIMED_ITERS]i64, i: int, d: i64) {
	if i >= WARMUP_ITERS {
		times[i - WARMUP_ITERS] = d
	}
}

// Returns the median ns of TIMED_ITERS runs of `once` after WARMUP_ITERS untimed ones, or false when any run
// fails.
time_median :: proc(data: []byte, ctx: $C, once: proc(data: []byte, ctx: C) -> bool) -> (ns: i64, ok: bool) {
	for _ in 0 ..< WARMUP_ITERS {
		if !once(data, ctx) {
			return 0, false
		}
	}
	times: [TIMED_ITERS]i64
	for i in 0 ..< TIMED_ITERS {
		t := time.tick_now()
		passed := once(data, ctx)
		times[i] = i64(time.tick_since(t))
		if !passed {
			return 0, false
		}
	}
	return median(times), true
}

// Validates `data` at `level`. Returns false when it is refused.
validates_clean :: proc(data: []byte, level: json.Strictness) -> bool {
	_, refused := json.validate(data, .Json, level).?
	return !refused
}

// Returns the peak resident set size in bytes (`ru_maxrss` counts bytes on macOS and KiB elsewhere).
// It is a high-water mark, so growth since `RSS_MARK` is an upper bound, not a footprint. It counts
// allocated capacity, including the harness's array doubling, not only the bytes stury holds.
rss_peak :: proc() -> u64 {
	ru: posix.rusage
	if posix.getrusage(.SELF, &ru) != .OK {
		return 0
	}
	peak := u64(ru.ru_maxrss)
	when ODIN_OS != .Darwin {
		peak *= 1024
	}
	return peak
}

// Returns the peak RSS growth past `mark`, the peak taken after the fixture was loaded.
rss_growth :: proc(mark: u64) -> u64 {
	now := rss_peak()
	if now <= mark {
		return 0
	}
	return now - mark
}

bench_substrate :: proc(data: []byte, level: json.Strictness) -> bool {
	median_ns, timed := time_median(data, level, validates_clean)
	if !timed {
		return false
	}
	ns_per_byte := f64(median_ns) / f64(len(data))
	gb_per_s := 1.0 / ns_per_byte // bytes per ns == GB/s
	fmt.printf("gb_per_s=%.4g rss_bytes=%d\n", gb_per_s, rss_growth(RSS_MARK))
	return true
}

// One record's byte range in an NDJSON stream. The records lanes validate small records (tiny strings) one
// by one, for the framing cost per record; the framing bytes count toward GB/s as part of the format's cost.
Record_Span :: struct { lo, hi: u64 }

// Splits the stream into records once, outside the clock. The newline search is harness work, not scanner
// work, and sonic-rs also splits first, so the two stay comparable.
split_records :: proc(data: []byte, spans: ^[dynamic]Record_Span) {
	start := u64(0)
	for b, i in data {
		if b == '\n' {
			if u64(i) > start {
				append(spans, Record_Span{start, u64(i)})
			}
			start = u64(i) + 1
		}
	}
	if start < u64(len(data)) {
		append(spans, Record_Span{start, u64(len(data))})
	}
}

// Validates each record strictly. Returns the record count, or false at the first refusal.
scan_records :: proc(data: []byte, spans: []Record_Span) -> (count: int, ok: bool) {
	for s in spans {
		if _, h := json.validate(data[s.lo:s.hi], .Json, .Strict).?; h {
			return count, false
		}
		count += 1
	}
	return count, true
}

// Times a strict validate of every pre-split line.
bench_records :: proc(data: []byte) -> bool {
	spans := make([dynamic]Record_Span, 0, 1 << 16)
	defer delete(spans)
	split_records(data, &spans)
	times: [TIMED_ITERS]i64
	for _ in 0 ..< WARMUP_ITERS {
		if _, warmed := scan_records(data, spans[:]); !warmed {
			return false
		}
	}
	n := 0
	for i in 0 ..< TIMED_ITERS {
		t := time.tick_now()
		count, scanned := scan_records(data, spans[:])
		if !scanned {
			return false
		}
		n = count
		times[i] = i64(time.tick_since(t))
	}
	gb_per_s := f64(len(data)) / f64(median(times))
	fmt.printf("gb_per_s=%.4g records=%d rss_bytes=%d\n", gb_per_s, n, rss_growth(RSS_MARK))
	return true
}

// Times `validate_records` over NDJSON on one pool at each width in `BATCH_WIDTHS`. Width 0 is the default
// (the pool's threads and the caller) and runs last. One sample is `BATCH_REPS` back-to-back calls, as a
// stream of windows makes them, because one call on a small file is too short to time alone. The widths
// alternate inside every iteration so drift affects them equally. Every call must report no faults.
// `speedup_vs_serial` is the one-worker median divided by the default's.
BATCH_WIDTHS :: [?]int{1, 2, 3, 6, 0}
BATCH_REPS :: 8

bench_record_batch :: proc(data: []byte) -> bool {
	widths := BATCH_WIDTHS
	pool: host.Batch_Pool
	host.batch_pool_init(&pool)
	defer host.batch_pool_destroy(&pool)
	times: [len(BATCH_WIDTHS)][TIMED_ITERS]i64
	records := 0
	it := json.records(data, .NDJSON)
	for _ in json.next_record(&it) {
		records += 1
	}
	learned := pool.widths
	for iter in -WARMUP_ITERS ..< TIMED_ITERS {
		for w, k in widths {
			// Width `w` uses the pool's runner with `w - 1` of its threads; width 1 uses no runner.
			view := pool.runner
			view.threads = min(w - 1, pool.runner.threads)
			runner := &pool.runner if w == 0 else &view if w > 1 else nil
			// Every view shares the pool's learned widths, which cap how many threads a call uses. A set
			// width starts with none learned; the default starts from what its own earlier calls learned.
			pool.widths = learned if w == 0 else {}
			t := time.tick_now()
			for _ in 0 ..< BATCH_REPS {
				faults, err := json.validate_records(data, .NDJSON, runner)
				clean := err == nil && len(faults) == 0
				delete(faults)
				if !clean {
					fmt.eprintf("width %d: validate_records failed or found a fault\n", w)
					return false
				}
			}
			took := i64(time.tick_since(t)) / BATCH_REPS
			if w == 0 {
				learned = pool.widths
			}
			if iter >= 0 {
				times[k][iter] = took
			}
		}
	}
	serial := median(times[0])
	fmt.printf("speedup_vs_serial=%.4g records=%d cores=%d", f64(serial) / f64(median(times[len(widths) - 1])), records, os.get_processor_core_count())
	for w, k in widths {
		fmt.printf(" w%d_gb_per_s=%.4g", w, f64(len(data)) / f64(median(times[k])))
	}
	fmt.printf(" rss_bytes=%d\n", rss_growth(RSS_MARK))
	return true
}

// Times one path query over the whole document. `answers=N` counts the matches, so a lane that misses
// answers shows it.
bench_path_wild :: proc(data: []byte, level: json.Strictness, steps: []json.Step) -> bool {
	paths := [1]json.Path{{steps = steps}}
	req: json.Request({.Path})
	req.strictness = level
	req.paths = paths[:]
	defer json.destroy(&req)
	median_ns, timed := time_median(data, &req, scan_ok)
	if !timed {
		return false
	}
	gb_per_s := f64(len(data)) / f64(median_ns)
	fmt.printf("gb_per_s=%.4g answers=%d rss_bytes=%d\n", gb_per_s, found_answers(req.answers[:]), rss_growth(RSS_MARK))
	return true
}

// Exits 1, naming the lane on stderr, when `ok` is false.
lane_ok :: proc(lane: string, ok: bool) {
	if !ok {
		fmt.fprintf(os.stderr, "probe: %s failed\n", lane)
		os.exit(1)
	}
}

main :: proc() {
	lane := ""
	// `--fixture` runs a lane on another document. The lane still sets the
	// strictness and the query shape.
	fixture := ""
	// `--key` replaces a `path_ab_*` lane's key; `--emit lazy|strict` also prints that arm's per-call time as `ns`.
	key, emit := "", ""
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--lane" && i + 1 < len(args):
			lane = args[i + 1]
		case len(a) > 7 && a[:7] == "--lane=":
			lane = a[7:]
		case a == "--fixture" && i + 1 < len(args):
			fixture = args[i + 1]
		case len(a) > 10 && a[:10] == "--fixture=":
			fixture = a[10:]
		case a == "--key" && i + 1 < len(args):
			key = args[i + 1]
		case a == "--emit" && i + 1 < len(args):
			emit = args[i + 1]
		}
	}
	if lane == "" {
		fmt.println("usage: probe --lane <name> [--fixture <name>] [--key <key>] [--emit lazy|strict]")
		os.exit(2)
	}
	file, level, known := lane_fixture(lane)
	if fixture != "" {
		file = fixture
		known = true
	}
	if !known {
		fmt.eprintf("probe: unknown lane '%s'\n", lane)
		os.exit(2)
	}
	// This lane reads its own file, so no fixture is loaded before it.
	switch lane {
	case "streaming_records":
		fmt.printf("profile=%v ", ODIN_OPTIMIZATION_MODE)
		lane_ok(lane, bench_stream(file))
		return
	}
	data, found := find_fixture(file)
	if !found {
		fmt.fprintf(os.stderr, "probe: fixture '%s' not found (run from the stury checkout's root)\n", file)
		os.exit(1)
	}
	defer delete(data)
	RSS_MARK = rss_peak()

	// Every lane prints its optimization profile first, since `-o:minimal` is the compiler's default.
	fmt.printf("profile=%v ", ODIN_OPTIMIZATION_MODE)

	switch lane {
	case "substrate_dups_lastwins":
		lane_ok(lane, bench_dups(data, .Last_Wins))
	case "substrate_dups_skip":
		lane_ok(lane, bench_dups(data, .Skip))
	case "substrate_fault":
		lane_ok(lane, bench_fault(data))
	case "substrate_tiny":
		lane_ok(lane, bench_tiny(data))
	case "path_ab_early":
		lane_ok(lane, bench_path_ab(data, key if key != "" else "k0000000", emit))
	case "path_ab_middle":
		lane_ok(lane, bench_path_ab(data, key if key != "" else "k0024000", emit))
	case "path_ab_late":
		lane_ok(lane, bench_path_ab(data, key if key != "" else "k0048000", emit))
	case "path_ab_absent":
		lane_ok(lane, bench_path_ab(data, key if key != "" else "nope", emit))
	case "records_scan":
		lane_ok(lane, bench_records(data))
	case "ndjson_records":
		lane_ok(lane, bench_record_batch(data))
	case "records_scan_manysmall", "records_scan_onebig":
		// The same proc as `records_scan`, so both halves of the pair share one protocol. `records=N`
		// prints 32,768 for manysmall and 1 for onebig.
		lane_ok(lane, bench_records(data))
	case "encode_doc":
		lane_ok(lane, bench_encode_doc(data, {}))
	case "encode_doc_pretty":
		lane_ok(lane, bench_encode_doc(data, {pretty = true}))
	case "encode_doc_indent2":
		lane_ok(lane, bench_encode_doc(data, {pretty = true, indent = 2}))
	case "encode_doc_indent4":
		lane_ok(lane, bench_encode_doc(data, {pretty = true, indent = 4}))
	case "encode_doc_ascii":
		lane_ok(lane, bench_encode_doc(data, {ascii_only = true}))
	case "encode_doc_html":
		lane_ok(lane, bench_encode_doc(data, {escape_html = true}))
	case "encode_doc_writer":
		lane_ok(lane, bench_encode_doc(data, {}, to_writer = true))
	case "encode_string":
		lane_ok(lane, bench_encode_string(data))
	case "encode_f64":
		lane_ok(lane, bench_encode_numbers(f64))
	case "encode_i64":
		lane_ok(lane, bench_encode_numbers(i64))
	case "marshal_logs":
		lane_ok(lane, bench_marshal_logs(data))
	case "marshal_logs_enums":
		lane_ok(lane, bench_marshal_logs(data, enums = true))
	case "marshal_logs_writer":
		lane_ok(lane, bench_marshal_logs(data, to_writer = true))
	case "set_logs":
		lane_ok(lane, bench_edit(data, .Set, ".logs[0].level", "error"))
	case "remove_logs":
		lane_ok(lane, bench_edit(data, .Remove, ".logs[0].level"))
	case "insert_logs":
		lane_ok(lane, bench_edit(data, .Insert, ".logs[0]", "x"))
	case "set_config":
		lane_ok(lane, bench_edit(data, .Set, ".k0000500", 7))
	case "splice_logs":
		lane_ok(lane, bench_splice_logs(data))
	case "unmarshal_logs":
		lane_ok(lane, bench_unmarshal_logs(data, .Unmarshal))
	case "tape_unmarshal_logs":
		lane_ok(lane, bench_unmarshal_logs(data, .Tape))
	case "unmarshal_logs_arena":
		lane_ok(lane, bench_unmarshal_logs(data, .Unmarshal_Arena))
	case "unmarshal_logs_subset_arena":
		lane_ok(lane, bench_unmarshal_logs_subset(data, .Unmarshal_Arena, STRICT_READ))
	case "unmarshal_nested_arena":
		lane_ok(lane, bench_unmarshal_nested(data, .Unmarshal_Arena))
	case "unmarshal_config_arena":
		lane_ok(lane, bench_unmarshal_config(data, .Unmarshal_Arena, STRICT_READ))
	case "check_logs":
		lane_ok(lane, bench_unmarshal_logs(data, .Check))
	case "unmarshal_logs_subset":
		lane_ok(lane, bench_unmarshal_logs_subset(data, .Unmarshal, STRICT_READ))
	case "tape_unmarshal_logs_subset":
		lane_ok(lane, bench_unmarshal_logs_subset(data, .Tape, STRICT_READ))
	case "unmarshal_logs_subset_lazy":
		lane_ok(lane, bench_unmarshal_logs_subset(data, .Unmarshal, LAZY_READ))
	case "unmarshal_nested":
		lane_ok(lane, bench_unmarshal_nested(data, .Unmarshal))
	case "check_nested":
		lane_ok(lane, bench_unmarshal_nested(data, .Check))
	case "tape_unmarshal_nested":
		lane_ok(lane, bench_unmarshal_nested(data, .Tape))
	case "unmarshal_config":
		lane_ok(lane, bench_unmarshal_config(data, .Unmarshal, STRICT_READ))
	case "unmarshal_config_lazy":
		lane_ok(lane, bench_unmarshal_config(data, .Unmarshal, LAZY_READ))
	case "tape_unmarshal_config":
		lane_ok(lane, bench_unmarshal_config(data, .Tape, LAZY_READ))
	case "path_wild_logs_id":
		lane_ok(lane, bench_path_wild(data, level, []json.Step{json.Name("logs"), json.Any{}, json.Name("id")}))
	case "path_wild_logs_all":
		lane_ok(lane, bench_path_wild(data, level, []json.Step{json.Name("logs"), json.Any{}, json.Any{}}))
	case "path_logs_last":
		lane_ok(lane, bench_path_wild(data, level, []json.Step{json.Name("logs"), json.Index(-1)}))
	case "path_logs_back":
		lane_ok(lane, bench_path_wild(data, level, []json.Step{json.Name("logs"), json.Index(-20)}))
	case "query_nodes":
		lane_ok(lane, bench_query(data, level, {.Nodes}))
	case "query_dom":
		lane_ok(lane, bench_query(data, level, {.Dom}))
	case "dom_read":
		lane_ok(lane, bench_query(data, level, {.Dom}, read_all = true))
	case "query_dom_fault", "query_dom_records_ndjson":
		// Not `bench_query`, which fails the lane on a refusal: refusing is the correct answer for these two.
		lane_ok(lane, bench_dom_refusal(data, level))
	case:
		// Every other lane is named for its fixture (`lane_fixture`). `substrate` (nested.json) and
		// `substrate_<f>` validate it; `query_dom_<f>`, `dom_read_<f>` and `query_nodes_<f>` build it. Each
		// fails the lane when the fixture is refused.
		switch {
		case lane == "substrate" || strings.has_prefix(lane, "substrate_"):
			lane_ok(lane, bench_substrate(data, level))
		case strings.has_prefix(lane, "query_dom_"):
			lane_ok(lane, bench_query(data, level, {.Dom}))
		case strings.has_prefix(lane, "dom_read_"):
			lane_ok(lane, bench_query(data, level, {.Dom}, read_all = true))
		case strings.has_prefix(lane, "query_nodes_"):
			lane_ok(lane, bench_query(data, level, {.Nodes}))
		case strings.has_prefix(lane, "csv_"):
			ok, csv_lane := bench_csv(lane, data, file)
			if !csv_lane {
				fmt.eprintf("probe: unknown lane '%s'\n", lane)
				os.exit(2)
			}
			lane_ok(lane, ok)
		case:
			fmt.eprintf("probe: unknown lane '%s'\n", lane)
			os.exit(2)
		}
	}
}
