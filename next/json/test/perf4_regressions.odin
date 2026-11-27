package json_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:host"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// Deep nesting past `ROW_LEVELS` (64) must grow the `write_rows` container stack cleanly across compact, indented,
// tabbed, ASCII, and comment-preserving JSON/JSONC/JSON5 modes, matching sink output byte for byte.
@(test)
perf4_write_rows_deep_nesting_past_stack_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	depth :: 150
	b := strings.builder_make(context.temp_allocator)
	for lvl in 0 ..< depth {
		if lvl % 2 == 0 {
			strings.write_string(&b, `{"k":`)
		} else {
			strings.write_byte(&b, '[')
		}
	}
	strings.write_string(&b, `"leaf"`)
	for lvl := depth - 1; lvl >= 0; lvl -= 1 {
		if lvl % 2 == 0 {
			strings.write_byte(&b, '}')
		} else {
			strings.write_byte(&b, ']')
		}
	}
	src := strings.to_string(b)
	doc, berr := json.build(transmute([]u8)src)
	defer tape.destroy(&doc)
	testing.expect_value(t, berr, nil)

	for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
		for opts in ([]json.Write_Options{{}, {indent = 2}, {tab = true}, {indent = 2, ascii = true}, {tab = true, ascii = true}}) {
			out, _, werr := json.write(&doc, spec, opts)
			defer delete(out)
			testing.expectf(t, werr == nil, "spec=%v opts=%v err=%v", spec, opts, werr)

			sink: strings.Builder
			defer strings.builder_destroy(&sink)
			_, serr := json.write_to(strings.to_writer(&sink), &doc, spec, opts)
			testing.expectf(t, serr == nil, "sink spec=%v opts=%v err=%v", spec, opts, serr)
			testing.expectf(t, strings.to_string(sink) == string(out), "sink mismatch spec=%v opts=%v", spec, opts)

			round, rerr := json.build(out, spec)
			defer tape.destroy(&round)
			testing.expectf(t, rerr == nil && len(round.nodes) == len(doc.nodes), "roundtrip spec=%v err=%v", spec, rerr)
		}
	}

	// Same deep nesting with comments so `rows_fact_value` and `rows_fact_close` also exercise stack growth past 64.
	bc := strings.builder_make(context.temp_allocator)
	strings.write_string(&bc, "/* lead */\n")
	for lvl in 0 ..< depth {
		if lvl % 2 == 0 {
			strings.write_string(&bc, `{"k":`)
		} else {
			strings.write_byte(&bc, '[')
		}
	}
	strings.write_string(&bc, `"leaf" // inline`)
	strings.write_byte(&bc, '\n')
	for lvl := depth - 1; lvl >= 0; lvl -= 1 {
		if lvl % 2 == 0 {
			strings.write_byte(&bc, '}')
		} else {
			strings.write_byte(&bc, ']')
		}
	}
	csrc := strings.to_string(bc)
	cdoc, cberr := json.build(transmute([]u8)csrc, .Jsonc)
	defer tape.destroy(&cdoc)
	testing.expect_value(t, cberr, nil)
	for opts in ([]json.Write_Options{{}, {indent = 2}, {tab = true}}) {
		cout, cdropped, cwerr := json.write(&cdoc, .Jsonc, opts)
		defer delete(cout)
		testing.expectf(t, cwerr == nil && cdropped == {}, "jsonc deep opts=%v dropped=%v err=%v", opts, cdropped, cwerr)
		cround, crerr := json.build(cout, .Jsonc)
		defer tape.destroy(&cround)
		testing.expectf(t, crerr == nil && len(cround.nodes) == len(cdoc.nodes), "jsonc roundtrip opts=%v err=%v", opts, crerr)
	}
}

// Exercises `doc_span` / `doc_span_held` on `.Held` windowed documents (`records_scan` over pieces), JSON5
// non-finite numbers in `put_number`, ASCII/astral escapes in `put_ascii`, and comment fallbacks in
// `inline_comments` / `put_comment`.
@(test)
perf4_write_held_span_ascii_and_comments :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Single `.Json5` record holding strings, comments, bare keys, astral runes, and non-finite numbers, streamed in pieces so `.Held` is set.
	rec_src := "{bare_key:\"é😀\",'sq':'a\\vb',inf:Infinity,ninf:-Infinity,nan:NaN,num:42} // c1\n"
	p: tape.Pieces
	defer tape.destroy(&p)
	bs := transmute([]u8)rec_src
	step :: 7
	p.last = step >= len(bs)
	demand, derr := tape.demand_of({{tape.Name("bare_key")}, {tape.Name("sq")}, {tape.Name("inf")}, {tape.Name("ninf")}, {tape.Name("nan")}, {tape.Name("num")}})
	defer tape.destroy_demand(&demand)
	testing.expect_value(t, derr, nil)

	r := json.records_open(bs[:min(step, len(bs))], .Lines, .Json5, json.Options{pieces = &p})
	defer tape.destroy_records(&r)
	recs: [4]tape.Record
	docs: [4]tape.Document
	got := 0
	for {
		chunk := json.records_scan(&r, &demand, recs[got:], docs[got:])
		got += chunk
		if !p.more {
			break
		}
		p.from = p.keep
		next_to := min(int(p.at) + step, len(bs))
		p.last = next_to == len(bs)
		werr := tape.records_window(&r, bs[p.from:next_to])
		testing.expect_value(t, werr, nil)
	}
	testing.expectf(t, got == 1 && recs[0].err == nil, "scan got=%d err=%v", got, recs[0].err)
	testing.expect(t, .Held in docs[0].flags, "expected .Held flag on windowed scan document")

	// Writing held doc as `.Json5` keeps non-finite numbers via `doc_span_held`.
	out5, _, w5err := json.write(&docs[0], .Json5, {indent = 2, ascii = true})
	defer delete(out5)
	testing.expect_value(t, w5err, nil)
	s5 := string(out5)
	testing.expectf(t, strings.contains(s5, "Infinity") && strings.contains(s5, "NaN") && strings.contains(s5, `\u00e9\ud83d\ude00`), "unexpected json5 out: %s", s5)

	// Writing the same `.Held` doc as strict `.Json` refuses `Infinity` (`No_Spelling`).
	outj, _, wjerr := json.write(&docs[0], .Json)
	defer delete(outj)
	ref, is_ref := wjerr.(write.Refused)
	testing.expectf(t, is_ref && ref.why == .No_Spelling, "expected No_Spelling refusal on Infinity->Json, got %v", wjerr)

	// Exercise `inline_comments` and `put_comment`: JSONC holds two inline comments where the first contains U+2028
	// (not a line terminator in JSONC); writing to JSON5 drops that first inline comment before emitting the second.
	c5_src := "{/* lead */\n\"a\":1 /* b1 \xe2\x80\xa8 */ /* b2 */ // l */ tail\n, \"b\": /* has */ \"x\\n\\u0001é😀\"\n}"
	c5_doc, c5_err := json.build(transmute([]u8)c5_src, .Jsonc)
	defer tape.destroy(&c5_doc)
	testing.expect_value(t, c5_err, nil)
	c5_out, c5_dropped, c5_werr := json.write(&c5_doc, .Json5, {ascii = true})
	defer delete(c5_out)
	testing.expect_value(t, c5_werr, nil)
	testing.expect(t, .Comment_Inline in c5_dropped, "expected U+2028 block inline comment before second inline comment to be dropped")
	c5_back, c5_berr := json.build(c5_out, .Json5)
	defer tape.destroy(&c5_back)
	testing.expectf(t, c5_berr == nil, "ascii json5 comments did not roundtrip: %v in %s", c5_berr, c5_out)
}

// Verifies `write_as`'s pre-Tree `dense_route` fast bypass and non-bypass edge cases (partial, cut, sub-node, key node).
@(test)
perf4_write_dense_bypass_and_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := `{"a":[1,2,3],"b":{"nested":"val"},"c":"plain"}`
	doc, err := json.build(transmute([]u8)src)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)

	// Dense fast path matches compact text exactly.
	compact, dropped, cerr := json.write(&doc, .Json)
	defer delete(compact)
	testing.expectf(t, cerr == nil && dropped == {} && string(compact) == src, "dense bypass mismatch: %s %v", compact, cerr)

	// Key node (`opts.node = 1`) must return `Bad_Option{"node"}`.
	bad_out, _, bad_err := json.write(&doc, .Json, {node = 1})
	defer delete(bad_out)
	bo, is_bo := bad_err.(tape.Bad_Option)
	testing.expectf(t, is_bo && bo.option == "node", "expected Bad_Option node, got %v", bad_err)

	// Sub-node (`opts.node = 2`, the `[1,2,3]` array) writes only that subtree cleanly.
	sub_out, _, sub_err := json.write(&doc, .Json, {node = 2})
	defer delete(sub_out)
	testing.expectf(t, sub_err == nil && string(sub_out) == "[1,2,3]", "sub-node mismatch: %s %v", sub_out, sub_err)

	// `.Cut` partial read must return `Refused{0, .Partial}` via `write_as` / `write_walked`.
	cut_p := tape.Pieces{so_far = true, allocator = context.allocator}
	defer tape.destroy(&cut_p)
	cut_src := `{"a":[1,2`
	cut_doc, cut_err := json.build(transmute([]u8)cut_src, .Json, {pieces = &cut_p})
	defer tape.destroy(&cut_doc)
	testing.expect_value(t, cut_err, nil)
	testing.expect(t, .Cut in cut_doc.flags, "expected .Cut flag")
	cout, _, cwerr := json.write(&cut_doc, .Json)
	defer delete(cout)
	cref, is_cref := cwerr.(write.Refused)
	testing.expectf(t, is_cref && cref.why == .Partial, "expected Partial refusal on .Cut doc, got %v", cwerr)
}

// Verifies runtime-selected `spec` and `lax` (`len(path) < 8` fast path vs `len(path) >= 8` `frame_init`) in `records_open`.
@(test)
perf4_records_dynamic_spec_and_path_lengths :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	line_src := "{\"k\":\"v1\"}\n{\"k\":\"v2\"}\n"
	short_path := [2]tape.Step{tape.Name("wrap"), tape.Name("items")}
	long_path := [9]tape.Step{
		tape.Name("a"), tape.Name("b"), tape.Name("c"), tape.Name("d"),
		tape.Name("e"), tape.Name("f"), tape.Name("g"), tape.Name("h"), tape.Name("k"),
	}
	nested_elem := `[{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"k":1}}}}}}}}},{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"k":2}}}}}}}}}]`
	nested_long_elem := `{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"k":[10,20]}}}}}}}}}`

	for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
		for max_depth in ([]u32{0, 32}) {
			opts := json.Options{budget = {depth = max_depth}}
			// Validate with runtime `spec` and `opts`.
			rv := json.records_open(transmute([]u8)line_src, .Lines, spec, opts)
			defer tape.destroy_records(&rv)
			out: [4]tape.Record
			n := json.records_validate(&rv, out[:])
			testing.expectf(t, n == 0 && rv.index == 2 && rv.err == nil, "spec=%v depth=%d validate n=%d idx=%d err=%v", spec, max_depth, n, rv.index, rv.err)

			// `.Elements` with `len(path) < 8` (`2` steps, hitting the no-`frame_init` fast path).
			elem_src := `{"wrap":{"items":[{"k":"a"},{"k":"b"}]}}`
			re := json.records_open(transmute([]u8)elem_src, .Elements, spec, opts, short_path[:])
			defer tape.destroy_records(&re)
			eout: [4]tape.Record
			eans: [4]tape.Span_Answer
			ne := json.records_find(&re, []tape.Step{tape.Name("k")}, eout[:], eans[:])
			testing.expectf(t, ne == 2 && re.err == nil && eans[0].outcome == .Found && eans[1].outcome == .Found, "short path elements spec=%v: ne=%d err=%v", spec, ne, re.err)

			// `.Elements` with `len(path) >= 8` (hitting `build.frame_init`) via `records_scan`.
			dem, derr := tape.demand_of({{}})
			defer tape.destroy_demand(&dem)
			testing.expect_value(t, derr, nil)
			rl := json.records_open(transmute([]u8)nested_long_elem, .Elements, spec, opts, long_path[:])
			defer tape.destroy_records(&rl)
			sout: [4]tape.Record
			sdocs: [4]tape.Document
			ns := json.records_scan(&rl, &dem, sout[:], sdocs[:])
			testing.expectf(t, ns == 2 && rl.err == nil, "long path elements scan spec=%v: ns=%d err=%v", spec, ns, rl.err)

			// Root `.Elements` with `records_find` traversing a 9-step path inside each record.
			rlong := json.records_open(transmute([]u8)nested_elem, .Elements, spec, opts)
			defer tape.destroy_records(&rlong)
			lout: [4]tape.Record
			lans: [4]tape.Span_Answer
			nl := json.records_find(&rlong, long_path[:], lout[:], lans[:])
			testing.expectf(t, nl == 2 && lans[0].outcome == .Found && lans[1].outcome == .Found, "long path find spec=%v nl=%d", spec, nl)
		}
	}
}

// Verifies parallel `records_validate`, `records_find`, and `records_scan` under small batch caps (both chunk-0 overflow
// fallback and multi-chunk fan-out via `Chunk_Context`), plus `.Seq` `sync_seq_rs` parity against serial.
@(test)
perf4_records_parallel_chunk_context_and_caps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	b := strings.builder_make(context.temp_allocator)
	n_lines :: 600
	for idx in 0 ..< n_lines {
		if idx % 73 == 0 {
			fmt.sbprintf(&b, "{{\"id\":%d,\"bad\":}}\n", idx)
		} else {
			fmt.sbprintf(&b, "{{\"id\":%d,\"ok\":true}}\n", idx)
		}
	}
	src := transmute([]u8)strings.to_string(b)
	path := [1]tape.Step{tape.Name("id")}
	demand, derr := tape.demand_of({path[:]})
	defer tape.destroy_demand(&demand)
	testing.expect_value(t, derr, nil)

	// Serial validate baseline.
	rs_val := json.records_open(src, .Lines, .Json)
	defer tape.destroy_records(&rs_val)
	serial_bad := make([dynamic]tape.Record, context.temp_allocator)
	for {
		buf: [32]tape.Record
		n := json.records_validate(&rs_val, buf[:])
		for rec in buf[:n] {
			append(&serial_bad, rec)
		}
		if n < len(buf) {
			break
		}
	}

	// Parallel validate with varying batch caps.
	for bcap in ([]int{4, 64, 128, 1024}) {
		rp := json.records_open(src, .Lines, .Json, {runner = &pool.runner})
		defer tape.destroy_records(&rp)
		pbad := make([dynamic]tape.Record, context.temp_allocator)
		buf := make([]tape.Record, bcap, context.temp_allocator)
		for {
			n := json.records_validate(&rp, buf)
			for rec in buf[:n] {
				append(&pbad, rec)
			}
			if n < len(buf) {
				break
			}
		}
		testing.expectf(t, len(pbad) == len(serial_bad) && rp.index == rs_val.index && rp.err == nil, "parallel validate cap=%d mismatch: %d vs %d idx=%d/%d", bcap, len(pbad), len(serial_bad), rp.index, rs_val.index)
		for k in 0 ..< min(len(pbad), len(serial_bad)) {
			testing.expectf(t, pbad[k] == serial_bad[k], "parallel validate rec %d mismatch at cap=%d: %v vs %v", k, bcap, pbad[k], serial_bad[k])
		}
	}

	// Parallel find & scan parity across small (triggers c0 pre-check) and medium batch caps.
	for bcap in ([]int{64, 128, 1024}) {
		rf_ser := json.records_open(src, .Lines, .Json, {dups = .First})
		defer tape.destroy_records(&rf_ser)
		rf_par := json.records_open(src, .Lines, .Json, {dups = .First, runner = &pool.runner})
		defer tape.destroy_records(&rf_par)

		sout := make([]tape.Record, bcap, context.temp_allocator)
		sans := make([]tape.Span_Answer, bcap, context.temp_allocator)
		pout := make([]tape.Record, bcap, context.temp_allocator)
		pans := make([]tape.Span_Answer, bcap, context.temp_allocator)
		for {
			ns := json.records_find(&rf_ser, path[:], sout, sans, {stop_early = true})
			np := json.records_find(&rf_par, path[:], pout, pans, {stop_early = true})
			testing.expectf(t, ns == np, "find count mismatch cap=%d: %d vs %d", bcap, np, ns)
			for k in 0 ..< min(ns, np) {
				testing.expectf(t, pout[k] == sout[k] && pans[k] == sans[k], "find rec %d cap=%d mismatch", k, bcap)
			}
			if ns < bcap {
				break
			}
		}
		testing.expect_value(t, rf_par.index, rf_ser.index)

		rsc_ser := json.records_open(src, .Lines, .Json, {dups = .First})
		defer tape.destroy_records(&rsc_ser)
		rsc_par := json.records_open(src, .Lines, .Json, {dups = .First, runner = &pool.runner})
		defer tape.destroy_records(&rsc_par)
		sdocs := make([]tape.Document, bcap, context.temp_allocator)
		pdocs := make([]tape.Document, bcap, context.temp_allocator)
		for {
			ns := json.records_scan(&rsc_ser, &demand, sout, sdocs)
			np := json.records_scan(&rsc_par, &demand, pout, pdocs)
			testing.expectf(t, ns == np, "scan count mismatch cap=%d: %d vs %d", bcap, np, ns)
			for k in 0 ..< min(ns, np) {
				testing.expectf(t, pout[k] == sout[k] && len(pdocs[k].nodes) == len(sdocs[k].nodes), "scan rec %d cap=%d mismatch", k, bcap)
			}
			if ns < bcap {
				break
			}
		}
		testing.expect_value(t, rsc_par.index, rsc_ser.index)
	}
}

// Verifies parallel `records_validate` mid-chunk batch splitting (`len(out) = 4`) on an input >= 128 KiB (past the
// release `parallel_records_from()` threshold) with multiple bad records inside chunk 0, chunk 1, and later chunks,
// checking exact bad-record, `r.index`, `r.pos`, and `quarantine` parity with serial `records_validate`.
@(test)
perf4_records_parallel_validate_mid_chunk_split :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	b := strings.builder_make(context.temp_allocator)
	// >= 170 KiB (8,000 lines) with > 10 bad records inside every quarter (chunk 0..3) so `len(out) = 4` splits
	// mid-chunk across chunk 0, chunk 1, and subsequent chunks even without `BUILD_PARALLEL_FROM=0`.
	n_lines :: 8000
	for idx in 0 ..< n_lines {
		switch idx {
		case 10, 40, 80, 120, 200, 400, 700, 1000, 1300, 1600, 1900:
			fmt.sbprintf(&b, "{{\"id\":%d,\"bad\":}}\n", idx)
		case 2100, 2200, 2300, 2400, 2500, 2700, 2900, 3100, 3400, 3700, 3900:
			fmt.sbprintf(&b, "{{\"id\":%d,\"bad\":}}\n", idx)
		case 4200, 4500, 4800, 5100, 5400, 5700:
			fmt.sbprintf(&b, "{{\"id\":%d,\"bad\":}}\n", idx)
		case 6200, 6500, 6800, 7100, 7400, 7700:
			fmt.sbprintf(&b, "{{\"id\":%d,\"bad\":}}\n", idx)
		case:
			fmt.sbprintf(&b, "{{\"id\":%d,\"ok\":true}}\n", idx)
		}
	}
	src := transmute([]u8)strings.to_string(b)
	testing.expectf(t, len(src) >= 128 << 10, "expected >= 128 KiB input, got %d", len(src))

	// Serial reference (with quarantine enabled to compare both emitted records and Bad_Record payloads).
	ser_q := make([dynamic]tape.Bad_Record, context.temp_allocator)
	r_ser := json.records_open(src, .Lines, .Json)
	defer tape.destroy_records(&r_ser)
	r_ser.quarantine = &ser_q
	ser_recs := make([dynamic]tape.Record, context.temp_allocator)
	for {
		buf: [4]tape.Record
		n := json.records_validate(&r_ser, buf[:])
		for rec in buf[:n] {
			append(&ser_recs, rec)
		}
		if n < len(buf) {
			break
		}
	}
	testing.expect_value(t, r_ser.err, nil)
	testing.expect_value(t, len(ser_recs), 34)
	testing.expect_value(t, len(ser_q), 34)
	testing.expect_value(t, r_ser.index, u64(n_lines))

	for with_quarantine in ([]bool{false, true}) {
		par_q := make([dynamic]tape.Bad_Record, context.temp_allocator)
		r_par := json.records_open(src, .Lines, .Json, {runner = &pool.runner})
		defer tape.destroy_records(&r_par)
		if with_quarantine {
			r_par.quarantine = &par_q
		}
		par_recs := make([dynamic]tape.Record, context.temp_allocator)
		for {
			buf: [4]tape.Record
			n := json.records_validate(&r_par, buf[:])
			for rec in buf[:n] {
				append(&par_recs, rec)
			}
			if n < len(buf) {
				break
			}
		}
		testing.expectf(t, r_par.err == nil && r_par.index == r_ser.index && r_par.pos == r_ser.pos, "q=%v final cursor mismatch: err=%v idx=%d/%d pos=%d/%d", with_quarantine, r_par.err, r_par.index, r_ser.index, r_par.pos, r_ser.pos)
		testing.expectf(t, len(par_recs) == len(ser_recs), "q=%v bad count mismatch: %d vs %d", with_quarantine, len(par_recs), len(ser_recs))
		for k in 0 ..< min(len(par_recs), len(ser_recs)) {
			testing.expectf(t, par_recs[k] == ser_recs[k], "q=%v rec %d mismatch: %v vs %v", with_quarantine, k, par_recs[k], ser_recs[k])
		}
		if with_quarantine {
			testing.expectf(t, len(par_q) == len(ser_q), "quarantine len mismatch: %d vs %d", len(par_q), len(ser_q))
			for k in 0 ..< min(len(par_q), len(ser_q)) {
				testing.expectf(t, par_q[k].lo == ser_q[k].lo && par_q[k].hi == ser_q[k].hi && par_q[k].err == ser_q[k].err && string(par_q[k].text) == string(ser_q[k].text), "quarantine[%d] mismatch", k)
			}
		}
	}
}
