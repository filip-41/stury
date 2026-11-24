// Hooks that record a walk's tokens and answer actions, and the checks every format's walk must pass with them.
package testkit

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A hook of the capabilities that answer actions, which records the tokens it is given and answers `action` at token
// `at`, storing a container it keeps through its inner hook only. Its registers are `a` the address of its next node in
// `nodes`, `b` its tokens and `c` its open containers. The walk checks its room, which starts at `room` nodes, and sizes
// its stack, which starts at `levels`.
Probe :: struct {
	tokens:   [dynamic]tape.Token,
	nodes:    []tape.Node,
	room:     int, // the nodes `nodes` has place for
	levels:   int, // the open levels its stack holds
	grows:    int, // the growths of its room
	deepens:  int, // the growths of its stack
	short:    int, // the nodes its inner hook's room lies short of its own, 1 for 0
	refuse:   bool, // its stack refuses to grow
	kept:     bool, // the next `End` closes a container the inner hook kept, which stored its node and its `End`
	at:       int, // the token answered `action`, -1 for none
	action:   hook.Action,
	cancel:   ^bool, // with `cancel` set, every token answers `Stop` once it reads true
	reached:  ^sync.Sema, // with `reached` set, posted at token `at`, which then waits for `cancel`
	inner:    Probe_Inner,
	ctx:      runtime.Context, // the test's, for the allocations the contextless hook makes
	protocol: hook.Protocol(PROBE_CAPS, hook.Levels(probe_levels_held, probe_levels_grow), hook.Rooms(probe_rooms_end, probe_rooms_grow), hook.Keeps(Probe_Inner, probe_inner, probe_kept, probe_kept_stubs)),
}

PROBE_CAPS :: hook.Capabilities{.Skips, .Levels, .Rooms, .Keeps}

// The hook a `Probe` keeps a container with. It stores the probe's nodes in a room one node short of the probe's, with
// no growth of its own, so an inner walk that checks the outer room writes past it.
Probe_Inner :: struct {
	outer:    ^Probe,
	kept:     int, // the tokens it was given
	stubs:    bool, // the last container was kept by `Keep_Stubs`
	protocol: hook.Protocol(PROBE_INNER_CAPS, hook.Levels(inner_levels_held, inner_levels_grow), hook.Rooms(inner_rooms_end, probe_rooms_grow_inner), hook.Unused),
}

PROBE_INNER_CAPS :: hook.Capabilities{.Levels, .Rooms}

// A `Probe` whose hook has no `.Rooms`, which keeps every container it answers `Keep` or `Keep_Stubs` for through its
// inner hook, as a scan keeps through its builder.
Probe_Bare :: struct {
	probe:    Probe,
	protocol: hook.Protocol(BARE_CAPS, hook.Levels(bare_levels_held, bare_levels_grow), hook.Unused, hook.Keeps(Probe_Inner, bare_inner, probe_kept, probe_kept_stubs)),
}

BARE_CAPS :: hook.Capabilities{.Skips, .Levels, .Keeps}

// The walk of a format for a `Probe_Bare` from registers `regs`.
Bare_Walk :: #type proc(src: []u8, opts: tape.Options, h: ^Probe_Bare, regs: ^hook.Regs) -> (u64, tape.Error)

bare_hook :: proc "contextless" (h: ^Probe_Bare, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return probe_hook(&h.probe, s, t)
}

@(private)
bare_levels_held :: proc "contextless" (h: rawptr) -> int {
	return probe_levels_held(&(^Probe_Bare)(h).probe)
}

@(private)
bare_levels_grow :: proc "contextless" (h: rawptr, want: int, s: ^hook.Regs, at: u64) -> bool {
	return probe_levels_grow(&(^Probe_Bare)(h).probe, want, s, at)
}

@(private)
bare_inner :: proc "contextless" (h: rawptr) -> rawptr {
	return probe_inner(&(^Probe_Bare)(h).probe)
}

// The walk of a format for a `Probe` from registers `regs`, which gives where the root value ends and the error.
Probe_Walk :: #type proc(src: []u8, opts: tape.Options, h: ^Probe, regs: ^hook.Regs) -> (u64, tape.Error)

// A probe with `room` nodes and `levels` open levels, answering `action` at token `at`.
probe_start :: proc(room, levels: int, at := -1, action := hook.Action.Next) -> (h: Probe) {
	h.nodes = make([]tape.Node, max(room, 1))
	h.room, h.levels, h.at, h.action, h.ctx = room, levels, at, action, context
	return
}

probe_end :: proc(h: ^Probe) {
	delete(h.tokens)
	delete(h.nodes)
}

probe_regs :: proc(h: ^Probe) -> hook.Regs {
	h.inner.outer = h
	return {a = u64(uintptr(raw_data(h.nodes))), b = 0, c = 0}
}

probe_hook :: proc "contextless" (h: ^Probe, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	context = h.ctx
	if h.cancel != nil {
		if h.reached != nil && len(h.tokens) == h.at {
			sync.sema_post(h.reached)
			for !sync.atomic_load(h.cancel) {
				thread.yield()
			}
		}
		if sync.atomic_load(h.cancel) {
			return s, .Stop
		}
	}
	if h.kept && t.kind == .End {
		h.kept = false
		append(&h.tokens, t)
		return s, .Next
	}
	if len(h.tokens) == h.at && (h.action == .Keep || h.action == .Keep_Stubs) {
		h.kept = true
		append(&h.tokens, t)
		return s, h.action
	}
	next := probe_store(h, s, t, probe_rooms_end(h))
	if len(h.tokens) - 1 == h.at {
		return next, h.action
	}
	return next, .Next
}

@(private)
probe_store :: proc(h: ^Probe, s: hook.Regs, t: tape.Token, end: uintptr) -> hook.Regs {
	s := s
	append(&h.tokens, t)
	if t.role <= .Key && t.kind != .End {
		if uintptr(s.a) >= end {
			panic("testkit: a node past the probe's room")
		}
		((^tape.Node)(uintptr(s.a)))^ = t
		s.a += size_of(tape.Node)
	}
	if t.kind == .End {
		s.c -= 1
	} else if t.kind > .Plain {
		if int(s.c) >= h.levels {
			panic("testkit: a container past the probe's levels")
		}
		s.c += 1
	}
	s.b += 1
	return s
}

@(private)
probe_levels_held :: proc "contextless" (h: rawptr) -> int {
	return (^Probe)(h).levels
}

@(private)
probe_levels_grow :: proc "contextless" (h: rawptr, want: int, _: ^hook.Regs, _: u64) -> bool {
	p := (^Probe)(h)
	if p.refuse {
		return false
	}
	p.levels, p.deepens = want, p.deepens + 1
	return true
}

@(private)
probe_rooms_end :: proc "contextless" (h: rawptr) -> uintptr {
	p := (^Probe)(h)
	return uintptr(raw_data(p.nodes)) + uintptr(p.room * size_of(tape.Node))
}

@(private)
probe_rooms_grow :: proc "contextless" (h: rawptr, s: ^hook.Regs, at: u64) -> bool {
	p := (^Probe)(h)
	context = p.ctx
	used := int((uintptr(s.a) - uintptr(raw_data(p.nodes))) / size_of(tape.Node))
	nodes := make([]tape.Node, 2 * p.room + 1)
	copy(nodes, p.nodes[:used])
	delete(p.nodes)
	p.nodes, p.room, p.grows = nodes, len(nodes), p.grows + 1
	s.a = u64(uintptr(raw_data(nodes))) + u64(used * size_of(tape.Node))
	return true
}

@(private)
probe_inner :: proc "contextless" (h: rawptr) -> rawptr {
	return &(^Probe)(h).inner
}

@(private)
probe_kept :: proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	i := (^Probe_Inner)(h)
	context = i.outer.ctx
	i.kept += 1
	i.stubs = false
	return probe_store(i.outer, s, t, inner_rooms_end(h)), .Next
}

@(private)
probe_kept_stubs :: proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	i := (^Probe_Inner)(h)
	context = i.outer.ctx
	i.kept += 1
	i.stubs = true
	return probe_store(i.outer, s, t, inner_rooms_end(h)), .Next
}

@(private)
inner_levels_held :: proc "contextless" (h: rawptr) -> int {
	return (^Probe_Inner)(h).outer.levels
}

@(private)
inner_levels_grow :: proc "contextless" (h: rawptr, want: int, s: ^hook.Regs, at: u64) -> bool {
	return probe_levels_grow((^Probe_Inner)(h).outer, want, s, at)
}

@(private)
inner_rooms_end :: proc "contextless" (h: rawptr) -> uintptr {
	p := (^Probe_Inner)(h).outer
	return probe_rooms_end(p) - uintptr(max(p.short, 1) * size_of(tape.Node))
}

@(private)
probe_rooms_grow_inner :: proc "contextless" (h: rawptr, s: ^hook.Regs, at: u64) -> bool {
	return probe_rooms_grow((^Probe_Inner)(h).outer, s, at)
}

// The tokens `walk` gives a probe answering `action` at token `at`, its error, and the probe, ended by the caller.
probe_run :: proc(walk: Probe_Walk, src: []u8, opts: tape.Options, room, levels: int, at := -1, action := hook.Action.Next) -> (h: Probe, err: tape.Error) {
	h = probe_start(room, levels, at, action)
	regs := probe_regs(&h)
	_, err = walk(src, opts, &h, &regs)
	return
}

// The index of the `End` of the container whose token is `tokens[at]`.
@(private)
end_of :: proc(tokens: []tape.Token, at: int) -> int {
	depth := 0
	for i in at ..< len(tokens) {
		if tokens[i].kind == .End {
			depth -= 1
		} else if tokens[i].kind > .Plain {
			depth += 1
		}
		if depth == 0 {
			return i
		}
	}
	return len(tokens) - 1
}

@(private)
same_tokens :: proc(t: ^testing.T, got, want: []tape.Token, what: string, src: []u8, at: int) -> bool {
	if len(got) != len(want) {
		testing.expectf(t, false, "%s at token %d of %q: %d tokens, want %d", what, at, string(src), len(got), len(want))
		return false
	}
	for g, i in got {
		if g != want[i] {
			testing.expectf(t, false, "%s at token %d of %q: token %d is %v, want %v", what, at, string(src), i, g, want[i])
			return false
		}
	}
	return true
}

// Checks that `walk` passes the value of the member whose key is `want[i]` when the hook answers `Skip` on the key: the
// facts before the value are given, the value is not, a container's tokens and `End` included, and the walk goes on
// after it. The skipped containers still take their steps of `Budget.steps`, of which the text has `containers`.
@(private)
key_skip :: proc(t: ^testing.T, walk: Probe_Walk, src: []u8, want: []tape.Token, i, containers: int) {
	j := i + 1
	for want[j].role > .Key {
		j += 1
	}
	end := end_of(want, j) if want[j].kind > .Plain else j
	expected := make([dynamic]tape.Token, context.temp_allocator)
	append(&expected, ..want[:j])
	append(&expected, ..want[end + 1:])
	h, e := probe_run(walk, src, {}, 1024, 1024, i, .Skip)
	testing.expectf(t, e == nil, "Skip at key %d of %q: %v", i, string(src), e)
	same_tokens(t, h.tokens[:], expected[:], "Skip at a key", src, i)
	probe_end(&h)
	h, e = probe_run(walk, src, {budget = {steps = u64(containers)}}, 1024, 1024, i, .Skip)
	testing.expectf(t, e == nil, "Skip at key %d of %q within %d steps: %v", i, string(src), containers, e)
	same_tokens(t, h.tokens[:], expected[:], "Skip at a key within the steps", src, i)
	probe_end(&h)
	if containers > 1 {
		h, e = probe_run(walk, src, {budget = {steps = u64(containers - 1)}}, 1024, 1024, i, .Skip)
		x, ok := e.(tape.Exceeded)
		testing.expectf(t, ok && x.kind == .Steps, "Skip at key %d of %q within %d steps: %v", i, string(src), containers - 1, e)
		probe_end(&h)
	}
}

// Checks that `walk` keeps the hook protocol over each text of `texts`, which it reads: `Stop`, `Skip`, `Rest`,
// `Keep` and `Keep_Stubs` at every token, `Skip` at every key, a room that starts full or grows at every node, a stack
// that grows from one level or is refused, and `Budget.steps` at every count of containers.
hook_protocol :: proc(t: ^testing.T, walk: Probe_Walk, texts: []string) {
	for text in texts {
		src := transmute([]u8)text
		whole, err := probe_run(walk, src, {}, 1024, 1024)
		defer probe_end(&whole)
		if !testing.expectf(t, err == nil, "%q: %v", text, err) {
			continue
		}
		want := whole.tokens[:]
		nodes := 0
		containers := 0
		for tok in want {
			nodes += int(tok.role <= .Key && tok.kind != .End)
			containers += int(tok.kind > .Plain && tok.kind != .End)
		}
		for i in 0 ..< len(want) {
			container := want[i].kind > .Plain && want[i].kind != .End
			end := end_of(want, i) if container else i
			h, e := probe_run(walk, src, {}, 1024, 1024, i, .Stop)
			testing.expectf(t, e == nil, "Stop at %d of %q: %v", i, text, e)
			same_tokens(t, h.tokens[:], want[:i + 1], "Stop", src, i)
			probe_end(&h)
			if want[i].role == .Key {
				key_skip(t, walk, src, want, i, containers)
			}
			if !container || want[i].role > .Key {
				continue
			}
			h, e = probe_run(walk, src, {}, 1024, 1024, i, .Skip)
			expected := make([dynamic]tape.Token, context.temp_allocator)
			append(&expected, ..want[:i + 1])
			append(&expected, ..want[end:])
			testing.expectf(t, e == nil, "Skip at %d of %q: %v", i, text, e)
			same_tokens(t, h.tokens[:], expected[:], "Skip", src, i)
			probe_end(&h)
			h, e = probe_run(walk, src, {}, 1024, 1024, i, .Rest)
			testing.expectf(t, e == nil, "Rest at %d of %q: %v", i, text, e)
			same_tokens(t, h.tokens[:], want[:i + 1], "Rest", src, i)
			probe_end(&h)
			actions := [2]hook.Action{.Keep, .Keep_Stubs}
			for action in actions {
				if action == .Keep_Stubs && want[i].kind != .Object {
					continue
				}
				// The inner room is full where the kept container goes, so the inner walk grows it.
				before := 1
				for tok in want[:i] {
					before += int(tok.role <= .Key && tok.kind != .End)
				}
				k, ke := probe_run(walk, src, {}, before, 1024, i, action)
				testing.expectf(t, ke == nil, "%v at %d of %q: %v", action, i, text, ke)
				// The inner hook takes the container from its open to its `End`, which the hook takes after.
				kept := make([dynamic]tape.Token, context.temp_allocator)
				append(&kept, ..want[:i + 1])
				append(&kept, ..want[i:end + 1])
				append(&kept, ..want[end:])
				same_tokens(t, k.tokens[:], kept[:], fmt.tprint(action), src, i)
				testing.expectf(t, k.inner.kept == end - i + 1, "%v at %d of %q: the inner hook took %d tokens, want %d", action, i, text, k.inner.kept, end - i + 1)
				testing.expectf(t, k.inner.stubs == (action == .Keep_Stubs), "%v at %d of %q: kept by the other proc", action, i, text)
				probe_end(&k)
			}
		}
		for room in 0 ..= nodes {
			h, e := probe_run(walk, src, {}, room, 1024)
			testing.expectf(t, e == nil, "room %d of %q: %v", room, text, e)
			same_tokens(t, h.tokens[:], want, "room", src, room)
			testing.expectf(t, (h.grows > 0) == (room < nodes), "room %d of %q: %d growths for %d nodes", room, text, h.grows, nodes)
			used := 0
			for tok in h.tokens {
				if tok.role <= .Key && tok.kind != .End {
					testing.expectf(t, h.nodes[used] == tok, "room %d of %q: node %d is %v, want %v", room, text, used, h.nodes[used], tok)
					used += 1
				}
			}
			probe_end(&h)
		}
		h, e := probe_run(walk, src, {}, 1024, 1)
		testing.expectf(t, e == nil, "one level of %q: %v", text, e)
		same_tokens(t, h.tokens[:], want, "one level", src, 0)
		deep := 0
		open := 0
		for tok in want {
			open += -1 if tok.kind == .End else int(tok.kind > .Plain)
			deep = max(deep, open)
		}
		testing.expectf(t, h.levels >= deep && (h.deepens > 0) == (deep > 1), "one level of %q: %d levels after %d growths, %d deep", text, h.levels, h.deepens, deep)
		probe_end(&h)
		if deep > 1 {
			r := probe_start(1024, 1)
			r.refuse = true
			regs := probe_regs(&r)
			_, re := walk(src, {}, &r, &regs)
			testing.expectf(t, re == runtime.Allocator_Error.Out_Of_Memory, "refused levels of %q: %v", text, re)
			probe_end(&r)
		}
		for steps in 1 ..= containers {
			h, e = probe_run(walk, src, {budget = {steps = u64(steps)}}, 1024, 1024)
			if steps < containers {
				x, ok := e.(tape.Exceeded)
				testing.expectf(t, ok && x.kind == .Steps, "%d steps of %q: %v", steps, text, e)
				opened := 0
				for tok in h.tokens {
					opened += int(tok.kind > .Plain && tok.kind != .End)
				}
				testing.expectf(t, opened == steps, "%d steps of %q: %d containers given", steps, text, opened)
			} else {
				testing.expectf(t, e == nil, "%d steps of %q: %v", steps, text, e)
				same_tokens(t, h.tokens[:], want, "steps", src, steps)
			}
			probe_end(&h)
		}
		free_all(context.temp_allocator)
	}
}

// The tokens `walk` gives a bare probe of `room` nodes, whose inner hook's room lies `short` nodes short of it,
// answering `action` at token `at`.
@(private)
bare_run :: proc(walk: Bare_Walk, src: []u8, room, short, at: int, action: hook.Action) -> (h: Probe_Bare, err: tape.Error) {
	h.probe = probe_start(room, 1024, at, action)
	h.probe.short = short
	regs := probe_regs(&h.probe)
	_, err = walk(src, {}, &h, &regs)
	return
}

// Checks that `walk` checks the room of the inner hook a container is kept through, whether or not the hook that keeps
// it has `.Rooms`: the inner room lies one node short of where the container's last node goes, and the walk grows it.
hook_inner_rooms :: proc(t: ^testing.T, walk: Bare_Walk, texts: []string) {
	for text in texts {
		src := transmute([]u8)text
		whole, err := bare_run(walk, src, 1024, 0, -1, .Next)
		defer probe_end(&whole.probe)
		if !testing.expectf(t, err == nil, "%q: %v", text, err) {
			continue
		}
		want := whole.probe.tokens[:]
		is_node :: proc(tok: tape.Token) -> int {
			return int(tok.role <= .Key && tok.kind != .End)
		}
		nodes := 0
		for tok in want {
			nodes += is_node(tok)
		}
		for i in 0 ..< len(want) {
			if want[i].kind <= .Plain || want[i].kind == .End || want[i].role > .Key {
				continue
			}
			end := end_of(want, i)
			after := 0
			for tok in want[end + 1:] {
				after += is_node(tok)
			}
			for action in ([2]hook.Action{.Keep, .Keep_Stubs}) {
				if action == .Keep_Stubs && want[i].kind != .Object {
					continue
				}
				k, e := bare_run(walk, src, nodes, after + 1, i, action)
				testing.expectf(t, e == nil, "%v at %d of %q: %v", action, i, text, e)
				kept := make([dynamic]tape.Token, context.temp_allocator)
				append(&kept, ..want[:i + 1])
				append(&kept, ..want[i:end + 1])
				append(&kept, ..want[end:])
				same_tokens(t, k.probe.tokens[:], kept[:], fmt.tprint(action), src, i)
				testing.expectf(t, k.probe.grows == 1, "%v at %d of %q: %d growths of the inner room, want 1", action, i, text, k.probe.grows)
				probe_end(&k.probe)
			}
		}
		free_all(context.temp_allocator)
	}
}

// Checks that a hook stops `walk` through a flag another thread sets, as a cancel or a deadline does, at the token it
// reads it at.
hook_cancel :: proc(t: ^testing.T, walk: Probe_Walk, text: string, at: int) {
	src := transmute([]u8)text
	cancel: bool
	reached: sync.Sema
	h := probe_start(1024, 1024, at)
	defer probe_end(&h)
	h.cancel, h.reached = &cancel, &reached
	canceller := thread.create_and_start_with_poly_data2(&cancel, &reached, proc(cancel: ^bool, reached: ^sync.Sema) {
		sync.sema_wait(reached)
		sync.atomic_store(cancel, true)
	})
	regs := probe_regs(&h)
	_, err := walk(src, {}, &h, &regs)
	thread.join(canceller)
	thread.destroy(canceller)
	testing.expectf(t, err == nil, "cancel of %q: %v", text, err)
	testing.expectf(t, len(h.tokens) == at, "cancel of %q: %d tokens, want %d", text, len(h.tokens), at)
}
