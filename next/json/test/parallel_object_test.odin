package json_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:host"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:testkit"

@(private = "file")
build_large_flat_object :: proc(min_bytes: int, spec: json.Spec, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(0, max(min_bytes, 4096), allocator)
	strings.write_byte(&b, '{')
	for i := 0; strings.builder_len(b) < min_bytes || i < 4500; i += 1 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		switch i % 6 {
		case 0:
			fmt.sbprintf(&b, `"k_%d":%d`, i, i * 3 + 1)
		case 1:
			fmt.sbprintf(&b, `"colon:comma,brace}}[%d]":"v\",{{[:]}}%d"`, i, i)
		case 2:
			fmt.sbprintf(&b, `"esc\"\\_\u0061_%d":true`, i)
		case 3:
			fmt.sbprintf(&b, `"utf8_λ_日本語_%d":"héllo_世界_%d"`, i, i)
		case 4:
			if spec == .Json5 && i % 12 == 4 {
				fmt.sbprintf(&b, `unquoted_%d:'single\'[:]%d'`, i, i)
			} else {
				fmt.sbprintf(&b, `"arr_%d":[1,2,3]`, i)
			}
		case 5:
			if spec == .Jsonc {
				fmt.sbprintf(&b, `/*c*/"obj_%d":{{"x":%d,"y":"ok"}}`, i, i)
			} else {
				fmt.sbprintf(&b, `"obj_%d":{{"x":%d,"y":"ok"}}`, i, i)
			}
		}
	}
	if spec != .Json {
		strings.write_byte(&b, ',')
	}
	strings.write_byte(&b, '}')
	return transmute([]u8)strings.to_string(b)
}

@(test)
parallel_object_shapes_and_pool_sizes :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Small boundary shapes across multi-thread runners and pools.
	small_cases := [?]string{
		`{}`,
		`{"a":1}`,
		`{"":"empty_key","k:1,2}":"v}[:],","a\"\\b":"\u0061\"\\","日本語":"値"}`,
		`{"meta":{"v":1},"items":[{"id":1,"sub":{"k":2}},{"id":2,"arr":[1,2,3]}],"tail":{"ok":true}}`,
	}
	pool4: host.Pool
	testing.expect(t, host.pool_init(&pool4, 4) == nil)
	defer host.pool_destroy(&pool4)

	for src_str in small_cases {
		src := transmute([]u8)src_str
		for threads in ([]int{2, 4, 8}) {
			sr := testkit.serial_runner(threads)
			ok, built := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), src, {}, &sr, src_str)
			testing.expect(t, ok && built)
		}
		ok, built := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), src, {}, &pool4.runner, src_str)
		testing.expect(t, ok && built)
	}

	// Large (> max(BUILD_PARALLEL_FROM, 640 KiB)) top-level and nested bulk objects across 1/4/8 threads.
	target_size := max(build.PARALLEL_FROM, 64 << 10) + 64 << 10
	for spec in json.Spec {
		flat := build_large_flat_object(target_size, spec, context.temp_allocator)

		// Nested bulk object whose large object sits inside `"payload"`.
		nb := strings.builder_make(0, len(flat) + 128, context.temp_allocator)
		strings.write_string(&nb, `{"header":{"id":42,"tags":["x","y"]},"payload":`)
		strings.write_bytes(&nb, flat)
		strings.write_string(&nb, `,"footer":99}`)
		nested := transmute([]u8)strings.to_string(nb)

		// Verify parallel fan-out actually executes on both root object and nested bulk object.
		for pair in ([]struct {
			name: string,
			src:  []u8,
		}{{"flat", flat}, {"nested", nested}}) {
			tasks := 0
			cr := testkit.counting_runner(4, &tasks)
			ok_fan, built_fan := testkit.threads_agree(t, json.reads(spec), json.as(spec), pair.src, {}, &cr, pair.name)
			testing.expectf(t, ok_fan && built_fan, "%s %v failed agree", pair.name, spec)
			testing.expectf(t, tasks >= 2, "%s %v did not run in parallel: tasks=%d", pair.name, spec, tasks)

			for workers in ([]int{1, 4, 8}) {
				pool: host.Pool
				testing.expect(t, host.pool_init(&pool, workers) == nil)
				defer host.pool_destroy(&pool)
				ok, built := testkit.threads_agree(t, json.reads(spec), json.as(spec), pair.src, {}, &pool.runner, pair.name)
				testing.expectf(t, ok && built, "%s %v w=%d", pair.name, spec, workers)
			}
		}

		// Caller-only allocator invariant for `.Default` parallel object builds.
		caller: testkit.Caller_Only
		only := testkit.caller_only(&caller, context.allocator)
		doc, err := json.build(flat, spec, {runner = &pool4.runner}, only)
		testing.expectf(t, err == nil && len(doc.nodes) > 4500, "%v caller_only err=%v nodes=%d", spec, err, len(doc.nodes))
		tape.destroy(&doc)
		testing.expect_value(t, caller.strays, 0)

		free_all(context.temp_allocator)
	}
}

@(test)
parallel_object_duplicates_policies :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Cross-chunk duplicates on root object (> FEW_KEYS hash buckets + escaped/unescaped aliases),
	//    nested whole objects (both <= 32 inline and > 32 scratch overflow), and crossing nested objects.
	b := strings.builder_make(0, 512 << 10, context.temp_allocator)
	strings.write_byte(&b, '{')
	// Crossing nested object split cleanly across parts: starts near front and closes at very end.
	strings.write_string(&b, `"early_key":"first","\u0065arly_key":"first_escaped",`)
	// Large whole inner object (> 32 keys to exercise `p.scratch` overflow) with internal duplicate.
	strings.write_string(&b, `"big_inner":{`)
	for j in 0 ..< 48 {
		if j > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, `"ik_%d":%d`, j if j != 40 else 3, j)
	}
	strings.write_string(&b, `},`)
	// Many root members (> 4096 to saturate MAX_CHILDREN on .Default/.All and drop on .First/.Last!)
	// plus periodic cross-chunk collisions hitting > FEW_KEYS keys per bucket.
	for i in 0 ..< 5500 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		key_id := i
		if i % 97 == 13 {
			key_id = i % 29
		}
		if i == 2750 {
			strings.write_string(&b, `"\u006b_0":{"nested_dup":1,"nested_dup":2}`)
			continue
		}
		if i % 10 == 0 {
			// Whole inner object (<= 32 keys) with repeated key and comment in JSONC.
			fmt.sbprintf(&b, `"k_%d":{{"x":1,"y":2,"x":%d,"pad":"0123456789abcdef"}}`, key_id, i)
		} else {
			fmt.sbprintf(&b, `"k_%d":{"v":%d,"tag":"payload-%05d-padding"}`, key_id, i, i)
		}
	}
	strings.write_string(&b, `,"early_key":"last"}`)
	cross_src := transmute([]u8)strings.to_string(b)

	// Crossing nested sub-object spans multiple chunks too (root member wraps another chunked sub-object).
	cb := strings.builder_make(0, 256 << 10, context.temp_allocator)
	strings.write_string(&cb, `{"wrap":{"first_k":"a",`)
	for i in 0 ..< 2500 {
		key_id := i if i % 61 != 5 else 1
		fmt.sbprintf(&cb, `"w_%d":[%d,"padding-string-for-chunks"],`, key_id, i)
	}
	strings.write_string(&cb, `"\u0066irst_k":"b"},"outer_dup":1,"\u006futer_dup":2}`)
	crossing_sub_src := transmute([]u8)strings.to_string(cb)

	// Whole-only early dup vs later crossing dup AND crossing early dup vs later whole dup under `.Refuse`.
	wb := strings.builder_make(0, 128 << 10, context.temp_allocator)
	strings.write_string(&wb, `{"whole_early":{"dup":1,"dup":2},`)
	for i in 0 ..< 1500 {
		fmt.sbprintf(&wb, `"u_%d":"padding-text-to-stretch-chunks-%d",`, i, i)
	}
	strings.write_string(&wb, `"cross_late":1,"cross_late":2}`)
	whole_earlier_src := transmute([]u8)strings.to_string(wb)

	// Earlier duplicate + later syntax fault under `.Refuse`, AND earlier syntax fault + later duplicate.
	err_dup_src := make([]u8, len(cross_src), context.temp_allocator)
	copy(err_dup_src, cross_src)
	err_dup_src[len(err_dup_src) - 3] = '!'

	// `.Refuse` where earliest dup is NEAR the end, after a middle syntax fault.
	fb := strings.builder_make(0, 128 << 10, context.temp_allocator)
	strings.write_byte(&fb, '{')
	for i in 0 ..< 1500 {
		if i == 750 {
			strings.write_string(&fb, `"bad":!,`)
		}
		fmt.sbprintf(&fb, `"f_%d":"padding-payload-%d",`, i, i)
	}
	strings.write_string(&fb, `"late_dup":1,"late_dup":2}`)
	fault_earlier_src := transmute([]u8)strings.to_string(fb)

	policies := [?]tape.Duplicates{.Default, .All, .Last, .First, .Refuse}
	for workers in ([]int{1, 4, 8}) {
		pool: host.Pool
		testing.expect(t, host.pool_init(&pool, workers) == nil)
		defer host.pool_destroy(&pool)
		for src_item in ([]struct {
			name: string,
			src:  []u8,
		}{
			{"cross", cross_src},
			{"crossing_sub", crossing_sub_src},
			{"whole_earlier", whole_earlier_src},
			{"dup_before_fault", err_dup_src},
			{"fault_before_dup", fault_earlier_src},
		}) {
			for pol in policies {
				ok, _ := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), src_item.src, {dups = pol}, &pool.runner, src_item.name)
				testing.expectf(t, ok, "%s pol=%v w=%d", src_item.name, pol, workers)
			}
		}
	}

	// Shared non-thread-safe `mem.Arena` as `opts.scratch` with parallel object build & `.Last`/`.First`/`.Refuse`.
	scratch_buf := make([]u8, 2 << 20, context.temp_allocator)
	arena: mem.Arena
	mem.arena_init(&arena, scratch_buf)
	scratch := mem.arena_allocator(&arena)
	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)

	for pol in ([]tape.Duplicates{.Default, .Last, .Refuse}) {
		mem.arena_free_all(&arena)
		want, werr := json.build(cross_src, .Json, {dups = pol})
		defer tape.destroy(&want)
		got, gerr := json.build(cross_src, .Json, {dups = pol, runner = &pool.runner, scratch = scratch})
		defer tape.destroy(&got)
		testing.expectf(t, testkit.same_refusal(gerr, werr) && testkit.same_documents(got, want) && got.flags == want.flags, "scratch pol=%v: %v vs %v", pol, gerr, werr)
	}

	// Deterministic small-chunk sweeping over JSONC/JSON5 objects with duplicate policies and facts.
	jb := strings.builder_make(0, 16 << 10, context.temp_allocator)
	strings.write_byte(&jb, '{')
	for i in 0 ..< 80 {
		if i > 0 {
			strings.write_byte(&jb, ',')
		}
		fmt.sbprintf(&jb, `/* pre %d */ %s:{{"a":1,"a":2}} /* post %d */`, i, `"dup"` if i % 7 == 0 else fmt.tprintf("k_%d", i), i)
	}
	strings.write_string(&jb, `,}`)
	j5 := transmute([]u8)strings.to_string(jb)
	for threads in ([]int{2, 5, 19, 64}) {
		sr := testkit.serial_runner(threads)
		for pol in policies {
			ok, _ := testkit.threads_agree(t, json.reads(.Json5), json.as(.Json5), j5, {dups = pol}, &sr, "json5 dups")
			testing.expectf(t, ok, "json5 pol=%v t=%d", pol, threads)
		}
	}

	free_all(context.temp_allocator)
}

@(test)
parallel_object_deep_opens_and_budgets :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)

	// 1. > SEAM_OPENS (75 net opens in chunk 0 before any comma) with > 700 KiB payload so parallel fan-out runs!
	deep_pad := max(build.PARALLEL_FROM, 64 << 10) + 64 << 10
	db := strings.builder_make(0, deep_pad + 4096, context.temp_allocator)
	DEEP_75 :: 75
	for i in 0 ..< DEEP_75 {
		fmt.sbprintf(&db, `{{"d_%d":`, i)
	}
	// First chunk ends right inside deep nesting before any `,`, or has multiple stretches opening > 64 brackets.
	strings.write_string(&db, `1,`)
	for i := 0; strings.builder_len(db) < deep_pad; i += 1 {
		fmt.sbprintf(&db, `"pad_%d":"payload-value-%06d",`, i, i)
	}
	strings.write_string(&db, `"end":0`)
	for _ in 0 ..< DEEP_75 {
		strings.write_byte(&db, '}')
	}
	deep_src := transmute([]u8)strings.to_string(db)

	tasks := 0
	cr := testkit.counting_runner(4, &tasks)
	ok_deep, built_deep := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), deep_src, {}, &cr, "deep_75")
	testing.expect(t, ok_deep && built_deep)
	testing.expectf(t, tasks >= 2, "> SEAM_OPENS object fell back to 1 thread: tasks=%d", tasks)

	ok_pool, built_pool := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), deep_src, {}, &pool.runner, "deep_75_pool")
	testing.expect(t, ok_pool && built_pool)

	// Also test > SEAM_OPENS inside a chunk that ALREADY has open containers and pops some before opening 75 more.
	mb := strings.builder_make(0, deep_pad + 8192, context.temp_allocator)
	strings.write_string(&mb, `{"a":{"b":{"c":{`)
	for i in 0 ..< 3000 {
		fmt.sbprintf(&mb, `"p_%d":"filler-bytes-to-reach-chunk1-%d",`, i, i)
	}
	// Close 3 levels then immediately open 75 levels (under `"nest_wrap"`) before next comma:
	strings.write_string(&mb, `"last":1}}},"nest_wrap":`)
	for i in 0 ..< DEEP_75 {
		fmt.sbprintf(&mb, `{{"nest_%d":`, i)
	}
	strings.write_byte(&mb, '{')
	for i in 0 ..< 3000 {
		if i > 0 {
			strings.write_byte(&mb, ',')
		}
		fmt.sbprintf(&mb, `"q_%d":"more-filler-bytes-%d"`, i, i)
	}
	strings.write_string(&mb, `,"done":true}`)
	for _ in 0 ..< DEEP_75 {
		strings.write_byte(&mb, '}')
	}
	strings.write_byte(&mb, '}')
	mix_src := transmute([]u8)strings.to_string(mb)
	ok_mix, built_mix := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), mix_src, {}, &pool.runner, "pops_then_75")
	testing.expect(t, ok_mix && built_mix)

	// 2. > SEAM_LEVELS (1100 levels) must gracefully fall back and still match serial!
	OVER_SEAM :: 1100
	ob := strings.builder_make(0, OVER_SEAM * 10 + 16384, context.temp_allocator)
	for i in 0 ..< OVER_SEAM {
		fmt.sbprintf(&ob, `{{"o_%d":`, i)
	}
	strings.write_string(&ob, `1`)
	for i in 0 ..< 400 {
		fmt.sbprintf(&ob, `,"x_%d":%d`, i, i)
	}
	for _ in 0 ..< OVER_SEAM {
		strings.write_byte(&ob, '}')
	}
	over_src := transmute([]u8)strings.to_string(ob)
	ok_over, built_over := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), over_src, {budget = {depth = 2000}}, &pool.runner, "over_seam_levels")
	testing.expect(t, ok_over && built_over)

	// Tight depth limit (< open count after > SEAM_OPENS, e.g. depth = 10 on 1100 levels with commas).
	sr8 := testkit.serial_runner(8)
	ok_d10, _ := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), over_src, {budget = {depth = 10}}, &sr8, "depth_10_over_seam")
	testing.expect(t, ok_d10)

	// 3. Budget.{depth, nodes, steps, memory} on flat + nested large object across chunks.
	small_obj_b := strings.builder_make(0, 64 << 10, context.temp_allocator)
	strings.write_byte(&small_obj_b, '{')
	for i in 0 ..< 400 {
		if i > 0 {
			strings.write_byte(&small_obj_b, ',')
		}
		fmt.sbprintf(&small_obj_b, `"m_%d":{{"v":%d,"a":[1,2,%d],"d":"dup","d":"dup2"}}`, i, i, i)
	}
	strings.write_byte(&small_obj_b, '}')
	bsrc := transmute([]u8)strings.to_string(small_obj_b)

	for lim in ([]u32{1, 2, 3, 4, 10}) {
		ok_d, _ := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bsrc, {budget = {depth = lim}}, &pool.runner, "depth")
		testing.expect(t, ok_d)
	}
	for nodes in ([]u32{1, 10, 100, 1500, 3500}) {
		ok_n, _ := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bsrc, {budget = {nodes = nodes}}, &sr8, "nodes")
		testing.expect(t, ok_n)
	}
	for steps in ([]u64{1, 5, 250, 790, 810}) {
		ok_s, _ := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bsrc, {budget = {steps = steps}}, &sr8, "steps")
		testing.expect(t, ok_s)
	}
	// Budget.steps when a syntax error occurs before/after the container budget.
	bad_step := make([]u8, len(bsrc), context.temp_allocator)
	copy(bad_step, bsrc)
	bad_step[len(bad_step) / 2] = '@'
	for steps in ([]u64{10, 400, 2000}) {
		ok_bs, _ := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bad_step, {budget = {steps = steps}}, &sr8, "steps_with_fault")
		testing.expect(t, ok_bs)
	}

	// Budget.memory across duplicate policies on objects.
	for pol in ([]tape.Duplicates{.Default, .Last, .First, .Refuse}) {
		for memory in ([]u64{256, 4096, u64(len(bsrc)), u64(len(bsrc)) * 8, u64(len(bsrc)) * 64}) {
			ok_m := testkit.threads_fit(t, json.reads(.Json), json.as(.Json), bsrc, {dups = pol, budget = {memory = memory}}, &pool.runner, "mem_obj")
			testing.expectf(t, ok_m, "mem=%d pol=%v", memory, pol)
		}
	}

	free_all(context.temp_allocator)
}

@(test)
parallel_object_comments_jsonc_json5_and_block_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Force a chunk cut WITHOUT a nearby '\n' (padding > 4096 bytes of spaces around cut)
	// and align `//\n` and `/**/` at bytes 62..65 within chunk `k > 0` to verify `lex_comments`
	// marks bits 62..63 properly at 64-byte SIMD block boundaries!
	// Use 2 chunks on a runner with threads=1? chunk_count checks min((threads+1)*4, ...); with 25 KB and serial_runner(1),
	// 8 chunks -> each chunk ~3 KB, wait: use 12 KB so CUT_LINE=4096 checks hi+4096. To avoid line cut, put > 4500 spaces after cut,
	// and place the comment at exact offsets around chunk 1's blocks [62..65], [126..129], etc.
	size := max(build.PARALLEL_FROM, 64 << 10)
	b := strings.builder_make(0, size + 16384, context.temp_allocator)
	strings.write_string(&b, `{"k0":1`)
	// Fill to ~30 KiB without any `\n` near chunk boundaries, then place `// \n` and `/* */` right across
	// every alignment mod 64 (0..63) before commas and closing braces inside objects/arrays!
	for len_i := 0; strings.builder_len(b) < size / 2 - 4096; len_i += 1 {
		fmt.sbprintf(&b, `,"p_%d":%d`, len_i, len_i)
	}
	// Long single-line space run so chunk boundaries inside the middle region have NO `\n` within 4096 bytes.
	strings.write_byte(&b, ',')
	for _ in 0 ..< 9000 {
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, `"probe":[1`)
	for shift in 0 ..< 68 {
		strings.write_string(&b, `,`)
		for _ in 0 ..< shift {
			strings.write_byte(&b, ' ')
		}
		fmt.sbprintf(&b, "[//]\n],[/*\n*/],")
		strings.write_string(&b, `//` + "\n")
		for _ in 0 ..< shift {
			strings.write_byte(&b, ' ')
		}
		fmt.sbprintf(&b, "%d", shift)
	}
	strings.write_string(&b, `]`)
	for shift in 0 ..< 68 {
		strings.write_string(&b, `,`)
		for _ in 0 ..< shift {
			strings.write_byte(&b, ' ')
		}
		fmt.sbprintf(&b, `/*}},]*/"c_%d":%d/*tail*/`, shift, shift)
		strings.write_string(&b, `//` + "\n")
	}
	// JSON5 Unicode whitespace + unquoted keys + single quotes + trailing commas.
	for i in 0 ..< 400 {
		fmt.sbprintf(&b, ",\u00a0k5_%d\u2028:'hello \\' [,:] \\\\ world %d'", i, i)
	}
	strings.write_string(&b, `,}`)
	src5 := transmute([]u8)strings.to_string(b)

	// JSONC variant without unquoted keys / single quotes / U+2028.
	cb := strings.builder_make(0, size + 16384, context.temp_allocator)
	strings.write_string(&cb, `{"k0":1`)
	for len_i := 0; strings.builder_len(cb) < size / 2 - 4096; len_i += 1 {
		fmt.sbprintf(&cb, `,"p_%d":%d`, len_i, len_i)
	}
	strings.write_byte(&cb, ',')
	for _ in 0 ..< 9000 {
		strings.write_byte(&cb, ' ')
	}
	strings.write_string(&cb, `"probe":[1`)
	for shift in 0 ..< 68 {
		strings.write_string(&cb, `,`)
		for _ in 0 ..< shift {
			strings.write_byte(&cb, ' ')
		}
		fmt.sbprintf(&cb, "[//]\n],[/*\n*/],")
		strings.write_string(&cb, `//` + "\n")
		for _ in 0 ..< shift {
			strings.write_byte(&cb, ' ')
		}
		fmt.sbprintf(&cb, "%d", shift)
	}
	strings.write_string(&cb, `]`)
	for shift in 0 ..< 68 {
		strings.write_string(&cb, `,`)
		for _ in 0 ..< shift {
			strings.write_byte(&cb, ' ')
		}
		fmt.sbprintf(&cb, `/*}},]*/"c_%d":%d`, shift, shift)
	}
	strings.write_string(&cb, `,}`)
	srcc := transmute([]u8)strings.to_string(cb)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)

	for workers in ([]int{1, 2, 4, 8}) {
		sr := testkit.serial_runner(workers)
		okc, builtc := testkit.threads_agree(t, json.reads(.Jsonc), json.as(.Jsonc), srcc, {}, &sr, "jsonc_edges")
		testing.expect(t, okc && builtc)
		ok5, built5 := testkit.threads_agree(t, json.reads(.Json5), json.as(.Json5), src5, {}, &sr, "json5_edges")
		testing.expect(t, ok5 && built5)
	}
	okp5, builtp5 := testkit.threads_agree(t, json.reads(.Json5), json.as(.Json5), src5, {dups = .Refuse}, &pool.runner, "json5_pool")
	testing.expect(t, okp5 && builtp5)

	free_all(context.temp_allocator)
}

@(test)
parallel_object_malformed_faults :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Build a clean ~96 KB base object so faults placed at front (5%), middle (50%), and tail (95%)
	// hit distinct chunks on multi-chunk runners and pool workers.
	base := build_large_flat_object(96 << 10, .Json, context.temp_allocator)

	// Inject diverse structural & lexical faults at multiple offsets and verify exact Fault{at, kind, detail} parity.
	injections := [?]string{
		`,"bad",1`,
		`,"bad":`,
		`,"bad"::1`,
		`,"bad":1,,`,
		`,"bad":"\q"`,
		`,"bad":"\u12"`,
		`,"bad":"unclosed`,
		`,"bad":]`,
		",{unquoted:1}",
		`,"bad":"` + "\xff" + `"`,
		`,"` + "\xff" + `":1`,
		`,"bad":"\uD800"`,
	}

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	sr := testkit.serial_runner(8)

	for inj in injections {
		for pct in ([]int{5, 50, 92}) {
			pos := len(base) * pct / 100
			// Find a clean ',' outside strings to replace a value member cleanly.
			for pos + 2 < len(base) && !(base[pos] == ',' && base[pos + 1] == '"') {
				pos += 1
			}
			if pos + 2 >= len(base) {
				continue
			}
			b := strings.builder_make(0, len(base) + len(inj) + 16, context.temp_allocator)
			strings.write_bytes(&b, base[:pos])
			strings.write_string(&b, inj)
			strings.write_bytes(&b, base[pos + 1:])
			bad := transmute([]u8)strings.to_string(b)

			for runner in ([]^tape.Runner{&pool.runner, &sr}) {
				ok, built := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bad, {}, runner, inj)
				testing.expectf(t, ok && !built, "strict fault missed for %q pct=%d", inj, pct)
			}
		}
	}

	// Trailing comma at end of strict JSON object + trailing garbage after closing `}` + truncated object.
	trailing_comma := make([]u8, len(base) + 1, context.temp_allocator)
	copy(trailing_comma, base[:len(base) - 1])
	trailing_comma[len(base) - 1] = ','
	trailing_comma[len(base)] = '}'

	trailing_junk := make([]u8, len(base) + 5, context.temp_allocator)
	copy(trailing_junk, base)
	copy(trailing_junk[len(base):], " junk")

	truncated := base[:len(base) - 1]

	// UTF-8 bad sequence under tolerate = {.Invalid_Utf8}
	bad_utf8 := make([]u8, len(base), context.temp_allocator)
	copy(bad_utf8, base)
	if mid_idx := strings.index(string(bad_utf8[len(bad_utf8) / 2:]), `"v`); mid_idx >= 0 {
		bad_utf8[len(bad_utf8) / 2 + mid_idx + 1] = 0xff
	}

	for bad in ([][]u8{trailing_comma, trailing_junk, truncated}) {
		ok1, built1 := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bad, {}, &pool.runner, "end_fault")
		testing.expect(t, ok1 && !built1)
		ok2, built2 := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bad, {}, &sr, "end_fault_sr")
		testing.expect(t, ok2 && !built2)
	}

	// Bad UTF-8 in values and keys with strict vs tolerate (`.Refuse` and `.Last`):
	ok_u_strict, built_u_strict := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bad_utf8, {}, &pool.runner, "bad_utf8_strict")
	testing.expect(t, ok_u_strict && !built_u_strict)
	ok_u_tol, built_u_tol := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bad_utf8, {tolerate = {.Invalid_Utf8}}, &pool.runner, "bad_utf8_tol")
	testing.expect(t, ok_u_tol && built_u_tol)

	// Bad UTF-8 inside keys in front and middle chunks under `.Refuse` and `.Last`.
	kb := strings.builder_make(0, len(base) + 64, context.temp_allocator)
	mid_cut := len(base) / 2
	for mid_cut + 2 < len(base) && !(base[mid_cut] == ',' && base[mid_cut + 1] == '"') {
		mid_cut += 1
	}
	strings.write_bytes(&kb, base[:mid_cut])
	strings.write_string(&kb, `,"badk_` + "\xff" + `":1,"badk_` + "\xff" + `":2`)
	strings.write_bytes(&kb, base[mid_cut:])
	bad_key_src := transmute([]u8)strings.to_string(kb)
	for pol in ([]tape.Duplicates{.Refuse, .Last}) {
		ok_bk, built_bk := testkit.threads_agree(t, json.reads(.Json), json.as(.Json), bad_key_src, {tolerate = {.Invalid_Utf8}, dups = pol}, &pool.runner, "bad_key_tol")
		testing.expectf(t, ok_bk && (built_bk == (pol != .Refuse)), "bad_key pol=%v", pol)
	}

	free_all(context.temp_allocator)
}
