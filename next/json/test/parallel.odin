package json_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "stury:host"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// A runner of `threads` threads that runs no call, so the caller claims every chunk, as many as `threads` makes, each
// in turn.
@(private = "file")
serial_runner :: proc(threads: int) -> tape.Runner {
	return {threads = threads, start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {}, finish = proc(data: rawptr) {}}
}

@(private = "file")
same_build :: proc(a, b: tape.Document) -> bool {
	same :: proc(x, y: []$T) -> bool {
		return mem.compare(slice.to_bytes(x), slice.to_bytes(y)) == 0
	}
	return same(a.nodes, b.nodes) && same(a.facts, b.facts) && same(a.counts, b.counts) && a.flags == b.flags && a.root_close == b.root_close && a.present == b.present && a.partial == nil && b.partial == nil && raw_data(a.src) == raw_data(b.src)
}

// Whether the build of `src` on `runner` gives the document and error of the build on one thread, and whether that
// build gave a document.
@(private = "file")
agree_on :: proc(t: ^testing.T, src: []u8, spec: json.Spec, opts: json.Options, runner: ^tape.Runner, name: string) -> (ok, built: bool) {
	want, werr := json.build(src, spec, opts)
	defer tape.destroy(&want)
	wide := opts
	wide.runner = runner
	got, gerr := json.build(src, spec, wide)
	defer tape.destroy(&got)
	ok = testing.expectf(t, same_refusal(gerr, werr) && same_build(got, want), "%s %v %v on %d threads: %v, one thread %v (%d and %d nodes)", name, spec, opts, runner.threads, gerr, werr, len(got.nodes), len(want.nodes))
	return ok, werr == nil
}

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

// Replaces one byte of `src` or cuts it short.
@(private = "file")
spoil :: proc(src: []u8) -> []u8 {
	if len(src) == 0 || rand.int_max(4) == 0 {
		return src[:rand.int_max(len(src) + 1)]
	}
	bytes := [?]u8{'}', ']', ',', '"', '\'', 'x', ':', '/', '\\', '[', '{', 0xff}
	src[rand.int_max(len(src))] = bytes[rand.int_max(len(bytes))]
	return src
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
		texts := [?][]u8{src, spoil(slice.clone(src, context.temp_allocator))}
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
				r := serial_runner(threads)
				builds += 1
				ok, built := agree_on(t, text, spec, opts, &r, fmt.tprintf("round %d text %d", round, i))
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
			r := serial_runner(threads)
			if ok, _ := agree_on(t, f.data, f.spec, {}, &r, f.name); !ok {
				return
			}
			if ok, _ := agree_on(t, f.data, f.spec, tolerant, &r, f.name); !ok {
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
			r := serial_runner(threads)
			if ok, _ := agree_on(t, text, spec, {}, &r, "ascii"); !ok {
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
				if ok, _ := agree_on(t, text, spec, {}, &pool.runner, names[i]); !ok {
					return
				}
			}
			small := pool.runner
			small.threads = len(text) / 4096
			if ok, _ := agree_on(t, text, spec, {}, &small, names[i]); !ok {
				return
			}
		}
	}
	free_all(context.temp_allocator)
}

@(private = "file")
Caller_Only :: struct {
	backing: runtime.Allocator,
	caller:  int,
	strays:  int,
}

// The allocator of a build on a pool is called on the calling thread alone, and a memory budget gives the error the
// build on one thread gives.
@(test)
parts_allocate_on_the_calling_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xa11c)
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	c := Caller_Only{backing = context.allocator, caller = sync.current_thread_id()}
	only := runtime.Allocator{proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
			c := (^Caller_Only)(data)
			if sync.current_thread_id() != c.caller {
				sync.atomic_add(&c.strays, 1)
			}
			return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
		}, &c}
	for spec in json.Spec {
		src := seam_text(spec, int(spec), 300)
		doc, err := json.build(src, spec, {runner = &pool.runner}, only)
		testing.expectf(t, err == nil && len(doc.nodes) > 300, "%v %v %d", spec, err, len(doc.nodes))
		tape.destroy(&doc)
		for memory in ([]u64{1, 4096, u64(len(src)), u64(len(src)) * 4, u64(len(src)) * 64}) {
			if ok, _ := agree_on(t, src, spec, {budget = {memory = memory}}, &pool.runner, "memory"); !ok {
				return
			}
		}
	}
	testing.expect_value(t, c.strays, 0)
	free_all(context.temp_allocator)
}

// A build under `Budget.memory` gives the document and the error of the build on one thread whatever the threads, for
// budgets from far below what the text needs to far above it and every byte around the least that is enough.
@(test)
memory_budget_gives_one_answer_on_every_thread_count :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xb0d9)
	one, many := serial_runner(3), serial_runner(17)
	for spec in json.Spec {
		for shape in ([]int{0, 2}) {
			src := seam_text(spec, shape, 300)
			for dups in ([]tape.Duplicates{.Default, .Last, .Refuse}) {
				builds :: proc(src: []u8, spec: json.Spec, dups: tape.Duplicates, memory: u64) -> bool {
					doc, err := json.build(src, spec, {budget = {memory = memory}, dups = dups})
					tape.destroy(&doc)
					return err == nil
				}
				// The least budget that builds the text, found by bisection from the first doubling that does.
				hi := u64(len(src))
				for hi < 8 * u64(len(src)) && !builds(src, spec, dups, hi) {
					hi *= 2
				}
				least := u64(0)
				if builds(src, spec, dups, hi) {
					lo := u64(0)
					for hi - lo > 1 {
						mid := lo + (hi - lo) / 2
						if builds(src, spec, dups, mid) {
							hi = mid
						} else {
							lo = mid
						}
					}
					least = hi
				}
				// The text repeats keys, so `.Refuse` builds none of it and its budgets all end in the same fault.
				testing.expectf(t, least != 0 || dups == .Refuse, "%v %d %v: no budget up to eight times the text builds it", spec, shape, dups)
				for memory := u64(1); memory < 8 * u64(len(src)); memory += 1 + memory / 5 {
					for runner in ([]^tape.Runner{&one, &many}) {
						if ok, _ := agree_on(t, src, spec, {budget = {memory = memory}, dups = dups}, runner, "budget"); !ok {
							return
						}
					}
				}
				for memory in max(least, 12) - 12 ..= least + 12 {
					for runner in ([]^tape.Runner{&one, &many}) {
						if ok, _ := agree_on(t, src, spec, {budget = {memory = memory}, dups = dups}, runner, "budget near the least"); !ok {
							return
						}
					}
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
			r := tape.Runner{threads = threads, start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) { (^int)(data)^ += 1 }, finish = proc(data: rawptr) {}, data = &starts}
			if ok, _ := agree_on(t, text.src, text.spec, {dups = text.dups}, &r, fmt.tprintf("text %d", i)); !ok {
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
			r := serial_runner(threads)
			if ok, built := agree_on(t, src, spec, {}, &r, "seam heavy"); !ok || !testing.expect(t, built) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}
