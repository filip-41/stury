package json_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:host"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The threads of serial runners that cut a text of `n` bytes into chunks of every size from a quarter of it down to one
// byte, a few sizes per power of two past 64 chunks, and no more than 4096 chunks.
@(private = "file")
cuts_of :: proc(n: int) -> [dynamic]int {
	threads := make([dynamic]int, context.temp_allocator)
	for k := 0; 4 * (k + 1) <= n && k < 1024; k += 1 + k / 16 {
		append(&threads, k)
	}
	return threads
}

// A string or comment whose bytes hold brackets, commas, quotes, escapes and line ends, so that a chunk that starts in
// it reads them wrong from any other place.
@(private = "file")
seam_string :: proc(b: ^strings.Builder, spec: json.Spec) {
	bodies := [?]string{`a, b], {\"c\": [1, 2]}`, `\" ] , { \\\" , [`, `\\`, `x\\\" ,]}`, `// not /* a comment`, `\n\t\\n`}
	body := bodies[rand.int_max(len(bodies))]
	if spec == .Json5 && rand.int_max(3) == 0 {
		fmt.sbprintf(b, `'%s " \' ,]'`, body)
		return
	}
	fmt.sbprintf(b, `"%s"`, body)
}

@(private = "file")
seam_gap :: proc(b: ^strings.Builder, spec: json.Spec) {
	if spec == .Json {
		plain := [?]string{"", " ", "\n  ", "\r\n"}
		strings.write_string(b, plain[rand.int_max(len(plain))])
		return
	}
	gaps := [?]string{"", " ", "\n  ", "/* ] , \" ' { */", "// ] , \" ' {\n", "// cr ends it ] \r", " /* a */ /* b */ ", "\n// c\n"}
	strings.write_string(b, gaps[rand.int_max(len(gaps))])
}

// A record: an object whose values are strings and comments of `seam_string` and `seam_gap`, numbers, and a value of
// `random_text`.
@(private = "file")
seam_record :: proc(b: ^strings.Builder, spec: json.Spec, i: int) {
	strings.write_byte(b, '{')
	seam_gap(b, spec)
	fmt.sbprintf(b, `"id": %d,`, i)
	seam_gap(b, spec)
	strings.write_string(b, `"text": `)
	seam_string(b, spec)
	strings.write_byte(b, ',')
	seam_gap(b, spec)
	strings.write_string(b, `"v": `)
	strings.write_bytes(b, random_text({spec, false}))
	seam_gap(b, spec)
	if spec != .Json && rand.int_max(4) == 0 {
		strings.write_byte(b, ',')
	}
	strings.write_byte(b, '}')
}

// `count` records as a root array, as the members of a root object, or under `.data.items`.
@(private = "file")
seam_text :: proc(spec: json.Spec, shape, count: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	switch shape {
	case 0:
		strings.write_byte(&b, '[')
	case 1:
		strings.write_byte(&b, '{')
	case:
		strings.write_string(&b, `{"meta": {"n": 1, "s": "x]"}, "data": {"items": [`)
	}
	for i in 0 ..< count {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		seam_gap(&b, spec)
		if shape == 1 {
			// A key repeats now and then, so a policy for repeated keys sees members in two chunks.
			fmt.sbprintf(&b, `"k%d": `, i if rand.int_max(5) != 0 else 0)
		}
		seam_record(&b, spec, i)
	}
	seam_gap(&b, spec)
	strings.write_string(&b, "]" if shape == 0 else "}" if shape == 1 else "]}, \"tail\": [1, {}]}")
	seam_gap(&b, spec)
	return transmute([]u8)strings.to_string(b)
}

// Over texts of records whose strings and comments hold brackets, quotes and line ends, valid and spoiled, cut at
// every chunk size, with budgets and repeated-key policies: the build in parts is the build on one thread, node for
// node, and refuses a text with the same error.
@(test)
parts_build_what_one_thread_builds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x5ea3)
	builds, valid := 0, 0
	for round in 0 ..< testkit.rounds(30) {
		spec := json.Spec(round % 3)
		src := seam_text(spec, rand.int_max(3), 2 + rand.int_max(5))
		texts := [?][]u8{src, testkit.mutate(src, "}],\"'x:/\\[{\xff")}
		for text, i in texts {
			opts: json.Options
			switch rand.int_max(6) {
			case 0:
				policies := [?]tape.Duplicates{.Refuse, .First, .Last}
				opts.dups = policies[rand.int_max(len(policies))]
			case 1:
				opts.budget.nodes = u32(rand.int_max(200))
			case 2:
				opts.budget.steps = u64(rand.int_max(20))
			case 3:
				opts.budget.depth = u32(1 + rand.int_max(6))
			case 4:
				opts.tolerate = {.Invalid_Utf8, .Non_Finite, .Lone_Surrogate}
			}
			for threads in cuts_of(len(text)) {
				r := testkit.serial_runner(threads)
				builds += 1
				ok, built := testkit.threads_agree(t, json.reads(spec), json.as(spec), text, opts, &r, fmt.tprintf("round %d text %d", round, i))
				valid += int(built)
				if !ok {
					log.infof("%s", string(text))
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, builds > 1000 && valid > builds / 4, "%d builds, %d of a valid text", builds, valid)
}

// The suites' texts, cut at every chunk size.
@(test)
parts_build_the_suites :: proc(t: ^testing.T) {
	testkit.deadline(t)
	files := corpus_files()
	defer delete(files)
	tolerant := json.Options{tolerate = {.Invalid_Utf8, .Non_Finite, .Lone_Surrogate}}
	for f in files {
		for threads in cuts_of(len(f.data)) {
			r := testkit.serial_runner(threads)
			if ok, _ := testkit.threads_agree(t, json.reads(f.spec), json.as(f.spec), f.data, {}, &r, f.name); !ok {
				return
			}
			if ok, _ := testkit.threads_agree(t, json.reads(f.spec), json.as(f.spec), f.data, tolerant, &r, f.name); !ok {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}

// A text of ASCII and other strings and keys, cut at every chunk size, gives the spellings of the build on one thread.
@(test)
parts_spell_ascii_texts_as_one_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in json.Spec {
		text := transmute([]u8)ascii_text(spec)
		for threads in cuts_of(len(text)) {
			r := testkit.serial_runner(threads)
			if ok, _ := testkit.threads_agree(t, json.reads(spec), json.as(spec), text, {}, &r, "ascii"); !ok {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
PARALLEL_FIXTURES := [?]string{"canada.json", "citm_catalog.json", "twitter.json"}

@(private = "file")
PARALLEL_FIXTURES_DIR :: #directory + "../../../bench/fixtures/corpus/"

// The fixture texts, where a checkout has them, on pools of 1, 2, 3, 4 and 8 threads and in small chunks, and the
// generated texts on the pools: the same documents, built by threads at once.
@(test)
parts_build_on_pools :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x9001)
	texts := make([dynamic][]u8, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for name in PARALLEL_FIXTURES {
		if src, err := os.read_entire_file(fmt.tprintf("%s%s", PARALLEL_FIXTURES_DIR, name), context.temp_allocator); err == nil {
			append(&texts, src)
			append(&names, name)
		}
	}
	for shape in 0 ..< 3 {
		append(&texts, seam_text(.Jsonc, shape, 400))
		append(&names, fmt.tprintf("shape %d", shape))
	}
	for workers in ([]int{1, 2, 3, 4, 8}) {
		pool: host.Pool
		host.pool_init(&pool, workers)
		defer host.pool_destroy(&pool)
		for text, i in texts {
			spec := json.Spec.Json if i < len(texts) - 3 else .Jsonc
			for _ in 0 ..< 3 {
				if ok, _ := testkit.threads_agree(t, json.reads(spec), json.as(spec), text, {}, &pool.runner, names[i]); !ok {
					return
				}
			}
			small := pool.runner
			small.threads = len(text) / 4096
			if ok, _ := testkit.threads_agree(t, json.reads(spec), json.as(spec), text, {}, &small, names[i]); !ok {
				return
			}
		}
	}
	free_all(context.temp_allocator)
}

// The allocator of a build on a pool is called on the calling thread alone, and a memory budget gives the document of the
// build on one thread or a refusal.
@(test)
parts_allocate_on_the_calling_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xa11c)
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	c: testkit.Caller_Only
	only := testkit.caller_only(&c, context.allocator)
	for spec in json.Spec {
		src := seam_text(spec, int(spec), 300)
		doc, err := json.build(src, spec, {runner = &pool.runner}, only)
		testing.expectf(t, err == nil && len(doc.nodes) > 300, "%v %v %d", spec, err, len(doc.nodes))
		tape.destroy(&doc)
		for memory in ([]u64{1, 4096, u64(len(src)), u64(len(src)) * 4, u64(len(src)) * 64}) {
			if !testkit.threads_fit(t, json.reads(spec), json.as(spec), src, {budget = {memory = memory}}, &pool.runner, "memory") {
				return
			}
		}
	}
	testing.expect_value(t, c.strays, 0)
	free_all(context.temp_allocator)
}

// A build under `Budget.memory` on a runner gives the document of the build on one thread or a refusal of the budget,
// whatever the threads, for budgets from far below what the text needs to far above it and every byte around the least
// that is enough.
@(test)
memory_budget_gives_the_one_thread_document_or_a_refusal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xb0d9)
	one, many := testkit.serial_runner(3), testkit.serial_runner(17)
	runners := [?]^tape.Runner{&one, &many}
	for spec in json.Spec {
		for shape in ([]int{0, 2}) {
			src := seam_text(spec, shape, 300)
			for dups in ([]tape.Duplicates{.Default, .Last, .Refuse}) {
				// The text repeats keys, so `.Refuse` builds none of it and its budgets all end in the same fault.
				if !testkit.threads_fit_budget_sweep(t, json.reads(spec), json.as(spec), src, {dups = dups}, runners[:], dups == .Refuse, "budget") {
					return
				}
			}
		}
	}
	free_all(context.temp_allocator)
}

// A text the walk takes, nested within the levels a part holds, is joined from its parts with no second build on one
// thread, which its runner sees as a third task: the facts of a text with comments, or the repeated keys under
// `.Refuse`. A JSON5 text whose white space past JSON's comes before close brackets, where its reading plans more
// nodes than the parts store, is joined too.
@(test)
parts_join_with_no_second_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x7a5c)
	Text :: struct {
		src:  []u8,
		spec: json.Spec,
		dups: tape.Duplicates,
	}
	texts := make([dynamic]Text, context.temp_allocator)
	for name in PARALLEL_FIXTURES {
		if src, err := os.read_entire_file(fmt.tprintf("%s%s", PARALLEL_FIXTURES_DIR, name), context.temp_allocator); err == nil {
			append(&texts, Text{src, .Json, .Refuse})
		}
	}
	for spec in ([]json.Spec{.Jsonc, .Json5}) {
		for shape in ([]int{0, 2}) {
			append(&texts, Text{seam_text(spec, shape, 400), spec, .Default})
		}
	}
	wide := strings.builder_make(context.temp_allocator)
	strings.write_byte(&wide, '[')
	for i in 0 ..< 2000 {
		fmt.sbprintf(&wide, "[%d,\u00a0],{{\"k\":%d,\u00a0}},", i, i)
	}
	strings.write_string(&wide, "0]")
	append(&texts, Text{transmute([]u8)strings.to_string(wide), .Json5, .Refuse})
	for text, i in texts {
		for threads in ([]int{3, 17, 70}) {
			starts := 0
			r := testkit.counting_runner(threads, &starts)
			if ok, _ := testkit.threads_agree(t, json.reads(text.spec), json.as(text.spec), text.src, {dups = text.dups}, &r, fmt.tprintf("text %d", i)); !ok {
				return
			}
			testing.expectf(t, starts >= 3, "text %d on %d threads: %d tasks", i, threads, starts)
		}
	}
	free_all(context.temp_allocator)
}

// A text of thousands of records cut into hundreds of parts, whose seams hold the open brackets of every part, gives the
// document of one thread at every thread count. Empty strings and keys and nested objects sit at the seams.
@(test)
parts_of_a_seam_heavy_text_build_as_one_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// The test runner's allocator shrinks a block in place, and the heap allocator moves it.
	context.allocator = runtime.heap_allocator()
	for spec in json.Spec {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"data":{"items":[`)
		for i in 0 ..< 40000 {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"":{{"":""}},"a":[[],{{}},"",{{"":[%d]}}]}}`, i)
		}
		strings.write_string(&b, `]}}`)
		src := transmute([]u8)strings.to_string(b)
		for threads in ([]int{2, 3, 7, 16, 64, 255, 700, 1500}) {
			r := testkit.serial_runner(threads)
			if ok, built := testkit.threads_agree(t, json.reads(spec), json.as(spec), src, {}, &r, "seam heavy"); !ok || !testing.expect(t, built) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}

// Parallel duplicate-key checking under a real thread pool and `Budget.memory` must not race on the allocator.
@(test)
segments_dups_parallel_with_budget_has_no_race :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	if host.pool_init(&pool, 4) != nil {
		return
	}
	defer host.pool_destroy(&pool)
	b := strings.builder_make(context.temp_allocator)
	defer free_all(context.temp_allocator)
	strings.write_byte(&b, '{')
	for i in 0 ..< 4000 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, `"k%d":{{"a":1,"b":2,"a":%d}}`, i, i)
	}
	strings.write_byte(&b, '}')
	src := transmute([]u8)strings.to_string(b)

	doc, err := json.build(src, .Json, {dups = .Last, budget = {memory = 64 << 20}, runner = &pool.runner})
	testing.expectf(t, err == nil, "parallel .Last build failed: %v", err)
	tape.destroy(&doc)

	doc2, err2 := json.build(src, .Json, {dups = .Refuse, budget = {memory = 64 << 20}, runner = &pool.runner})
	tape.destroy(&doc2)
	f, is_fault := err2.(tape.Fault)
	testing.expectf(t, is_fault && f.kind == .Duplicate_Key, "parallel .Refuse build: got %v", err2)
}

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

				// Parallel find across small (triggers c0 pre-check) and full batch caps.
				for bcap in ([]int{64, 3100}) {
					rfp := json.records_open(src, framing, .Json, {runner = &pool.runner})
					defer tape.destroy_records(&rfp)
					pfout := make([]tape.Record, 3100)
					defer delete(pfout)
					pfans := make([]tape.Span_Answer, 3100)
					defer delete(pfans)
					pfn := 0
					for {
						want_cap := min(bcap, len(pfout) - pfn)
						k := json.records_find(&rfp, path, pfout[pfn:pfn + want_cap], pfans[pfn:pfn + want_cap], {stop_early = true})
						pfn += k
						if k < want_cap {
							break
						}
					}
					testing.expectf(t, pfn == sfn && rfp.index == rfs.index && rfp.err == rfs.err, "seq=%v w=%d cap=%d find n=%d/%d", seq, workers, bcap, pfn, sfn)
					for i in 0 ..< min(pfn, sfn) {
						testing.expectf(t, pfout[i] == sfout[i] && pfans[i] == sfans[i], "seq=%v w=%d cap=%d find[%d]", seq, workers, bcap, i)
					}
				}

				// Parallel scan across small (triggers c0 pre-check) and full batch caps.
				for bcap in ([]int{64, 3100}) {
					rsp := json.records_open(src, framing, .Json, {runner = &pool.runner})
					defer tape.destroy_records(&rsp)
					psout := make([]tape.Record, bcap)
					defer delete(psout)
					psdocs := make([]tape.Document, bcap)
					defer delete(psdocs)
					psn := 0
					for {
						k := json.records_scan(&rsp, &demand, psout, psdocs)
						for i in 0 ..< k {
							idx := psn + i
							testing.expectf(t, idx < ssn && psout[i] == ssout[idx] && len(psdocs[i].nodes) == len(ssdocs[idx].nodes), "seq=%v w=%d cap=%d scan[%d]", seq, workers, bcap, idx)
						}
						psn += k
						if k < bcap {
							break
						}
					}
					testing.expectf(t, psn == ssn && rsp.index == rss.index && rsp.err == rss.err, "seq=%v w=%d cap=%d scan n=%d/%d", seq, workers, bcap, psn, ssn)
				}
			}
		}
	}
}

// Custom allocator that returns `.Mode_Not_Implemented` for `.Query_Features` while forwarding allocations (must safely fall back to serial).
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
		ca := testkit.Failing{backing = context.allocator, fail_at = 1, sticky = true}
		q := make([dynamic]json.Bad_Record, testkit.failing_allocator(&ca))
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
