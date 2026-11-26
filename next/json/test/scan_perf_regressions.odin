package json_tests

import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

@(test)
scan_single_and_multi_names_leaf_frames_and_dups :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step { return tape.Name(s) }
	A :: tape.All{}

	// Multi-edge `.Names` + `.Leaves` fast path with bloom collisions ("stutas" same length/head/tail as "status"),
	// escaped keys, duplicate `.First`/`.Last` replacement (including `scan_kill` `tail_pop`), and skipped subtrees.
	src := `{"rows":[` +
		`{"stutas":99,"service":"api","nested":{"x":[1,2]},"status":200,"status":500,"\u0069d":"r1"},` +
		`{"ts":"t2","id":"r2-a","id":"r2-b","status":404}` +
		`]}`
	paths := [][]tape.Step{{N("rows"), A, N("status")}, {N("rows"), A, N("id")}, {N("rows"), A, N("ts")}}
	dm, derr := tape.demand_of(paths)
	testing.expect_value(t, derr, nil)
	defer tape.destroy(&dm)

	// `.Last` keeps replaced later values and pops overwritten single-edge tails cleanly.
	doc_last, err_last := json.scan(transmute([]u8)src, &dm, .Json, {}, {dups = .Last})
	testing.expect_value(t, err_last, nil)
	defer tape.destroy(&doc_last)
	ans_last := testkit.render_answers(&doc_last)
	testing.expect_value(t, ans_last, `0=500 0=404 1="r1" 1="r2-b" 2=Missing 2="t2"`)

	// `.First` keeps first occurrence and skips later duplicates.
	doc_first, err_first := json.scan(transmute([]u8)src, &dm, .Json, {}, {dups = .First})
	testing.expect_value(t, err_first, nil)
	defer tape.destroy(&doc_first)
	ans_first := testkit.render_answers(&doc_first)
	testing.expect_value(t, ans_first, `0=200 0=404 1="r1" 1="r2-a" 2=Missing 2="t2"`)

	// Single-edge `named != 0` duplicate `.Last` `tail_pop` and `.First` early pass + >16 `Scan_Room.missing` overflow.
	dup_src := `{"k":"one","skip":{"a":1},"k":"two","extra":3}`
	dm_one, _ := tape.demand_of([][]tape.Step{{N("k")}})
	defer tape.destroy(&dm_one)
	d1_last, _ := json.scan(transmute([]u8)dup_src, &dm_one, .Json, {}, {dups = .Last})
	defer tape.destroy(&d1_last)
	testing.expect_value(t, testkit.render_answers(&d1_last), `0="two"`)

	d1_first, _ := json.scan(transmute([]u8)dup_src, &dm_one, .Json, {}, {dups = .First})
	defer tape.destroy(&d1_first)
	testing.expect_value(t, testkit.render_answers(&d1_first), `0="one"`)

	// More than 16 missing names overflows `Scan_Room.missing` (`[16]Scan_Missing`) cleanly without corrupting answers.
	wide_missing := make([][]tape.Step, 20)
	defer delete(wide_missing)
	wide_names := [20]string{
		"m00", "m01", "m02", "m03", "m04", "m05", "m06", "m07", "m08", "m09",
		"m10", "m11", "m12", "m13", "m14", "m15", "m16", "m17", "m18", "keep",
	}
	for nm, i in wide_names {
		step := make([]tape.Step, 1)
		step[0] = N(nm)
		wide_missing[i] = step
	}
	defer for s in wide_missing {
		delete(s)
	}
	dm_miss, _ := tape.demand_of(wide_missing)
	defer tape.destroy(&dm_miss)
	d_miss, err_miss := json.scan(transmute([]u8)string(`{"keep":7,"other":8}`), &dm_miss)
	testing.expect_value(t, err_miss, nil)
	defer tape.destroy(&d_miss)
	at, p, _ := json.answer({doc = &d_miss}, 19, 0)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, d_miss.nodes[at].lo, u64(8))
}

@(test)
scan_lists_multi_path_scatter_and_heterogeneous_ndjson_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step { return tape.Name(s) }
	A :: tape.All{}

	// Heterogeneous NDJSON stream mimicking `docs.ndjson` (changing key schemas + escaped strings + missing field).
	ndjson := strings.concatenate({
		`{"id":1,"txt":"plain\tval","pad":{"big":[1,2,3]}}` + "\n",
		`{"other":"x","nested":{"k":"v"}}` + "\n",
		`{"pad":0,"id":3,"txt":"end"}` + "\n",
	})
	defer delete(ndjson)

	dm_nd, _ := tape.demand_of([][]tape.Step{{N("id")}, {N("txt")}})
	defer tape.destroy(&dm_nd)
	r := json.records_open(transmute([]u8)ndjson, .Lines)
	defer tape.destroy_records(&r)
	out_recs: [4]tape.Record
	docs: [4]tape.Document
	got := json.records_scan(&r, &dm_nd, out_recs[:], docs[:])
	testing.expect_value(t, got, 3)
	defer for &d in docs[:got] {
		tape.destroy(&d)
	}
	testing.expect_value(t, testkit.render_answers(&docs[0]), `0=1 1="plain\tval"`)
	testing.expect_value(t, testkit.render_answers(&docs[1]), `0=Missing 1=Missing`)
	testing.expect_value(t, testkit.render_answers(&docs[2]), `0=3 1="end"`)

	// >32 demand paths exercises `scan_lists` fallback outside `small_starts: [32]u32`.
	many_paths := make([][]tape.Step, 36)
	defer delete(many_paths)
	for i in 0 ..< 36 {
		s := make([]tape.Step, 2)
		s[0] = A
		buf: [4]u8
		buf[0] = 'k'
		buf[1] = u8('0' + i / 10)
		buf[2] = u8('0' + i % 10)
		s[1] = N(strings.clone(string(buf[:3])))
		many_paths[i] = s
	}
	defer for s in many_paths {
		delete(string(s[1].(tape.Name)))
		delete(s)
	}
	dm_many, _ := tape.demand_of(many_paths)
	defer tape.destroy(&dm_many)
	d_many, err_many := json.scan(transmute([]u8)string(`[{"k00":1,"k35":9},{"k35":2}]`), &dm_many)
	testing.expect_value(t, err_many, nil)
	defer tape.destroy(&d_many)
	p0_at, p0_p, _ := json.answer({doc = &d_many}, 0, 0)
	testing.expect_value(t, p0_p, tape.Presence.Found)
	testing.expect(t, d_many.nodes[p0_at].kind == .Number)
	_, p35_p0, _ := json.answer({doc = &d_many}, 35, 0)
	_, p35_p1, _ := json.answer({doc = &d_many}, 35, 1)
	testing.expect_value(t, p35_p0, tape.Presence.Found)
	testing.expect_value(t, p35_p1, tape.Presence.Found)
}
