package jq

// Memory: the arenas outputs and inputs are made in, emptied between them, and values copied out of them.

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import json "../../../json"

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
	context.allocator = virtual.arena_allocator(&sc.arena)
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

// The arena an output given to `out` may be made in, as `out` holds nothing of it once it has taken it but
// what it copies out: a scope's, and a reduce's or foreach's scratch once on, when it binds the output to a
// variable (a pattern may run the update more than once, reading the output after a copy freed it).
// Nil for any other sink.
item_arena :: proc(ip: ^Interp, out: ^Sink) -> ^virtual.Arena {
	if out.emit == scope_emit {
		return &ip.scope.arena
	}
	if out.emit == reduce_emit || out.emit == foreach_emit {
		x := (^Bind_Sink)(out)
		if sc := x.scratch; sc != nil && sc.on && len(x.n.patterns) == 1 && x.n.patterns[0].kind == .Var {
			return &sc.scratch
		}
	}
	return nil
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
		context.allocator = virtual.arena_allocator(&r.arenas[cur])
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
	virtual.arena_free_all(&r.arenas[i])
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
		context.allocator = virtual.arena_allocator(&sc.scratch) if on else outside
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
// container made: the copy is shared with nothing, so an update that changes the state in place goes on doing so (a
// table left in the scratch would be emptied with it).
@(private)
copy_out :: proc(v: Value, from: [3]^virtual.Arena, owned: ^Owned) -> Value {
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
	return copy_value(&c, v)
}

@(private = "file")
COPY_SHARED_FROM :: 64

@(private = "file")
Copier :: struct {
	owned: ^Owned,
	made:  map[Copied]Value,
	spans: [dynamic][2]uintptr, // the arenas' blocks, by address
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
	case nil, bool:
	case Ref:
		if !held(c, x.doc) {
			return v
		}
		if m, ok := c.made[{x.doc, -1}]; ok {
			return Ref{m.(Ref).doc, x.node}
		}
		// The rows and the text, and what the scan decoded. What was decoded since is decoded again.
		d := new(json.Document)
		d^ = {src = transmute([]byte)copy_string(c, string(x.doc.src)), dialect = x.doc.dialect, deep = x.doc.deep}
		d.rows = slice.clone_to_dynamic(x.doc.rows[:])
		d.values = slice.clone_to_dynamic(x.doc.values[:])
		d.facts = slice.clone_to_dynamic(x.doc.facts[:])
		c.made[{x.doc, -1}] = Ref{d, json.ROOT}
		return Ref{d, x.node}
	case Number:
		return Number{f = x.f, lit = copy_string(c, x.lit)}
	case string:
		return copy_string(c, x)
	case ^Array:
		if !held(c, x) {
			return v
		}
		if m, ok := c.made[{x, -1}]; ok {
			return m
		}
		a := new_array(len(x.items))
		append(&a.items, ..x.items[:]) // one block; only the members that point into the arenas are made anew
		for &m in a.items {
			switch t in m {
			case nil, bool:
			case Number:
				if len(t.lit) > 0 {
					m = copy_value(c, m)
				}
			case string, ^Array, ^Object, Ref, Path:
				m = copy_value(c, m)
			}
		}
		c.made[{x, -1}] = a
		if c.owned != nil {
			c.owned[a] = true
		}
		return a
	case Path:
		if m, ok := c.made[{x, -1}]; ok {
			return m
		}
		a := path_array((^Path_Step)(x))
		for &m in a.items {
			m = copy_value(c, m)
		}
		c.made[{x, -1}] = a
		if c.owned != nil {
			c.owned[a] = true
		}
		return a
	case ^Object:
		if !held(c, x) {
			return v
		}
		if m, ok := c.made[{x, -1}]; ok {
			return m
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
		c.made[{x, -1}] = o
		if c.owned != nil {
			c.owned[o] = true
		}
		return o
	}
	return v
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
