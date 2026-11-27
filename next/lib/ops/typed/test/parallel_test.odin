package typed_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "stury:cbor"
import "stury:dsv"
import "stury:host"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:testkit"

@(private = "file")
TAG :: struct {
	code: string `json:"code"`,
	rank: i64    `json:"rank"`,
}

@(private = "file")
Payload :: union {
	i64,
	string,
	bool,
}

@(private = "file")
Aligned_Cell :: struct #align (128) {
	v: i64 `json:"v"`,
	s: string `json:"s"`,
}

@(private = "file")
Rich_Item :: struct {
	id:     i64             `json:"id"`,
	name:   string          `json:"name"`,
	note:   string          `json:"note"`,
	active: bool            `json:"active"`,
	score:  f64             `json:"score"`,
	opt:    Maybe(i64)      `json:"opt"`,
	tag:    ^TAG            `json:"tag"`,
	val:    Payload         `json:"val"`,
	pair:   [2]i64          `json:"pair"`,
	labels: []string        `json:"labels"`,
	counts: map[string]i64  `json:"counts"`,
}

@(private = "file")
Envelope :: struct {
	version: i64            `json:"version"`,
	service: string         `json:"service"`,
	node:    ^TAG           `json:"node"`,
	kv:      map[string]i64 `json:"kv"`,
	items:   []Rich_Item    `json:"items"`,
	extra:   []Rich_Item    `json:"extra"`,
	tail:    i64            `json:"tail"`,
}

@(private = "file")
Dsv_Row :: struct {
	id:    i64    `csv:"id"`,
	name:  string `csv:"name"`,
	score: f64    `csv:"score"`,
	ok:    bool   `csv:"ok"`,
	note:  string `csv:"note"`,
}

@(private = "file")
Dsv_Pos :: struct {
	id:    i64,
	name:  string,
	score: f64,
	ok:    bool,
}

@(private = "file")
Wide_Dsv :: struct {
	c00, c01, c02, c03, c04, c05, c06, c07, c08, c09: i64,
	c10, c11, c12, c13, c14, c15, c16, c17, c18, c19: i64,
	c20, c21, c22, c23, c24, c25, c26, c27, c28, c29: i64,
	c30, c31, c32, c33, c34, c35, c36, c37, c38, c39: i64,
	c40, c41, c42, c43, c44, c45, c46, c47, c48, c49: i64,
	c50, c51, c52, c53, c54, c55, c56, c57, c58, c59: i64,
	c60, c61, c62, c63, c64, c65, c66, c67, c68, c69: string,
}

@(private = "file")
Cbor_Row :: struct {
	id:    i64            `cbor:"id"`,
	stamp: time.Time      `cbor:"when"`,
	raw:   []u8           `cbor:"raw"`,
	name:  string         `cbor:"name"`,
	ok:    bool           `cbor:"ok"`,
	kv:    map[string]i64 `cbor:"kv"`,
}

@(private = "file")
Chain_Node :: struct {
	v:    i64         `json:"v"`,
	next: ^Chain_Node `json:"next"`,
}

// 65+ fields (> SEEN_BITS = 61) plus recursive `Chain_Node` (> 64 frames deep) so `seen_start_wide` / `frames_grow`
// exercise `Locked_Scratch` simultaneously across workers.
@(private = "file")
Wide65 :: struct {
	f00, f01, f02, f03, f04, f05, f06, f07, f08, f09: i64,
	f10, f11, f12, f13, f14, f15, f16, f17, f18, f19: i64,
	f20, f21, f22, f23, f24, f25, f26, f27, f28, f29: i64,
	f30, f31, f32, f33, f34, f35, f36, f37, f38, f39: i64,
	f40, f41, f42, f43, f44, f45, f46, f47, f48, f49: i64,
	f50, f51, f52, f53, f54, f55, f56, f57, f58, f59: i64,
	f60, f61, f62, f63, f64:                          string,
	chain:                                            ^Chain_Node,
}

@(private = "file")
tag_equal :: proc(a, b: ^TAG) -> bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.code == b.code && a.rank == b.rank
}

@(private = "file")
payload_equal :: proc(a, b: Payload) -> bool {
	switch va in a {
	case i64:
		vb, ok := b.(i64)
		return ok && va == vb
	case string:
		vb, ok := b.(string)
		return ok && va == vb
	case bool:
		vb, ok := b.(bool)
		return ok && va == vb
	}
	return b == nil
}

@(private = "file")
rich_equal :: proc(a, b: []Rich_Item) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x.id != y.id || x.name != y.name || x.note != y.note || x.active != y.active || x.score != y.score {
			return false
		}
		if x.opt != y.opt || !tag_equal(x.tag, y.tag) || !payload_equal(x.val, y.val) || x.pair != y.pair {
			return false
		}
		if len(x.labels) != len(y.labels) || len(x.counts) != len(y.counts) {
			return false
		}
		for j in 0 ..< len(x.labels) {
			if x.labels[j] != y.labels[j] {
				return false
			}
		}
		for k, v in x.counts {
			bv, found := y.counts[k]
			if !found || bv != v {
				return false
			}
		}
	}
	return true
}

@(private = "file")
free_rich_list :: proc(items: []Rich_Item, borrow: bool, a: runtime.Allocator) {
	for it in items {
		if !borrow {
			delete(it.name, a)
			for lb in it.labels {
				delete(lb, a)
			}
			if s, ok := it.val.(string); ok {
				delete(s, a)
			}
			for k in it.counts {
				delete(k, a)
			}
		}
		if it.tag != nil {
			if !borrow {
				delete(it.tag.code, a)
			}
			free(it.tag, a)
		}
		// `note` always contains `\n` or `\t`, so it is decoded and allocated even under `borrow`.
		delete(it.note, a)
		delete(it.labels, a)
		delete(it.counts)
	}
	delete(items, a)
}

@(private = "file")
make_rich_json :: proc(count: int, spec: json.Spec, envelope: bool, with_dups: bool, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(0, count * 220, allocator)
	if envelope {
		if spec == .Jsonc {
			strings.write_string(&b, "/* prefix comment */\n")
		}
		strings.write_string(&b, `{"version":7,"service":"edge","node":{"code":"p0","rank":11},"kv":{"a":1,"b":2},"items":[`)
	} else {
		strings.write_byte(&b, '[')
	}
	for i in 0 ..< count {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		if spec == .Jsonc && i % 40 == 0 {
			strings.write_string(&b, " /* inline */ ")
		}
		dup := `,"id":999999` if with_dups && i % 13 == 0 else ""
		if spec == .Json5 && i % 24 == 0 {
			fmt.sbprintf(&b, "{{id:%d,name:'plain-%d',note:\"esc\\n%d\",active:%v,score:%d.5,opt:null,tag:null,val:true,pair:[1,2],labels:['x','y'],counts:{{k:%d}}}}",
				i, i, i, i % 2 == 0, i % 100, i)
		} else {
			switch i % 3 {
			case 0:
				fmt.sbprintf(&b, `{{"id":%d,"name":"row-%d","note":"n\t%d","active":%v,"score":%d.25,"opt":%d,"tag":{{"code":"tg","rank":%d}},"val":"v-%d","pair":[%d,%d],"labels":["l1","l2"],"counts":{{"x":%d}}%s}}`,
					i, i, i, i % 2 == 0, i % 50, i, i % 7, i, i, i + 1, i, dup)
			case 1:
				fmt.sbprintf(&b, `{{"id":%d,"name":"row-%d","note":"n\t%d","active":%v,"score":%d.75,"opt":null,"tag":null,"val":%d,"pair":[%d,%d],"labels":[],"counts":{{"y":%d}}%s}}`,
					i, i, i, i % 2 == 0, i % 50, i * 2, i, i + 2, i, dup)
			case:
				fmt.sbprintf(&b, `{{"id":%d,"name":"row-%d","note":"n\t%d","active":%v,"score":%d.5,"opt":%d,"tag":{{"code":"tc","rank":3}},"val":%v,"pair":[%d,%d],"labels":["z"],"counts":{{"z":%d}}%s}}`,
					i, i, i, i % 2 == 0, i % 50, i + 3, i % 2 == 0, i, i + 3, i, dup)
			}
		}
	}
	if spec != .Json {
		strings.write_byte(&b, ',')
	}
	if envelope {
		strings.write_string(&b, `],"extra":[],"tail":42}`)
	} else {
		strings.write_byte(&b, ']')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_large_csv :: proc(rows: int, spec: dsv.Spec, no_trailing_nl: bool, with_header: bool, allocator := context.allocator) -> []u8 {
	sep := "\t" if spec == .Tsv else ","
	b := strings.builder_make(0, rows * 64, allocator)
	if with_header {
		fmt.sbprintf(&b, "id%sname%sscore%sok%snote\n", sep, sep, sep, sep)
	}
	for i in 0 ..< rows {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		if spec == .Csv && i % 15 == 0 {
			if with_header {
				fmt.sbprintf(&b, "%d,\"q\"\"%d\"\"\",%d.25,%v,\"l1\nl2\"", i, i, i % 100, i % 2 == 0)
			} else {
				fmt.sbprintf(&b, "%d,\"q\"\"%d\"\"\",%d.25,%v", i, i, i % 100, i % 2 == 0)
			}
		} else if with_header {
			fmt.sbprintf(&b, "%d%srow-%d%s%d.5%s%v%snote-%d", i, sep, i, sep, i % 100, sep, i % 2 == 0, sep, i)
		} else {
			fmt.sbprintf(&b, "%d%srow-%d%s%d.5%s%v", i, sep, i, sep, i % 100, sep, i % 2 == 0)
		}
	}
	if !no_trailing_nl {
		strings.write_byte(&b, '\n')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_wide_csv :: proc(rows: int, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(0, rows * 256, allocator)
	for c in 0 ..< 70 {
		if c > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "c%02d", c)
	}
	strings.write_byte(&b, '\n')
	for r in 0 ..< rows {
		for c in 0 ..< 70 {
			if c > 0 {
				strings.write_byte(&b, ',')
			}
			if c < 60 {
				fmt.sbprintf(&b, "%d", r + c)
			} else {
				fmt.sbprintf(&b, "s-%d-%d", r, c)
			}
		}
		strings.write_byte(&b, '\n')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_cbor_rows :: proc(count: int, spec: cbor.Spec, allocator := context.allocator) -> []u8 {
	rows := make([]Cbor_Row, count, context.temp_allocator)
	for &it, i in rows {
		kv := make(map[string]i64, context.temp_allocator)
		kv["k"] = i64(i)
		it = {
			id    = i64(i),
			stamp = time.Time{_nsec = 1_700_000_000_000_000_000 + i64(i) * 1_000_000_000},
			raw   = []u8{u8(i), u8(i >> 8), 0xAB},
			name  = "payload-item-0123456789abcdef",
			ok    = i % 2 == 0,
			kv    = kv,
		}
	}
	defer free_all(context.temp_allocator)
	out, err := cbor.marshal(&rows, spec, allocator = allocator)
	assert(err == nil)
	return out
}

// Verifies JSON / JSONC / JSON5 parallel typed unmarshal across thread counts {1, 2, 4, 18}, root & nested spine,
// dynamic arrays, pre-made vs one-shot plans, borrow/copy, and all duplicate policies.
@(test)
typed_parallel_json_specs_and_threads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in json.Spec {
		root_src := make_rich_json(2800, spec, false, true)
		defer delete(root_src)
		env_src := make_rich_json(2800, spec, true, false)
		defer delete(env_src)
		env_dups_src := make_rich_json(2800, spec, true, true)
		defer delete(env_dups_src)

		ref_va: virtual.Arena
		_ = virtual.arena_init_growing(&ref_va)
		defer virtual.arena_destroy(&ref_va)
		ref_a := virtual.arena_allocator(&ref_va)

		for dups in ([]tape.Duplicates{.Last, .First, .Refuse}) {
			want_root: []Rich_Item
			serr_r := json.unmarshal(root_src, &want_root, spec, {}, {dups = dups}, ref_a)
			want_env: Envelope
			s_env_src := env_dups_src if dups == .Refuse else env_src
			serr_e := json.unmarshal(s_env_src, &want_env, spec, {}, {dups = dups}, ref_a)

			root_plan, rerr := json.plan_make([]Rich_Item)
			testing.expect(t, rerr == nil)
			defer json.plan_destroy(&root_plan)

			for workers in ([]int{1, 2, 4, 18}) {
				pool: host.Pool
				_ = host.pool_init(&pool, workers)
				defer host.pool_destroy(&pool)

				for borrow in ([]bool{false, true}) {
					va: virtual.Arena
					_ = virtual.arena_init_growing(&va)
					defer virtual.arena_destroy(&va)
					alloc := virtual.arena_allocator(&va)

					got_root: [dynamic]Rich_Item
					perr_r := json.unmarshal(root_src, &got_root, spec, {borrow_strings = borrow}, {runner = &pool.runner, dups = dups}, alloc)
					testing.expectf(t, perr_r == serr_r, "%v dups=%v w=%d borrow=%v root err=%v vs %v", spec, dups, workers, borrow, perr_r, serr_r)
					if serr_r == nil {
						testing.expectf(t, rich_equal(got_root[:], want_root), "%v dups=%v w=%d borrow=%v root mismatch", spec, dups, workers, borrow)
					}

					// Root slice with pre-built plan on workers=18 and env nested spine
					if workers == 18 {
						got_p: []Rich_Item
						perr_p := json.unmarshal(root_src, &got_p, spec, {borrow_strings = borrow, plan = &root_plan}, {runner = &pool.runner, dups = dups}, alloc)
						testing.expectf(t, perr_p == serr_r && (serr_r != nil || rich_equal(got_p, want_root)), "%v dups=%v plan root mismatch", spec, dups)
					}

					got_env: Envelope
					perr_e := json.unmarshal(s_env_src, &got_env, spec, {borrow_strings = borrow}, {runner = &pool.runner, dups = dups}, alloc)
					testing.expectf(t, perr_e == serr_e, "%v dups=%v w=%d borrow=%v env err=%v vs %v", spec, dups, workers, borrow, perr_e, serr_e)
					if serr_e == nil {
						testing.expectf(t, got_env.version == want_env.version && got_env.tail == want_env.tail && rich_equal(got_env.items, want_env.items),
							"%v dups=%v w=%d env mismatch", spec, dups, workers)
					}
				}
			}
		}
	}
}

// Verifies DSV (CSV/TSV/Plain, dynamic arrays, no trailing LF, no_header positional, [][]string, wide >=64 cols,
// non-list fallback) and CBOR (all specs, indefinite root arrays, tags, reserved byte fallback) across 1/2/4/18 threads.
@(test)
typed_parallel_dsv_and_cbor_variants :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. DSV variants including `no_trailing_nl` (`w.unclosed = k != n_parts - 1`), dynamic arrays, `[][]string`, no_header, and wide headers.
	for spec in dsv.Spec {
		src_eof := make_large_csv(12000, spec, true, true)
		defer delete(src_eof)
		ref_va: virtual.Arena
		_ = virtual.arena_init_growing(&ref_va)
		defer virtual.arena_destroy(&ref_va)
		ref_a := virtual.arena_allocator(&ref_va)

		want: []Dsv_Row
		testing.expect(t, dsv.unmarshal(src_eof, &want, spec, allocator = ref_a) == nil)
		testing.expectf(t, len(want) == 12000, "%v len=%d", spec, len(want))

		src_pos := make_large_csv(14000, spec, true, false)
		defer delete(src_pos)
		want_pos: []Dsv_Pos
		testing.expect(t, dsv.unmarshal(src_pos, &want_pos, spec, opts = {format = tape.Dsv_Options{no_header = true}}, allocator = ref_a) == nil)

		want_cells: [][]string
		testing.expect(t, dsv.unmarshal(src_pos, &want_cells, spec, allocator = ref_a) == nil)

		for workers in ([]int{1, 2, 4, 18}) {
			pool: host.Pool
			_ = host.pool_init(&pool, workers)
			defer host.pool_destroy(&pool)

			va: virtual.Arena
			_ = virtual.arena_init_growing(&va)
			defer virtual.arena_destroy(&va)
			a := virtual.arena_allocator(&va)

			got_dyn: [dynamic]Dsv_Row
			err := dsv.unmarshal(src_eof, &got_dyn, spec, {borrow_strings = workers % 2 == 0}, {runner = &pool.runner}, a)
			testing.expectf(t, err == nil && len(got_dyn) == len(want) && got_dyn[len(got_dyn) - 1] == want[len(want) - 1],
				"%v w=%d dyn err=%v len=%d", spec, workers, err, len(got_dyn))

			got_pos: []Dsv_Pos
			perr := dsv.unmarshal(src_pos, &got_pos, spec, {}, {format = tape.Dsv_Options{no_header = true}, runner = &pool.runner}, a)
			testing.expectf(t, perr == nil && len(got_pos) == len(want_pos) && got_pos[len(got_pos) - 1] == want_pos[len(want_pos) - 1],
				"%v w=%d pos err=%v", spec, workers, perr)

			got_cells: [][]string
			cerr := dsv.unmarshal(src_pos, &got_cells, spec, {borrow_strings = true}, {runner = &pool.runner}, a)
			testing.expectf(t, cerr == nil && len(got_cells) == len(want_cells) && len(got_cells[0]) == 4,
				"%v w=%d cells err=%v", spec, workers, cerr)
		}
	}

	// Wide CSV (>= 64 columns -> header_keys spills off stack) + tight Budget.memory + non-list target (`Dsv_Row`).
	{
		wide_src := make_wide_csv(2600)
		defer delete(wide_src)
		pool: host.Pool
		_ = host.pool_init(&pool, 4)
		defer host.pool_destroy(&pool)

		ref_va, par_va: virtual.Arena
		_ = virtual.arena_init_growing(&ref_va)
		_ = virtual.arena_init_growing(&par_va)
		defer virtual.arena_destroy(&ref_va)
		defer virtual.arena_destroy(&par_va)

		want_w, got_w: []Wide_Dsv
		testing.expect(t, dsv.unmarshal(wide_src, &want_w, .Csv, allocator = virtual.arena_allocator(&ref_va)) == nil)
		testing.expect(t, dsv.unmarshal(wide_src, &got_w, .Csv, {}, {runner = &pool.runner}, virtual.arena_allocator(&par_va)) == nil)
		testing.expectf(t, len(got_w) == len(want_w) && got_w[0].c69 == want_w[0].c69 && got_w[len(got_w) - 1] == want_w[len(want_w) - 1], "wide csv mismatch")

		// Non-list target (`Dsv_Row`) refuses 2nd row cleanly via serial fallback without pre-scanning.
		multi_row := make_large_csv(10, .Csv, false, true)
		defer delete(multi_row)
		one_row: Dsv_Row
		s_one: Dsv_Row
		serr := dsv.unmarshal(multi_row, &s_one, .Csv, allocator = virtual.arena_allocator(&ref_va))
		perr := dsv.unmarshal(multi_row, &one_row, .Csv, {}, {runner = &pool.runner}, virtual.arena_allocator(&par_va))
		testing.expectf(t, perr == serr && perr != nil, "non-list dsv: perr=%v serr=%v", perr, serr)
	}

	// 2. CBOR all specs + indefinite root array `0x9f ... 0xff` + tags + non-array / reserved fallback.
	for spec in cbor.Spec {
		csrc := make_cbor_rows(7000, spec)
		defer delete(csrc)

		ref_va: virtual.Arena
		_ = virtual.arena_init_growing(&ref_va)
		defer virtual.arena_destroy(&ref_va)
		want: []Cbor_Row
		testing.expectf(t, cbor.unmarshal(csrc, &want, spec, allocator = virtual.arena_allocator(&ref_va)) == nil, "%v serial failed", spec)

		for workers in ([]int{1, 2, 4, 18}) {
			pool: host.Pool
			_ = host.pool_init(&pool, workers)
			defer host.pool_destroy(&pool)
			va: virtual.Arena
			_ = virtual.arena_init_growing(&va)
			defer virtual.arena_destroy(&va)

			got: [dynamic]Cbor_Row
			err := cbor.unmarshal(csrc, &got, spec, {borrow_strings = workers == 4}, {runner = &pool.runner, dups = .Refuse}, virtual.arena_allocator(&va))
			testing.expectf(t, err == nil && len(got) == len(want), "cbor %v w=%d err=%v len=%d/%d", spec, workers, err, len(got), len(want))
			for i in 0 ..< min(len(got), len(want)) {
				if got[i].id != want[i].id || got[i].stamp != want[i].stamp || got[i].name != want[i].name || len(got[i].raw) != len(want[i].raw) {
					testing.expectf(t, false, "cbor %v w=%d item[%d] mismatch", spec, workers, i)
					break
				}
			}
		}
	}

	// Indefinite CBOR root array (`0x9f` + element items + `0xff`).
	{
		kv := make(map[string]i64, context.temp_allocator)
		kv["k"] = 7
		sample := Cbor_Row{
			id    = 42,
			stamp = time.Time{_nsec = 1_700_000_000_000_000_000},
			raw   = []u8{1, 2, 3},
			name  = "payload-item-0123456789abcdef",
			ok    = true,
			kv    = kv,
		}
		item_bytes, merr := cbor.marshal(&sample, .Cbor)
		testing.expect(t, merr == nil)
		defer delete(item_bytes)
		defer free_all(context.temp_allocator)

		count :: 7000
		indef := make([]u8, 2 + count * len(item_bytes))
		defer delete(indef)
		indef[0] = 0x9f
		for i in 0 ..< count {
			copy(indef[1 + i * len(item_bytes):], item_bytes)
		}
		indef[len(indef) - 1] = 0xff

		ref_va, par_va: virtual.Arena
		_ = virtual.arena_init_growing(&ref_va)
		_ = virtual.arena_init_growing(&par_va)
		defer virtual.arena_destroy(&ref_va)
		defer virtual.arena_destroy(&par_va)
		want_in, got_in: []Cbor_Row
		testing.expect(t, cbor.unmarshal(indef, &want_in, .Cbor, allocator = virtual.arena_allocator(&ref_va)) == nil)

		pool: host.Pool
		_ = host.pool_init(&pool, 4)
		defer host.pool_destroy(&pool)
		testing.expect(t, cbor.unmarshal(indef, &got_in, .Cbor, {}, {runner = &pool.runner}, virtual.arena_allocator(&par_va)) == nil)
		testing.expectf(t, len(got_in) == count && len(got_in) == len(want_in) && got_in[count - 1].id == 42, "cbor indef mismatch: %d/%d", len(got_in), len(want_in))

		// Reserved additional info byte `0x9c` in root falls back cleanly to serial fault without OOB/panic.
		bad_res := make([]u8, 64)
		defer delete(bad_res)
		bad_res[0] = 0x9c
		dummy: []Cbor_Row
		testing.expect(t, cbor.unmarshal(bad_res, &dummy, .Cbor, {}, {runner = &pool.runner}, virtual.arena_allocator(&par_va)) != nil)
	}
}

// Audits Ruling #8 allocator classifications, shared `opts.scratch == caller` (`mem.Arena`), wide structs (>61 fields),
// deep nesting (>64 frames), high alignment (>=128B), Tracking/Scratch/Stack/Mutex/unknown fallback, and `.Direct` leaks.
@(test)
typed_parallel_ruling8_allocators_and_shared_scratch :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Verify `parallel_alloc_class` for every Ruling #8 allocator kind.
	heap := runtime.heap_allocator()
	testing.expect(t, typed.parallel_alloc_class(heap, {}) == .Direct)
	testing.expect(t, typed.parallel_alloc_class(heap, {budget = {memory = 1 << 20}}) == .Serial)
	testing.expect(t, typed.parallel_alloc_class(context.temp_allocator, {}) == .Blocks)

	va: virtual.Arena
	_ = virtual.arena_init_growing(&va)
	defer virtual.arena_destroy(&va)
	testing.expect(t, typed.parallel_alloc_class(virtual.arena_allocator(&va), {}) == .Blocks)

	da: mem.Dynamic_Arena
	mem.dynamic_arena_init(&da)
	defer mem.dynamic_arena_destroy(&da)
	testing.expect(t, typed.parallel_alloc_class(mem.dynamic_arena_allocator(&da), {}) == .Blocks)

	ma_buf := make([]u8, 8 << 20)
	defer delete(ma_buf)
	ma: mem.Arena
	mem.arena_init(&ma, ma_buf)
	ma_alloc := mem.arena_allocator(&ma)
	testing.expect(t, typed.parallel_alloc_class(ma_alloc, {}) == .Blocks)
	testing.expect(t, typed.parallel_alloc_class(ma_alloc, {budget = {memory = 64 << 10}}) == .Serial)

	scr: mem.Scratch_Allocator
	_ = mem.scratch_allocator_init(&scr, 16 << 20)
	defer mem.scratch_allocator_destroy(&scr)
	testing.expect(t, typed.parallel_alloc_class(mem.scratch_allocator(&scr), {}) == .Serial)

	stk_buf := make([]u8, 16 << 20)
	defer delete(stk_buf)
	stk: mem.Stack
	mem.stack_init(&stk, stk_buf)
	testing.expect(t, typed.parallel_alloc_class(mem.stack_allocator(&stk), {}) == .Serial)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, heap)
	defer mem.tracking_allocator_destroy(&track)
	testing.expect(t, typed.parallel_alloc_class(mem.tracking_allocator(&track), {}) == .Serial)

	mtx: mem.Mutex_Allocator
	mem.mutex_allocator_init(&mtx, heap)
	testing.expect(t, typed.parallel_alloc_class(mem.mutex_allocator(&mtx), {}) == .Serial)

	testing.expect(t, typed.parallel_alloc_class(testkit.unknown_allocator(), {}) == .Serial)
	uf := testkit.Failing{backing = heap, fail_at = -1}
	ua := testkit.failing_allocator(&uf)
	testing.expect(t, typed.parallel_alloc_class(ua, {}) == .Serial)

	// Build a payload combining:
	// - skipped prefix > 1100 levels deep (`walk_prefix` grows `Walk.levels` via `scratch`, NOT `prefix_alloc`!)
	// - element `chain` > 70 levels deep (`frames_grow` -> `Locked_Scratch`)
	// - 66-field struct with reversed keys (`seen_start_wide` / `seen_end_wide` -> `Locked_Scratch`)
	// - shared `opts.scratch == caller` (`mem.Arena`) under BOTH `Budget.memory == 0` AND `Budget.memory != 0` under TSan!
	Wide65_Doc :: struct {
		items: []Wide65 `json:"items"`,
	}
	w65_b := strings.builder_make()
	defer strings.builder_destroy(&w65_b)
	strings.write_string(&w65_b, `{"walk_skip":`)
	for _ in 0 ..< 1100 {
		strings.write_byte(&w65_b, '[')
	}
	strings.write_byte(&w65_b, '1')
	for _ in 0 ..< 1100 {
		strings.write_byte(&w65_b, ']')
	}
	strings.write_string(&w65_b, `,"items":[`)
	for i in 0 ..< 2200 {
		if i > 0 {
			strings.write_byte(&w65_b, ',')
		}
		fmt.sbprintf(&w65_b, `{{"f64":"v-%d","f32":%d,"f00":%d`, i, i + 1, i)
		if i % 64 == 0 {
			strings.write_string(&w65_b, `,"chain":{"v":1`)
			for _ in 0 ..< 70 {
				strings.write_string(&w65_b, `,"next":{"v":2`)
			}
			for _ in 0 ..< 71 {
				strings.write_byte(&w65_b, '}')
			}
		}
		strings.write_byte(&w65_b, '}')
	}
	strings.write_string(&w65_b, `]}`)
	w65_src := transmute([]u8)strings.to_string(w65_b)

	for workers in ([]int{4, 18}) {
		pool: host.Pool
		_ = host.pool_init(&pool, workers)
		defer host.pool_destroy(&pool)

		// Shared non-thread-safe `mem.Arena` as BOTH caller & opts.scratch (`Budget.memory == 0` AND `Budget.memory != 0`) -> must be TSan-clean!
		for lim in ([]u64{0, 8 << 20}) {
			mem.arena_free_all(&ma)
			doc: Wide65_Doc
			err := json.unmarshal(w65_src, &doc, .Json, {}, {runner = &pool.runner, scratch = ma_alloc, budget = {memory = lim}}, ma_alloc)
			testing.expectf(t, err == nil && len(doc.items) == 2200 && doc.items[2199].f64 == "v-2199" && doc.items[2199].f00 == 2199,
				"shared arena w=%d lim=%d: err=%v len=%d", workers, lim, err, len(doc.items))
		}
	}

	// Dynamic_Arena, Scratch_Allocator, Stack, Mutex_Allocator, Tracking_Allocator, Unknown_Allocator on rich JSON.
	rich_src := make_rich_json(2200, .Json, true, false)
	defer delete(rich_src)
	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	{
		doc: Envelope
		err := json.unmarshal(rich_src, &doc, .Json, {borrow_strings = true}, {runner = &pool.runner}, mem.dynamic_arena_allocator(&da))
		testing.expectf(t, err == nil && len(doc.items) == 2200, "Dynamic_Arena err=%v", err)
	}
	{
		doc: Envelope
		err := json.unmarshal(rich_src, &doc, .Json, {borrow_strings = true}, {runner = &pool.runner}, mem.scratch_allocator(&scr))
		testing.expectf(t, err == nil && len(doc.items) == 2200, "Scratch err=%v", err)
	}
	{
		doc: Envelope
		err := json.unmarshal(rich_src, &doc, .Json, {borrow_strings = true}, {runner = &pool.runner}, mem.stack_allocator(&stk))
		testing.expectf(t, err == nil && len(doc.items) == 2200, "Stack err=%v", err)
	}
	{
		doc: Envelope
		err := json.unmarshal(rich_src, &doc, .Json, {borrow_strings = true}, {runner = &pool.runner, budget = {memory = 32 << 20}}, mem.tracking_allocator(&track))
		testing.expectf(t, err == nil && len(doc.items) == 2200, "Tracking err=%v", err)
		if doc.node != nil {
			free(doc.node, mem.tracking_allocator(&track))
		}
		delete(doc.kv)
		free_rich_list(doc.items, true, mem.tracking_allocator(&track))
		delete(doc.extra, mem.tracking_allocator(&track))
		testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0, "Tracking leaks=%d", len(track.allocation_map))
	}
	{
		doc: Envelope
		err := json.unmarshal(rich_src, &doc, .Json, {borrow_strings = true}, {runner = &pool.runner}, mem.mutex_allocator(&mtx))
		testing.expectf(t, err == nil && len(doc.items) == 2200, "Mutex err=%v", err)
		if doc.node != nil {
			free(doc.node, mem.mutex_allocator(&mtx))
		}
		delete(doc.kv)
		free_rich_list(doc.items, true, mem.mutex_allocator(&mtx))
		delete(doc.extra, mem.mutex_allocator(&mtx))
	}
	{
		doc: Envelope
		err := json.unmarshal(rich_src, &doc, .Json, {borrow_strings = true}, {runner = &pool.runner}, ua)
		testing.expectf(t, err == nil && len(doc.items) == 2200, "Unknown err=%v", err)
		if doc.node != nil {
			free(doc.node, ua)
		}
		delete(doc.kv)
		free_rich_list(doc.items, true, ua)
		delete(doc.extra, ua)
	}

	// Aligned struct (> 64 bytes alignment -> verifies `worker_block_grow` alignment).
	{
		ab := strings.builder_make()
		defer strings.builder_destroy(&ab)
		strings.write_byte(&ab, '[')
		for i in 0 ..< 4500 {
			if i > 0 {
				strings.write_byte(&ab, ',')
			}
			fmt.sbprintf(&ab, `{{"v":%d,"s":"aligned-%d"}}`, i, i)
		}
		strings.write_byte(&ab, ']')
		asrc := transmute([]u8)strings.to_string(ab)

		mem.arena_free_all(&ma)
		cells: []Aligned_Cell
		err := json.unmarshal(asrc, &cells, .Json, {}, {runner = &pool.runner}, ma_alloc)
		testing.expectf(t, err == nil && len(cells) == 4500, "aligned err=%v len=%d", err, len(cells))
		testing.expectf(t, uintptr(raw_data(cells)) % 128 == 0, "slice alignment not 128: %p", raw_data(cells))
	}
}

// Tests caller-filled target preservation (`^Struct`, `map[string]i64`, `[]T`) across ALL duplicate policies
// (especially `.First` regression where `hold_map`/`hold_pointee` must still save caller state during `read_parallel_spine`),
// mid-chunk faults, suffix faults, `.Direct` mixed borrow/escape cleanup, and fresh-budget serial fallback!
@(test)
typed_parallel_target_preservation_and_budgets :: proc(t: ^testing.T) {
	testkit.deadline(t)

	src := make_rich_json(3200, .Json, true, false)
	defer delete(src)

	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	// Corrupt suffix (`tail` bad type) AND corrupt mid-chunk (`"score":"x"`).
	tail_idx := strings.last_index(string(src), `"tail":42}`)
	testing.expect(t, tail_idx > 0)
	bad_suf := make([]u8, tail_idx + len(`"tail":"bad"}`))
	defer delete(bad_suf)
	copy(bad_suf, src[:tail_idx])
	copy(bad_suf[tail_idx:], `"tail":"bad"}`)

	bad_mid := make([]u8, len(src))
	defer delete(bad_mid)
	copy(bad_mid, src)
	mid_idx := strings.index(string(bad_mid[len(bad_mid) / 2:]), `"score":`) + len(bad_mid) / 2
	bad_mid[mid_idx + 8] = '"'
	bad_mid[mid_idx + 9] = 'x'
	bad_mid[mid_idx + 10] = '"'

	for dups in ([]tape.Duplicates{.Last, .First, .Refuse}) {
		for bad_case in ([][]u8{bad_mid, bad_suf}) {
			// 1. Arena target preservation (`^TAG` + pre-populated `map` + pre-populated `items` + scalars)
			s_va, p_va: virtual.Arena
			_ = virtual.arena_init_growing(&s_va)
			_ = virtual.arena_init_growing(&p_va)
			defer virtual.arena_destroy(&s_va)
			defer virtual.arena_destroy(&p_va)
			sa := virtual.arena_allocator(&s_va)
			pa := virtual.arena_allocator(&p_va)

			init_env :: proc(a: runtime.Allocator) -> Envelope {
				nd := new(TAG, a)
				nd^ = {code = "orig-code", rank = 777}
				kv := make(map[string]i64, a)
				kv["keep"] = 55
				it := make([]Rich_Item, 1, a)
				it[0] = {id = 999, name = "orig-item", note = "keep"}
				return {version = 100, service = "orig-svc", node = nd, kv = kv, items = it, tail = 888}
			}

			s_tgt := init_env(sa)
			p_tgt := init_env(pa)
			s_path, p_path: [dynamic]tape.Step
			defer delete(s_path)
			defer delete(p_path)

			serr := json.unmarshal(bad_case, &s_tgt, .Json, {path = &s_path}, {dups = dups}, sa)
			perr := json.unmarshal(bad_case, &p_tgt, .Json, {path = &p_path}, {dups = dups, runner = &pool.runner}, pa)
			testing.expectf(t, serr != nil && perr == serr && len(p_path) == len(s_path),
				"dups=%v err/path mismatch: perr=%v serr=%v p=%v s=%v", dups, perr, serr, p_path, s_path)
			// Verify `p_tgt` matches serial post-error state across scalars, slices, `^TAG`, and `map[string]i64`.
			testing.expectf(t, p_tgt.tail == s_tgt.tail && p_tgt.version == s_tgt.version && p_tgt.service == s_tgt.service && rich_equal(p_tgt.items, s_tgt.items),
				"dups=%v scalar/slice mismatch: p=(tail=%d,len=%d) s=(tail=%d,len=%d)", dups, p_tgt.tail, len(p_tgt.items), s_tgt.tail, len(s_tgt.items))
			testing.expectf(t, p_tgt.node != nil && p_tgt.node.code == s_tgt.node.code && p_tgt.node.rank == s_tgt.node.rank,
				"dups=%v node mismatch: p=%v s=%v", dups, p_tgt.node^, s_tgt.node^)
			testing.expectf(t, len(p_tgt.kv) == len(s_tgt.kv) && p_tgt.kv["keep"] == s_tgt.kv["keep"] && p_tgt.kv["a"] == s_tgt.kv["a"],
				"dups=%v kv mismatch: p=%v s=%v", dups, p_tgt.kv, s_tgt.kv)
		}

		// 2. `.Direct` heap target preservation with mixed borrowed & escaped strings under `borrow = true` + suffix failure!
		heap := runtime.heap_allocator()
		h_tgt := Envelope{
			node = new(TAG, heap),
			kv   = make(map[string]i64, heap),
			tail = 321,
		}
		h_tgt.node^ = {code = "h", rank = 9}
		h_tgt.kv["hk"] = 12
		herr := json.unmarshal(bad_suf, &h_tgt, .Json, {borrow_strings = true}, {dups = dups, runner = &pool.runner}, heap)
		testing.expectf(t, herr != nil && h_tgt.tail == 321 && h_tgt.node != nil && h_tgt.node.code == "p0" && h_tgt.kv["hk"] == 12 && h_tgt.kv["a"] == 1,
			"direct heap dups=%v err=%v", dups, herr)
		free(h_tgt.node, heap)
		// `a` and `b` in `kv` are borrowed spans into `bad_suf` (not heap-allocated), `"hk"` is rodata.
		delete(h_tgt.kv)
		free_rich_list(h_tgt.items, true, heap)
		delete(h_tgt.extra, heap)
	}

	// 3. Fresh-budget guarantee: parallel consumes blocks up to tight limit -> serial retry still sees FULL fresh `Budget.memory`.
	// Test both a limit too small (Exceeded{.Memory}) and a boundary limit where serial fits!
	{
		va_s, va_p: virtual.Arena
		_ = virtual.arena_init_growing(&va_s)
		_ = virtual.arena_init_growing(&va_p)
		defer virtual.arena_destroy(&va_s)
		defer virtual.arena_destroy(&va_p)

		// Compare serial vs parallel across several tight limits on both valid AND failing suffix payloads.
		for lim in ([]u64{1024, 150 << 10, 400 << 10, 2 << 20, 32 << 20}) {
			s_env, p_env: Envelope
			serr := json.unmarshal(src, &s_env, .Json, {}, {budget = {memory = lim}}, virtual.arena_allocator(&va_s))
			perr := json.unmarshal(src, &p_env, .Json, {}, {budget = {memory = lim}, runner = &pool.runner}, virtual.arena_allocator(&va_p))
			testing.expectf(t, perr == serr, "budget %d valid: perr=%v serr=%v", lim, perr, serr)

			sb_env, pb_env: Envelope
			sberr := json.unmarshal(bad_suf, &sb_env, .Json, {}, {budget = {memory = lim}}, virtual.arena_allocator(&va_s))
			pberr := json.unmarshal(bad_suf, &pb_env, .Json, {}, {budget = {memory = lim}, runner = &pool.runner}, virtual.arena_allocator(&va_p))
			testing.expectf(t, pberr == sberr, "budget %d bad_suf: perr=%v serr=%v", lim, pberr, sberr)
		}
	}
}

// Seeded randomized fuzz parity between serial and parallel (JSON / DSV / CBOR) across random thread counts & fault injections.
@(test)
typed_parallel_seeded_fuzz_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x0C_F022)

	rounds := testkit.rounds(3)
	worker_counts := [4]int{1, 2, 4, 18}
	for round in 0 ..< rounds {
		workers := worker_counts[rand.int_max(4)]
		pool: host.Pool
		_ = host.pool_init(&pool, workers)
		defer host.pool_destroy(&pool)

		va_s, va_p: virtual.Arena
		_ = virtual.arena_init_growing(&va_s)
		_ = virtual.arena_init_growing(&va_p)
		defer virtual.arena_destroy(&va_s)
		defer virtual.arena_destroy(&va_p)
		sa := virtual.arena_allocator(&va_s)
		pa := virtual.arena_allocator(&va_p)

		// JSON (envelope or root, random fault ~50%)
		env := rand.int_max(2) == 1
		jsrc := make_rich_json(2400, .Json, env, false)
		defer delete(jsrc)
		if round % 2 == 1 {
			pos := rand.int_max(len(jsrc) - 1)
			jsrc[pos] = '@'
		}
		if env {
			sd, pd: Envelope
			se := json.unmarshal(jsrc, &sd, .Json, {}, {}, sa)
			pe := json.unmarshal(jsrc, &pd, .Json, {}, {runner = &pool.runner}, pa)
			testing.expectf(t, pe == se, "fuzz json env round=%d w=%d: pe=%v se=%v", round, workers, pe, se)
			if se == nil {
				testing.expectf(t, rich_equal(pd.items, sd.items), "fuzz json env items round=%d", round)
			}
		} else {
			sd, pd: []Rich_Item
			se := json.unmarshal(jsrc, &sd, .Json, {}, {}, sa)
			pe := json.unmarshal(jsrc, &pd, .Json, {}, {runner = &pool.runner}, pa)
			testing.expectf(t, pe == se, "fuzz json root round=%d w=%d: pe=%v se=%v", round, workers, pe, se)
			if se == nil {
				testing.expectf(t, rich_equal(pd, sd), "fuzz json root items round=%d", round)
			}
		}

		// CSV (valid or injected broken quote / ragged row)
		csrc := make_large_csv(10000, .Csv, round % 2 == 0, true)
		defer delete(csrc)
		if round % 2 == 1 && len(csrc) > 200 {
			p := 100 + rand.int_max(len(csrc) - 150)
			csrc[p] = '"'
		}
		sc, pc: []Dsv_Row
		cse := dsv.unmarshal(csrc, &sc, .Csv, {}, {}, sa)
		cpe := dsv.unmarshal(csrc, &pc, .Csv, {}, {runner = &pool.runner}, pa)
		testing.expectf(t, cpe == cse, "fuzz csv round=%d w=%d: cpe=%v cse=%v", round, workers, cpe, cse)
		if cse == nil {
			testing.expectf(t, len(pc) == len(sc) && pc[0] == sc[0] && pc[len(pc) - 1] == sc[len(sc) - 1], "fuzz csv mismatch round=%d", round)
		}

		// CBOR
		bsrc := make_cbor_rows(5500, .Preferred)
		defer delete(bsrc)
		if round % 2 == 1 && len(bsrc) > 32 {
			p := 8 + rand.int_max(len(bsrc) - 16)
			bsrc[p] = 0xff
		}
		sb, pb: []Cbor_Row
		bse := cbor.unmarshal(bsrc, &sb, .Preferred, {}, {}, sa)
		bpe := cbor.unmarshal(bsrc, &pb, .Preferred, {}, {runner = &pool.runner}, pa)
		testing.expectf(t, bpe == bse, "fuzz cbor round=%d w=%d: bpe=%v bse=%v", round, workers, bpe, bse)
		if bse == nil {
			testing.expectf(t, len(pb) == len(sb) && pb[len(pb) - 1].id == sb[len(sb) - 1].id, "fuzz cbor mismatch round=%d", round)
		}
	}
}

@(private = "file")
Capped_Scratch :: struct {
	lock:  sync.Mutex,
	back:  runtime.Allocator,
	held:  int,
	peak:  int,
	limit: int,
}

@(private = "file")
capped_scratch_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	c := (^Capped_Scratch)(data)
	sync.mutex_guard(&c.lock)
	grows := 0
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		grows = size
	case .Resize, .Resize_Non_Zeroed:
		grows = size - old_size
	}
	if c.limit != 0 && grows > 0 && c.held + grows > c.limit {
		return nil, .Out_Of_Memory
	}
	out, err := c.back.procedure(c.back.data, mode, size, alignment, old_memory, old_size, loc)
	if err != nil {
		return out, err
	}
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		c.held += size
	case .Resize, .Resize_Non_Zeroed:
		c.held = c.held - min(c.held, old_size) + size
	case .Free:
		c.held -= min(c.held, old_size)
	case .Free_All:
		c.held = 0
	}
	c.peak = max(c.peak, c.held)
	return out, nil
}

// Regression tests for post-implementation review findings:
// 1. Nil caller allocator (`borrow_strings = false`) in `copy_span` / `store_string` (with & without memory budget).
// 2. `Refusing_Reader` early spine fallback leak check (`Tracking_Allocator` on `opts.scratch`).
// 3. `undo_target` restoring pre-populated `map` / `^T` when `pool.limit` is exhausted during parallel fallback.
// 4. `.Direct` failure cleanup under tiny `opts.scratch` without partial-release retry double-free.
// 5. Mismatched `uopts.plan` tag rejection in `dsv`/`cbor` `unmarshal_parallel`.
@(test)
typed_parallel_review_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Nil caller allocator with pre-made plan and `borrow_strings = false` (must not SIGSEGV or clobber `dest`).
	{
		Small_Str :: struct {
			s: string `json:"s"`,
			n: i64    `json:"n"`,
		}
		plan, perr := json.plan_make(Small_Str)
		testing.expect(t, perr == nil)
		defer typed.plan_destroy(&plan)

		nil_alloc := runtime.Allocator{}
		for lim in ([]u64{0, 4096}) {
			tgt := Small_Str{s = "keep", n = 99}
			e1 := json.unmarshal(transmute([]u8)string(`{"s":"hello","n":7}`), &tgt, .Json, {plan = &plan}, {budget = {memory = lim}}, nil_alloc)
			testing.expectf(t, e1 != nil && tgt.s == "keep", "nil alloc plain lim=%d: err=%v s=%q", lim, e1, tgt.s)

			tgt2 := Small_Str{s = "keep", n = 99}
			e2 := json.unmarshal(transmute([]u8)string(`{"s":"hi\nthere","n":7}`), &tgt2, .Json, {plan = &plan}, {budget = {memory = lim}}, nil_alloc)
			testing.expectf(t, e2 != nil && tgt2.s == "keep", "nil alloc decoded lim=%d: err=%v s=%q", lim, e2, tgt2.s)

			tgt3 := Small_Str{s = "keep", n = 99}
			e3 := json.unmarshal(transmute([]u8)string(`{"s":"","n":7}`), &tgt3, .Json, {plan = &plan}, {budget = {memory = lim}}, nil_alloc)
			testing.expectf(t, e3 == nil && tgt3.s == "" && tgt3.n == 7, "nil alloc empty lim=%d: err=%v tgt=%v", lim, e3, tgt3)
		}
	}

	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	// 2. `Refusing_Reader` early spine fallback must not leak `probe.keys`/`probe.opens`/`probe.hashed`.
	{
		// Build a wide prefix (> FEW_KEYS = 16 keys so `probe.hashed` is allocated too) plus `items` list.
		Wide_Prefix_Env :: struct {
			k00, k01, k02, k03, k04, k05, k06, k07, k08, k09: i64,
			k10, k11, k12, k13, k14, k15, k16, k17:           i64,
			items:                                            []Rich_Item `json:"items"`,
		}
		build_spine :: proc(n_items: int, bad_mid, unclosed: bool) -> []u8 {
			b := strings.builder_make()
			strings.write_byte(&b, '{')
			for i in 0 ..< 18 {
				fmt.sbprintf(&b, `"k%02d":%d,`, i, i)
			}
			strings.write_string(&b, `"items":[`)
			if unclosed {
				// Single giant truncated item so `split_list` fails / sees `< 2` parts after `probe.found` opens.
				strings.write_string(&b, `{"id":1,"name":"only","note":"`)
				for _ in 0 ..< 256 {
					strings.write_byte(&b, 'x')
				}
				return transmute([]u8)strings.to_string(b)
			}
			for i in 0 ..< n_items {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				if bad_mid && i == n_items - 5 {
					fmt.sbprintf(&b, `{{"id":%d,"id":%d}}`, i, i + 1)
				} else {
					fmt.sbprintf(&b, `{{"id":%d,"name":"n%d","note":"o%d","active":true,"score":1.5}}`, i, i, i)
				}
			}
			strings.write_string(&b, `]}`)
			return transmute([]u8)strings.to_string(b)
		}

		bad_split_src := build_spine(0, false, true)
		defer delete(bad_split_src)
		bad_part_src := build_spine(1800, true, false)
		defer delete(bad_part_src)

		for payload in ([][]u8{bad_split_src, bad_part_src}) {
			va_s, va_p: virtual.Arena
			_ = virtual.arena_init_growing(&va_s)
			_ = virtual.arena_init_growing(&va_p)
			defer virtual.arena_destroy(&va_s)
			defer virtual.arena_destroy(&va_p)

			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, runtime.heap_allocator())
			defer mem.tracking_allocator_destroy(&track)
			ta := mem.tracking_allocator(&track)

			sd, pd: Wide_Prefix_Env
			se := json.unmarshal(payload, &sd, .Json, {}, {dups = .Refuse}, virtual.arena_allocator(&va_s))
			pe := json.unmarshal(payload, &pd, .Json, {}, {dups = .Refuse, runner = &pool.runner, scratch = ta}, virtual.arena_allocator(&va_p))
			testing.expectf(t, se != nil && pe == se, "refuse spine err mismatch: pe=%v se=%v", pe, se)
			testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0,
				"refuse spine leaked %d allocs, %d bad_frees", len(track.allocation_map), len(track.bad_free_array))
		}
	}

	// 3. `undo_target` restores pre-populated `map[string]i64` & `^TAG` even when `pool.limit` is exhausted.
	{
		// Build a spine where `node` & multi-key `kv` are mutated before `items` (> `BLOCK_INIT*2` budget pressure).
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, `{"version":1,"service":"svc","node":{"code":"p0","rank":5},"kv":{"a":1,"b":2,"c":3,"d":4},"items":[`)
		for i in 0 ..< 4500 {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"id":%d,"name":"nm-%d","note":"nt-%d","active":true,"score":2.5,"labels":["x%d","y%d"]}}`, i, i, i, i, i)
		}
		strings.write_string(&b, `],"tail":99}`)
		src := transmute([]u8)strings.to_string(b)

		init_env :: proc(a: runtime.Allocator) -> Envelope {
			nd := new(TAG, a)
			nd^ = {code = "orig-code", rank = 777}
			kv := make(map[string]i64, a)
			kv["keep"] = 55
			return {version = 100, service = "orig-svc", node = nd, kv = kv, tail = 888}
		}

		for dups in ([]tape.Duplicates{.First, .Last, .Refuse}) {
			for lim in ([]u64{128 << 10, 136 << 10, 144 << 10, 160 << 10, 192 << 10, 256 << 10}) {
				va_s, va_p: virtual.Arena
				_ = virtual.arena_init_growing(&va_s)
				_ = virtual.arena_init_growing(&va_p)
				defer virtual.arena_destroy(&va_s)
				defer virtual.arena_destroy(&va_p)

				s_tgt := init_env(virtual.arena_allocator(&va_s))
				p_tgt := init_env(virtual.arena_allocator(&va_p))

				se := json.unmarshal(src, &s_tgt, .Json, {}, {dups = dups, budget = {memory = lim}}, virtual.arena_allocator(&va_s))
				pe := json.unmarshal(src, &p_tgt, .Json, {}, {dups = dups, budget = {memory = lim}, runner = &pool.runner}, virtual.arena_allocator(&va_p))
				testing.expectf(t, pe == se, "undo budget dups=%v lim=%d: pe=%v se=%v", dups, lim, pe, se)
				testing.expectf(t, p_tgt.node != nil && p_tgt.node.code == s_tgt.node.code && p_tgt.node.rank == s_tgt.node.rank,
					"undo node mismatch dups=%v lim=%d: p=%v s=%v", dups, lim, p_tgt.node^, s_tgt.node^)
				testing.expectf(t, len(p_tgt.kv) == len(s_tgt.kv) && p_tgt.kv["keep"] == s_tgt.kv["keep"] && ("a" in p_tgt.kv) == ("a" in s_tgt.kv) && p_tgt.kv["a"] == s_tgt.kv["a"],
					"undo kv mismatch dups=%v lim=%d: p=%v s=%v", dups, lim, p_tgt.kv, s_tgt.kv)
				testing.expectf(t, p_tgt.version == s_tgt.version && p_tgt.tail == s_tgt.tail && rich_equal(p_tgt.items, s_tgt.items),
					"undo fields mismatch dups=%v lim=%d", dups, lim)
			}
		}
	}

	// 4. `.Direct` failure cleanup under tiny `opts.scratch` must not abort partial `release` and retry double-free.
	{
		Deep_Item :: struct {
			id:    i64         `json:"id"`,
			label: string      `json:"label"`,
			tags:  []string    `json:"tags"`,
			chain: ^Chain_Node `json:"chain"`,
		}
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_byte(&b, '[')
		n := 1400
		for i in 0 ..< n {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			if i == n - 3 {
				// Invalid field value near the end so earlier chunks have allocated heap chains/strings before failing.
				strings.write_string(&b, `{"id":"bad"}`)
				continue
			}
			fmt.sbprintf(&b, `{{"id":%d,"label":"lbl-%d","tags":["t%d","u%d"],"chain":{{"v":1`, i, i, i, i)
			// Depth 24 guarantees `release` must grow `steps` past initial cap (16).
			for d in 0 ..< 24 {
				fmt.sbprintf(&b, `,"next":{{"v":%d`, d)
			}
			for _ in 0 ..< 25 {
				strings.write_byte(&b, '}')
			}
			strings.write_byte(&b, '}')
		}
		strings.write_byte(&b, ']')
		src := transmute([]u8)strings.to_string(b)

		free_deep_items :: proc(items: []Deep_Item, a: runtime.Allocator) {
			for it in items {
				delete(it.label, a)
				for tg in it.tags {
					delete(tg, a)
				}
				delete(it.tags, a)
				cur := it.chain
				for cur != nil {
					nxt := cur.next
					free(cur, a)
					cur = nxt
				}
			}
			delete(items, a)
		}

		// Probe uncapped scratch peak first, then cap `opts.scratch` tightly (~700 B above parse peak).
		probe_cs := Capped_Scratch{back = runtime.heap_allocator()}
		probe_sa := runtime.Allocator{capped_scratch_proc, &probe_cs}
		probe_out: []Deep_Item
		perr := json.unmarshal(src, &probe_out, .Json, {}, {runner = &pool.runner, scratch = probe_sa}, runtime.heap_allocator())
		testing.expect(t, perr != nil && probe_cs.held == 0)
		defer free_deep_items(probe_out, runtime.heap_allocator())

		tight_cs := Capped_Scratch{back = runtime.heap_allocator(), limit = probe_cs.peak + 700}
		tight_sa := runtime.Allocator{capped_scratch_proc, &tight_cs}
		tight_out: []Deep_Item
		terr := json.unmarshal(src, &tight_out, .Json, {}, {runner = &pool.runner, scratch = tight_sa}, runtime.heap_allocator())
		defer free_deep_items(tight_out, runtime.heap_allocator())
		testing.expectf(t, terr == perr && tight_cs.held == 0 && len(tight_out) == len(probe_out),
			"direct tight scratch cleanup: terr=%v perr=%v held=%d len=%d/%d", terr, perr, tight_cs.held, len(tight_out), len(probe_out))
	}

	// 5. Mismatched `uopts.plan` tag rejected upfront in `dsv` and `cbor` `unmarshal_parallel`.
	{
		va: virtual.Arena
		_ = virtual.arena_init_growing(&va)
		defer virtual.arena_destroy(&va)
		a := virtual.arena_allocator(&va)

		jplan_dsv, jerr1 := json.plan_make([]Dsv_Row)
		testing.expect(t, jerr1 == nil)
		defer typed.plan_destroy(&jplan_dsv)
		csv_src := make_large_csv(600, .Csv, true, true)
		defer delete(csv_src)
		drows: []Dsv_Row
		testing.expect(t, dsv.unmarshal(csv_src, &drows, .Csv, {plan = &jplan_dsv}, {runner = &pool.runner}, a) == tape.Bad_Option{"plan"})

		jplan_cbor, jerr2 := json.plan_make([]Cbor_Row)
		testing.expect(t, jerr2 == nil)
		defer typed.plan_destroy(&jplan_cbor)
		cbor_src := make_cbor_rows(400, .Preferred)
		defer delete(cbor_src)
		brows: []Cbor_Row
		testing.expect(t, cbor.unmarshal(cbor_src, &brows, .Preferred, {plan = &jplan_cbor}, {runner = &pool.runner}, a) == tape.Bad_Option{"plan"})
	}
}
