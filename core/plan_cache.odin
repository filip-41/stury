package core

// Which plan a typed call runs: the caller's, the thread's cached one, or a temporary one. A cached or temporary
// plan has the zero opts and no hooks, made for the format `format` returns. One cache serves every format.

import "base:runtime"

// How many types a thread's plan cache holds.
PLAN_CACHE_TYPES :: 16

// The plans calls made without one use, held per thread (`@(thread_local)`) so no lock: the most recently used
// first, the least recently used destroyed to make room. A plan is cached per type and format.
@(private = "file")
Plan_Cache :: struct {
	plans: [PLAN_CACHE_TYPES]^Hooked_Plan,
	// Calls now running on this thread with a cached plan. A nested one (from inside a hook) evicts nothing:
	// the plan it would destroy may be the one an outer call is using.
	users: int,
}

@(private = "file", thread_local)
plan_cache: Plan_Cache

@(fini, private = "file")
plan_cache_fini :: proc "contextless" () {
	context = runtime.default_context()
	plan_cache_clear()
}

// The cached plan for `T`, made on a miss. Nil when a nested call misses or the heap refuses: the caller makes
// a temporary plan. Each plan taken is given back with `plan_done`.
@(private = "file")
plan_cache_take :: proc(c: ^Plan_Cache, T: typeid, format: proc() -> Plan_Format) -> ^Hooked_Plan {
	for p, k in c.plans {
		if p == nil {
			break
		}
		if p.root == T && p.made_for == format {
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
	p, err := new(Hooked_Plan, heap)
	if err != nil {
		return nil
	}
	p^ = default_plan(T, format, heap)
	if last := c.plans[PLAN_CACHE_TYPES - 1]; last != nil {
		hooked_plan_destroy(last)
		free(last, heap)
	}
	copy(c.plans[1:], c.plans[:PLAN_CACHE_TYPES - 1])
	c.plans[0] = p
	c.users += 1
	return p
}

// Frees every plan this thread's cache holds, for every format, as eviction frees one: in the heap allocator they
// were made in, whatever `context.allocator` is. It does nothing while a call on this thread is using the cache
// (from inside a hook). A thread that made typed calls without a plan calls it before it ends.
plan_cache_clear :: proc() {
	c := &plan_cache
	if c.users > 0 {
		return
	}
	heap := runtime.heap_allocator()
	for &p in c.plans {
		if p == nil {
			break
		}
		hooked_plan_destroy(p)
		free(p, heap)
		p = nil
	}
}

// A call is done with the cached plan `p`. One that reported `.Out_Of_Memory` may be unusable, so it is
// destroyed, unless an outer call is using it.
@(private = "file")
plan_cache_done :: proc(c: ^Plan_Cache, p: ^Hooked_Plan, out_of_memory: bool) {
	c.users -= 1
	if !out_of_memory || c.users > 0 {
		return
	}
	for q, k in c.plans {
		if q == p {
			copy(c.plans[k:], c.plans[k + 1:])
			c.plans[PLAN_CACHE_TYPES - 1] = nil
			hooked_plan_destroy(p)
			free(p, runtime.heap_allocator())
			return
		}
	}
}

// The plan a call for `T` in the format `format` returns runs: `given`'s for that format, which must have been
// made for `T` (`ok` false otherwise), else the cache's plan, else a temporary one made in `tmp`. `plan_done`
// gives it back.
plan_for :: proc(given: ^Shared_Plan, T: typeid, tmp: ^Hooked_Plan, format: proc() -> Plan_Format) -> (p: ^Hooked_Plan, ok: bool) {
	if given != nil {
		p = shared_plan_for(given, format)
		return p, p != nil && p.root == T
	}
	if p = plan_cache_take(&plan_cache, T, format); p != nil {
		return p, true
	}
	tmp^ = default_plan(T, format, runtime.heap_allocator())
	return tmp, true
}

@(private = "file")
default_plan :: proc(T: typeid, format: proc() -> Plan_Format, a: runtime.Allocator) -> Hooked_Plan {
	return hooked_plan_init(T, {}, format, a)
}

// A call is done with `p`, the plan `plan_for` gave it for `given` and `tmp`.
plan_done :: proc(p: ^Hooked_Plan, given: ^Shared_Plan, tmp: ^Hooked_Plan, out_of_memory: bool) {
	switch {
	case given != nil:
	case p == tmp:
		hooked_plan_destroy(tmp)
	case:
		plan_cache_done(&plan_cache, p, out_of_memory)
	}
}
