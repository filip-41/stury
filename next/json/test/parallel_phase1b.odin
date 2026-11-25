package json_tests

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:host"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// --- Deliverable 1: Records Part 2 (.Seq, .Concatenated, skip/quarantine, max_bytes, spine) ---

@(test)
records_seq_rfc7464_semantics :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Empty RS runs are skipped; leading bytes before first RS are `unframed`; top-level numbers without trailing
	// whitespace are `cut_number`; multi-line JSON values inside RS are valid; faults do not stop later records.
	src := "\x1e{\"a\":1}\n\x1e\x1e  \n\x1e{\n\"a\": 2\n}\x1e123\n\x1e456\x1e{\"a\":bad}\x1e{\"a\":3}\n"
	path := []tape.Step{tape.Name("a")}
	demand, _ := tape.demand_of({path})
	defer tape.destroy_demand(&demand)

	for spec in json.Spec {
		r := json.records_open(transmute([]u8)src, .Seq, spec)
		defer tape.destroy_records(&r)
		out: [16]tape.Record
		ans: [16]tape.Span_Answer
		n := json.records_find(&r, path, out[:], ans[:], {stop_early = true})
		testing.expectf(t, n == 6 && r.err == nil && r.index == 6, "%v seq count=%d err=%v idx=%d", spec, n, r.err, r.index)
		testing.expectf(t, out[0].err == nil && ans[0].outcome == .Found, "%v rec0: %v %v", spec, out[0], ans[0])
		testing.expectf(t, out[1].err == nil && ans[1].outcome == .Found, "%v rec1: %v %v", spec, out[1], ans[1])
		testing.expectf(t, out[2].err == nil, "%v rec2 (123\\n): %v", spec, out[2])
		// rec3 is `456` with no whitespace before 0x1E -> cut_number
		f3, ok3 := out[3].err.(tape.Fault)
		testing.expectf(t, ok3 && f3.kind == .Bad_Number && tape.fault_rule(f3).code == "cut_number", "%v rec3: %v", spec, out[3].err)
		// rec4 is `{"a":bad}` -> fault
		testing.expectf(t, out[4].err != nil && ans[4].outcome == .Missing, "%v rec4: %v %v", spec, out[4], ans[4])
		// rec5 is `{"a":3}\n` -> valid after fault
		testing.expectf(t, out[5].err == nil && ans[5].outcome == .Found, "%v rec5: %v %v", spec, out[5], ans[5])

		// Validate returns only the 2 bad records (rec3 and rec4).
		rv := json.records_open(transmute([]u8)src, .Seq, spec)
		defer tape.destroy_records(&rv)
		bad: [8]tape.Record
		nv := json.records_validate(&rv, bad[:])
		testing.expectf(t, nv == 2 && rv.index == 6 && rv.err == nil, "%v seq validate: nv=%d idx=%d err=%v", spec, nv, rv.index, rv.err)
		testing.expectf(t, bad[0] == out[3] && bad[1] == out[4], "%v seq validate mismatch: %v vs %v", spec, bad[:nv], out[3:5])

		// Scan agrees with find.
		rs := json.records_open(transmute([]u8)src, .Seq, spec)
		defer tape.destroy_records(&rs)
		sout: [16]tape.Record
		docs: [16]tape.Document
		ns := json.records_scan(&rs, &demand, sout[:], docs[:])
		testing.expectf(t, ns == 6 && rs.err == nil, "%v seq scan: ns=%d err=%v", spec, ns, rs.err)
		for i in 0 ..< ns {
			testing.expectf(t, sout[i] == out[i], "%v seq scan rec %d: %v vs %v", spec, i, sout[i], out[i])
		}
	}

	// Unframed bytes before first 0x1E -> `unframed`, then framed record succeeds.
	unframed := " {\"x\":1}\x1e{\"x\":2}\n"
	ru := json.records_open(transmute([]u8)unframed, .Seq, .Json)
	defer tape.destroy_records(&ru)
	uout: [4]tape.Record
	uans: [4]tape.Span_Answer
	nu := json.records_find(&ru, {tape.Name("x")}, uout[:], uans[:])
	testing.expectf(t, nu == 2 && ru.err == nil, "unframed: nu=%d err=%v", nu, ru.err)
	fu, oku := uout[0].err.(tape.Fault)
	testing.expectf(t, oku && fu.kind == .Bad_Char && tape.fault_rule(fu).code == "unframed" && fu.at == 1, "unframed err: %v", uout[0].err)
	testing.expectf(t, uout[1].err == nil && uans[1].outcome == .Found, "after unframed: %v %v", uout[1], uans[1])

	// Pieces agreement across chunk sizes for `.Seq`.
	for step in ([]int{1, 3, 7, 19}) {
		p: tape.Pieces
		defer tape.destroy_pieces(&p)
		bs := transmute([]u8)src
		p.last = step >= len(bs)
		rp := json.records_open(bs[:min(step, len(bs))], .Seq, .Json, {pieces = &p})
		defer tape.destroy_records(&rp)
		got := make([dynamic]tape.Record, context.temp_allocator)
		for {
			buf: [4]tape.Record
			ans_buf: [4]tape.Span_Answer
			k := json.records_find(&rp, path, buf[:], ans_buf[:])
			for i in 0 ..< k {
				append(&got, buf[i])
			}
			if !p.more {
				break
			}
			p.from = p.keep
			next_to := min(int(p.at) + step, len(bs))
			p.last = next_to == len(bs)
			werr := tape.records_window(&rp, bs[p.from:next_to])
			testing.expectf(t, werr == nil, "seq pieces step=%d window err=%v", step, werr)
		}
		testing.expectf(t, len(got) == 6 && rp.err == nil, "seq pieces step=%d len=%d err=%v", step, len(got), rp.err)
	}
}

@(test)
records_concatenated_and_skip_quarantine :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Concatenated values: self-delimiting + whitespace separated + comments in JSONC.
	src := `{"a":1}{"a":2} [3] "hi" 42 true false null`
	r := json.records_open(transmute([]u8)src, .Concatenated, .Json)
	defer tape.destroy_records(&r)
	out: [16]tape.Record
	ans: [16]tape.Span_Answer
	n := json.records_find(&r, {tape.Name("a")}, out[:], ans[:])
	testing.expectf(t, n == 8 && r.err == nil, "concat n=%d err=%v", n, r.err)
	testing.expectf(t, string(src[out[0].lo:out[0].hi]) == `{"a":1}` && ans[0].outcome == .Found, "c0")
	testing.expectf(t, string(src[out[1].lo:out[1].hi]) == `{"a":2}` && ans[1].outcome == .Found, "c1")
	testing.expectf(t, string(src[out[4].lo:out[4].hi]) == `42`, "c4")
	testing.expectf(t, string(src[out[7].lo:out[7].hi]) == `null`, "c7")

	// `runs_on`: `1x` and `1,2` fault at the offending byte rather than yielding `1`.
	for bad_src in ([]string{"1x", "1,2", "truefalse", "1/2"}) {
		rb := json.records_open(transmute([]u8)bad_src, .Concatenated, .Json)
		defer tape.destroy_records(&rb)
		bout: [4]tape.Record
		bans: [4]tape.Span_Answer
		nb := json.records_find(&rb, nil, bout[:], bans[:])
		f, is_f := rb.err.(tape.Fault)
		testing.expectf(t, nb == 0 && is_f && tape.fault_rule(f).code == "trailing", "%q: nb=%d err=%v", bad_src, nb, rb.err)
	}

	// `records_skip` on `.Concatenated` resumes at next line (and on fault's own line when fault starts a fresh line).
	dirty := "{\"a\":1}\n{bad}\n{\"a\":2}\n123\n{\"a\":3}\n"
	rs := json.records_open(transmute([]u8)dirty, .Concatenated, .Json)
	defer tape.destroy_records(&rs)
	rs.skip_bad = true
	vbad: [8]tape.Record
	nv := json.records_validate(&rs, vbad[:])
	testing.expectf(t, nv == 1 && rs.err == nil && rs.index == 5, "concat skip_bad validate: nv=%d idx=%d err=%v", nv, rs.index, rs.err)
	testing.expectf(t, string(dirty[vbad[0].lo:vbad[0].hi]) == "{bad}", "skipped text=%q", dirty[vbad[0].lo:vbad[0].hi])

	// Quarantine sink on `.Lines`, `.Seq`, and `.Concatenated` yields ONLY valid records in `out`/`answers`.
	for tc in ([]struct{ text: string, framing: tape.Framing }{
		{"{\"a\":1}\n{bad}\n{\"a\":2}\n", .Lines},
		{"\x1e{\"a\":1}\n\x1e{bad}\n\x1e{\"a\":2}\n", .Seq},
		{"{\"a\":1}\n{bad}\n{\"a\":2}\n", .Concatenated},
	}) {
		q := make([dynamic]tape.Bad_Record)
		defer delete(q)
		rq := json.records_open(transmute([]u8)tc.text, tc.framing, .Json)
		defer tape.destroy_records(&rq)
		rq.quarantine = &q
		qout: [8]tape.Record
		qans: [8]tape.Span_Answer
		nq := json.records_find(&rq, {tape.Name("a")}, qout[:], qans[:])
		testing.expectf(t, nq == 2 && len(q) == 1 && rq.err == nil, "%v quarantine: nq=%d bad=%d err=%v", tc.framing, nq, len(q), rq.err)
		testing.expectf(t, qout[0].err == nil && qout[1].err == nil && qans[0].outcome == .Found && qans[1].outcome == .Found, "%v valid outputs", tc.framing)
		testing.expectf(t, strings.trim_space(string(q[0].text)) == "{bad}" && q[0].err != nil, "%v bad entry: %q %v", tc.framing, q[0].text, q[0].err)
	}

	// `records_skip` returns false on `.Elements` (non-resumable framing).
	re := json.records_open(transmute([]u8)string("[1, bad, 2]"), .Elements, .Json)
	defer tape.destroy_records(&re)
	eout: [4]tape.Record
	_ = json.records_validate(&re, eout[:])
	_, skipped := tape.records_skip(&re)
	testing.expectf(t, !skipped && re.err != nil, "elements must not skip")
}

@(test)
records_max_bytes_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Whole-text max_bytes: first record fits (8 bytes), second exceeds (20 bytes) -> Too_Wide (`records.too_long`).
	src := "{\"a\":1}\n{\"a\":\"0123456789abcdef\"}\n{\"a\":2}\n"
	r := json.records_open(transmute([]u8)src, .Lines, .Json)
	defer tape.destroy_records(&r)
	r.max_bytes = 12
	out: [8]tape.Record
	ans: [8]tape.Span_Answer
	n := json.records_find(&r, {tape.Name("a")}, out[:], ans[:])
	f, is_f := r.err.(tape.Fault)
	testing.expectf(t, n == 1 && is_f && f.kind == .Too_Wide && tape.fault_rule(f).code == "too_long", "max_bytes whole: n=%d err=%v", n, r.err)

	// Streaming pieces max_bytes: unbounded record without newline triggers Too_Wide once unread window > max_bytes.
	stream := fmt.tprintf("{{\"a\":1}}\n%s", strings.repeat("x", 64, context.temp_allocator))
	bs := transmute([]u8)stream
	p: tape.Pieces
	defer tape.destroy_pieces(&p)
	rp := json.records_open(bs[:16], .Lines, .Json, {pieces = &p})
	defer tape.destroy_records(&rp)
	rp.max_bytes = 24
	k1 := json.records_find(&rp, {tape.Name("a")}, out[:], ans[:])
	testing.expectf(t, k1 == 1 && rp.err == nil && p.more, "stream rec1: k1=%d err=%v more=%v", k1, rp.err, p.more)
	// Feed window holding 40 unread bytes (> 24) still with no newline.
	p.from = p.keep
	p.last = false
	_ = tape.records_window(&rp, bs[p.from:p.from + 40])
	k2 := json.records_find(&rp, {tape.Name("a")}, out[:], ans[:])
	f2, is_f2 := rp.err.(tape.Fault)
	testing.expectf(t, k2 == 0 && is_f2 && f2.kind == .Too_Wide && tape.fault_rule(f2).code == "too_long" && !p.more, "stream too_long: k2=%d err=%v more=%v", k2, rp.err, p.more)
}

@(test)
json_spine_finds_bulk_array :: proc(t: ^testing.T) {
	testkit.deadline(t)
	big := strings.repeat("1,", 3000, context.temp_allocator)
	// Root array
	at, levels, ok := json.spine(transmute([]u8)string("[1,2,3]"))
	testing.expectf(t, ok && at == 0 && levels == 0, "root: %v %v %v", at, levels, ok)
	// Nested spine past small side members
	nested := fmt.tprintf(`{{"meta":{{"v":1}},"items":[%s0]}}`, big)
	at, levels, ok = json.spine(transmute([]u8)nested)
	testing.expectf(t, ok && levels == 1 && nested[at] == '[', "nested: at=%d levels=%d ok=%v", at, levels, ok)
	// Small array inside object (< SIDE_BYTES) has no spine
	_, _, ok = json.spine(transmute([]u8)string(`{"a":[1]}`))
	testing.expectf(t, !ok, "small nested should not be spine")
	// Scalar root has no spine
	_, _, ok = json.spine(transmute([]u8)string(`42`))
	testing.expectf(t, !ok, "scalar should not be spine")
	// JSONC with comments
	commented := fmt.tprintf(`/* hdr */ {{"k":"v", /* c */ "rows":[%s0]}}`, big)
	at, levels, ok = json.spine(transmute([]u8)commented, .Jsonc)
	testing.expectf(t, ok && levels == 1 && commented[at] == '[', "jsonc spine: %v %v %v", at, levels, ok)
}

// --- Deliverables 2 & 3: Parallel validate, parallel records_*, parallel typed unmarshal ---

@(private = "file")
Log_Item :: struct {
	id:     i64             `json:"id"`,
	level:  string          `json:"level"`,
	msg:    string          `json:"msg"`,
	ok:     bool            `json:"ok"`,
	score:  f64             `json:"score"`,
	tags:   []string        `json:"tags"`,
	extra:  map[string]i64  `json:"extra"`,
}

@(private = "file")
Log_Envelope :: struct {
	version: i64        `json:"version"`,
	service: string     `json:"service"`,
	items:   []Log_Item `json:"items"`,
	footer:  i64        `json:"footer"`,
}

@(private = "file")
make_large_json_array :: proc(count: int, spec: json.Spec, envelope: bool, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(0, count * 110, allocator)
	if envelope {
		if spec == .Jsonc {
			strings.write_string(&b, "/* header */\n")
		}
		strings.write_string(&b, `{"version":7,"service":"billing","items":[`)
	} else {
		strings.write_byte(&b, '[')
	}
	for i in 0 ..< count {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		if spec == .Jsonc && i % 64 == 0 {
			strings.write_string(&b, " /* c */ ")
		}
		if spec == .Json5 && i % 32 == 0 {
			fmt.sbprintf(&b, "{{id:%d,level:'warn',msg:\"m\\n%d\",ok:%v,score:%d.5,tags:['a','b'],extra:{{k:%d}}}}", i, i, i % 2 == 0, i % 100, i)
		} else {
			fmt.sbprintf(&b, `{{"id":%d,"level":"info","msg":"msg\t%d","ok":%v,"score":%d.25,"tags":["t1","t2"],"extra":{{"x":%d}}}}`, i, i, i % 2 == 0, i % 100, i)
		}
	}
	if spec != .Json {
		strings.write_byte(&b, ',') // trailing comma for JSONC/JSON5
	}
	if envelope {
		strings.write_string(&b, `],"footer":999}`)
	} else {
		strings.write_byte(&b, ']')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_large_ndjson :: proc(count: int, seq: bool, with_faults: bool, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(0, count * 90, allocator)
	for i in 0 ..< count {
		if seq {
			strings.write_byte(&b, 0x1e)
		}
		if with_faults && (i == 5 || i == count / 2 || i == count - 3) {
			fmt.sbprintf(&b, `{{"id":%d,"bad":}}`, i)
		} else {
			fmt.sbprintf(&b, `{{"id":%d,"service":"svc-%d","status":%d,"msg":"hello world %d"}}`, i, i % 10, 200 + i % 5, i)
		}
		strings.write_byte(&b, '\n')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
items_equal :: proc(a, b: []Log_Item) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x.id != y.id || x.level != y.level || x.msg != y.msg || x.ok != y.ok || x.score != y.score || len(x.tags) != len(y.tags) || len(x.extra) != len(y.extra) {
			return false
		}
		for j in 0 ..< len(x.tags) {
			if x.tags[j] != y.tags[j] {
				return false
			}
		}
		for k, v in x.extra {
			if bv, ok := y.extra[k]; !ok || bv != v {
				return false
			}
		}
	}
	return true
}

@(private = "file")
free_items :: proc(items: []Log_Item, borrow: bool, a: runtime.Allocator) {
	for it in items {
		if !borrow {
			delete(it.level, a)
			for tg in it.tags {
				delete(tg, a)
			}
		}
		// `msg` has escape (`\t` or `\n`) so it is always allocated even when borrowing!
		delete(it.msg, a)
		delete(it.tags, a)
		for k in it.extra {
			if !borrow {
				delete(k, a)
			}
		}
		delete(it.extra)
	}
	delete(items, a)
}

@(test)
parallel_json_validate_equals_serial :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in json.Spec {
		src := make_large_json_array(6000, spec, true)
		defer delete(src)
		want := json.validate(src, spec)
		testing.expectf(t, want == nil, "%v valid serial err: %v", spec, want)
		for workers in ([]int{1, 2, 4, 18}) {
			pool: host.Pool
			_ = host.pool_init(&pool, workers)
			defer host.pool_destroy(&pool)
			got := json.validate(src, spec, {runner = &pool.runner})
			testing.expectf(t, got == want, "%v w=%d valid: got=%v want=%v", spec, workers, got, want)
		}
		// Inject faults in early, middle, and late positions.
		for frac in ([]int{10, 50, 90}) {
			bad := make([]u8, len(src))
			defer delete(bad)
			copy(bad, src)
			pos := len(bad) * frac / 100
			// Find a '{' near pos and corrupt it.
			for pos < len(bad) && bad[pos] != '{' {
				pos += 1
			}
			if pos + 1 < len(bad) {
				bad[pos + 1] = '@'
			}
			want_err := json.validate(bad, spec)
			testing.expectf(t, want_err != nil, "%v frac=%d expected fault", spec, frac)
			pool: host.Pool
			_ = host.pool_init(&pool, 4)
			defer host.pool_destroy(&pool)
			got_err := json.validate(bad, spec, {runner = &pool.runner})
			testing.expectf(t, got_err == want_err, "%v frac=%d fault mismatch: got=%v want=%v", spec, frac, got_err, want_err)
		}
	}
}

@(test)
parallel_json_records_equal_serial :: proc(t: ^testing.T) {
	testkit.deadline(t)
	path := []tape.Step{tape.Name("status")}
	demand, _ := tape.demand_of({path, {tape.Name("service")}})
	defer tape.destroy_demand(&demand)

	for seq in ([]bool{false, true}) {
		framing := tape.Framing.Seq if seq else .Lines
		for dirty in ([]bool{false, true}) {
			src := make_large_ndjson(3000, seq, dirty)
			defer delete(src)

			// Serial reference for validate
			rs := json.records_open(src, framing, .Json)
			defer tape.destroy_records(&rs)
			sbad: [16]tape.Record
			sn := json.records_validate(&rs, sbad[:])

			// Serial reference for find
			rfs := json.records_open(src, framing, .Json)
			defer tape.destroy_records(&rfs)
			sfout := make([]tape.Record, 3100)
			defer delete(sfout)
			sfans := make([]tape.Span_Answer, 3100)
			defer delete(sfans)
			sfn := json.records_find(&rfs, path, sfout, sfans, {stop_early = true})

			// Serial reference for scan
			rss := json.records_open(src, framing, .Json)
			defer tape.destroy_records(&rss)
			ssout := make([]tape.Record, 3100)
			defer delete(ssout)
			ssdocs := make([]tape.Document, 3100)
			defer delete(ssdocs)
			ssn := json.records_scan(&rss, &demand, ssout, ssdocs)

			for workers in ([]int{1, 2, 4, 18}) {
				pool: host.Pool
				_ = host.pool_init(&pool, workers)
				defer host.pool_destroy(&pool)

				// Parallel validate (both full batch and tiny batch of 2 to test partial-batch resume!)
				for cap in ([]int{16, 2}) {
					rp := json.records_open(src, framing, .Json, {runner = &pool.runner})
					defer tape.destroy_records(&rp)
					pbad := make([dynamic]tape.Record)
					defer delete(pbad)
					for {
						buf: [16]tape.Record
						k := json.records_validate(&rp, buf[:cap])
						for i in 0 ..< k {
							append(&pbad, buf[i])
						}
						if k < cap {
							break
						}
					}
					testing.expectf(t, len(pbad) == sn && rp.index == rs.index && rp.err == rs.err, "seq=%v dirty=%v w=%d cap=%d validate: len=%d/%d idx=%d/%d", seq, dirty, workers, cap, len(pbad), sn, rp.index, rs.index)
					for i in 0 ..< min(len(pbad), sn) {
						testing.expectf(t, pbad[i] == sbad[i], "seq=%v w=%d bad[%d]: %v vs %v", seq, workers, i, pbad[i], sbad[i])
					}
				}

				// Parallel find
				rfp := json.records_open(src, framing, .Json, {runner = &pool.runner})
				defer tape.destroy_records(&rfp)
				pfout := make([]tape.Record, 3100)
				defer delete(pfout)
				pfans := make([]tape.Span_Answer, 3100)
				defer delete(pfans)
				pfn := json.records_find(&rfp, path, pfout, pfans, {stop_early = true})
				testing.expectf(t, pfn == sfn && rfp.index == rfs.index && rfp.err == rfs.err, "seq=%v w=%d find n=%d/%d", seq, workers, pfn, sfn)
				for i in 0 ..< min(pfn, sfn) {
					testing.expectf(t, pfout[i] == sfout[i] && pfans[i] == sfans[i], "seq=%v w=%d find[%d]", seq, workers, i)
				}

				// Parallel scan
				rsp := json.records_open(src, framing, .Json, {runner = &pool.runner})
				defer tape.destroy_records(&rsp)
				psout := make([]tape.Record, 3100)
				defer delete(psout)
				psdocs := make([]tape.Document, 3100)
				defer delete(psdocs)
				psn := json.records_scan(&rsp, &demand, psout, psdocs)
				testing.expectf(t, psn == ssn && rsp.index == rss.index && rsp.err == rss.err, "seq=%v w=%d scan n=%d/%d", seq, workers, psn, ssn)
				for i in 0 ..< min(psn, ssn) {
					testing.expectf(t, psout[i] == ssout[i] && len(psdocs[i].nodes) == len(ssdocs[i].nodes), "seq=%v w=%d scan[%d]", seq, workers, i)
				}
			}
		}
	}
}

// Custom allocator that returns `.Mode_Not_Implemented` for `.Query_Features` (must safely fall back to serial).
@(private = "file")
unknown_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	if mode == .Query_Features {
		return nil, .Mode_Not_Implemented
	}
	backing := (^runtime.Allocator)(data)^
	return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
parallel_json_typed_root_and_spine :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in json.Spec {
		// Both root array and nested envelope spine array (> 512 KiB so parallel triggers naturally).
		root_src := make_large_json_array(5500, spec, false)
		defer delete(root_src)
		env_src := make_large_json_array(5500, spec, true)
		defer delete(env_src)

		// Serial references (into virtual arena)
		var_ref: virtual.Arena
		_ = virtual.arena_init_growing(&var_ref)
		defer virtual.arena_destroy(&var_ref)
		ref_alloc := virtual.arena_allocator(&var_ref)

		want_root: []Log_Item
		testing.expect(t, json.unmarshal(root_src, &want_root, spec, allocator = ref_alloc) == nil)
		want_env: Log_Envelope
		testing.expect(t, json.unmarshal(env_src, &want_env, spec, allocator = ref_alloc) == nil)

		// Test thread counts 1, 2, 4, 18 across arena, heap, borrow & copy, and .Refuse!
		for workers in ([]int{1, 2, 4, 18}) {
			pool: host.Pool
			_ = host.pool_init(&pool, workers)
			defer host.pool_destroy(&pool)
			for borrow in ([]bool{false, true}) {
				// 1. Virtual Arena (`.Blocks` class)
				va: virtual.Arena
				_ = virtual.arena_init_growing(&va)
				defer virtual.arena_destroy(&va)
				a_alloc := virtual.arena_allocator(&va)

				got_root: []Log_Item
				err1 := json.unmarshal(root_src, &got_root, spec, {borrow_strings = borrow}, {runner = &pool.runner}, a_alloc)
				testing.expectf(t, err1 == nil && items_equal(got_root, want_root), "%v w=%d borrow=%v arena root err=%v", spec, workers, borrow, err1)

				got_env: Log_Envelope
				err2 := json.unmarshal(env_src, &got_env, spec, {borrow_strings = borrow}, {runner = &pool.runner, dups = .Refuse}, a_alloc)
				testing.expectf(t, err2 == nil && got_env.version == want_env.version && got_env.service == want_env.service && got_env.footer == want_env.footer && items_equal(got_env.items, want_env.items), "%v w=%d borrow=%v arena env err=%v", spec, workers, borrow, err2)

				// 2. Runtime heap (`.Direct` class, only test on w=4 and w=18 to keep test crisp)
				if workers == 4 || workers == 18 {
					heap := runtime.heap_allocator()
					h_env: Log_Envelope
					err3 := json.unmarshal(env_src, &h_env, spec, {borrow_strings = borrow}, {runner = &pool.runner}, heap)
					testing.expectf(t, err3 == nil && items_equal(h_env.items, want_env.items), "%v w=%d borrow=%v heap env err=%v", spec, workers, borrow, err3)
					if !borrow {
						delete(h_env.service, heap)
					}
					free_items(h_env.items, borrow, heap)
				}
			}
		}
	}

	// Test all remaining allocator classes: mem.Arena, temp_allocator, Tracking_Allocator, unknown custom allocator.
	src := make_large_json_array(5500, .Json, true)
	defer delete(src)
	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	// Tracking_Allocator (must fall back safely to serial with zero leaks / zero races)
	{
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, runtime.heap_allocator())
		defer mem.tracking_allocator_destroy(&track)
		ta := mem.tracking_allocator(&track)
		env: Log_Envelope
		err := json.unmarshal(src, &env, .Json, {borrow_strings = true}, {runner = &pool.runner}, ta)
		testing.expectf(t, err == nil && len(env.items) == 5500, "tracking err=%v", err)
		free_items(env.items, true, ta)
		testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0, "tracking leaks=%d bad_frees=%d", len(track.allocation_map), len(track.bad_free_array))
	}

	// Unknown allocator (must fall back safely to serial)
	{
		backing := runtime.heap_allocator()
		ua := runtime.Allocator{unknown_alloc_proc, &backing}
		env: Log_Envelope
		err := json.unmarshal(src, &env, .Json, {borrow_strings = true}, {runner = &pool.runner}, ua)
		testing.expectf(t, err == nil && len(env.items) == 5500, "unknown alloc err=%v", err)
		free_items(env.items, true, ua)
	}

	// temp_allocator (`.Blocks` class)
	{
		env: Log_Envelope
		err := json.unmarshal(src, &env, .Json, {borrow_strings = false}, {runner = &pool.runner}, context.temp_allocator)
		testing.expectf(t, err == nil && len(env.items) == 5500 && env.footer == 999, "temp alloc err=%v", err)
		free_all(context.temp_allocator)
	}

	// Faults & type refusals in prefix, middle part, last part, and suffix + caller-filled target + path + budget!
	{
		// Type refusal in middle of array: `"score":"nope"`
		bad := make([]u8, len(src))
		defer delete(bad)
		copy(bad, src)
		idx := strings.index(string(bad[len(bad) / 2:]), `"score":`) + len(bad) / 2
		bad[idx + 8] = '"'
		bad[idx + 9] = 'x'
		bad[idx + 10] = '"'

		// Serial reference error + path
		spath: [dynamic]tape.Step
		defer delete(spath)
		va_s: virtual.Arena
		_ = virtual.arena_init_growing(&va_s)
		defer virtual.arena_destroy(&va_s)
		stgt := Log_Envelope{version = 123, service = "keep", footer = 456}
		serr := json.unmarshal(bad, &stgt, .Json, {path = &spath}, allocator = virtual.arena_allocator(&va_s))
		testing.expect(t, serr != nil)

		// Parallel on arena
		ppath: [dynamic]tape.Step
		defer delete(ppath)
		va_p: virtual.Arena
		_ = virtual.arena_init_growing(&va_p)
		defer virtual.arena_destroy(&va_p)
		ptgt := Log_Envelope{version = 123, service = "keep", footer = 456}
		perr := json.unmarshal(bad, &ptgt, .Json, {path = &ppath}, {runner = &pool.runner}, virtual.arena_allocator(&va_p))
		testing.expectf(t, perr == serr && len(ppath) == len(spath), "refusal mismatch: perr=%v serr=%v ppath=%v spath=%v", perr, serr, ppath, spath)

		// Parallel on heap (`.Direct`) with fault -> must free all worker allocations cleanly and match serial error!
		hpath: [dynamic]tape.Step
		defer delete(hpath)
		htgt := Log_Envelope{version = 123, service = "keep", footer = 456}
		herr := json.unmarshal(bad, &htgt, .Json, {borrow_strings = true, path = &hpath}, {runner = &pool.runner}, runtime.heap_allocator())
		testing.expectf(t, herr == serr, "heap refusal mismatch: herr=%v serr=%v", herr, serr)
		free_items(htgt.items, true, runtime.heap_allocator())
	}

	// Suffix syntax fault with caller-filled target -> cleanly undone and retried serially!
	{
		bad_suf := make([]u8, len(src))
		defer delete(bad_suf)
		copy(bad_suf, src)
		bad_suf[len(bad_suf) - 2] = '!'
		va_s: virtual.Arena
		_ = virtual.arena_init_growing(&va_s)
		defer virtual.arena_destroy(&va_s)
		stgt := Log_Envelope{version = 1, service = "orig", footer = 55}
		serr := json.unmarshal(bad_suf, &stgt, .Json, allocator = virtual.arena_allocator(&va_s))

		va_p: virtual.Arena
		_ = virtual.arena_init_growing(&va_p)
		defer virtual.arena_destroy(&va_p)
		ptgt := Log_Envelope{version = 1, service = "orig", footer = 55}
		perr := json.unmarshal(bad_suf, &ptgt, .Json, {}, {runner = &pool.runner}, virtual.arena_allocator(&va_p))
		testing.expectf(t, perr == serr && ptgt.footer == stgt.footer, "suffix fault: perr=%v serr=%v", perr, serr)
	}

	// Edge Budget.memory with arena: tight budget triggers Exceeded{.Memory} matching serial.
	{
		va_s, va_p: virtual.Arena
		_ = virtual.arena_init_growing(&va_s)
		_ = virtual.arena_init_growing(&va_p)
		defer virtual.arena_destroy(&va_s)
		defer virtual.arena_destroy(&va_p)
		for lim in ([]u64{1024, 256 << 10, 64 << 20}) {
			s_env, p_env: Log_Envelope
			serr := json.unmarshal(src, &s_env, .Json, {}, {budget = {memory = lim}}, virtual.arena_allocator(&va_s))
			perr := json.unmarshal(src, &p_env, .Json, {}, {budget = {memory = lim}, runner = &pool.runner}, virtual.arena_allocator(&va_p))
			testing.expectf(t, perr == serr, "budget %d: perr=%v serr=%v", lim, perr, serr)
		}
	}
}

// Regression tests for Phase 1B adversarial review findings:
// - C1: `records_scan_chunks` OOM during `r.block.outgrown` adoption must not UAF or drop OOM.
// - C2: shared non-thread-safe `opts.scratch` arena under parallel `records_scan`/`records_find`/`records_validate`.
// - H3: `records_validate_chunks` `quarantine` OOM preserves exact `r.index`/`r.pos` consistency.
// - M7: JSON5 `.Seq` `cut_number` handles hex, `Infinity`, and `NaN`.
@(test)
parallel_records_review_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// M7: JSON5 `.Seq` cut_number on hex, Infinity, NaN (without vs with trailing whitespace).
	{
		seq5 := "\x1e0x1f\x1e0x1f\n\x1eInfinity\x1e-Infinity \x1eNaN\x1e+NaN\n"
		r := json.records_open(transmute([]u8)seq5, .Seq, .Json5)
		defer tape.destroy_records(&r)
		out: [8]tape.Record
		n := json.records_validate(&r, out[:])
		testing.expectf(t, r.err == nil && n == 3, "json5 seq cut_number: n=%d err=%v", n, r.err)
		for i in 0 ..< min(n, 3) {
			f, ok := out[i].err.(tape.Fault)
			testing.expectf(t, ok && f.kind == .Bad_Number && tape.fault_rule(f).code == "cut_number", "json5 cut_number[%d]: %v", i, out[i].err)
		}
	}

	// Build a large NDJSON payload with deep nesting (> WALK_LEVELS = 32) so workers allocate from `opts.scratch`.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 1600 {
		if i % 400 == 100 {
			fmt.sbprintf(&b, "{{\"id\":%d,\"bad\":!!!}}\n", i)
		} else if i % 40 == 0 {
			// Deeply nested (40 levels) to force walk stack growth on `opts.scratch`.
			strings.write_string(&b, `{"id":`)
			fmt.sbprintf(&b, "%d", i)
			strings.write_string(&b, `,"deep":`)
			for _ in 0 ..< 40 {
				strings.write_byte(&b, '[')
			}
			strings.write_byte(&b, '1')
			for _ in 0 ..< 40 {
				strings.write_byte(&b, ']')
			}
			strings.write_string(&b, "}\n")
		} else {
			fmt.sbprintf(&b, "{{\"id\":%d,\"tag\":\"row-%05d-padding-payload-for-chunks\"}}\n", i, i)
		}
	}
	src := transmute([]u8)strings.to_string(b)

	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	// C2: Shared non-thread-safe `mem.Arena` as `opts.scratch` across parallel scan/find/validate (TSan-verified).
	{
		scratch_buf := make([]u8, 4 << 20)
		defer delete(scratch_buf)
		arena: mem.Arena
		mem.arena_init(&arena, scratch_buf)
		scratch := mem.arena_allocator(&arena)

		path := []tape.Step{tape.Name("id")}
		demand, derr := tape.demand_of({path})
		testing.expect(t, derr == nil)
		defer tape.destroy_demand(&demand)

		// Parallel scan with shared non-thread-safe `opts.scratch`.
		rs := json.records_open(src, .Lines, .Json)
		defer tape.destroy_records(&rs)
		rp := json.records_open(src, .Lines, .Json, {runner = &pool.runner, scratch = scratch})
		defer tape.destroy_records(&rp)
		out_s := make([]tape.Record, 256)
		docs_s := make([]tape.Document, 256)
		out_p := make([]tape.Record, 256)
		docs_p := make([]tape.Document, 256)
		defer delete(out_s)
		defer delete(docs_s)
		defer delete(out_p)
		defer delete(docs_p)
		for {
			ns := json.records_scan(&rs, &demand, out_s, docs_s)
			np := json.records_scan(&rp, &demand, out_p, docs_p)
			testing.expectf(t, ns == np && rs.err == rp.err && rs.index == rp.index && rs.pos == rp.pos, "C2 scan mismatch: ns=%d np=%d", ns, np)
			if ns == 0 {
				break
			}
		}

		// Parallel find with shared non-thread-safe `opts.scratch`.
		mem.arena_free_all(&arena)
		rfs := json.records_open(src, .Lines, .Json)
		defer tape.destroy_records(&rfs)
		rfp := json.records_open(src, .Lines, .Json, {runner = &pool.runner, scratch = scratch})
		defer tape.destroy_records(&rfp)
		ans_s := make([]tape.Span_Answer, 256)
		ans_p := make([]tape.Span_Answer, 256)
		defer delete(ans_s)
		defer delete(ans_p)
		for {
			ns := json.records_find(&rfs, path, out_s, ans_s)
			np := json.records_find(&rfp, path, out_p, ans_p)
			testing.expectf(t, ns == np && rfs.err == rfp.err && rfs.index == rfp.index, "C2 find mismatch: ns=%d np=%d", ns, np)
			if ns == 0 {
				break
			}
		}

		// Parallel validate with shared non-thread-safe `opts.scratch`.
		mem.arena_free_all(&arena)
		rvs := json.records_open(src, .Lines, .Json)
		defer tape.destroy_records(&rvs)
		rvp := json.records_open(src, .Lines, .Json, {runner = &pool.runner, scratch = scratch})
		defer tape.destroy_records(&rvp)
		ns := json.records_validate(&rvs, out_s)
		np := json.records_validate(&rvp, out_p)
		testing.expectf(t, ns == np && rvs.err == rvp.err && rvs.index == rvp.index, "C2 validate mismatch: ns=%d np=%d", ns, np)
	}

	// C1: OOM during `r.block.outgrown` reserve in `records_scan_chunks` must not UAF, leak, or silently drop OOM.
	{
		Fail_On_Slice :: struct {
			backing:  runtime.Allocator,
			fail_cap: bool,
			tripped:  bool,
		}
		fail_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
			f := (^Fail_On_Slice)(data)
			// `r.block.outgrown` holds `[]u8` elements (16 bytes each), so a small allocation <= 256 bytes after blocks exist is `reserve(&r.block.outgrown, ...)`.
			if (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) && size > 0 && size <= 512 && alignment == align_of([]u8) {
				f.tripped = true
				return nil, .Out_Of_Memory
			}
			return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
		}
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, runtime.heap_allocator())
		defer mem.tracking_allocator_destroy(&track)
		fa := Fail_On_Slice{backing = mem.tracking_allocator(&track)}
		f_alloc := runtime.Allocator{fail_proc, &fa}

		demand, _ := tape.demand_of({[]tape.Step{tape.Name("id")}})
		defer tape.destroy_demand(&demand)
		r := json.records_open(src, .Lines, .Json, {runner = &pool.runner})
		out := make([]tape.Record, 512)
		docs := make([]tape.Document, 512)
		defer delete(out)
		defer delete(docs)
		n := json.records_scan(&r, &demand, out, docs, allocator = f_alloc)
		tape.destroy_records(&r)
		testing.expectf(t, fa.tripped && n == 0 && r.err == runtime.Allocator_Error.Out_Of_Memory, "C1 oom: tripped=%v n=%d err=%v", fa.tripped, n, r.err)
		for d, i in docs {
			if d.nodes != nil || d.allocator.procedure != nil {
				testing.expectf(t, false, "C1 doc[%d] not zeroed on OOM", i)
				break
			}
		}
		testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0, "C1 leaks=%d bad_frees=%d", len(track.allocation_map), len(track.bad_free_array))
	}

	// H3: `quarantine` OOM mid-batch in `records_validate_chunks` keeps `r.index`/`r.pos` synced with `out[:n]`.
	{
		Cap_Alloc :: struct {
			backing: runtime.Allocator,
			max_n:   int,
			calls:   int,
		}
		cap_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
			c := (^Cap_Alloc)(data)
			if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
				c.calls += 1
				if c.calls > c.max_n {
					return nil, .Out_Of_Memory
				}
			}
			return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
		}
		ca := Cap_Alloc{backing = context.allocator, max_n = 1}
		q := make([dynamic]json.Bad_Record, runtime.Allocator{cap_proc, &ca})
		defer delete(q)
		r := json.records_open(src, .Lines, .Json, {runner = &pool.runner})
		r.quarantine = &q
		defer tape.destroy_records(&r)
		out: [32]tape.Record
		n := json.records_validate(&r, out[:])
		testing.expectf(t, r.err == runtime.Allocator_Error.Out_Of_Memory && len(q) == n, "H3 quarantine OOM: n=%d len(q)=%d err=%v", n, len(q), r.err)
		if n > 0 {
			testing.expectf(t, r.pos >= out[n - 1].hi && r.index > 0, "H3 cursor desync: pos=%d last_hi=%d idx=%d", r.pos, out[n - 1].hi, r.index)
		}
	}
}
