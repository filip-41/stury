package core

// Which plan a typed call runs: the caller's, a format's per-thread cached one, or a temporary one. `P` is the
// format's plan, made by its `init` and freed by its `destroy`, whose `root` is the type it was made for.

import "base:runtime"

// How many types a thread's plan cache holds.
PLAN_CACHE_TYPES :: 16

// The plans calls made without one use, held by the format per thread (`@(thread_local)`) so no lock: the most
// recently used first, the least recently used destroyed to make room.
Plan_Cache :: struct($P: typeid) {
	plans: [PLAN_CACHE_TYPES]^P,
	// Calls now running on this thread with a cached plan. A nested one (from inside a hook) evicts nothing:
	// the plan it would destroy may be the one an outer call is using.
	users: int,
}

// The cached plan for `T`, made on a miss. Nil when a nested call misses or the heap refuses: the caller makes
// a temporary plan. Each plan taken is given back with `plan_cache_done`.
plan_cache_take :: proc(c: ^Plan_Cache($P), T: typeid, init: proc(T: typeid, a: runtime.Allocator) -> P, destroy: proc(p: ^P)) -> ^P {
	for p, k in c.plans {
		if p == nil {
			break
		}
		if p.root == T {
			copy(c.plans[1:k + 1], c.plans[:k])
			c.plans[0] = p
			c.users += 1
			return p
		}
	}
	if c.users > 0 {
		return nil
	}
	heap := runtime.heap_allocator()
	p, err := new(P, heap)
	if err != nil {
		return nil
	}
	p^ = init(T, heap)
	if last := c.plans[PLAN_CACHE_TYPES - 1]; last != nil {
		destroy(last)
		free(last, heap)
	}
	copy(c.plans[1:], c.plans[:PLAN_CACHE_TYPES - 1])
	c.plans[0] = p
	c.users += 1
	return p
}

// Frees every plan the cache holds, as eviction frees one: in the heap allocator they were made in, whatever
// `context.allocator` is. It does nothing while a call on this thread is using the cache (from inside a hook).
plan_cache_clear :: proc(c: ^Plan_Cache($P), destroy: proc(p: ^P)) {
	if c.users > 0 {
		return
	}
	heap := runtime.heap_allocator()
	for &p in c.plans {
		if p == nil {
			break
		}
		destroy(p)
		free(p, heap)
		p = nil
	}
}

// A call is done with the cached plan `p`. One that reported `.Out_Of_Memory` may be unusable, so it is
// destroyed, unless an outer call is using it.
@(private = "file")
plan_cache_done :: proc(c: ^Plan_Cache($P), p: ^P, out_of_memory: bool, destroy: proc(p: ^P)) {
	c.users -= 1
	if !out_of_memory || c.users > 0 {
		return
	}
	for q, k in c.plans {
		if q == p {
			copy(c.plans[k:], c.plans[k + 1:])
			c.plans[PLAN_CACHE_TYPES - 1] = nil
			destroy(p)
			free(p, runtime.heap_allocator())
			return
		}
	}
}

// The plan a call for `T` runs: `given`, which must have been made for `T` (`ok` false otherwise), else the
// cache's plan, else a temporary one made in `tmp`. `plan_done` gives it back.
plan_for :: proc(c: ^Plan_Cache($P), given: ^P, T: typeid, tmp: ^P, init: proc(T: typeid, a: runtime.Allocator) -> P, destroy: proc(p: ^P)) -> (p: ^P, ok: bool) {
	if given != nil {
		return given, given.root == T
	}
	if p = plan_cache_take(c, T, init, destroy); p != nil {
		return p, true
	}
	tmp^ = init(T, runtime.heap_allocator())
	return tmp, true
}

// A call is done with `p`, the plan `plan_for` gave it for `given` and `tmp`.
plan_done :: proc(c: ^Plan_Cache($P), p, given, tmp: ^P, out_of_memory: bool, destroy: proc(p: ^P)) {
	switch p {
	case given:
	case tmp:
		destroy(tmp)
	case:
		plan_cache_done(c, p, out_of_memory, destroy)
	}
}
