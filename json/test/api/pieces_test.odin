package json_tests

// `validate` and `build` on a runner read a large root array in its pieces (`json.split_array`), with one thread's
// verdict, offset and rows: a fault in a late piece, one across a cut, and one at a cut give the serial answer.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import host "../../../host"
import json "../.."

// A root array of `n` entries of every kind, escaped strings and keys among them, spread over many pieces.
@(private = "file")
big_array :: proc(n: int, open := "[", close := "]") -> []byte {
	b := strings.builder_make()
	strings.write_string(&b, open)
	for i in 0 ..< n {
		if i > 0 {
			strings.write_string(&b, ",\n ")
		}
		switch i % 4 {
		case 0:
			fmt.sbprintf(&b, `{{"id":%d,"msg":"line\n%d é","kA":[1,2.5e3,true,null]}}`, i, i)
		case 1:
			fmt.sbprintf(&b, `[%d,"plain",{{}},[]]`, i)
		case 2:
			fmt.sbprintf(&b, `"s%d\t"`, i)
		case 3:
			fmt.sbprintf(&b, `%d.25`, i)
		}
	}
	strings.write_string(&b, close)
	return b.buf[:]
}

@(private = "file")
same_rows :: proc(t: ^testing.T, a, b: ^json.Document, loc := #caller_location) {
	testing.expect_value(t, len(a.rows), len(b.rows), loc)
	testing.expect(t, mem.compare(mem.slice_to_bytes(a.rows[:]), mem.slice_to_bytes(b.rows[:])) == 0, "rows differ", loc = loc)
	testing.expect(t, string(a.values[:]) == string(b.values[:]), "decoded bytes differ", loc = loc)
	testing.expect(t, mem.compare(mem.slice_to_bytes(a.key_texts[:]), mem.slice_to_bytes(b.key_texts[:])) == 0, "decoded keys differ", loc = loc)
	testing.expect_value(t, a.decoded, b.decoded, loc)
	testing.expect_value(t, a.pruned, b.pruned, loc)
	testing.expect_value(t, a.distinct_keys, b.distinct_keys, loc)
	testing.expect_value(t, a.spelling, b.spelling, loc)
	testing.expect(t, raw_data(a.src) == raw_data(b.src), "sources differ", loc = loc)
}

// The answer of `validate` and `build` on the pool is the calling thread's.
@(private = "file")
agrees :: proc(t: ^testing.T, src: []byte, runner: ^json.Batch_Runner, opts := json.Read_Opts{}, loc := #caller_location) {
	testing.expect_value(t, json.validate(src, opts, runner), json.validate(src, opts), loc)
	serial, serr := json.build(src, opts)
	defer json.destroy(&serial)
	parallel, perr := json.build(src, opts, runner = runner)
	defer json.destroy(&parallel)
	testing.expect_value(t, perr, serr, loc)
	if serr == nil {
		same_rows(t, &parallel, &serial, loc)
	}
	// A `.Nodes` document, which decodes nothing at the build, joins from its pieces the same way.
	whole: json.Request({.Nodes})
	defer json.destroy(&whole)
	_ = json.request_init(&whole, opts = opts)
	werr := json.scan(src, &whole)
	s, found := json.find_spine(src)
	if werr != nil || !found || s.levels > 0 {
		return
	}
	pieces, split := json.split_array(src, s.lo, s.z + 1, runner, context.allocator)
	defer delete(pieces)
	testing.expect(t, split, "no pieces", loc = loc)
	o := opts
	nodes, joined := json.pieces_build(src, s.lo, s.z + 1, pieces, build_nodes, &o, runner, context.allocator)
	defer json.destroy(&nodes)
	testing.expect(t, joined, "not joined", loc = loc)
	same_rows(t, &nodes, &whole.doc, loc)
	// Unjoined, each piece's entries are the whole build's, in order, over the same source.
	docs, built := json.pieces_docs(src, pieces, build_nodes, &o, runner, context.allocator)
	testing.expect(t, built, "not built", loc = loc)
	defer {
		for &d in docs {
			json.destroy(&d)
		}
		delete(docs)
	}
	all := json.children(&whole.doc, json.ROOT)
	for &d in docs {
		it := json.children(&d, json.ROOT)
		for row in json.children(&it) {
			want, _ := json.children(&all)
			raw, wraw := json.get_raw(&d, row), json.get_raw(&whole.doc, want)
			if raw_data(raw) != raw_data(wraw) || len(raw) != len(wraw) {
				testing.expect(t, false, "piece entry differs", loc = loc)
				return
			}
		}
	}
	_, more := json.children(&all)
	testing.expect(t, !more, "entries left", loc = loc)
}

@(private = "file")
build_nodes :: proc(opts: ^json.Read_Opts, text: []byte) -> (doc: json.Document, err: Maybe(json.Error)) {
	req: json.Request({.Nodes})
	_ = json.request_init(&req, opts = opts^, allocator = runtime.heap_allocator())
	if e := json.scan(text, &req); e != nil {
		err = json.Error{kind = .Bad_Option}
	}
	doc, req.doc = req.doc, {}
	json.destroy(&req)
	return
}

// The cuts the pool makes in `src`, which must be several.
@(private = "file")
cuts_of :: proc(t: ^testing.T, src: []byte, runner: ^json.Batch_Runner) -> []json.Piece {
	s, found := json.find_spine(src)
	testing.expect(t, found, "no spine")
	pieces, ok := json.split_array(src, s.lo, s.z + 1, runner, context.allocator)
	testing.expectf(t, ok && len(pieces) > 4, "%d pieces", len(pieces))
	return pieces
}

@(test)
test_pieces_agree_with_one_thread :: proc(t: ^testing.T) {
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.destroy(&pool)
	src := big_array(40_000)
	defer delete(src)
	pieces := cuts_of(t, src, &pool.runner)
	defer delete(pieces)
	agrees(t, src, &pool.runner)
	// The pieces vouch for the array alone, so a fault in one is a piece that fails.
	plain := json.Read_Opts{}
	check :: proc(opts: ^json.Read_Opts, text: []byte) -> Maybe(json.Error) {
		return json.validate(text, opts^)
	}
	testing.expect(t, json.pieces_pass(src, pieces, check, &plain, &pool.runner))
	src[pieces[5].lo + 1] = '}'
	testing.expect(t, !json.pieces_pass(src, pieces, check, &plain, &pool.runner))
	agrees(t, src, &pool.runner)
	src[pieces[5].lo + 1] = ' '
	agrees(t, src, &pool.runner)
	// Each piece's nesting is the array's: one level more than an entry's own.
	agrees(t, src, &pool.runner, {limits = {max_depth = 3}})
	agrees(t, src, &pool.runner, {limits = {max_depth = 2}})
	agrees(t, src, &pool.runner, {duplicates = .Refuse})
	// `.First` drops each piece's repeated members, as one thread drops the whole array's.
	repeats := strings.concatenate({"[", strings.repeat(`{"a":1,"b":[2,"a"],"a":{"a":3,"a":4}},`, 20_000, context.temp_allocator), "{}]"}, context.temp_allocator)
	agrees(t, transmute([]byte)repeats, &pool.runner, {duplicates = .First})
	free_all(context.temp_allocator)

	// A fault in a late piece.
	late := pieces[len(pieces) - 2]
	bad := strings.index_byte(string(src[late.lo:late.hi]), 't')
	src[late.lo + bad] = 'x'
	agrees(t, src, &pool.runner)
	src[late.lo + bad] = 't'

	// A string left open at a cut, which runs into the next piece.
	cut := pieces[len(pieces) / 2].hi
	quote := strings.last_index_byte(string(src[:cut]), '"')
	src[quote] = 'a'
	agrees(t, src, &pool.runner)
	src[quote] = '"'

	// No comma at a cut, and an empty entry there.
	src[cut] = ' '
	agrees(t, src, &pool.runner)
	src[cut - 1], src[cut] = ',', ','
	agrees(t, src, &pool.runner)
}

@(test)
test_pieces_spine_validates :: proc(t: ^testing.T) {
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.destroy(&pool)
	src := big_array(40_000, `{"v":1,"logs":[`, `],"n":"x"}`)
	defer delete(src)
	pieces := cuts_of(t, src, &pool.runner)
	defer delete(pieces)
	agrees(t, src, &pool.runner)
	agrees(t, src, &pool.runner, {limits = {max_depth = 4}})
	// A fault beside the array, and one in it.
	src[len(src) - 3] = '\\'
	agrees(t, src, &pool.runner)
	src[len(src) - 3] = 'x'
	src[pieces[3].lo + 2] = '}'
	agrees(t, src, &pool.runner)
}
