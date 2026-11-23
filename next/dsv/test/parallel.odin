package dsv_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "stury:dsv"
import "stury:host"
import "stury:lib/core/tape"
import "stury:testkit"

// Builds of delimited texts on a runner's threads against the build on one thread.

// A runner of `threads` threads that runs no call, so the caller reads every chunk and walks every part, as many as
// `threads` makes, each in turn.
@(private = "file")
serial_runner :: proc(threads: int) -> tape.Runner {
	return {threads = threads, start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {}, finish = proc(data: rawptr) {}}
}

// A runner whose `start` counts its calls and runs none, so a build that joins its parts starts a task more than one
// that falls back to one thread.
@(private = "file")
counting_runner :: proc(threads: int, starts: ^int) -> tape.Runner {
	return {threads = threads, start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) { (^int)(data)^ += 1 }, finish = proc(data: rawptr) {}, data = starts}
}

// The thread counts every text is built on, and for a short text the counts that cut it at each of its LFs.
@(private = "file")
threads_of :: proc(n: int) -> []int {
	threads := make([dynamic]int, context.temp_allocator)
	append(&threads, 1, 2, 3, 17, 70)
	for k := 4; 4 * k <= n && k < 600; k += 1 + k / 8 {
		append(&threads, k)
	}
	return threads[:]
}

// A cell whose bytes a chunk that starts inside it reads wrong from any other place: quoted cells holding delimiters,
// LFs, CR LFs and `""`, escapes, characters of two to four bytes, numbers and empty cells.
@(private = "file")
seam_cell :: proc(b: ^strings.Builder, spec: dsv.Spec, header: bool, col: int) {
	if header {
		fmt.sbprintf(b, "k%d", col)
		return
	}
	switch spec {
	case .Csv:
		cells := [?]string{"\"a,\nb\"", "\"\"\"\"", "\"x\r\n\"\"\n\"", "\"\n\"", "\"\"", "\"#c,\"\"\n# d\"", "plain", "-12.5e3", "", "true", "\xc3\xa9\xe2\x82\xac", "\xf0\x9f\x98\x80x"}
		strings.write_string(b, cells[rand.int_max(len(cells))])
	case .Tsv:
		cells := [?]string{"a\\tb", "\\n\\r\\0\\\\", "\"q\"", "plain", "7", "", "\xc3\xa9\xe2\x82\xac"}
		strings.write_string(b, cells[rand.int_max(len(cells))])
	case .Plain:
		cells := [?]string{"\"q", "plain", "0", "", "false", "\xf0\x9f\x98\x80"}
		strings.write_string(b, cells[rand.int_max(len(cells))])
	}
}

// A text of `rows` records of `width` cells under a header, with comment lines holding quotes and delimiters, empty
// lines, CR LF line ends, ragged records when `ragged`, and a wide header of `width` cells.
@(private = "file")
seam_text :: proc(spec: dsv.Spec, rows, width: int, comments, ragged: bool) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	delim := u8('\t') if spec == .Tsv else ','
	if comments {
		strings.write_string(&b, "# a \"head, comment\n")
	}
	for row in 0 ..< rows + 1 {
		switch {
		case comments && rand.int_max(5) == 0:
			strings.write_string(&b, "# \"open, quote\n" if rand.int_max(2) == 0 else "#\r\n")
		case rand.int_max(9) == 0:
			strings.write_string(&b, "\n" if rand.int_max(2) == 0 else "\r\n")
		}
		cells := width if !ragged || row == 0 else 1 + rand.int_max(width + 2)
		for col in 0 ..< cells {
			if col > 0 {
				strings.write_byte(&b, delim)
			}
			seam_cell(&b, spec, row == 0, col)
		}
		strings.write_string(&b, "\r\n" if rand.int_max(3) == 0 else "\n")
	}
	if comments && rand.int_max(2) == 0 {
		strings.write_string(&b, "# the \"foot\n# and more")
	}
	return transmute([]u8)strings.to_string(b)
}

// Replaces one byte of `src` or cuts it short.
@(private = "file")
spoil :: proc(src: []u8) -> []u8 {
	if len(src) == 0 || rand.int_max(4) == 0 {
		return src[:rand.int_max(len(src) + 1)]
	}
	bytes := [?]u8{'"', ',', '\t', '\n', '\r', '\\', '#', 'x', 0xff, 0xc3}
	src[rand.int_max(len(src))] = bytes[rand.int_max(len(bytes))]
	return src
}

// The option sets the texts are built under: each tolerance, each `Dsv_Options` field, the budgets and the policies.
@(private = "file")
parallel_options :: proc(spec: dsv.Spec) -> []dsv.Options {
	all := dsv.Tolerances{.Ragged, .Bare_Quote, .Invalid_Utf8}
	return slice.clone(
		[]dsv.Options {
			{},
			{format = dsv.Dsv_Options{comment = '#'}},
			{format = dsv.Dsv_Options{no_header = true}},
			{format = dsv.Dsv_Options{infer = true}},
			{format = dsv.Dsv_Options{delimiter = ';' if spec == .Csv else ','}},
			{tolerate = {.Ragged}},
			{tolerate = {.Bare_Quote}},
			{tolerate = {.Invalid_Utf8}},
			{format = dsv.Dsv_Options{comment = '#', no_header = true, infer = true}, tolerate = all},
			{format = dsv.Dsv_Options{comment = '#'}, tolerate = all},
			{budget = {steps = 9}},
			{budget = {nodes = 60}, tolerate = {.Ragged}},
			{budget = {depth = 1}},
			{budget = {memory = 4096}},
			{dups = .Refuse},
			{dups = .First, tolerate = {.Ragged}},
		},
		context.temp_allocator,
	)
}

// Whether two documents of one text hold the same table.
@(private = "file")
same_table :: proc(a, b: ^dsv.Document) -> bool {
	if (a.ext == nil) != (b.ext == nil) {
		return false
	}
	if a.ext == nil {
		return true
	}
	x, y := a.ext.format.(tape.Tabular_Ext), b.ext.format.(tape.Tabular_Ext)
	return slice.equal(x.tables, y.tables) && slice.equal(x.slots, y.slots) && x.dups == y.dups && x.options == y.options
}

// The thread law over `src`, with the tables compared too. Under a memory budget the law is the one-thread document or a
// refusal of the budget.
@(private = "file")
agree :: proc(t: ^testing.T, spec: dsv.Spec, src: []u8, opts: dsv.Options, runner: ^tape.Runner, name: string) -> (ok, built: bool) {
	if opts.budget.memory != 0 {
		return testkit.threads_fit(t, dsv.reads(spec), dsv.as(spec), src, opts, runner, name), false
	}
	if ok, built = testkit.threads_agree(t, dsv.reads(spec), dsv.as(spec), src, opts, runner, name); !ok {
		return
	}
	one, _ := dsv.build(src, spec, opts)
	defer dsv.destroy(&one)
	wide := opts
	wide.runner = runner
	many, _ := dsv.build(src, spec, wide)
	defer dsv.destroy(&many)
	ok = testing.expectf(t, same_table(&one, &many), "%s %v %v on %d threads: the tables differ", name, spec, opts, runner.threads)
	return
}

// Over texts whose chunks start inside quoted cells with LFs and `""`, past CR LFs, before characters of several bytes,
// in comment lines, in ragged records and in a header wider than a chunk, valid and spoiled, built under every option
// set on every thread count: the build in parts is the build on one thread, node for node, table for table, and
// refuses a text with the same error.
@(test)
parts_build_what_one_thread_builds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xd5f1)
	builds, valid := 0, 0
	for round in 0 ..< testkit.rounds(12) {
		spec := dsv.Spec(round % 3)
		for opts in parallel_options(spec) {
			o, _ := opts.format.(dsv.Dsv_Options)
			width := 1 + rand.int_max(5) if round % 4 != 3 else 150 + rand.int_max(60)
			// Ragged records that no tolerance takes fault at the first record of another width.
			src := seam_text(spec, 4 + rand.int_max(30), width, o.comment != 0, .Ragged in opts.tolerate || rand.int_max(4) == 0)
			texts := [?][]u8{src, spoil(slice.clone(src, context.temp_allocator))}
			for text, i in texts {
				for threads in threads_of(len(text)) {
					r := serial_runner(threads)
					builds += 1
					ok, built := agree(t, spec, text, opts, &r, fmt.tprintf("round %d text %d", round, i))
					valid += int(built)
					if !ok {
						log.infof("%q", string(text))
						return
					}
				}
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, builds > 1000 && valid > builds / 4, "%d builds, %d of a valid text", builds, valid)
}

// A long valid text is joined from its parts with no build on one thread: the runner sees the chunks read and the
// parts walked, and the facts placed of a text with comments.
@(test)
parts_join_with_no_build_on_one_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x10b5)
	for spec in dsv.Spec {
		for comments in ([]bool{false, true}) {
			src := seam_text(spec, 400, 4, comments, false)
			opts := dsv.Options{format = dsv.Dsv_Options{comment = '#' if comments else 0}}
			for threads in ([]int{3, 17, 70}) {
				starts := 0
				r := counting_runner(threads, &starts)
				if ok, built := agree(t, spec, src, opts, &r, "joined"); !ok || !testing.expect(t, built) {
					return
				}
				// `agree` builds on the runner twice.
				testing.expectf(t, starts == 2 * (3 if comments else 2), "%v comments %v on %d threads: %d tasks", spec, comments, threads, starts)
			}
		}
	}
	free_all(context.temp_allocator)
}

// A text of many records, each holding a quoted cell of several lines, whose chunks mostly start inside a quoted cell,
// builds as on one thread on every thread count.
@(test)
parts_of_multiline_cells_build_as_one_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "id,text,n\n")
	for i in 0 ..< 5000 {
		fmt.sbprintf(&b, "%d,\"line one\nline, two\r\n\"\"three\"\"\n\",%d\n", i, i % 7)
	}
	src := transmute([]u8)strings.to_string(b)
	for threads in ([]int{1, 2, 3, 7, 17, 70, 255, 1000}) {
		r := serial_runner(threads)
		if ok, built := agree(t, .Csv, src, {}, &r, "multiline"); !ok || !testing.expect(t, built) {
			return
		}
	}
	free_all(context.temp_allocator)
}

// Long texts on pools of 1, 2, 3, 4 and 8 threads: the same documents, built by threads at once.
@(test)
parts_build_on_pools :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x9002)
	Text :: struct {
		src:  []u8,
		spec: dsv.Spec,
		opts: dsv.Options,
	}
	texts := make([dynamic]Text, context.temp_allocator)
	for spec in dsv.Spec {
		append(&texts, Text{seam_text(spec, 2000, 6, false, false), spec, {}})
		append(&texts, Text{seam_text(spec, 2000, 5, true, true), spec, {format = dsv.Dsv_Options{comment = '#', infer = true}, tolerate = {.Ragged, .Invalid_Utf8, .Bare_Quote}}})
	}
	for workers in ([]int{1, 2, 3, 4, 8}) {
		pool: host.Pool
		host.pool_init(&pool, workers)
		defer host.pool_destroy(&pool)
		for text, i in texts {
			for _ in 0 ..< 3 {
				if ok, _ := agree(t, text.spec, text.src, text.opts, &pool.runner, fmt.tprintf("text %d", i)); !ok {
					return
				}
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

// The allocator of a build on a pool is called on the calling thread alone, and a memory budget gives the document of the
// build on one thread or a refusal.
@(test)
parts_allocate_on_the_calling_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xa11d)
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
	for spec in dsv.Spec {
		src := seam_text(spec, 300, 3, true, false)
		opts := dsv.Options{format = dsv.Dsv_Options{comment = '#'}, runner = &pool.runner}
		doc, err := dsv.build(src, spec, opts, only)
		testing.expectf(t, err == nil && len(doc.nodes) > 300, "%v %v %d", spec, err, len(doc.nodes))
		dsv.destroy(&doc)
		for memory in ([]u64{1, 4096, u64(len(src)), u64(len(src)) * 4, u64(len(src)) * 64}) {
			if ok, _ := agree(t, spec, src, {budget = {memory = memory}}, &pool.runner, "memory"); !ok {
				return
			}
		}
	}
	testing.expect_value(t, c.strays, 0)
	free_all(context.temp_allocator)
}

// A build in parts frees every block it took, whether it joins its parts, falls back to one thread or faults.
@(test)
parts_free_what_they_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xf4ee)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	for spec in dsv.Spec {
		src := seam_text(spec, 200, 3, true, false)
		bad := spoil(slice.clone(src, context.temp_allocator))
		r := serial_runner(9)
		for text in ([][]u8{src, bad}) {
			for opts in parallel_options(spec) {
				wide := opts
				wide.runner = &r
				doc, _ := dsv.build(text, spec, wide, mem.tracking_allocator(&track))
				dsv.destroy(&doc)
			}
		}
	}
	testing.expectf(t, len(track.allocation_map) == 0, "%d blocks left", len(track.allocation_map))
	free_all(context.temp_allocator)
}

// A memory budget the build on one thread fits gives, at every thread count, the document of that build or the refusal of
// the budget, never another document. The build on one thread under a budget gives the same answer every time.
@(test)
memory_budget_gives_the_one_thread_document_or_a_refusal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xb0da)
	defer free_all(context.temp_allocator)
	one, many := serial_runner(3), serial_runner(17)
	builds :: proc(src: []u8, spec: dsv.Spec, opts: dsv.Options, memory: u64) -> bool {
		wide := opts
		wide.budget.memory = memory
		doc, err := dsv.build(src, spec, wide)
		dsv.destroy(&doc)
		return err == nil
	}
	for spec in dsv.Spec {
		for opts in ([]dsv.Options{{}, {format = dsv.Dsv_Options{comment = '#'}}, {tolerate = {.Ragged}}, {format = dsv.Dsv_Options{no_header = true}}}) {
			d, _ := opts.format.(dsv.Dsv_Options)
			src := seam_text(spec, 300, 3, d.comment != 0, .Ragged in opts.tolerate)
			// The least budget that builds the text, found by bisection from the first doubling that does.
			hi := u64(len(src))
			for hi < 64 * u64(len(src)) && !builds(src, spec, opts, hi) {
				hi *= 2
			}
			if !testing.expectf(t, builds(src, spec, opts, hi), "%v %v: no budget up to 64 times the text builds it", spec, opts) {
				continue
			}
			lo := u64(0)
			for hi - lo > 1 {
				mid := lo + (hi - lo) / 2
				if builds(src, spec, opts, mid) {
					hi = mid
				} else {
					lo = mid
				}
			}
			least := hi
			testing.expect(t, builds(src, spec, opts, least) == builds(src, spec, opts, least), "one thread answers a budget the same each time")
			for memory in max(least, 12) - 12 ..= least + 12 {
				for runner in ([]^tape.Runner{&one, &many}) {
					wide := opts
					wide.budget.memory = memory
					if !testkit.threads_fit(t, dsv.reads(spec), dsv.as(spec), src, wide, runner, "budget near the least") {
						return
					}
				}
			}
			for memory := u64(1); memory < 4 * u64(len(src)); memory += 1 + memory / 3 {
				wide := opts
				wide.budget.memory = memory
				if !testkit.threads_fit(t, dsv.reads(spec), dsv.as(spec), src, wide, &many, "budget") {
					return
				}
			}
		}
	}
}
