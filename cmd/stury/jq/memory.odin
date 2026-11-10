package jq

// Memory: the arenas outputs and inputs are made in, emptied between them, and values copied out of them.

import "base:intrinsics"
import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import core_pkg "../../../core"

// The allocator of a growing arena an input's document is built in. Emptying it keeps its first block and writes no
// zeros over it, and a shrink gives the last allocation's tail back without zeroing it, so a build's unused node room
// is never written: only `.Alloc` and `.Resize` promise zeros, and they write them over what they give. An output
// scope's arena, which takes many small allocations, keeps the virtual arena's own zeroing (`scope_allocator`).
arena_allocator :: proc(a: ^virtual.Arena) -> runtime.Allocator {
	return {arena_proc, a}
}

@(private = "file")
arena_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> (out: []byte, err: runtime.Allocator_Error) {
	arena := (^virtual.Arena)(data)
	switch mode {
	case .Free_All:
		for arena.curr_block != nil && arena.curr_block.prev != nil {
			virtual.arena_growing_free_last_memory_block(arena, loc)
		}
		if arena.curr_block != nil {
			arena.curr_block.used = 0
		}
		arena.total_used = 0
		return
	case .Resize, .Resize_Non_Zeroed:
		if old != nil && 0 < size && size <= old_size && uintptr(old) & uintptr(alignment - 1) == 0 {
			// The tail of the block's last allocation goes back to the block, so that it can grow again in place.
			if b := arena.curr_block; b != nil && uintptr(old) + uintptr(old_size) == uintptr(b.base) + uintptr(b.used) {
				b.used -= uint(old_size - size)
				arena.total_used -= uint(old_size - size)
			}
			return ([^]byte)(old)[:size], nil
		}
	case .Alloc, .Alloc_Non_Zeroed, .Free, .Query_Features, .Query_Info:
	}
	out, err = virtual.arena_allocator_proc(data, mode, size, alignment, old, old_size, loc)
	if err == nil && (mode == .Alloc || mode == .Resize) {
		kept := 0 if old == nil else min(old_size, len(out))
		intrinsics.mem_zero(raw_data(out[kept:]), len(out) - kept)
	}
	return
}

// What `a` has handed out, if it is an arena the interpreter evaluates in.
@(private)
arena_used :: proc(a: runtime.Allocator) -> (uint, bool) {
	if a.procedure != arena_proc {
		return 0, false
	}
	return (^virtual.Arena)(a.data).total_used, true
}

// The outputs of a pipe or a binding whose outputs are printed (`Interp.printer`): what the rest makes for each
// output of `n` (its left side) and the output itself, if `input` read it, is made in an arena that is emptied once
// the arena holds SCOPE_EMPTIED_FROM, between two outputs, when nothing made there is left: the rest has run, its
// outputs printed and gone, as jq's reference counts free them. One scope at a time: a pipe within the rest runs in
// the scope. What lives outside the arena is never changed to hold what is in it: values are immutable but for an
// update's own containers, which live and die within the rest. Scopes go to a free list of the arena's own. A
// document's decoding caches lie in the document's own memory, `input` reads into the arena only for the scope's own
// output, and an error, the one value that outlives the rest, fails the scope with the arena kept (one caught within
// the rest is let go with the arena: `ip.err`).
@(private)
eval_scoped_outputs :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, rest: ^Sink) -> Signal {
	sc := &ip.scope
	if !sc.ready {
		if virtual.arena_init_growing(&sc.arena) != nil {
			return eval_commas(ip, n, input, env, false, rest)
		}
		sc.ready = true
	}
	s := Scope_Sink{sink = {emit = scope_emit}, ip = ip, out = rest}
	sc.on = true
	sig := eval_commas(ip, n, input, env, false, &s)
	sc.on = false
	return sig
}

SCOPE_EMPTIED_FROM :: 256 << 10

// `ip` as a copy another thread runs on its own: it keeps none of the arenas, caches and messages of what it was copied
// from, which go on belonging to that interpreter.
detach_memory :: proc(ip: ^Interp) {
	ip.scope, ip.recycler, ip.faults, ip.text, ip.free_envs, ip.messages, ip.regions = {}, {}, {}, {}, nil, {}, nil
}

// The arenas a detached copy set up, given back once nothing it made is read.
free_detached :: proc(ip: ^Interp) {
	if ip.scope.ready {
		virtual.arena_destroy(&ip.scope.arena)
	}
	if ip.recycler.ready {
		virtual.arena_destroy(&ip.recycler.arenas[0])
		virtual.arena_destroy(&ip.recycler.arenas[1])
	}
	if ip.faults.ready {
		virtual.arena_destroy(&ip.faults.arenas[0])
		virtual.arena_destroy(&ip.faults.arenas[1])
	}
	free_regions(ip)
	detach_memory(ip)
}

// The memory `fail` makes an error's message in, `arenas[0]`, and the details it shows (`brief`) in, `arenas[1]`.
// A message is read until the next `fail` empties its arena: the error it raises is caught, and a handler reads a copy
// (`caught`), or it ends the run, before another can be raised. Details are read until their message is made.
Fault_Memory :: struct {
	arenas: [2]virtual.Arena,
	ready:  bool, // the arenas are set up
}

// The allocator of a new message, the last one's emptied, or of a detail: the context allocator if the arenas cannot
// be had.
@(private)
message_allocator :: proc(ip: ^Interp) -> runtime.Allocator {
	if !faults_ready(&ip.faults) {
		return context.allocator
	}
	a := arena_allocator(&ip.faults.arenas[0])
	free_all(a)
	return a
}

@(private)
detail_allocator :: proc(ip: ^Interp) -> runtime.Allocator {
	return arena_allocator(&ip.faults.arenas[1]) if faults_ready(&ip.faults) else context.allocator
}

@(private = "file")
faults_ready :: proc(f: ^Fault_Memory) -> bool {
	if !f.ready {
		if virtual.arena_init_growing(&f.arenas[0]) != nil {
			return false
		}
		if virtual.arena_init_growing(&f.arenas[1]) != nil {
			virtual.arena_destroy(&f.arenas[0])
			return false
		}
		f.ready = true
	}
	return true
}

@(private)
forget_details :: proc(ip: ^Interp) {
	if ip.faults.ready {
		free_all(arena_allocator(&ip.faults.arenas[1]))
	}
}

// `err`, a caught error, as a value that outlives the next `fail`.
@(private)
caught :: proc(ip: ^Interp, err: Value) -> Value {
	s, is_str := err.(string)
	if !is_str || !ip.faults.ready || !in_arena(&ip.faults.arenas[0], raw_data(s)) {
		return err
	}
	return strings.clone(s)
}

// Whether `p` lies in a block of `a`.
@(private = "file")
in_arena :: proc(a: ^virtual.Arena, p: rawptr) -> bool {
	for b := a.curr_block; b != nil; b = b.prev {
		if uintptr(b.base) <= uintptr(p) && uintptr(p) < uintptr(b.base) + uintptr(b.reserved) {
			return true
		}
	}
	return false
}

// The allocator of an output scope's arena: the virtual arena's, which keeps the memory past a block's use zeroed so
// that `.Alloc` writes nothing, but a shrink by KEPT_TAIL or more leaves the tail in use, neither given back nor
// zeroed, until the arena is emptied. A build's unused node room, reserved for a text as long as the file, is then
// never written: emptying lets the block made for it go whole.
@(private = "file")
scope_allocator :: proc(sc: ^Output_Scope) -> runtime.Allocator {
	return {scope_arena_proc, &sc.arena}
}

KEPT_TAIL :: 64 << 10

@(private = "file")
scope_arena_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return virtual.arena_alloc((^virtual.Arena)(data), uint(size), uint(alignment), loc)
	case .Resize, .Resize_Non_Zeroed:
		if old != nil && 0 < size && size <= old_size - KEPT_TAIL && uintptr(old) & uintptr(alignment - 1) == 0 {
			return ([^]byte)(old)[:size], nil
		}
	case .Free, .Free_All, .Query_Features, .Query_Info:
	}
	return virtual.arena_allocator_proc(data, mode, size, alignment, old, old_size, loc)
}

Output_Scope :: struct {
	arena:     virtual.Arena,
	ready:     bool, // the arena is set up
	on:        bool, // a pipe or binding runs in it
	free_envs: ^Env, // scopes made in the arena, given back
}

Scope_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	out:        ^Sink,
}

scope_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Scope_Sink)(s)
	ip := x.ip
	sc := &ip.scope
	context.allocator = scope_allocator(sc)
	envs := ip.free_envs
	ip.free_envs = sc.free_envs
	sig := x.out.emit(x.out, it)
	sc.free_envs = ip.free_envs
	ip.free_envs = envs
	if sig == .Go && sc.arena.total_used >= SCOPE_EMPTIED_FROM {
		virtual.arena_free_all(&sc.arena)
		sc.free_envs = nil
		ip.err = nil // the last caught error's, emptied with the arena
	}
	return sig
}

// The allocator of the arena an output given to `out` may be made in, as `out` holds nothing of it once it has taken
// it but what it copies out: a scope's, and a reduce's or foreach's scratch once on, when it binds the output to a
// variable (a pattern may run the update more than once, reading the output after a copy freed it).
// False for any other sink.
item_arena :: proc(ip: ^Interp, out: ^Sink) -> (runtime.Allocator, bool) {
	if out.emit == scope_emit {
		return scope_allocator(&ip.scope), true
	}
	if out.emit == reduce_emit || out.emit == foreach_emit {
		x := (^Bind_Sink)(out)
		if sc := x.scratch; sc != nil && sc.on && len(x.n.patterns) == 1 && x.n.patterns[0].kind == .Var {
			return arena_allocator(&sc.scratch), true
		}
	}
	return {}, false
}

// `[a | b]` with `b` run for each output of `a` in a region, an arena of its own, once what `b` makes has grown the
// collect's memory by SCOPE_EMPTIED_FROM and REGION_ITEM_MIN per item: the region is emptied between two outputs of
// `a` once it holds as much, after the items `b` made there are copied out, as jq's reference counts free what `b` drops. Nothing else made in
// the region outlives `b`'s run, as in an output scope (`eval_scoped_outputs`), but an error, copied out with the
// items. A region that holds little but its items is given back and the collect goes on in its memory.
@(private)
collect_regioned :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, into: ^[dynamic]Value) -> Signal {
	x := region_collect(ip, n.b, env, into)
	return end_region_collect(&x, eval_commas(ip, n.a, input, env, false, &x))
}

// A collect of `b`'s outputs into `into`, each input given to it by `emit`, regioned as `collect_regioned` has it.
Region_Collect :: struct {
	using sink: Sink,
	ip:         ^Interp,
	b:          ^Node,
	env:        ^Env,
	items:      Collect_Sink,
	outside:    runtime.Allocator, // the collect's memory
	start:      uint, // what the collect's memory had handed out when it began, max(uint) if it cannot tell
	first:      int, // the items it held then
	inputs:     uint, // the inputs given to `b` outside a region
	region:     ^Region,
	from:       int, // the first item that may lie in the region
}

region_collect :: proc(ip: ^Interp, b: ^Node, env: ^Env, into: ^[dynamic]Value) -> Region_Collect {
	x := Region_Collect{sink = {emit = region_collect_emit}, ip = ip, b = b, env = env, items = {sink = {emit = collect_emit}, into = into}, outside = context.allocator}
	used, ok := arena_used(context.allocator)
	x.start, x.first = used if ok else max(uint), len(into)
	return x
}

// `sig`, with the items, or the error, left in the region copied out of it.
end_region_collect :: proc(x: ^Region_Collect, sig: Signal) -> Signal {
	r := x.region
	if r == nil {
		return sig
	}
	context.allocator = x.outside
	from := [3]^virtual.Arena{&r.arena, nil, nil}
	if sig == .Go {
		copy_all_out(x.items.into[x.from:], from, nil)
	} else if x.ip.err != nil {
		x.ip.err = copy_out(x.ip.err, from, nil)
	}
	give_region(x.ip, r)
	x.region = nil
	return sig
}

// What `b` makes per item before a collect takes a region: less is mostly the items themselves, which a region
// would only copy.
REGION_ITEM_MIN :: 1 << 9
// A region whose items take more than 1/REGION_KEPT_MAX of it costs more to copy out than it gives back.
REGION_KEPT_MAX :: 4
// How often a collect outside a region checks whether to take one, in inputs, after the first few.
REGION_CHECKED_EVERY :: 64

// Whether a collect or a `last` checks at its `n`th input whether to take a region: at each power of two, so that a
// few inputs that make much are seen, and then each REGION_CHECKED_EVERY.
@(private = "file")
region_checked :: #force_inline proc(n: uint) -> bool {
	return n % REGION_CHECKED_EVERY == 0 || n & (n - 1) == 0
}

// An arena a collect runs `b` in, kept for the next once given back. Aligned to a cache line pair, since threads lock
// their regions' arenas on every allocation.
Region :: struct #align(128) {
	arena:     virtual.Arena,
	free_envs: ^Env, // scopes made in the arena, given back
	next:      ^Region, // the next region given back
}

@(private = "file")
region_collect_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Region_Collect)(s)
	ip := x.ip
	if x.region == nil {
		x.inputs += 1
		if !region_checked(x.inputs) || !take_region_now(x) {
			return eval(ip, x.b, it, x.env, false, &x.items)
		}
	}
	r := x.region
	context.allocator = arena_allocator(&r.arena)
	envs := ip.free_envs
	ip.free_envs = r.free_envs
	sig := eval(ip, x.b, it, x.env, false, &x.items)
	r.free_envs = ip.free_envs
	ip.free_envs = envs
	if sig == .Go && r.arena.total_used >= SCOPE_EMPTIED_FROM {
		empty_region(x)
	}
	return sig
}

// Whether `x` takes a region from here: what `b` made for the items so far is more than they could be. A collect
// whose first REGION_CHECKED_EVERY inputs made less takes none, and runs `b` without looking again.
@(private = "file")
take_region_now :: #force_no_inline proc(x: ^Region_Collect) -> bool {
	used, ok := arena_used(context.allocator)
	made := used - min(used, x.start)
	items := len(x.items.into) - x.first
	switch {
	case !ok || x.start == max(uint) || made < REGION_ITEM_MIN * uint(items):
		if x.inputs >= REGION_CHECKED_EVERY {
			x.sink.emit = unregioned_emit
		}
		return false
	case made < SCOPE_EMPTIED_FROM:
		return false
	}
	x.region, x.from = take_region(x.ip), len(x.items.into)
	if x.region == nil {
		x.sink.emit = unregioned_emit
	}
	return x.region != nil
}

@(private = "file")
unregioned_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Region_Collect)(s)
	return eval(x.ip, x.b, it, x.env, false, &x.items)
}

// The items made in the region copied out, and the region emptied, or given back if they took much of it.
@(private = "file")
empty_region :: proc(x: ^Region_Collect) {
	r := x.region
	context.allocator = x.outside
	held := r.arena.total_used
	before, _ := arena_used(x.outside)
	copy_all_out(x.items.into[x.from:], {&r.arena, nil, nil}, nil)
	after, _ := arena_used(x.outside)
	x.from = len(x.items.into)
	x.ip.err = nil // the last caught error's, emptied with the region
	if REGION_KEPT_MAX * (after - min(after, before)) >= held {
		give_region(x.ip, r)
		x.region, x.sink.emit = nil, unregioned_emit
		return
	}
	free_all(arena_allocator(&r.arena))
	r.free_envs = nil
}

// The outputs of a pipe's or a binding's left side `n` into `rest`, whose outputs go to `last(f)`'s sink: once what the
// rest makes has grown the memory by SCOPE_EMPTIED_FROM, it runs in a region, emptied between two outputs once it
// holds as much, after the output `last` keeps is copied to one of two homes, the other emptied, as jq's reference
// counts free the outputs `last` drops. What `last` keeps at the end, or an error, is copied out to the memory it
// began in.
@(private)
eval_kept_outputs :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, rest: ^Sink, last: ^Last_Sink) -> Signal {
	used, ok := arena_used(context.allocator)
	if !ok {
		return eval_commas(ip, n, input, env, false, rest)
	}
	last.kept = true
	x := Kept_Outputs{sink = {emit = kept_emit}, ip = ip, rest = rest, last = last, outside = context.allocator, start = used}
	sig := eval_commas(ip, n, input, env, false, &x)
	last.kept = false
	context.allocator = x.outside
	from := [3]^virtual.Arena{}
	for r, i in ([3]^Region{x.region, x.homes[0], x.homes[1]}) {
		if r != nil {
			from[i] = &r.arena
		}
	}
	if sig == .Go && last.found {
		last.it.v = copy_out(last.it.v, from, nil)
	} else if sig != .Go && ip.err != nil {
		ip.err = copy_out(ip.err, from, nil)
	}
	for r in ([3]^Region{x.region, x.homes[0], x.homes[1]}) {
		if r != nil {
			give_region(ip, r)
		}
	}
	return sig
}

@(private = "file")
Kept_Outputs :: struct {
	using sink: Sink,
	ip:         ^Interp,
	rest:       ^Sink,
	last:       ^Last_Sink,
	outside:    runtime.Allocator, // the memory `last` began in
	start:      uint, // what it had handed out then
	inputs:     uint, // the inputs given to the rest outside a region
	region:     ^Region,
	homes:      [2]^Region, // `last`'s output copied out of the region, into `homes[home]`
	home:       int,
}

@(private = "file")
kept_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Kept_Outputs)(s)
	ip := x.ip
	if x.region == nil {
		x.inputs += 1
		if !region_checked(x.inputs) || !keep_in_region(x) {
			return x.rest.emit(x.rest, it)
		}
	}
	r := x.region
	context.allocator = arena_allocator(&r.arena)
	envs := ip.free_envs
	ip.free_envs = r.free_envs
	sig := x.rest.emit(x.rest, it)
	r.free_envs = ip.free_envs
	ip.free_envs = envs
	if sig == .Go && r.arena.total_used >= SCOPE_EMPTIED_FROM {
		move_kept(x)
	}
	return sig
}

// Whether the rest runs in a region from here, as it has made SCOPE_EMPTIED_FROM.
@(private = "file")
keep_in_region :: #force_no_inline proc(x: ^Kept_Outputs) -> bool {
	used, _ := arena_used(context.allocator)
	if used - min(used, x.start) < SCOPE_EMPTIED_FROM {
		return false
	}
	x.region = take_region(x.ip)
	x.start = max(uint) if x.region == nil else x.start
	return x.region != nil
}

// `last`'s output copied to the home not holding it, the region and the other home emptied. Without a home to copy
// to, it is copied out to the memory `last` began in, which the rest goes on in.
@(private = "file")
move_kept :: proc(x: ^Kept_Outputs) {
	to := &x.homes[1 - x.home]
	if to^ == nil {
		to^ = take_region(x.ip)
	}
	at := x.homes[x.home]
	if x.last.found {
		context.allocator = arena_allocator(&to^.arena) if to^ != nil else x.outside
		x.last.it.v = copy_out(x.last.it.v, {&x.region.arena, &at.arena if at != nil else nil, nil}, nil)
	}
	x.ip.err = nil // the last caught error's, emptied with the region
	if to^ == nil {
		give_region(x.ip, x.region)
		x.region, x.start = nil, max(uint)
		if at != nil {
			give_region(x.ip, at)
			x.homes[x.home] = nil
		}
		return
	}
	free_all(arena_allocator(&x.region.arena))
	x.region.free_envs = nil
	if at != nil {
		free_all(arena_allocator(&at.arena))
	}
	x.home = 1 - x.home
}

// The regions `ip` keeps, given back to the system.
free_regions :: proc(ip: ^Interp) {
	for r := ip.regions; r != nil; {
		next := r.next
		virtual.arena_destroy(&r.arena)
		free(r, runtime.heap_allocator())
		r = next
	}
	ip.regions = nil
}

@(private = "file")
take_region :: proc(ip: ^Interp) -> ^Region {
	if r := ip.regions; r != nil {
		ip.regions = r.next
		return r
	}
	r := new(Region, runtime.heap_allocator())
	if r == nil {
		return nil
	}
	if virtual.arena_init_growing(&r.arena) != nil {
		free(r, runtime.heap_allocator())
		return nil
	}
	return r
}

@(private = "file")
give_region :: proc(ip: ^Interp, r: ^Region) {
	free_all(arena_allocator(&r.arena))
	r.free_envs = nil
	r.next = ip.regions
	ip.regions = r
}

// Memory `inputs` reads into when what takes its outputs keeps none of them (`recycled_inputs`).
Input_Recycler :: struct {
	arenas:    [2]virtual.Arena,
	free_envs: [2]^Env, // scopes made in each arena, given back
	ready:     bool, // the arenas are set up
	on:        bool, // an `inputs` reads into them
}

// What keeps something of an output given to `out` once `out` returns: nothing (it is printed, or
// dropped), `last`'s sink, or a reduce's or a foreach's that has a scratch. Each sink on the way passes
// the output on and keeps nothing of it: a pipe's, a binding's, `limit`'s, `skip`'s, `isempty`'s and a
// `try`'s. `ok` is false for any other sink, which may keep what it likes.
@(private = "file")
input_keeper :: proc(ip: ^Interp, out: ^Sink) -> (last: ^Last_Sink, reduce: ^Bind_Sink, ok: bool) {
	s := out
	for {
		switch e := s.emit; {
		case s == ip.printer || e == scope_emit:
			return nil, nil, true
		case e == last_emit:
			return (^Last_Sink)(s), nil, true
		case e == reduce_emit || e == foreach_emit:
			// one taking `inputs` itself reads into its scratch already (`item_arena`)
			x := (^Bind_Sink)(s)
			return nil, x, s != out && x.scratch != nil
		case e == pipe_emit:
			s = (^Pipe_Sink)(s).out
		case e == bind_emit:
			s = (^Bind_Sink)(s).out
		case e == sourced_emit:
			s = (^Source_Outputs)(s).rest
		case e == guard_emit:
			s = (^Guard_Sink)(s).out
		case e == limit_emit || e == skip_emit || e == isempty_emit:
			s = (^Native_Sink)(s).out
		case:
			return nil, nil, false
		}
	}
}

// `inputs` into `out` where `out` keeps nothing of an input once it has taken it but what `input_keeper` finds: each
// input, and what is made of it, lies in an arena emptied once it holds SCOPE_EMPTIED_FROM between two inputs, as
// jq's reference counts free an input once it is past. What `last` keeps lies in the other of the two arenas, swapped
// as it takes a new output, and is copied out at the end, as an error is. Into a reduce or a foreach,
// `scratch_inputs`. It returns false when the arenas are another `inputs`' or cannot be had.
recycled_inputs :: proc(ip: ^Interp, input: Item, out: ^Sink) -> (sig: Signal, ok: bool) {
	last, reduce := input_keeper(ip, out) or_return
	if reduce != nil {
		return scratch_inputs(ip, input, out, reduce), true
	}
	r := &ip.recycler
	if r.on {
		return
	}
	if !r.ready {
		if virtual.arena_init_growing(&r.arenas[0]) != nil {
			return
		}
		if virtual.arena_init_growing(&r.arenas[1]) != nil {
			virtual.arena_destroy(&r.arenas[0])
			return
		}
		r.ready = true
	}
	r.on = true
	outside := context.allocator
	envs := ip.free_envs
	cur := 0
	for {
		context.allocator = arena_allocator(&r.arenas[cur])
		ip.free_envs = r.free_envs[cur]
		found := false
		if last != nil {
			found, last.found = last.found, false
		}
		v, msg, status := ip.inputs.next(ip.inputs.data)
		sig = input_signal(ip, v, msg, status, input, false, out)
		r.free_envs[cur] = ip.free_envs
		took := last != nil && last.found
		if last != nil {
			last.found ||= found
		}
		if sig != .Go || status != .Value {
			break
		}
		if took {
			cur = 1 - cur
			empty_recycled(ip, cur)
		} else if r.arenas[cur].total_used >= SCOPE_EMPTIED_FROM {
			empty_recycled(ip, cur)
		}
	}
	ip.free_envs = envs
	context.allocator = outside
	from := [3]^virtual.Arena{&r.arenas[0], &r.arenas[1], nil}
	if last != nil && last.found {
		last.it.v = copy_out(last.it.v, from, nil)
	}
	if sig == .Fail {
		ip.err = copy_out(ip.err, from, nil)
	}
	r.on = false
	return sig, true
}

@(private = "file")
empty_recycled :: proc(ip: ^Interp, i: int) {
	r := &ip.recycler
	free_all(arena_allocator(&r.arenas[i]))
	r.free_envs[i] = nil
	ip.err = nil // the last caught error's, emptied with the arena
}

// `inputs` into a reduce or a foreach `x` through sinks that keep nothing: each input, and what is made of
// it, in the scratch, and the state copied out of it between inputs, not between the updates an input runs,
// which may read it (`reduce (inputs | select(.ok)) as $x (0; . + $x.n)`). The scratch is on from the first
// input: each is a document, and those a source drops before the REDUCE_SCOPED_FROM updates that would start
// it are otherwise held for the run.
@(private = "file")
scratch_inputs :: proc(ip: ^Interp, input: Item, out: ^Sink, x: ^Bind_Sink) -> Signal {
	outside := context.allocator
	if sc := x.scratch; sc != nil && !sc.on && !start_scratch(x) {
		x.scratch = nil // out of memory for the arenas: the reduce goes on unscoped
	}
	for {
		sc := x.scratch
		on := sc != nil && sc.on
		context.allocator = arena_allocator(&sc.scratch) if on else outside
		envs := ip.free_envs
		if on {
			ip.free_envs = sc.free_envs
		}
		if sc != nil {
			sc.deferred = true
		}
		v, msg, status := ip.inputs.next(ip.inputs.data)
		sig := input_signal(ip, v, msg, status, input, false, out)
		if on {
			sc.free_envs = ip.free_envs
			ip.free_envs = envs
		}
		if sc != nil {
			sc.deferred = false
			if sig == .Go && sc.on && collects(sc) {
				collect_scratch(x)
			}
		}
		if sig != .Go || status != .Value {
			return sig
		}
	}
}

// `v` with what the arenas `from` hold made anew in the context allocator, each container and each string of
// COPY_SHARED_FROM bytes or more once however often it is shared, as jq shares them by reference counts (a shorter
// string's copies take at most a few times the slots that hold it), and each document (an input read there) whole,
// rows and text, once. The rest outlives the arenas and is kept. `owned`, if given, is emptied and then holds each
// container made that `v` holds once: the copy is shared with nothing outside `v`, so an update that changes the state
// in place goes on doing so (a table left in the scratch would be emptied with it).
@(private)
copy_out :: proc(v: Value, from: [3]^virtual.Arena, owned: ^Owned) -> Value {
	v := v
	copy_all_out(([^]Value)(&v)[:1], from, owned)
	return v
}

// Each of `vs` as `copy_out` makes it, what they share made once.
@(private)
copy_all_out :: proc(vs: []Value, from: [3]^virtual.Arena, owned: ^Owned) {
	if owned != nil {
		owned^ = {}
	}
	heap := runtime.heap_allocator()
	c := Copier{owned = owned, made = make(map[Copied]Value, allocator = heap), spans = make([dynamic][2]uintptr, heap)}
	defer delete(c.made)
	defer delete(c.spans)
	for a in from {
		for b := a.curr_block if a != nil else nil; b != nil; b = b.prev {
			append(&c.spans, [2]uintptr{uintptr(b.base), uintptr(b.base) + uintptr(b.reserved)})
		}
	}
	slice.sort_by(c.spans[:], proc(a, b: [2]uintptr) -> bool {return a[0] < b[0]})
	if len(c.spans) > 0 {
		c.lo, c.hi = c.spans[0][0], slice.last(c.spans[:])[1]
	}
	for &v in vs {
		v = copy_value(&c, v)
	}
}

@(private = "file")
COPY_SHARED_FROM :: 64

@(private = "file")
Copier :: struct {
	owned: ^Owned,
	made:  map[Copied]Value,
	spans: [dynamic][2]uintptr, // the arenas' blocks, by address
	lo:    uintptr, // the first block's start
	hi:    uintptr, // the last block's end
}

// A container (`n` -1) or the bytes of a string, copied.
@(private = "file")
Copied :: struct {
	p: rawptr,
	n: int,
}

@(private = "file")
copy_value :: proc(c: ^Copier, v: Value) -> Value {
	switch x in v {
	case nil, bool, f64:
	case Ref:
		if !held(c, x.doc) {
			return v
		}
		if m, ok := c.made[{x.doc, -1}]; ok {
			return Ref{m.(Ref).doc, x.node}
		}
		d := new(core_pkg.Document)
		d^, _ = core_pkg.clone(x.doc)
		d.src = transmute([]byte)copy_string(c, string(x.doc.src))
		c.made[{x.doc, -1}] = Ref{d, core_pkg.ROOT}
		return Ref{d, x.node}
	case ^Number_Text:
		text := copy_string(c, x.text)
		if raw_data(text) == raw_data(x.text) && !held(c, x) {
			return x
		}
		made := new_clone(x^)
		made.text = text
		return made
	case string:
		return copy_string(c, x)
	case ^Array:
		// A slice made outside the arenas may share the items of an array in them.
		if !held(c, x) && !held(c, raw_data(x.items)) {
			return v
		}
		if m, ok := c.made[{x, -1}]; ok {
			return shared(c, m)
		}
		a := new_array(len(x.items))
		non_zero_resize(&a.items, len(x.items))
		for m, i in x.items {
			a.items[i] = copy_value(c, m)
		}
		return made_container(c, x, a)
	case Path:
		if m, ok := c.made[{x, -1}]; ok {
			return shared(c, m)
		}
		a := path_array((^Path_Step)(x))
		for &m in a.items {
			m = copy_value(c, m)
		}
		return made_container(c, rawptr(x), a)
	case ^Object:
		if !held(c, x) {
			return v
		}
		if m, ok := c.made[{x, -1}]; ok {
			return shared(c, m)
		}
		o := new_object()
		o.keys = make([dynamic]string, 0, len(x.keys))
		o.vals = make([dynamic]Value, 0, len(x.vals))
		for k, i in x.keys {
			append(&o.keys, copy_string(c, k))
			append(&o.vals, copy_value(c, x.vals[i]))
		}
		if len(x.index) > 0 {
			o.index = make(map[string]int, len(o.keys))
			for k, i in o.keys {
				o.index[k] = i
			}
		}
		return made_container(c, x, o)
	case ^Commented:
		w := new(Commented)
		w^ = x^
		w.v = copy_value(c, x.v)
		for &bodies in w.bodies {
			bodies = slice.clone(bodies)
			for &b in bodies {
				b = copy_string(c, b)
			}
		}
		return w
	}
	return v
}

// A container the copy reaches a second time, which `owned` no longer records, nor anything in it: with two holders,
// none is changed in place.
@(private = "file")
shared :: proc(c: ^Copier, v: Value) -> Value {
	if c.owned != nil && c.owned[container(v)] {
		disown(v, c.owned)
	}
	return v
}

// The container `made` for `from`, which `owned` records when the copy is for a reduce or foreach.
@(private = "file")
made_container :: proc(c: ^Copier, from: rawptr, made: $T) -> T {
	c.made[{from, -1}] = made
	if c.owned != nil {
		c.owned[rawptr(made)] = true
	}
	return made
}

@(private = "file")
copy_string :: proc(c: ^Copier, s: string) -> string {
	p := raw_data(s)
	if len(s) == 0 || !held(c, p) {
		return s
	}
	if len(s) < COPY_SHARED_FROM {
		return strings.clone(s)
	}
	if m, ok := c.made[{p, len(s)}]; ok {
		return m.(string)
	}
	t := strings.clone(s)
	c.made[{p, len(s)}] = t
	return t
}

// Whether `p` lies in one of the arenas copied from.
@(private = "file")
held :: proc(c: ^Copier, p: rawptr) -> bool {
	at := uintptr(p)
	if at < c.lo || c.hi <= at {
		return false
	}
	lo, hi := 0, len(c.spans)
	for lo < hi {
		mid := (lo + hi) / 2
		if c.spans[mid][0] <= at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo > 0 && at < c.spans[lo - 1][1]
}
