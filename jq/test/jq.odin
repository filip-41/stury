package jq_test

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import core "../../core"
import "../../core/write"
import schema "../../core/schema"
import json "../../json"
import jq ".."

// The outputs of a run, each as compact JSON.
Collect :: struct {
	using sink: jq.Sink,
	answers:    [dynamic]string,
}

collect :: proc() -> Collect {
	return {sink = {emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
				c := (^Collect)(s)
				append(&c.answers, jq.to_json(it.v))
				return .Go
			}}}
}

// What the hooks of a test saw and serve: the messages written, the inputs left, the environment and the files.
World :: struct {
	messages: strings.Builder,
	inputs:   []core.Value,
	read:     int,
	environ:  []string,
	files:    map[string]string,
}

hooks :: proc(w: ^World) -> jq.Hooks {
	return {
		data = w,
		inputs = {data = w, next = proc(data: rawptr) -> (core.Value, string, jq.Input_Status) {
				w := (^World)(data)
				if w.read == len(w.inputs) {
					return nil, "", .End
				}
				w.read += 1
				return w.inputs[w.read - 1], "", .Value
			}, position = proc(data: rawptr) -> (string, int) {
				return "inputs", (^World)(data).read
			}},
		messages = proc(data: rawptr, text: []byte) {
			strings.write_bytes(&(^World)(data).messages, text)
		},
		environ = proc(data: rawptr, allocator := context.allocator) -> ([]string, string) {
			return (^World)(data).environ, ""
		},
		load_file = proc(data: rawptr, path: string, raw: bool, r: core.As) -> (core.Value, string) {
			text, found := (^World)(data).files[path]
			if !found {
				return nil, "Could not open it"
			}
			return text, ""
		},
		path_kind = proc(data: rawptr, path: string) -> jq.Path_Kind {
			return .File if path in (^World)(data).files else .Missing
		},
		real_path = proc(data: rawptr, path: string, allocator := context.allocator) -> string {
			return strings.clone(path, allocator)
		},
		now = proc(data: rawptr) -> f64 {
			return 1425599621.5
		},
		random = proc(data: rawptr, buf: []byte) {
			for &b, i in buf {
				b = byte(i)
			}
		},
	}
}

// `text` compiled and run on `input` under `w`'s hooks, in an arena of its own: the answers, how the run ended,
// its error as JSON, and the compile errors.
run :: proc(w: ^World, text: string, input: core.Value = nil, search: []string = nil) -> (answers: []string, outcome: jq.Outcome, err: string, errors: []jq.Error) {
	ip: jq.Interp
	jq.init(&ip, {hooks = hooks(w), search = search})
	defer jq.destroy(&ip)
	prog, compile_errors := jq.compile(&ip, text)
	if compile_errors != nil {
		return nil, .Done, "", compile_errors
	}
	c := collect()
	outcome = jq.run(&ip, prog, input, &c)
	if outcome == .Raised {
		err = jq.to_json(ip.err)
	}
	return c.answers[:], outcome, err, nil
}

numbers :: proc(xs: ..f64) -> core.Value {
	a := core.new_array(len(xs))
	for x in xs {
		append(&a.items, x)
	}
	return a
}

@(test)
runs_give_every_answer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	w: World
	answers, outcome, _, _ := run(&w, ".[] | . * 2", numbers(1, 2, 3))
	testing.expect_value(t, outcome, jq.Outcome.Done)
	testing.expect_value(t, len(answers), 3)
	testing.expect_value(t, strings.join(answers, " "), "2 4 6")
}

@(test)
errors_are_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	w: World
	_, _, _, errors := run(&w, ".[")
	testing.expect_value(t, len(errors), 1)
	testing.expect_value(t, errors[0].fault, jq.Compile_Fault.Filter)
	testing.expect(t, strings.has_prefix(errors[0].msg, "syntax error"), errors[0].msg)
	_, _, _, errors = run(&w, "nope")
	testing.expect_value(t, errors[0].msg, "nope/0 is not defined at <top-level>, line 1, column 1:\n    nope\n    ^^^^")
	answers, outcome, err, _ := run(&w, `1, error("boom"), 2`)
	testing.expect_value(t, outcome, jq.Outcome.Raised)
	testing.expect_value(t, err, `"boom"`)
	testing.expect_value(t, len(answers), 1)
}

@(test)
hooks_serve_inputs_messages_and_the_environment :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	w := World{inputs = {f64(1), f64(2)}, environ = {"HOME=/h", "TERM=dumb"}}
	answers, _, _, _ := run(&w, `[inputs] | debug | . as $a | ("x" | stderr) | [$a, input_line_number, $ENV.HOME]`)
	testing.expect_value(t, len(answers), 1)
	testing.expect_value(t, answers[0], `[[1,2],2,"/h"]`)
	testing.expect_value(t, strings.to_string(w.messages), "[\"DEBUG:\",[1,2]]\nx")
}

@(test)
halt_ends_the_run_with_its_code :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	w: World
	answers, outcome, _, _ := run(&w, `1, ("bye\n" | halt_error(3)), 2`)
	testing.expect_value(t, outcome, jq.Outcome.Halted)
	testing.expect_value(t, len(answers), 1)
	testing.expect_value(t, strings.to_string(w.messages), "bye\n")
}

@(test)
modules_load_through_the_hooks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	w: World
	w.files["/lib/m.jq"] = "def twice: . * 2;"
	answers, _, _, _ := run(&w, `import "m" as m; m::twice`, f64(21), search = {"/lib"})
	testing.expect_value(t, len(answers), 1)
	testing.expect_value(t, answers[0], "42")
	_, _, _, errors := run(&w, `import "gone" as g; g::f`, search = {"/lib"})
	testing.expect_value(t, len(errors), 1)
	testing.expect_value(t, errors[0].fault, jq.Compile_Fault.Module)
	testing.expect_value(t, errors[0].msg, "module not found: gone")
}

Job :: struct {
	text:   string,
	input:  core.Value,
	rounds: int,
	start:  ^sync.Barrier,
	same:   bool,
}

// Two interpreters on two threads at once, each its own program, regexes and sorts included, agree with one run alone.
@(test)
two_interpreters_run_at_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	start: sync.Barrier
	sync.barrier_init(&start, 2)
	jobs := [2]Job {
		{text = `[.[] | tostring | test("^[0-9]+$")] | length`, input = numbers(3, 1, 2), rounds = 200, start = &start},
		{text = `sort | map(. * 10) | max`, input = numbers(5, 4, 9), rounds = 200, start = &start},
	}
	threads: [2]^thread.Thread
	for &j, i in jobs {
		threads[i] = thread.create_and_start_with_data(&j, proc(data: rawptr) {
			j := (^Job)(data)
			context.allocator = context.temp_allocator
			defer free_all(context.temp_allocator)
			w: World
			first, _, _, _ := run(&w, j.text, j.input)
			sync.barrier_wait(j.start)
			j.same = true
			for _ in 0 ..< j.rounds {
				again, _, _, _ := run(&w, j.text, j.input)
				j.same = j.same && len(again) == 1 && again[0] == first[0]
			}
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect(t, jobs[0].same)
	testing.expect(t, jobs[1].same)
}

// `text` compiled on an interpreter of its own, which the caller destroys.
compiled :: proc(ip: ^jq.Interp, text: string, vars: []jq.Var = nil) -> jq.Program {
	jq.init(ip, {})
	prog, _ := jq.compile(ip, text, vars)
	return prog
}

// The JSON text `text` as a value.
parsed :: proc(text: string) -> core.Value {
	doc, _ := core.refuse_key_clash(core.build(transmute([]u8)text, json.as(.Json)))
	return core.document_value(doc)
}

@(test)
programs_tell_their_shape :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ip: jq.Interp
	defer jq.destroy(&ip)
	testing.expect_value(t, jq.shape(compiled(&ip, ".a | length")).serial, bit_set[jq.Serial]{})
	testing.expect_value(t, jq.shape(compiled(&ip, "def f: input; [f]")).serial, bit_set[jq.Serial]{.Inputs})
	testing.expect_value(t, jq.shape(compiled(&ip, "input_filename, debug, halt")).serial, bit_set[jq.Serial]{.Position, .Messages, .Halts})
	testing.expect_value(t, jq.shape(compiled(&ip, "def f: f; f, recurse(.a)")).serial, bit_set[jq.Serial]{.Recurses})
	s := jq.shape(compiled(&ip, "select(.a[0] < 3)"))
	testing.expect_value(t, s.select_faults, bit_set[jq.Shape_Fault]{})
	testing.expect_value(t, s.selection.path, ".a[0]")
	testing.expect_value(t, s.selection.op, jq.Comparison.Lt)
	sel := s.selection
	testing.expect(t, jq.selects(sel, f64(2)) && !jq.selects(sel, f64(3)) && !jq.selects(sel, core.new_array()))
	testing.expect_value(t, jq.shape(compiled(&ip, "select(.a)")).select_faults, bit_set[jq.Shape_Fault]{.Not_Comparison})
	s = jq.shape(compiled(&ip, "{a, b: .c}"))
	testing.expect(t, s.column_faults == {} && s.columns.shape == .Object)
	testing.expect_value(t, strings.join(s.columns.keys[:], " "), "a b")
	testing.expect_value(t, strings.join(s.columns.names[:], " "), "a c")
	testing.expect_value(t, jq.shape(compiled(&ip, "{(.k): .v}")).column_faults, bit_set[jq.Shape_Fault]{.Object_Key})
	spine := jq.shape(compiled(&ip, ".items[] | .x")).spine
	testing.expect(t, spine.kind == .Entries && len(spine.names) == 1 && spine.names[0] == "items")
	c := collect()
	jq.run(&ip, spine.each.?, parsed(`{"x": 7}`), &c)
	testing.expect_value(t, strings.join(c.answers[:], " "), "7")
	spine = jq.shape(compiled(&ip, ".a.b | length")).spine
	testing.expect(t, spine.kind == .Length && len(spine.names) == 2)
	spine = jq.shape(compiled(&ip, "[.items[] | .x] | add")).spine
	testing.expect(t, spine.kind == .Collect && spine.tailed && spine.each != nil && spine.tail.body != nil)
}

// Copies of one interpreter collect over an array as `[.[] | f]` does.
@(test)
copies_collect_alike :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ip: jq.Interp
	defer jq.destroy(&ip)
	prog := compiled(&ip, ". * $k", {{"k", f64(10)}})
	jq.share(&ip, prog)
	copy: jq.Interp
	defer jq.destroy(&copy)
	for _ in 0 ..< 2 {
		jq.clone(&ip, &copy)
		into: [dynamic]core.Value
		testing.expect_value(t, jq.collect(&copy, prog, parsed("[1, 2, 3]"), &into), jq.Outcome.Done)
		testing.expect_value(t, jq.to_json(&core.Array{items = into}), "[10,20,30]")
	}
}

@(test)
filters_type_against_a_schema :: proc(t: ^testing.T) {
	// The typing's nodes made in the temp allocator, which its own scratch also uses.
	context.allocator = context.temp_allocator
	c, err := schema.compile(transmute([]u8)string(`{"type": "object", "properties": {"a": {"type": "integer"}}}`), json.as(.Json))
	testing.expect(t, err == nil)
	ip: jq.Interp
	defer jq.destroy(&ip)
	_, refusals := jq.check_types(compiled(&ip, ".a + $n", {{"n", f64(1)}}), c.description, {})
	testing.expect_value(t, len(refusals), 0)
	_, refusals = jq.check_types(compiled(&ip, ".a | ascii_downcase"), c.description, {})
	testing.expect_value(t, len(refusals), 1)
}

// A document read as jq reads values: a repeated key once with its last value, in jq's kinds and order.
@(test)
values_read_as_jq_reads_them :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v := parsed(`{"a": 1, "b": "x", "a": null}`)
	testing.expect(t, jq.kind(v) == .Object && jq.type_name(v) == "object" && jq.truthy(v))
	testing.expect_value(t, jq.length_of(v), 2)
	it := jq.iterate(v)
	seen: [dynamic]string
	for k, m in jq.next_member(&it) {
		append(&seen, k, jq.type_name(m))
		if s, is_str := jq.string_of(jq.scalar(m)); is_str {
			testing.expect_value(t, s, "x")
		}
	}
	testing.expect_value(t, strings.join(seen[:], " "), "a null b string")
	testing.expect_value(t, jq.property_value(f64(1), .Tag), nil)
}

@(test)
texts_read_and_print_as_jq_does :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src := transmute([]u8)string("[1,")
	_, fault := core.refuse_key_clash(core.build(src, json.as(.Json)))
	testing.expect_value(t, jq.parse_message(src, fault.?), "Unfinished JSON term at EOF at line 1, column 3")
	b := strings.builder_make()
	testing.expect_value(t, jq.valid_utf8("a\xffb"), "a\ufffdb")
	strings.builder_reset(&b)
	jq.write_valid_utf8(&b, "\xc3")
	testing.expect_value(t, strings.to_string(b), "\ufffd")
	spare: [write.ROOM_MAX]u8
	out: write.Out
	write.init(&out, &spare, context.allocator)
	spill := jq.Spill{at = 1 << 20}
	jq.write_value(&out, "\u00e9", {opts = {ascii = true}, spill = &spill})
	text, _ := write.finish(&out)
	testing.expect_value(t, string(text), `"\u00e9"`)
}

// The interpreter's own arena allocator holds a run's values, as a caller that empties it between inputs gives it.
@(test)
runs_in_the_interpreters_arena :: proc(t: ^testing.T) {
	values: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&values), nil)
	defer virtual.arena_destroy(&values)
	context.allocator = jq.run_allocator(&values)
	ip: jq.Interp
	defer jq.destroy(&ip)
	prog := compiled(&ip, "[.[] | {v: .}] | length")
	c := collect()
	testing.expect_value(t, jq.run(&ip, prog, numbers(1, 2), &c, transient = true), jq.Outcome.Done)
	testing.expect_value(t, c.answers[0], "2")
}

// The outputs of a run, kept as values.
Keep :: struct {
	using sink: jq.Sink,
	values:     [dynamic]core.Value,
}

// A run's outputs outlive the interpreter that made them: `capture` and `match` copy their group names.
@(test)
outputs_outlive_their_interpreter :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	keep := Keep{sink = {emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
				append(&(^Keep)(s).values, it.v)
				return .Go
			}}}
	ip: jq.Interp
	jq.run(&ip, compiled(&ip, `capture("(?<grp>x+)"), (match("(?<g>x)") | .captures[0].name)`), "xx", &keep)
	jq.destroy(&ip)
	other: jq.Interp
	defer jq.destroy(&other)
	jq.run(&other, compiled(&other, `[match("(?<zzz>y)")]`), "yyyy", &keep) // reuses what the first one freed
	testing.expect_value(t, jq.to_json(keep.values[0]), `{"grp":"xx"}`)
	testing.expect_value(t, jq.to_json(keep.values[1]), `"g"`)
}

// `strftime` reads every spelling of `%s` and `%z` as UTC, whatever the process's zone.
@(test)
strftime_is_utc_in_any_zone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	before, had := os.lookup_env("TZ", context.allocator)
	defer if had {
		_ = os.set_env("TZ", before)
	} else {
		os.unset_env("TZ")
	}
	_ = os.set_env("TZ", "Asia/Tokyo")
	w: World
	zoned, _, _, _ := run(&w, `0 | strflocaltime("%z")`)
	if zoned[0] == `"+0000"` {
		return // the C library does not see this process's TZ here
	}
	answers, _, _, _ := run(&w, `86400 | [strftime("%s"), strftime("%Es"), strftime("%-s"), strftime("%_s"), strftime("%0s"), strftime("%z"), strftime("%Oz"), strftime("%-z")]`)
	testing.expect_value(t, answers[0], `["86400","86400","86400","86400","86400","+0000","+0000","+0"]`)
}

// A sink ends a run: `.Break` with no error, after a run whose label broke, and `raise` with its error.
@(test)
sinks_end_runs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ip: jq.Interp
	defer jq.destroy(&ip)
	c := collect()
	testing.expect_value(t, jq.run(&ip, compiled(&ip, "first(range(3))"), nil, &c), jq.Outcome.Done)
	stop := jq.Sink{emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {return .Break}}
	testing.expect_value(t, jq.run(&ip, compiled(&ip, "label $out | 1, 2"), nil, &stop), jq.Outcome.Done)
	Refuse :: struct {
		using sink: jq.Sink,
		ip:         ^jq.Interp,
	}
	refuse := Refuse{sink = {emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
				return jq.raise((^Refuse)(s).ip, "no")
			}}, ip = &ip}
	testing.expect_value(t, jq.run(&ip, compiled(&ip, "1, 2"), nil, &refuse), jq.Outcome.Raised)
	testing.expect_value(t, jq.to_json(ip.err), `"no"`)
}

// `now` and the uuids read the clock and the random source through the hooks, and fail without them.
@(test)
time_and_chance_are_hooks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	w: World
	answers, _, _, _ := run(&w, `[now, uuid_v4, uuid_v7]`)
	testing.expect_value(t, answers[0], `[1425599621.5,"00010203-0405-4607-8809-0a0b0c0d0e0f","014bec5b-e97c-7607-8809-0a0b0c0d0e0f"]`)
	ip: jq.Interp
	defer jq.destroy(&ip)
	c := collect()
	testing.expect_value(t, jq.run(&ip, compiled(&ip, "now"), nil, &c), jq.Outcome.Raised)
	testing.expect_value(t, jq.to_json(ip.err), `"now/0 not implemented on this platform"`)
}

// `$ENV` and `env` live in the program's memory, as its literals do, so they outlive the interpreter and a clone that
// gave them, and `destroy` leaves nothing behind: what the test makes is in its own arena, and anything else must
// be given back to the test's allocator.
@(test)
env_outlives_its_interpreter :: proc(t: ^testing.T) {
	values: virtual.Arena
	defer virtual.arena_destroy(&values)
	outside := context.allocator
	context.allocator = jq.run_allocator(&values)
	keep := Keep{sink = {emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
				append(&(^Keep)(s).values, it.v)
				return .Go
			}}}
	w := World{environ = {"A=1", "B=two"}}
	for _ in 0 ..< 2 {
		ip: jq.Interp
		jq.init(&ip, {hooks = hooks(&w)})
		prog, _ := jq.compile(&ip, "$ENV, env.B")
		jq.run(&ip, prog, nil, &keep)
		copy: jq.Interp
		jq.clone(&ip, &copy)
		jq.run(&copy, prog, nil, &keep)
		jq.destroy(&copy)
		jq.destroy(&ip)
	}
	other: jq.Interp
	defer jq.destroy(&other)
	jq.run(&other, compiled(&other, `[range(64) | tostring * 8]`), nil, &keep) // reuses what they freed
	// The first run that reads $ENV makes it in the program's memory, here the test's arena, and the next reuses it.
	jq.init(&other, {hooks = hooks(&w)})
	plain, _ := jq.compile(&other, "null | length")
	reads, _ := jq.compile(&other, "env | length")
	grew: [3]uint
	for prog, i in ([]jq.Program{plain, reads, reads}) {
		before := values.total_used
		jq.run(&other, prog, nil, &Collect{sink = {emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {return .Go}}})
		grew[i] = values.total_used - before
	}
	testing.expect(t, grew[1] > grew[0] && grew[2] < grew[1])
	context.allocator = outside
	testing.expect_value(t, len(keep.values), 9)
	for i in 0 ..< 4 {
		testing.expect_value(t, jq.to_json(keep.values[2 * i], allocator = context.temp_allocator), `{"A":"1","B":"two"}`)
		testing.expect_value(t, jq.to_json(keep.values[2 * i + 1], allocator = context.temp_allocator), `"two"`)
	}
}
