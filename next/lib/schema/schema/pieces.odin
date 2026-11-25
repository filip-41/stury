// Piece / element-level plan splitting helpers for root-array schemas.
package schema

import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

// Compiled plans for a root array whose rules apply per element (`items` + optional `minItems`/`maxItems`).
// Allows checking individual array elements independently (e.g., streaming or parallel record workers).
Elements :: struct {
	item_plan:   check.Plan,
	has_counts:  bool,
	counts_plan: check.Plan,
	min_items:   u64,
	max_items:   Maybe(u64),
	keyword_pfx: []tape.Step,
	allocator:   runtime.Allocator,
}

// Extracts a per-element `Elements` plan if `d`'s root is a pure `items`-only array (with optional min/maxItems),
// or returns `nil` when the root has cross-element or non-array constraints.
@(require_results)
elements_of :: proc(d: ^rules.Description, allocator := context.allocator) -> ^Elements {
	if d == nil {
		return nil
	}
	node, hops := rules.ref_end(d, d.root)
	if node == rules.NONE {
		return nil
	}
	n := d.nodes[node]
	counts := n.rules
	counts.min_items, counts.max_items = 0, nil
	if .Array not_in n.kinds || n.array < 0 || n.object >= 0 || counts != {} || n.has_enum || n.const_of != nil ||
	   len(n.any_of) + len(n.all_of) + len(n.one_of) > 0 || n.not != nil || n.cond != {} ||
	   n.ref != nil || n.dynamic_ref != nil || n.unevaluated_items != nil || n.unevaluated_properties != nil {
		return nil
	}
	a := d.arrays[n.array]
	if len(a.prefix) > 0 || a.contains != nil || a.min_contains != nil || a.max_contains != nil || a.items == rules.NONE {
		return nil
	}
	e, aerr := new(Elements, allocator)
	if aerr != nil {
		return nil
	}
	e.allocator = allocator
	view := d^
	view.root = a.items
	item_plan, ierr := check.compile(&view, allocator)
	if ierr.kind != .None {
		free(e, allocator)
		return nil
	}
	e.item_plan = item_plan
	e.min_items, e.max_items = n.rules.min_items, n.rules.max_items

	if e.min_items > 0 || e.max_items != nil {
		arrays, arr_err := make([dynamic]rules.Array, 0, len(d.arrays), allocator)
		if arr_err != nil {
			elements_destroy(e)
			return nil
		}
		defer delete(arrays)
		if _, app_err := append(&arrays, ..d.arrays[:]); app_err != nil {
			elements_destroy(e)
			return nil
		}
		arrays[n.array].items = rules.NONE
		counted := d^
		counted.arrays = arrays
		cplan, cerr := check.compile(&counted, allocator)
		if cerr.kind != .None {
			elements_destroy(e)
			return nil
		}
		e.counts_plan = cplan
		e.has_counts = true
	}

	words, werr := make([]tape.Step, hops + 1, allocator)
	if werr != nil {
		elements_destroy(e)
		return nil
	}
	hop := d.root
	for i in 0 ..< hops {
		words[i] = tape.Name(rules.ref_keyword(&d.nodes[hop]))
		hop = d.nodes[hop].ref.?
	}
	words[hops] = tape.Name("items")
	e.keyword_pfx = words
	return e
}

// Frees `e` and its compiled plans.
elements_destroy :: proc(e: ^Elements) {
	if e == nil {
		return
	}
	a := e.allocator
	check.plan_destroy(&e.item_plan)
	if e.has_counts {
		check.plan_destroy(&e.counts_plan)
	}
	delete(e.keyword_pfx, a)
	free(e, a)
}
