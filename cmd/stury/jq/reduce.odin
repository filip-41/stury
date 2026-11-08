package jq

// `reduce` and `foreach`: their states, updated in place where they may be, and the scratch arena their
// updates run in.

import "base:runtime"
import "core:mem/virtual"

// A reduce or foreach: its init's outputs, each starting the loop.
eval_reduce :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Bind_Sink{sink = {emit = reduce_init_emit if n.kind == .Reduce else foreach_init_emit}, ip = ip, n = n, input = input, env = env, track = track, out = out}
	return eval(ip, n.b, input, env, track, &s)
}

// The reduction from an output of the init. jq's reduce moves its input out of the slot the init
// reads it from, so after the first the source runs on null. Under `track` the source runs in the
// init's path state, and the result is the output of a path expression in it, as jq's state goes
// back to the init's when the source has no more.
reduce_init_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Bind_Sink)(s)
	source := x.input
	if x.found {
		source = {v = nil}
	}
	x.found = true
	r := Bind_Sink{sink = {emit = reduce_emit}, ip = x.ip, n = x.n, env = x.env, track = x.track, state = it.v}
	owned: Owned
	if !x.track && (in_place_update(x.n.c) || adds_to_state(x.n.c)) {
		r.owned = &owned
	}
	scratch := Reduce_Scratch{in_place = r.owned != nil}
	if !x.track {
		scratch.used, _ = arena_used(context.allocator)
		r.scratch = &scratch
	}
	outer := x.ip.owned
	x.ip.owned = r.owned
	defer x.ip.owned = outer
	start := state_of(it)
	if x.track {
		source.path = placed(start, source.v)
	}
	sig := eval(x.ip, x.n.a, source, x.env, x.track, &r)
	if scratch.on {
		end_scratch(&r, sig)
	}
	if sig != .Go {
		return sig
	}
	return x.out.emit(x.out, {v = r.state, path = placed(start, r.state) if x.track else nil})
}

reduce_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Bind_Sink)(s)
	st := state_of(it)
	return bind_alternatives(x, it.v, reduce_step, &st if x.track else nil)
}

// A reduce runs its first REDUCE_SCOPED_FROM updates in the memory of the input, or fewer when they make
// REDUCE_SCRATCH_MIN there. From then on each update runs in a scratch arena, and once the scratch holds
// REDUCE_SCRATCH_STATES times what the state took when last copied (more for a small state, REDUCE_SCRATCH_MIN at
// least) the state is copied to a home arena and the scratch and the last home are emptied. Not scoped: an update
// that makes under a byte of garbage (looked at again each REDUCE_SCOPED_FROM updates), one whose garbage since the
// last copy is under 16 times its state's growth, and any update under path(), whose state's path outlives it.
// Nothing but the state outlives an update: an input read in the scratch (`item_arena`) and an error are copied out
// with the state. A foreach whose outputs are printed (`Interp.printer`) runs its updates and extracts so too. One
// over `inputs` is scoped from its first input (`scratch_inputs`).
REDUCE_SCOPED_FROM :: 1024
REDUCE_SCRATCH_MIN :: 1 << 20
// An update that makes a new state each time copies one out each REDUCE_SCRATCH_STATES updates, or, one not changing
// it in place, each REDUCE_SMALL_STATES while as many states take at most REDUCE_SMALL_SCRATCH.
REDUCE_SCRATCH_STATES :: 2
REDUCE_SMALL_STATES :: 8
REDUCE_SMALL_SCRATCH :: 8 << 20

Reduce_Scratch :: struct {
	on:        bool,
	steps:     int, // the updates run unscoped since `used` was read
	used:      uint, // what the memory outside had handed out then
	outside:   runtime.Allocator, // where the reduce's result goes
	scratch:   virtual.Arena,
	homes:     [2]virtual.Arena,
	home:      int, // the home holding the state, once copied
	kept:      uint, // the bytes the state took when last copied
	in_place:  bool, // the update changes the state in place
	free_envs: ^Env, // scopes made in the scratch, given back
	deferred:  bool, // an input runs through updates that may read it: `scratch_inputs` collects after them
	updates:   int, // the updates run in the scratch
}

reduce_step :: proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal {
	if sc := x.scratch; sc != nil && (sc.on || scoped_from_here(x)) {
		return scoped_update(x, e, st, reduce_update)
	}
	return reduce_update(x, e, st)
}

// Whether the scratch starts with this update.
@(private = "file")
scoped_from_here :: proc(x: ^Bind_Sink) -> bool {
	sc := x.scratch
	sc.steps += 1
	used, ok := arena_used(context.allocator)
	made := used - min(used, sc.used) if ok else 0
	if sc.steps < REDUCE_SCOPED_FROM && made < REDUCE_SCRATCH_MIN {
		return false
	}
	if ok && made < REDUCE_SCOPED_FROM {
		sc.steps, sc.used = 0, used
		return false
	}
	if !start_scratch(x) {
		x.scratch = nil // out of memory for the arenas: the reduce goes on unscoped
		return false
	}
	// What the updates made outside bounds the state's size, which the first copy is weighed against.
	sc.kept = made
	return true
}

@(private = "file")
scoped_update :: #force_no_inline proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State, update: proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal) -> Signal {
	sc, ip := x.scratch, x.ip
	context.allocator = arena_allocator(&sc.scratch)
	envs := ip.free_envs
	ip.free_envs = sc.free_envs
	sig := update(x, e, st)
	sc.free_envs = ip.free_envs
	ip.free_envs = envs
	sc.updates += 1
	if sig == .Go && !sc.deferred && collects(sc) {
		collect_scratch(x)
	}
	return sig
}

// Whether the scratch holds enough to copy the state out of it.
@(private)
collects :: proc(sc: ^Reduce_Scratch) -> bool {
	small := REDUCE_SMALL_STATES * sc.kept if !sc.in_place && REDUCE_SMALL_STATES * sc.kept <= REDUCE_SMALL_SCRATCH else 0
	return sc.scratch.total_used >= max(REDUCE_SCRATCH_MIN, REDUCE_SCRATCH_STATES * sc.kept, small)
}

// The state copied to the other home, and the scratch and the last home emptied.
@(private)
collect_scratch :: proc(x: ^Bind_Sink) {
	sc := x.scratch
	found := sc.scratch.total_used + sc.homes[sc.home].total_used
	next := &sc.homes[1 - sc.home]
	context.allocator = arena_allocator(next)
	x.state = copy_out(x.state, {&sc.scratch, &sc.homes[sc.home], nil}, x.owned)
	kept := next.total_used
	grown := kept - min(kept, sc.kept)
	sc.kept = kept
	free_all(arena_allocator(&sc.homes[sc.home]))
	free_all(arena_allocator(&sc.scratch))
	sc.home = 1 - sc.home
	sc.free_envs = nil
	x.ip.err = nil // the last caught error's, emptied with the scratch
	if found - min(found, kept) < 16 * grown {
		end_scratch(x, .Go, x.owned)
		x.scratch = nil
	}
}

@(private)
start_scratch :: proc(x: ^Bind_Sink) -> bool {
	sc := x.scratch
	if virtual.arena_init_growing(&sc.scratch) != nil {
		return false
	}
	if virtual.arena_init_growing(&sc.homes[0]) != nil || virtual.arena_init_growing(&sc.homes[1]) != nil {
		virtual.arena_destroy(&sc.scratch)
		virtual.arena_destroy(&sc.homes[0])
		return false
	}
	sc.on, sc.outside = true, context.allocator
	if x.owned != nil {
		// From here on only what the arenas hold changes in place, so what lies outside them holds only what
		// lies outside too, and `copy_out` keeps it as it is.
		x.owned^ = {}
	}
	return true
}

// The reduce's state, or its error, copied out of its arenas, which are then freed. `owned` is the
// table of an update that goes on changing the state in place.
@(private = "file")
end_scratch :: proc(x: ^Bind_Sink, sig: Signal, owned: ^Owned = nil) {
	sc := x.scratch
	context.allocator = sc.outside
	from := [3]^virtual.Arena{&sc.scratch, &sc.homes[0], &sc.homes[1]}
	if sig == .Go {
		x.state = copy_out(x.state, from, owned)
	} else if x.ip.err != nil {
		x.ip.err = copy_out(x.ip.err, from, nil)
	}
	virtual.arena_destroy(&sc.scratch)
	virtual.arena_destroy(&sc.homes[0])
	virtual.arena_destroy(&sc.homes[1])
	sc.on = false
}

@(private = "file")
reduce_update :: proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal {
	// The state is the update's last output so far, or null, also when it fails: jq takes the state out
	// of its variable for the update and stores each output, and a `?//` in the source that catches the
	// error goes on from there (`reduce ([1] as [$a] ?// $a | $a) as $x (5; if $x == 1 then error else . + 10 end)`
	// is 10).
	if x.owned != nil && !x.n.c.single {
		state, found, sig := add_last(x.ip, x.n.c, x.state, e, x.owned)
		x.state = state if found else nil
		return sig
	}
	if x.owned != nil {
		state, found, sig := update_value(x.ip, x.n.c, x.state, e, x.owned)
		x.state = state if found && sig == .Go else nil
		return sig
	}
	last := Last_Sink{sink = {emit = last_emit}}
	sig := eval(x.ip, x.n.c, in_state(x.state, st), e, x.track, &last)
	x.state = last.it.v
	return sig
}

// The outputs of a pipe's or a binding's left side `n` into `rest`, whose outputs go to the reduce or foreach `x`.
// Once `x` has a scratch, the rest runs in it for an output of `n`, and the scratch is collected after the rest, not
// between the updates it runs, as what the rest makes may live through them. Not for an output after one whose rest
// ran more than SOURCE_DEFERRED_MAX updates, which may make much between them: it runs as any source does, and a pipe
// in it may run its own outputs so.
@(private)
eval_sourced_outputs :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, rest: ^Sink, x: ^Bind_Sink) -> Signal {
	s := Source_Outputs{sink = {emit = sourced_emit}, rest = rest, reduce = x, long = true}
	return eval_commas(ip, n, input, env, false, &s)
}

SOURCE_DEFERRED_MAX :: 16

Source_Outputs :: struct {
	using sink: Sink,
	rest:       ^Sink,
	reduce:     ^Bind_Sink,
	long:       bool, // the last rest ran more than SOURCE_DEFERRED_MAX updates, or ran outside the scratch
}

// Whether a pipe or binding into `out` runs its outputs as `eval_sourced_outputs` has it: `out` is a reduce's or
// foreach's, and no rest runs in its scratch yet.
sources_outputs :: proc(out: ^Sink) -> bool {
	if out.emit != reduce_emit && out.emit != foreach_emit {
		return false
	}
	sc := (^Bind_Sink)(out).scratch
	return sc != nil && !sc.deferred
}

sourced_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Source_Outputs)(s)
	sc := x.reduce.scratch
	if x.long || sc == nil || !sc.on || sc.deferred {
		updates := sc.updates if sc != nil else 0
		sig := x.rest.emit(x.rest, it)
		x.long = sc == nil || !sc.on || sc.updates - updates > SOURCE_DEFERRED_MAX
		return sig
	}
	ip := x.reduce.ip
	context.allocator = arena_allocator(&sc.scratch)
	envs := ip.free_envs
	ip.free_envs = sc.free_envs
	sc.deferred = true
	updates := sc.updates
	sig := x.rest.emit(x.rest, it)
	sc.deferred = false
	sc.free_envs = ip.free_envs
	ip.free_envs = envs
	x.long = sc.updates - updates > SOURCE_DEFERRED_MAX
	if sig == .Go && collects(sc) {
		collect_scratch(x.reduce)
	}
	return sig
}

// The loop from an output of the init: the source runs in the init's path state, each update in the
// source output's, and each extract in the update's. An update that only writes into the state changes it
// in place, as a reduce's does (`foreach_extract`), if it has at most one output: each output is a state
// the extract sees, and each would be made from the state before the update.
foreach_init_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Bind_Sink)(s)
	f := x^
	f.sink.emit, f.state = foreach_emit, it.v
	owned: Owned
	if !x.track && x.n.c.single && in_place_update(x.n.c) {
		f.owned = &owned
	}
	scratch := Reduce_Scratch{in_place = f.owned != nil}
	if !x.track && (x.out == x.ip.printer || x.out.emit == scope_emit) {
		scratch.used, _ = arena_used(context.allocator)
		f.scratch = &scratch
	}
	outer := x.ip.owned
	x.ip.owned = f.owned
	defer x.ip.owned = outer
	source := x.input
	if x.track {
		source.path = placed(state_of(it), source.v)
	}
	sig := eval(x.ip, x.n.a, source, x.env, x.track, &f)
	if scratch.on {
		f.state = nil // its outputs are printed and gone
		end_scratch(&f, sig)
	}
	return sig
}

foreach_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Bind_Sink)(s)
	st := state_of(it)
	return bind_alternatives(x, it.v, foreach_step, &st if x.track else nil)
}

foreach_step :: proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal {
	if sc := x.scratch; sc != nil && (sc.on || scoped_from_here(x)) {
		return scoped_update(x, e, st, foreach_update)
	}
	return foreach_update(x, e, st)
}

@(private = "file")
foreach_update :: proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal {
	if x.owned != nil {
		state, found, sig := update_value(x.ip, x.n.c, x.state, e, x.owned)
		x.state = state if found else nil
		if sig != .Go || !found {
			return sig
		}
		return foreach_extract(x, e)
	}
	// An update with no output leaves the state null, as jq's does.
	step := x^
	step.env = e
	step.state = nil
	step.sink.emit = foreach_state_emit
	sig := eval(x.ip, x.n.c, in_state(x.state, st), e, x.track, &step)
	x.state = step.state
	return sig
}

foreach_state_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Bind_Sink)(s)
	x.state = it.v
	if x.n.d == nil {
		return x.out.emit(x.out, it)
	}
	return eval(x.ip, x.n.d, it, x.env, x.track, x.out)
}

// The extract on the state an in-place update left. What it outputs may be kept past the next update,
// which then must not change in place a container it holds: the update copies again from there.
foreach_extract :: proc(x: ^Bind_Sink, e: ^Env) -> Signal {
	v, check := foreach_view(x.n.c, x.state)
	out := Escape_Sink{sink = {emit = escape_emit}, owned = x.owned, out = x.out}
	to := &out.sink if check else x.out
	if x.n.d == nil {
		return to.emit(to, {v = v})
	}
	return eval(x.ip, x.n.d, {v = v}, e, false, to)
}

Escape_Sink :: struct {
	using sink: Sink,
	owned:      ^Owned,
	out:        ^Sink,
}

escape_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Escape_Sink)(s)
	budget := 64
	if len(x.owned) > 0 && holds_owned(it.v, x.owned, &budget) {
		clear(x.owned)
	}
	return x.out.emit(x.out, it)
}
