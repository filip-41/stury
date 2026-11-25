package jq

import "base:runtime"
import "stury:lib/query"

// Scopes and the frame stack of the evaluator.

// A run-time scope: the slots a binding, a label or a call with parameters makes, over the scope it was made in. Held by
// a count: the evaluator's register, frames, the scopes made over it and closures each hold one.
@(private)
Env :: struct {
	using block: query.Block,
	parent:      ^Env,
	count:       u16,
	closures:    bool, // the slots hold closures, else values
	_:           [13 - size_of(rawptr)]u8, // the slots after it start 8-aligned on every target
}

#assert(size_of(Env) == 24)

// A filter argument: the node the caller wrote and the scope it runs in.
@(private)
Closure :: struct {
	node: ^Node,
	env:  ^Env, // held
}

@(private)
Slot :: struct #raw_union {
	value:   query.Value,
	closure: Closure,
}

#assert(size_of(Slot) == 16)

@(private)
env_slots :: #force_inline proc "contextless" (e: ^Env) -> [^]Slot {
	return ([^]Slot)(uintptr(e) + size_of(Env))
}

// A scope of `count` slots over `parent`, which it holds, the slots zero: absent values, or closures of no node.
@(private)
new_env :: proc(m: ^Machine, parent: ^Env, count: int, closures: bool) -> (e: ^Env, status: query.Status) {
	b := query.alloc_block(m.h, size_of(Env) + count * size_of(Slot)) or_return
	e = (^Env)(b)
	e.parent, e.count, e.closures = env_retain(parent), u16(count), closures
	runtime.mem_zero(env_slots(e), count * size_of(Slot))
	return e, .Ok
}

@(private)
env_retain :: #force_inline proc "contextless" (e: ^Env) -> ^Env {
	if e != nil {
		e.rc += 1
	}
	return e
}

// Gives up a reference to `e`, freeing it and what only it held, scope chains and closures alike, with no recursion.
@(private)
env_release :: proc(m: ^Machine, e: ^Env) {
	if e == nil {
		return
	}
	e.rc -= 1
	if e.rc != 0 {
		return
	}
	env_free(m, e)
}

@(private)
env_free :: #force_no_inline proc(m: ^Machine, first: ^Env) {
	pending: [dynamic]^Env
	defer delete(pending)
	e := first
	for {
		for e != nil {
			slots := env_slots(e)
			for i in 0 ..< int(e.count) {
				if e.closures {
					if c := slots[i].closure.env; c != nil {
						c.rc -= 1
						if c.rc == 0 {
							if pending.allocator.procedure == nil {
								pending = make([dynamic]^Env, 0, 4, m.h.allocator)
							}
							append(&pending, c)
						}
					}
				} else {
					query.release(m.h, slots[i].value)
				}
			}
			next := e.parent
			query.give_back(m.h, e, size_of(Env) + int(e.count) * size_of(Slot))
			e = nil
			if next != nil {
				next.rc -= 1
				if next.rc == 0 {
					e = next
				}
			}
		}
		if len(pending) == 0 {
			break
		}
		e = pop(&pending)
	}
}

// The scope `hops` up from `e`.
@(private)
env_up :: #force_inline proc "contextless" (e: ^Env, hops: u32) -> ^Env {
	x := e
	for _ in 0 ..< hops {
		x = x.parent
	}
	return x
}

// Sets value slot `i` of `e`, which takes `v`, giving up what it held.
@(private)
env_set :: #force_inline proc(m: ^Machine, e: ^Env, i: u16, v: query.Value) {
	s := &env_slots(e)[i]
	query.release(m.h, s.value)
	s.value = v
}

// ---- The frame stack

@(private)
Frame_Kind :: enum u8 {
	Pipe,
	Comma,
	Collect,
	Tally,
	Iter,
	Range,
	If,
	Bin_R,
	Bin_L,
	Truth,
	Neg,
	Format,
	Step,
	Key,
	Bind,
	Alternative,
	Destruct,
	Alt,
	Try,
	Out,
	Label,
	Limit,
	Skip,
	Cut,
	Isempty,
	Last,
	Select,
	Path,
	Reduce,
	Reduce_Update,
	Foreach,
	Foreach_Update,
	Args,
	Arg,
	Update,
	Update_Each,
	Gen,
	Css,
}

// The header of every frame: what kind it is, where its outputs go and the frame below it.
@(private)
Frame :: struct {
	kind:  Frame_Kind,
	track: bool, // its outputs carry paths
	_:     u16,
	size:  u32,
	below: ^Frame,
	k:     ^Frame,
}

@(private)
CHUNK_BYTES :: 64 << 10

@(private)
Chunk :: struct {
	using block: query.Block,
	prev:        ^Chunk,
	end:         uintptr,
}

@(private)
Stack :: struct {
	top:   ^Frame,
	at:    uintptr, // the next free byte of `chunk`
	chunk: ^Chunk,
	spare: ^Chunk,
	depth: int,
}

// A frame of type `T` on the stack, its header set and the rest zero.
@(private)
push :: #force_inline proc(m: ^Machine, $T: typeid, kind: Frame_Kind, k: ^Frame) -> (f: ^T, status: query.Status) {
	size := uintptr(size_of(T) + 15) &~ 15
	s := &m.stack
	if s.chunk == nil || s.at + size > s.chunk.end {
		stack_grow(m, int(size)) or_return
	}
	f = (^T)(s.at)
	s.at += size
	f^ = {}
	f.kind, f.size, f.below, f.k = kind, u32(size), s.top, k
	s.top = f
	s.depth += 1
	return f, .Ok
}

@(private)
stack_grow :: #force_no_inline proc(m: ^Machine, size: int) -> query.Status {
	s := &m.stack
	c := s.spare
	s.spare = nil
	if c == nil {
		bytes := max(CHUNK_BYTES, size + size_of(Chunk))
		b := query.alloc_block(m.h, bytes) or_return
		c = (^Chunk)(b)
		c.end = uintptr(c) + uintptr(bytes)
	}
	c.prev = s.chunk
	s.chunk = c
	s.at = (uintptr(c) + size_of(Chunk) + 15) &~ 15
	return .Ok
}

// Pops the top frame, which stays readable until the next push.
@(private)
pop_frame :: #force_inline proc(m: ^Machine) {
	s := &m.stack
	f := s.top
	s.top = f.below
	s.depth -= 1
	s.at = uintptr(f)
	if s.at == (uintptr(s.chunk) + size_of(Chunk) + 15) &~ 15 && s.chunk.prev != nil {
		stack_shrink(m)
	}
}

@(private)
stack_shrink :: #force_no_inline proc(m: ^Machine) {
	s := &m.stack
	c := s.chunk
	s.chunk = c.prev
	if s.spare != nil {
		query.give_back(m.h, (^query.Block)(s.spare), int(s.spare.end - uintptr(s.spare)))
	}
	s.spare = c
	s.at = uintptr(s.top) + uintptr(s.top.size) if s.top != nil else (uintptr(s.chunk) + size_of(Chunk) + 15) &~ 15
}

@(private)
stack_destroy :: proc(m: ^Machine) {
	s := &m.stack
	for c := s.chunk; c != nil; {
		prev := c.prev
		query.give_back(m.h, (^query.Block)(c), int(c.end - uintptr(c)))
		c = prev
	}
	if s.spare != nil {
		query.give_back(m.h, (^query.Block)(s.spare), int(s.spare.end - uintptr(s.spare)))
	}
	s^ = {}
}
