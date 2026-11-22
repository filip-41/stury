package json_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

@(private = "file")
walk_of :: proc($S: json.Spec) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := json.walk(src, S, opts, h, regs, testkit.probe_hook)
		return at, err
	}
}

@(private = "file")
bare_walk_of :: proc($S: json.Spec) -> testkit.Bare_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe_Bare, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := json.walk(src, S, opts, h, regs, testkit.bare_hook)
		return at, err
	}
}

@(private = "file")
bare_walk_in_pieces_of :: proc($S: json.Spec) -> testkit.Bare_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe_Bare, regs: ^hook.Regs) -> (u64, tape.Error) {
		p := tape.Pieces{allocator = context.allocator}
		defer tape.destroy(&p)
		o := opts
		o.pieces = &p
		at, err, _ := json.walk(src[:len(src) / 2], S, o, h, regs, testkit.bare_hook)
		if err != nil || !p.more {
			return at, err
		}
		p.from, p.last = p.keep, true
		at, err, _ = json.walk(src[p.keep:], S, o, h, regs, testkit.bare_hook)
		return at, err
	}
}

// The walk of a text in two pieces, cut in its middle, the second window from the first read's `keep`.
@(private = "file")
walk_in_pieces_of :: proc($S: json.Spec) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		p := tape.Pieces{allocator = context.allocator}
		defer tape.destroy(&p)
		o := opts
		o.pieces = &p
		at, err, _ := json.walk(src[:len(src) / 2], S, o, h, regs, testkit.probe_hook)
		if err != nil || !p.more {
			return at, err
		}
		p.from, p.last = p.keep, true
		at, err, _ = json.walk(src[p.keep:], S, o, h, regs, testkit.probe_hook)
		return at, err
	}
}

@(private = "file")
PROTOCOL_TEXTS := [?]string{
	`1`,
	`[]`,
	`{}`,
	`[1,"a",true,null,[2,[3]],{"k":{"l":[]}}]`,
	`{"a":1,"b":[{"c":2},{"d":[3,4]}],"e":{}}`,
	`[[1.5,-2,3e4,0,7,8,9,10,11,12,13,14,15],[16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31],[1,2,3,4,5,6,7,8,9,10]]`,
	`[[[[[[[[[[[[[[[[[[[["deep"]]]]]]]]]]]]]]]]]]]]`,
	` { "x" : [ 1 , { "y" : "z" } ] } `,
}

@(private = "file")
COMMENT_TEXTS := [?]string{
	`// head
[1, /* in */ {"a": [2,],}, ] // tail`,
	`{"a": {"b": /* c */ [1, 2]}, /* d */ "e": 3}`,
}

// Every JSON walk keeps the hook protocol: actions at every token, room and level growth, and `Budget.steps`.
@(test)
json_walks_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.hook_protocol(t, walk_of(.Json), PROTOCOL_TEXTS[:])
	testkit.hook_protocol(t, walk_in_pieces_of(.Json), PROTOCOL_TEXTS[:])
	testkit.hook_protocol(t, walk_in_pieces_of(.Jsonc), COMMENT_TEXTS[:])
	testkit.hook_protocol(t, walk_in_pieces_of(.Json5), COMMENT_TEXTS[:])
	testkit.hook_protocol(t, walk_of(.Jsonc), PROTOCOL_TEXTS[:])
	testkit.hook_protocol(t, walk_of(.Jsonc), COMMENT_TEXTS[:])
	testkit.hook_protocol(t, walk_of(.Json5), PROTOCOL_TEXTS[:])
	testkit.hook_protocol(t, walk_of(.Json5), COMMENT_TEXTS[:])
}

// The room of the inner hook a container is kept through is checked in every walk, whatever the hook that keeps it has.
@(test)
json_walks_check_the_inner_room :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.hook_inner_rooms(t, bare_walk_of(.Json), PROTOCOL_TEXTS[:])
	testkit.hook_inner_rooms(t, bare_walk_in_pieces_of(.Json), PROTOCOL_TEXTS[:])
	testkit.hook_inner_rooms(t, bare_walk_in_pieces_of(.Jsonc), COMMENT_TEXTS[:])
	testkit.hook_inner_rooms(t, bare_walk_in_pieces_of(.Json5), COMMENT_TEXTS[:])
	testkit.hook_inner_rooms(t, bare_walk_of(.Jsonc), COMMENT_TEXTS[:])
	testkit.hook_inner_rooms(t, bare_walk_of(.Json5), COMMENT_TEXTS[:])
}

// A hook stops a walk from another thread through a flag.
@(test)
json_walk_cancels_through_a_flag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.repeat(`{"a":[1,2,{"b":"c"}]},`, 200, context.temp_allocator)
	testkit.hook_cancel(t, walk_of(.Json), strings.concatenate({"[", text, "1]"}, context.temp_allocator), 300)
}

// `Budget.steps` counts the containers a build, scan or find opens, those it passes included, and refuses one past it.
@(test)
reads_keep_the_steps_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a":[{"b":1},{"b":2}],"c":{"d":[3]},"e":4}`)
	CONTAINERS :: 6
	path := []tape.Step{tape.Name("e")}
	paths := [][]tape.Step{path}
	for steps in u64(1) ..= CONTAINERS + 1 {
		opts := json.Options{budget = {steps = steps}}
		over := steps < CONTAINERS
		doc, err := json.build(src, .Json, opts)
		x, exceeded := err.(tape.Exceeded)
		testing.expectf(t, over == (exceeded && x.kind == .Steps), "build, %d steps: %v", steps, err)
		tape.destroy(&doc)
		demand, derr := tape.demand_of(paths)
		testing.expect(t, derr == nil)
		part, serr := json.scan(src, &demand, .Json, {}, opts)
		x, exceeded = serr.(tape.Exceeded)
		testing.expectf(t, over == (exceeded && x.kind == .Steps), "scan, %d steps: %v", steps, serr)
		tape.destroy(&part)
		tape.destroy_demand(&demand)
		answer, ferr := json.find(src, path, .Json, {}, opts)
		x, exceeded = ferr.(tape.Exceeded)
		testing.expectf(t, over == (exceeded && x.kind == .Steps), "find, %d steps: %v", steps, ferr)
		testing.expect(t, over || answer.lo == 41)
		verr := json.validate(src, .Json, opts)
		x, exceeded = verr.(tape.Exceeded)
		testing.expectf(t, over == (exceeded && x.kind == .Steps), "validate, %d steps: %v", steps, verr)
	}
}

// The levels a read grows past its frame are allocated in the caller's context.
@(test)
deep_reads_allocate_in_the_callers_context :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Seen :: struct {
		backing: runtime.Allocator,
		calls:   int,
		elsewhere: int, // calls in a context other than the caller's
	}
	seen := Seen{backing = context.allocator}
	checking := runtime.Allocator{proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		s := (^Seen)(data)
		s.calls += 1
		s.elsewhere += int(context.user_index != 42)
		return s.backing.procedure(s.backing.data, mode, size, alignment, old, old_size, loc)
	}, &seen}
	depth := json.WALK_LEVELS * 2
	text := strings.concatenate({strings.repeat("[", depth, context.temp_allocator), strings.repeat("]", depth, context.temp_allocator)}, context.temp_allocator)
	src := transmute([]u8)text
	context.user_index = 42
	testing.expect(t, json.validate(src, .Json, {}, checking) == nil)
	doc, err := json.build(src, .Json, {}, checking)
	testing.expect(t, err == nil)
	tape.destroy(&doc)
	path := []tape.Step{tape.Name("x")}
	_, ferr := json.find(src, path, .Json, {}, {}, checking)
	testing.expect(t, ferr == nil)
	paths := [][]tape.Step{path}
	demand, _ := tape.demand_of(paths)
	part, serr := json.scan(src, &demand, .Json, {}, {}, checking)
	testing.expect(t, serr == nil)
	tape.destroy(&part)
	tape.destroy_demand(&demand)
	testing.expect(t, seen.calls > 0)
	testing.expectf(t, seen.elsewhere == 0, "%d of %d calls in another context", seen.elsewhere, seen.calls)
}

// The offset a walk stopped by a hook returns, just past the token it stopped at: past a scalar's own bytes and its
// closing quote, past a container's bracket, and past a close.
stop_offset :: proc(src: []u8, tok: tape.Token) -> u64 {
	if tok.kind == .End {
		return tok.lo + 1
	}
	if tok.kind > .Plain {
		return tok.lo + 1
	}
	return tok.lo + u64(tok.n) + u64(tok.kind == .String && tok.spelling & tape.SPELLING_QUOTED != 0)
}

// A hook that stops a walk at any token, among records whose gaps and keys the walk has learned, ends it just past that
// token, whatever state read it.
@(test)
stops_end_just_past_the_token :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	shapes := [?]string {
		`{"id":1,"name":"a","ok":true,"n":null,"f":-1.5,"t":[1],"u":{"k":"v"}}`,
		"{\n  \"id\": 1,\n  \"name\": \"a\",\n  \"ok\": false,\n  \"t\": [],\n  \"u\": {}\n}",
		`{ "id" : 1 , "name" : "a" , "ok" : true , "u" : { "k" : "v" } }`,
	}
	for spec in ([]json.Spec{.Json, .Json5}) {
		walk := walk_of(.Json) if spec == .Json else walk_of(.Json5)
		for shape in shapes {
			text, _ := records(shape, ",", shape, 20)
			src := transmute([]u8)text
			whole, err := testkit.probe_run(walk, src, {}, 1 << 12, 1024)
			defer testkit.probe_end(&whole)
			if !testing.expectf(t, err == nil, "%v: %v", spec, err) {
				continue
			}
			for tok, i in whole.tokens {
				h := testkit.probe_start(1 << 12, 1024, i, .Stop)
				regs := testkit.probe_regs(&h)
				at, stop_err := walk(src, {}, &h, &regs)
				testing.expectf(t, stop_err == nil && at == stop_offset(src, tok), "%v: stop at token %d %v of %q: ends at %d, want %d", spec, i, tok, shape, at, stop_offset(src, tok))
				testkit.probe_end(&h)
			}
		}
	}
}

// The hook protocol over records whose gaps and keys the walk has learned, so that the actions, the end of the room
// and a refused stack come at the keys and values its matched states read.
@(test)
json_walks_keep_the_hook_protocol_in_learned_gaps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	shapes := [?]string {
		`{"id":1,"name":"a","ok":true,"n":null,"f":-1.5,"t":[1],"u":{"k":"v"}}`,
		"{\n  \"id\": 1,\n  \"name\": \"a\",\n  \"ok\": false,\n  \"t\": [],\n  \"u\": {}\n}",
		`{ "id" : 1 , "name" : "a" , "ok" : true , "u" : { "k" : "v" } }`,
	}
	for shape in shapes {
		// The protocol frees the temporary allocator after each text, so each walk has a text of its own.
		text, _ := records(shape, ",", shape, 6)
		testkit.hook_protocol(t, walk_of(.Json), {text})
		text, _ = records(shape, ",", shape, 6)
		testkit.hook_protocol(t, walk_of(.Json5), {text})
	}
}
