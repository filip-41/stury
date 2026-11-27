// Compiled & streaming factored held-array support (`Factor_Array`) for `uniqueItems`,
// `contains`/`minContains`/`maxContains`, `unevaluatedItems: false`, `allOf`/`anyOf`/`oneOf`/`not`/`if`,
// array `const`/`enum`, `prefixItems`/`items`, and per-part `minItems`/`maxItems`.
package check

import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

@(private)
Factor_Contains :: struct {
	record:       i32,
	min_contains: u64,
	max_contains: u64,
	evals:        bool,
	part:         u8,
}

@(private)
Factor_Array_Count :: struct {
	min_items: u64,
	max_items: u64,
	parts:     u64,
}

@(private)
Factor_Array :: struct {
	unique_parts:   u64,              // inner parts requiring `uniqueItems: true`
	spine_unique:   bool,             // outer node `uniqueItems: true` at depth 0
	need_unique:    bool,             // `spine_unique || unique_parts != 0`
	eval_all_items: u64,              // parts whose `items != NONE` (non-const; evaluate all indices >= max_prefix)
	prefix:         []^Factor_Member, // positional element judges `0 ..< len(prefix)`
	rest:           ^Factor_Member,   // element judge for `idx >= len(prefix)`
	contains:       []Factor_Contains,
	counts:         []Factor_Array_Count,
}

@(private)
Unique_Entry :: struct {
	hash:      u64,
	is_scalar: bool,
	tok:       tape.Token,     // valid when `is_scalar` (points into `h.src`)
	ref:       rules.Node_Ref, // valid when `!is_scalar`
}

@(private)
Arr_Open_State :: struct {
	contains_hits:   []u64,
	contains_evals:  [dynamic]u64,            // per element index: bitmask of `contains` indices that matched (when `len(contains) <= 64`)
	elem_evals:      [dynamic]u64,            // per element index: bitmask of `prefix`/`rest` parts that evaluated it
	elem_at:         [dynamic]u64,            // per element index: value byte offset (when `collect_errors` + `uneval_false`/`closings`)
	spilled_uniq:    bool,
	uniq_buckets:    map[u64][dynamic]Unique_Entry,
	cap_docs:        [dynamic]^tape.Document, // owned single-element documents kept until `]` for `uniqueItems`
}

// Compiles held node `node` (with `edge`) into an array `Factor` when `.Array in n.kinds` and array factoring
// applies (`uniqueItems`, `contains`, combinators, `unevaluatedItems: false`, or array `const`/`enum`).
@(private)
array_factor_of :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> ^Factor {
	if b.err.kind != .None || node == rules.NONE {
		return nil
	}
	n := &d.nodes[node]
	if .Array not_in n.kinds {
		return nil
	}
	uneval_false := false
	if ui, has := n.unevaluated_items.?; has {
		ui_end := resolve_end_ro(b, d, arena, ui)
		if ui_end == rules.NONE || d.nodes[ui_end].kinds != {} {
			return nil
		}
		uneval_false = true
	}

	fb := Factor_Build{
		b = b,
		d = d,
		arena = arena,
		tables = b.tables,
		parts = make([dynamic]Part_Info, b.tables),
		ops = make([dynamic]Factor_Op, b.tables),
		closings = make([dynamic]Factor_Closing, b.tables),
		contains = make([dynamic]Contains_Build, b.tables),
		ok = true,
	}

	// Gather the boolean circuit and flat parts of `node`.
	root_op := gather_array(&fb, node, edge, 0, nil)
	if !fb.ok || root_op < 0 || len(fb.parts) == 0 {
		return nil
	}
	if len(fb.parts) > MAX_FACTOR_PARTS {
		return nil
	}

	r_outer, clash := rules.merged(n, edge)
	has_spine := clash == "" && (r_outer.min_items > 0 || r_outer.max_items != nil)

	has_const_part := false
	has_inner_uniq := false
	for pt in fb.parts {
		if pt.is_const {
			has_const_part = true
		}
		if pt.unique_items {
			has_inner_uniq = true
		}
	}
	need_unique := fb.spine_unique || has_inner_uniq
	if len(fb.parts) == 1 && ops_monotone(fb.ops[:]) && !need_unique && len(fb.contains) == 0 && !uneval_false && len(fb.closings) == 0 && !has_const_part && !has_spine {
		return nil
	}

	ops_slice := ops_flatten(&fb, root_op)
	if len(ops_slice) == 0 {
		return nil
	}

	max_prefix := 0
	for pt in fb.parts {
		if pt.is_contains || pt.is_presence {
			continue
		}
		if pt.is_const {
			max_prefix = max(max_prefix, len(pt.const_arr))
		} else if pt.arr >= 0 {
			max_prefix = max(max_prefix, len(d.arrays[pt.arr].prefix))
		}
	}

	f, ferr := new(Factor, arena)
	fa, faerr := new(Factor_Array, arena)
	if ferr != nil || faerr != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	f.n = u8(len(fb.parts))
	f.ops = ops_slice
	f.uneval_false = uneval_false
	f.all_parts = ~u64(0) if f.n == 64 else (u64(1) << f.n) - 1
	f.monotone = ops_monotone(f.ops)
	f.direct_errors = ops_conjunctive_only(f.ops) && len(fb.closings) == 0
	f.arr = fa
	f.part_meta, f.no_emit_mask = finalize_part_meta(b, arena, fb.parts[:])

	// Spine counts (outer `minItems`/`maxItems`).
	if has_spine {
		cnt_node := rules.Node{
			kinds = rules.EVERY_KIND,
			rules = rules.Rules{min_items = r_outer.min_items, max_items = r_outer.max_items},
			array = -1,
			object = -1,
		}
		f.spine_leaf = checked_leaf(b, &cnt_node, {}, arena)
	}

	fa.spine_unique = fb.spine_unique
	fa.need_unique = need_unique
	counts_list := make([dynamic]Factor_Array_Count, arena)
	for pt, pi in fb.parts {
		bit := u64(1) << uint(pi)
		if pt.is_presence || pt.is_contains {
			continue
		}
		if pt.unique_items {
			fa.unique_parts |= bit
		}
		if pt.min_members > 0 || pt.max_members < max(u64) {
			merged := false
			for &c in counts_list {
				if c.min_items == pt.min_members && c.max_items == pt.max_members {
					c.parts |= bit
					merged = true
					break
				}
			}
			if !merged {
				append(&counts_list, Factor_Array_Count{min_items = pt.min_members, max_items = pt.max_members, parts = bit})
			}
		}
		if pt.arr >= 0 && !pt.no_eval && d.arrays[pt.arr].items != rules.NONE {
			fa.eval_all_items |= bit
		}
	}
	fa.counts = counts_list[:]

	if len(fb.contains) > 0 {
		if len(fb.contains) > 64 {
			return nil
		}
		clist, cerr := make([]Factor_Contains, len(fb.contains), arena)
		if cerr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		for cb, i in fb.contains {
			clist[i] = {
				record = cb.record,
				min_contains = cb.min_c,
				max_contains = cb.max_c,
				evals = cb.evals,
				part = cb.part,
			}
		}
		fa.contains = clist
	}

	if len(fb.closings) > 0 {
		cl, clerr := make([]Factor_Closing, len(fb.closings), arena)
		if clerr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		copy(cl, fb.closings[:])
		f.closings = cl
	}

	if max_prefix > 0 {
		pref, perr := make([]^Factor_Member, max_prefix, arena)
		if perr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		for i in 0 ..< max_prefix {
			fm, ok := build_array_member(&fb, i)
			if !ok {
				return nil
			}
			pref[i] = fm
		}
		fa.prefix = pref
	}
	rest_fm, ok := build_array_member(&fb, -1)
	if !ok {
		return nil
	}
	fa.rest = rest_fm

	append(&b.factors, f)
	return f
}

@(private = "file")
gather_array :: proc(fb: ^Factor_Build, node: rules.Node_Index, edge: rules.Rules, depth: int, site_prefix: []tape.Step) -> i16 {
	if !fb.ok || depth > 32 {
		fb.ok = false
		return -1
	}
	if node == rules.NONE {
		return add_trivial_part(fb, site_prefix)
	}
	b, d := fb.b, fb.d
	saved_scope := b.scope
	defer b.scope = saved_scope
	words := make([dynamic]string, fb.tables)
	end_node := resolve_end(b, d, fb.arena, node, &words)
	site := site_with_words(b, fb.arena, site_prefix, words[:])
	if end_node == rules.NONE {
		return add_trivial_part(fb, site)
	}
	n := &d.nodes[end_node]
	if .Array not_in n.kinds {
		return add_fail_part(fb, end_node, edge, site)
	}
	part_uneval_false := false
	if ui, has := n.unevaluated_items.?; has {
		if depth > 0 {
			ui_end := resolve_end_ro(b, d, fb.arena, ui)
			if ui_end == rules.NONE || d.nodes[ui_end].kinds != {} {
				fb.ok = false
				return -1
			}
			part_uneval_false = true
		}
	}

	children := make([dynamic]i16, fb.tables)

	if n.const_of != nil {
		cand_op := gather_const_arrays(fb, n, depth, site)
		if !fb.ok {
			return -1
		}
		append(&children, cand_op)
	}
	if n.has_enum {
		enum_op := gather_enum_arrays(fb, n, depth, site)
		if !fb.ok {
			return -1
		}
		append(&children, enum_op)
	}

	r_merged, clash := rules.merged(n, edge)
	if clash != "" {
		fb.ok = false
		return -1
	}
	if depth == 0 && r_merged.unique {
		fb.spine_unique = true
	}

	has_own := false
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if len(a.prefix) > 0 || a.items != rules.NONE {
			has_own = true
		}
	}
	if depth > 0 && (r_merged.min_items > 0 || r_merged.max_items != nil || r_merged.unique) {
		has_own = true
	}

	if has_own {
		if len(fb.parts) >= MAX_FACTOR_PARTS {
			fb.ok = false
			return -1
		}
		pi := Part_Info{
			node = end_node,
			obj = -1,
			arr = n.array,
			scope = b.scope,
			site = site,
			min_members = r_merged.min_items if depth > 0 else 0,
			max_members = (r_merged.max_items.? or_else max(u64)) if depth > 0 else max(u64),
			unique_items = depth > 0 && r_merged.unique,
			add_uneval = n.array >= 0 && b.unevaluated[{1, n.array}],
			add_node = rules.NONE,
			keys_node = rules.NONE,
		}
		bit := u8(len(fb.parts))
		append(&fb.parts, pi)
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Part, bit = bit})
		append(&children, op_idx)
	}

	if n.array >= 0 {
		a := &d.arrays[n.array]
		if c, has_c := a.contains.?; has_c {
			if len(fb.parts) >= MAX_FACTOR_PARTS {
				fb.ok = false
				return -1
			}
			csite := [1]tape.Step{tape.Name("contains")}
			c_rec := arm_record(b, d, fb.arena, c, csite[:])
			c_bit := u8(len(fb.parts))
			append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, arr = -1, site = site, max_members = max(u64), add_node = rules.NONE, keys_node = rules.NONE, is_contains = true})
			append(&fb.contains, Contains_Build{
				record = c_rec,
				min_c = a.min_contains.? or_else 1,
				max_c = a.max_contains.? or_else max(u64),
				evals = a.evaluates_contains,
				part = c_bit,
			})
			c_op := i16(len(fb.ops))
			append(&fb.ops, Factor_Op{kind = .Part, bit = c_bit})
			append(&children, c_op)
		}
	}

	if r, has := n.ref.?; has {
		saved := b.scope
		enter_scope(b, d, fb.arena, r)
		ref_site := site_concat(b, fb.arena, site, tape.Name(rules.ref_keyword(n)))
		sub := gather_array(fb, r, {}, depth + 1, ref_site)
		b.scope = saved
		if !fb.ok {
			return -1
		}
		append(&children, sub)
	}

	if dr, has := n.dynamic_ref.?; has {
		target := dynamic_target(b, d, n, dr)
		saved := b.scope
		enter_scope(b, d, fb.arena, target)
		dr_site := site_concat(b, fb.arena, site, tape.Name(rules.dynamic_keyword(n)))
		sub := gather_array(fb, target, {}, depth + 1, dr_site)
		b.scope = saved
		if !fb.ok {
			return -1
		}
		append(&children, sub)
	}

	for a, idx in n.all_of {
		sub_site := site_concat(b, fb.arena, site, tape.Name("allOf"), tape.Index(idx))
		sub := gather_array(fb, a, {}, depth + 1, sub_site)
		if !fb.ok {
			return -1
		}
		append(&children, sub)
	}

	if len(n.any_of) > 0 {
		arms := make([dynamic]i16, fb.tables)
		for a, idx in n.any_of {
			sub_site := site_concat(b, fb.arena, site, tape.Name("anyOf"), tape.Index(idx))
			sub := gather_array(fb, a, {}, depth + 1, sub_site)
			if !fb.ok {
				return -1
			}
			append(&arms, sub)
		}
		append(&children, emit_group_op(fb, .Any, arms[:], site))
	}

	if len(n.one_of) > 0 {
		arms := make([dynamic]i16, fb.tables)
		for a, idx in n.one_of {
			sub_site := site_concat(b, fb.arena, site, tape.Name("oneOf"), tape.Index(idx))
			sub := gather_array(fb, a, {}, depth + 1, sub_site)
			if !fb.ok {
				return -1
			}
			append(&arms, sub)
		}
		append(&children, emit_group_op(fb, .One, arms[:], site))
	}

	if nt, has := n.not.?; has {
		not_site := site_concat(b, fb.arena, site, tape.Name("not"))
		sub := gather_array(fb, nt, {}, depth + 1, not_site)
		if !fb.ok {
			return -1
		}
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Not, first = sub, site = site})
		append(&children, op_idx)
	}

	if test, has := n.cond.test.?; has {
		if_site := site_concat(b, fb.arena, site, tape.Name("if"))
		test_op := gather_array(fb, test, {}, depth + 1, if_site)
		then_op := i16(-1)
		if th, has_th := n.cond.then.?; has_th {
			then_site := site_concat(b, fb.arena, site, tape.Name("then"))
			then_op = gather_array(fb, th, {}, depth + 1, then_site)
		}
		else_op := i16(-1)
		if ot, has_ot := n.cond.other.?; has_ot {
			else_site := site_concat(b, fb.arena, site, tape.Name("else"))
			else_op = gather_array(fb, ot, {}, depth + 1, else_site)
		}
		if !fb.ok {
			return -1
		}
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .If, first = test_op, count = then_op, else_op = else_op, site = site})
		append(&children, op_idx)
	}

	if len(children) == 0 {
		return add_trivial_part(fb, site)
	}
	res := children[0] if len(children) == 1 else emit_group_op(fb, .All, children[:], site)

	if part_uneval_false {
		if len(fb.parts) >= MAX_FACTOR_PARTS {
			fb.ok = false
			return -1
		}
		c_bit := u8(len(fb.parts))
		ui_site := site_concat(b, fb.arena, site, tape.Name("unevaluatedItems"))
		append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, arr = -1, site = ui_site, uneval_kw = "unevaluatedItems", max_members = max(u64), add_node = rules.NONE, keys_node = rules.NONE})
		append(&fb.closings, Factor_Closing{part = c_bit, root_op = res})
		c_op := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Part, bit = c_bit})
		pair := [2]i16{res, c_op}
		res = emit_group_op(fb, .All, pair[:], site)
	}
	return res
}

@(private = "file")
gather_const_arrays :: proc(fb: ^Factor_Build, n: ^rules.Node, depth: int, site: []tape.Step) -> i16 {
	return gather_const_container(fb, n, site, true)
}

@(private = "file")
gather_enum_arrays :: proc(fb: ^Factor_Build, n: ^rules.Node, depth: int, site: []tape.Step) -> i16 {
	return gather_enum_container(fb, n, site, true)
}

@(private = "file")
build_array_member :: proc(fb: ^Factor_Build, elem_idx: int) -> (^Factor_Member, bool) {
	d := fb.d
	fm, err := new(Factor_Member, fb.arena)
	if err != nil {
		refuse_plan(fb.b, .No_Memory)
		return nil, false
	}
	cons := make([dynamic]Factored_Constraint, fb.tables)
	for pt, pi in fb.parts {
		bit := u64(1) << uint(pi)
		if pt.is_presence || pt.is_contains {
			continue
		}
		if pt.is_const {
			if elem_idx >= 0 && elem_idx < len(pt.const_arr) {
				c_node := const_member_node(fb.b, d, fb.arena, fb.tables, pt.const_arr[elem_idx])
				if c_node == rules.NONE {
					return nil, false
				}
				append(&cons, Factored_Constraint{node = c_node, part = u8(pi), scope = pt.scope, k_step = tape.Index(elem_idx), elem_idx = -1})
			}
			continue
		}
		if pt.arr < 0 {
			continue
		}
		a := &d.arrays[pt.arr]
		if elem_idx >= 0 && elem_idx < len(a.prefix) {
			if !pt.no_eval {
				fm.evals |= bit
			}
			append(&cons, Factored_Constraint{
				node = a.prefix[elem_idx],
				part = u8(pi),
				scope = pt.scope,
				k_step = tape.Name("items" if a.tuple else "prefixItems"),
				elem_idx = elem_idx,
			})
		} else if a.items != rules.NONE {
			if !pt.no_eval {
				fm.evals |= bit
			}
			rest_kw := "unevaluatedItems" if pt.add_uneval else "additionalItems" if a.tuple else "items"
			append(&cons, Factored_Constraint{
				node = a.items,
				part = u8(pi),
				scope = pt.scope,
				k_step = tape.Name(rest_kw),
				elem_idx = -1,
			})
		}
	}
	return compile_member_constraints(fb, fm, cons[:])
}

// Initializes factored array runtime state when opening `[`.
@(private)
factored_arr_open :: proc(h: ^Checker, fo: ^Factored_Open) -> bool {
	f := fo.factor
	fa := f.arr
	if fa.need_unique && !h.arr_uniq_in_use {
		h.arr_uniq_in_use = true
		fo.using_inline_uniq = true
		runtime.mem_zero(&h.arr_uniq_slots[0], size_of(h.arr_uniq_slots))
		h.arr_uniq_n = 0
		if len(fa.contains) == 0 && !f.uneval_false && len(f.closings) == 0 {
			return true
		}
	}
	if !fa.need_unique && len(fa.contains) == 0 && !f.uneval_false && len(f.closings) == 0 {
		return true
	}
	return ensure_arr_state(h, fo) != nil
}

@(private = "file")
ensure_arr_state :: proc(h: ^Checker, fo: ^Factored_Open) -> ^Arr_Open_State {
	if fo.arr_state != nil {
		return fo.arr_state
	}
	st, err := new(Arr_Open_State, h.scratch)
	if err != nil {
		h.fatal = .No_Memory
		return nil
	}
	fa := fo.factor.arr
	if len(fa.contains) > 0 {
		hits, herr := make([]u64, len(fa.contains), h.scratch)
		if herr != nil {
			free(st, h.scratch)
			h.fatal = .No_Memory
			return nil
		}
		st.contains_hits = hits
	}
	st.contains_evals.allocator = h.scratch
	st.elem_evals.allocator = h.scratch
	st.elem_at.allocator = h.scratch
	st.uniq_buckets.allocator = h.scratch
	st.cap_docs.allocator = h.scratch
	fo.arr_state = st
	return st
}

@(private)
free_arr_state :: proc(h: ^Checker, st: ^Arr_Open_State) {
	if st == nil {
		return
	}
	delete(st.contains_hits, h.scratch)
	delete(st.contains_evals)
	delete(st.elem_evals)
	delete(st.elem_at)
	for _, list in st.uniq_buckets {
		delete(list)
	}
	delete(st.uniq_buckets)
	for d in st.cap_docs {
		if d != nil {
			if d.ext == h.xml_ext {
				d.ext = nil
			}
			tape.destroy(d)
			free(d, h.scratch)
		}
	}
	delete(st.cap_docs)
	free(st, h.scratch)
}

@(private)
factored_arr_elem_member :: #force_inline proc "contextless" (fa: ^Factor_Array, elem_idx: u64) -> ^Factor_Member #no_bounds_check {
	if elem_idx < u64(len(fa.prefix)) {
		return fa.prefix[elem_idx]
	}
	return fa.rest
}

// Spills inline `[32]string` seen so far into `st.uniq_buckets` when switching to general `uniqueItems`.
@(private = "file")
spill_inline_unique :: proc(h: ^Checker, fo: ^Factored_Open) -> ^Arr_Open_State {
	st := ensure_arr_state(h, fo)
	if st == nil {
		return nil
	}
	if !st.spilled_uniq {
		st.spilled_uniq = true
		if fo.using_inline_uniq {
			for i in 0 ..< int(h.arr_uniq_n) {
				s := h.arr_uniq_strs[i]
				hv, herr := rules.value_hash(rules.Value(s), h.dups, h.scratch)
				if herr != nil {
					h.fatal = .No_Memory
					return nil
				}
				lo := u64(uintptr(raw_data(s)) - uintptr(raw_data(h.src)))
				tok := tape.Token{lo = lo, n = u32(len(s)), kind = .String, role = .Value, spelling = h.arr_uniq_spells[i]}
				if !uniq_bucket_add(h, st, hv, true, tok, {}) {
					return nil
				}
			}
			h.arr_uniq_in_use = false
			fo.using_inline_uniq = false
		}
	}
	return st
}

@(private = "file")
uniq_bucket_add :: proc(h: ^Checker, st: ^Arr_Open_State, hv: u64, is_scalar: bool, tok: tape.Token, ref: rules.Node_Ref) -> bool {
	if prevs, exists := &st.uniq_buckets[hv]; exists {
		if _, aerr := append(prevs, Unique_Entry{hash = hv, is_scalar = is_scalar, tok = tok, ref = ref}); aerr != nil {
			h.fatal = .No_Memory
			return false
		}
		return true
	}
	list, lerr := make([dynamic]Unique_Entry, 0, 2, h.scratch)
	if lerr != nil {
		h.fatal = .No_Memory
		return false
	}
	if _, aerr := append(&list, Unique_Entry{hash = hv, is_scalar = is_scalar, tok = tok, ref = ref}); aerr != nil {
		delete(list)
		h.fatal = .No_Memory
		return false
	}
	if _, _, _, merr := map_entry(&st.uniq_buckets, hv); merr != nil {
		delete(list)
		h.fatal = .No_Memory
		return false
	}
	st.uniq_buckets[hv] = list
	return true
}

@(private = "file")
unique_entry_value :: proc "contextless" (h: ^Checker, e: ^Unique_Entry, stack_doc: ^tape.Document, stack_node: ^[1]tape.Node) -> rules.Value {
	if e.is_scalar {
		stack_node[0] = tape.Node(e.tok)
		stack_doc^ = tape.Document{src = h.src, nodes = stack_node[:], format = h.format, ext = h.xml_ext}
		return rules.Node_Ref{doc = stack_doc, node = 0}
	}
	return e.ref
}

@(private = "file")
check_arr_unique_scalar :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> bool #no_bounds_check {
	if fo.using_inline_uniq && (t.kind == .String && (t.spelling & tape.SPELLING_DECODE == 0)) && h.arr_uniq_n < 32 {
		s := string(h.src[t.lo:][:t.n])
		hv := member_hash(s) & 63
		for {
			slot := h.arr_uniq_slots[hv]
			if slot == 0 {
				idx := h.arr_uniq_n
				h.arr_uniq_slots[hv] = idx + 1
				h.arr_uniq_spells[idx] = t.spelling
				h.arr_uniq_strs[idx] = s
				h.arr_uniq_n += 1
				return true
			}
			if h.arr_uniq_strs[slot - 1] == s {
				return false
			}
			hv = (hv + 1) & 63
		}
	}
	st := spill_inline_unique(h, fo)
	if st == nil {
		return false
	}
	nodes := [1]tape.Node{tape.Node(t)}
	doc := tape.Document{src = h.src, nodes = nodes[:], format = h.format, ext = h.xml_ext}
	val := rules.Value(rules.Node_Ref{doc = &doc, node = 0})
	hv, herr := rules.value_hash(val, h.dups, h.scratch)
	if herr != nil {
		h.fatal = .No_Memory
		return false
	}
	if prevs, exists := &st.uniq_buckets[hv]; exists {
		pnodes: [1]tape.Node = ---
		pdoc: tape.Document = ---
		for &p in prevs^ {
			pval := unique_entry_value(h, &p, &pdoc, &pnodes)
			if !p.is_scalar && p.ref.doc.ext == nil && h.xml_ext != nil {
				p.ref.doc.ext = h.xml_ext
			}
			eq, eerr := rules.value_equal(val, pval, h.dups, h.scratch)
			if eerr != nil {
				h.fatal = .No_Memory
				return false
			}
			if eq {
				return false
			}
		}
	}
	_ = uniq_bucket_add(h, st, hv, true, t, {})
	return true
}

@(private = "file")
check_arr_unique_ref :: proc(h: ^Checker, fo: ^Factored_Open, doc_val: tape.Document, doc_ptr: ^tape.Document, node: tape.Node_Index, adopted_copy: bool) -> (unique: bool, kept: bool) {
	st := spill_inline_unique(h, fo)
	if st == nil {
		return false, false
	}
	local_doc := doc_val
	cur_doc := doc_ptr if doc_ptr != nil else &local_doc
	if cur_doc.ext == nil && h.xml_ext != nil {
		cur_doc.ext = h.xml_ext
	}
	val := rules.Value(rules.Node_Ref{doc = cur_doc, node = node})
	hv, herr := rules.value_hash(val, h.dups, h.scratch)
	if herr != nil {
		h.fatal = .No_Memory
		return false, false
	}
	if prevs, exists := &st.uniq_buckets[hv]; exists {
		pnodes: [1]tape.Node = ---
		pdoc: tape.Document = ---
		for &p in prevs^ {
			pval := unique_entry_value(h, &p, &pdoc, &pnodes)
			if !p.is_scalar && p.ref.doc.ext == nil && h.xml_ext != nil {
				p.ref.doc.ext = h.xml_ext
			}
			eq, eerr := rules.value_equal(val, pval, h.dups, h.scratch)
			if eerr != nil {
				h.fatal = .No_Memory
				return false, false
			}
			if eq {
				return false, false
			}
		}
	}
	if adopted_copy {
		heap_doc, derr := new(tape.Document, h.scratch)
		if derr != nil {
			h.fatal = .No_Memory
			return false, false
		}
		heap_doc^ = local_doc
		if _, aerr := append(&st.cap_docs, heap_doc); aerr != nil {
			free(heap_doc, h.scratch)
			h.fatal = .No_Memory
			return false, false
		}
		_ = uniq_bucket_add(h, st, hv, false, {}, rules.Node_Ref{doc = heap_doc, node = node})
		return true, true
	}
	_ = uniq_bucket_add(h, st, hv, false, {}, rules.Node_Ref{doc = doc_ptr, node = node})
	return true, false
}

@(private = "file")
record_arr_elem_pos_and_refuse :: proc(h: ^Checker, fo: ^Factored_Open, fm: ^Factor_Member, elem_idx: u64, val_at: u64) {
	f := fo.factor
	if f.uneval_false || len(f.closings) > 0 {
		st := ensure_arr_state(h, fo)
		if st == nil {
			return
		}
		for len(st.elem_at) <= int(elem_idx) {
			append(&st.elem_at, 0)
		}
		st.elem_at[elem_idx] = val_at
	}
	if fm != nil && fm.refuse != 0 && (fm.refuse & ~f.no_emit_mask) != 0 {
		factored_buf_err(h, fo, Factored_Err{
			kind = .Direct,
			no_emit_mask = f.no_emit_mask,
			err_kind = .Wrong_Kind,
			at = val_at,
			keyword = "type",
			elem_idx = elem_idx,
			has_member = true,
			sites = fm.refuse_sites,
		})
	}
}

// Evaluates a scalar element inside an open `Factor_Array`.
@(private)
factored_arr_scalar :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (doomed: bool) {
	f := fo.factor
	fa := f.arr
	elem_idx := fo.seen_count
	fo.seen_count += 1

	// 1. `uniqueItems` check on scalar element.
	if fa.need_unique && (!fo.arr_unique_failed || (!fo.collect_errors && (fa.unique_parts & ~fo.failed) != 0)) {
		if !check_arr_unique_scalar(h, fo, t) {
			fo.arr_unique_failed = true
			fo.failed |= fa.unique_parts
			if !fo.collect_errors && factored_can_record_first(h, fo) {
				if fa.spine_unique {
					record_first_factored_err(h, fo, .Not_Unique, fo.open_at, "uniqueItems", "", "", 0, false, nil, spine = true)
				} else if (fa.unique_parts & ~f.no_emit_mask) != 0 {
					// Record against first matching part with uniqueItems.
					up := fa.unique_parts & ~f.no_emit_mask
					b := u8(0)
					for b < f.n && (up & (u64(1) << b)) == 0 {
						b += 1
					}
					record_first_factored_err(h, fo, .Not_Unique, fo.open_at, "uniqueItems", "", "", 0, false, nil, b)
				}
			}
			if fa.spine_unique && can_doom_spine_unique(h) {
				return true
			}
		}
		if h.fatal != .None {
			return true
		}
	}

	// 2. Positional / items `Factor_Member`.
	fm := factored_arr_elem_member(fa, elem_idx)
	fo.active_member = fm
	if fo.collect_errors {
		record_arr_elem_pos_and_refuse(h, fo, fm, elem_idx, t.lo)
		if h.fatal != .None {
			return true
		}
	}
	if fm != nil {
		fo.failed |= fm.refuse
		if (f.uneval_false || len(f.closings) > 0) && elem_idx < u64(len(fa.prefix)) {
			st := ensure_arr_state(h, fo)
			if st == nil {
				return true
			}
			for len(st.elem_evals) <= int(elem_idx) {
				append(&st.elem_evals, 0)
			}
			st.elem_evals[elem_idx] = fm.evals
		}
		if factored_scalar(h, fo, t) {
			return true
		}
	}
	if h.fatal != .None {
		return true
	}

	// 3. `contains` checks on scalar element.
	if len(fa.contains) > 0 {
		st := ensure_arr_state(h, fo)
		if st == nil {
			return true
		}
		cmask := u64(0)
		for c, ci in fa.contains {
			if scalar_passes_record(h, c.record, t) {
				st.contains_hits[ci] += 1
				if c.evals {
					cmask |= u64(1) << uint(ci)
				}
			}
			if h.fatal != .None {
				return true
			}
		}
		if f.uneval_false || len(f.closings) > 0 {
			for len(st.contains_evals) <= int(elem_idx) {
				append(&st.contains_evals, 0)
			}
			st.contains_evals[elem_idx] = cmask
		}
	}

	return can_doom_factored(h, f, fo.failed)
}

@(private = "file")
can_doom_spine_unique :: #force_inline proc "contextless" (h: ^Checker) -> bool {
	return h.sink == nil && h.dups != .Last && h.dups != .Group && h.nest_depth == 0 && h.nf == 1 && h.choice_depth == 0
}

// Evaluates a container opening token inside an open `Factor_Array` (`streaming` mode).
@(private)
factored_arr_container :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (choice_rec: ^Record, use_fork: bool, for_elem: bool, skip: bool, doomed: bool) {
	f := fo.factor
	fa := f.arr
	elem_idx := fo.seen_count
	fo.seen_count += 1

	fm := factored_arr_elem_member(fa, elem_idx)
	fo.active_member = fm
	if fm != nil && (f.uneval_false || len(f.closings) > 0) && elem_idx < u64(len(fa.prefix)) {
		st := ensure_arr_state(h, fo)
		if st == nil {
			return nil, false, false, false, true
		}
		for len(st.elem_evals) <= int(elem_idx) {
			append(&st.elem_evals, 0)
		}
		st.elem_evals[elem_idx] = fm.evals
	}
	if fo.collect_errors {
		record_arr_elem_pos_and_refuse(h, fo, fm, elem_idx, t.lo)
		if h.fatal != .None {
			return nil, false, false, false, true
		}
	}

	need_uniq := fa.need_unique && (!fo.arr_unique_failed || (!fo.collect_errors && (fa.unique_parts & ~fo.failed) != 0))
	want_kind := rules.Kind.Object if t.kind == .Object else rules.Kind.Array
	need_contains := false
	for c in fa.contains {
		if record_accepts_kind(h.plan, c.record, want_kind, 0) {
			need_contains = true
			break
		}
	}
	if need_uniq || need_contains {
		return nil, false, true, false, false
	}

	crec, ufork, sk, dm := factored_container(h, fo, t)
	return crec, ufork, false, sk, dm
}

// Finishes a single container element capture started for a `Factor_Array` (`uniqueItems` / `contains`).
@(private)
factored_arr_finish_elem_capture :: proc(h: ^Checker, doc_val: tape.Document, owner: ^Record, fo_idx: int, fm: ^Factor_Member, at: u64) -> (ok: bool, adopted: bool) {
	fo := factored_at(h, fo_idx)
	elem_idx := fo.seen_count - 1
	return factored_arr_eval_elem_node(h, doc_val, nil, 0, fo_idx, fm, elem_idx, adopt_doc = true)
}

// Evaluates a container element node already in a `tape.Document` (`doc`, `node`) for an open `Factor_Array`.
@(private)
factored_arr_eval_elem_node :: proc(h: ^Checker, doc_val: tape.Document, doc_ptr: ^tape.Document, node: tape.Node_Index, fo_idx: int, fm: ^Factor_Member, elem_idx: u64, adopt_doc: bool) -> (ok: bool, adopted: bool) {
	local_doc := doc_val
	cur_doc := doc_ptr if doc_ptr != nil else &local_doc
	fo := factored_at(h, fo_idx)
	f := fo.factor
	fa := f.arr

	// 1. Judge `fm` (`refuse`, `table`, `leaves`, `choices`).
	if fm != nil {
		fo.failed |= fm.refuse
		if eval_factored_fork_node(h, cur_doc, node, fo_idx, fm) {
			return false, false
		}
		if h.fatal != .None {
			return false, false
		}
		fo = factored_at(h, fo_idx)
	}

	// 2. Judge `fa.contains` (`subcheck_node` in `quiet = true`).
	if len(fa.contains) > 0 {
		st := ensure_arr_state(h, fo)
		if st == nil {
			return false, false
		}
		cmask := u64(0)
		for c, ci in fa.contains {
			if subcheck_node(h, cur_doc, node, c.record, nil, nil, quiet = true) {
				st.contains_hits[ci] += 1
				if c.evals {
					cmask |= u64(1) << uint(ci)
				}
			}
			if h.fatal != .None {
				return false, false
			}
			fo = factored_at(h, fo_idx)
		}
		if f.uneval_false || len(f.closings) > 0 {
			for len(st.contains_evals) <= int(elem_idx) {
				append(&st.contains_evals, 0)
			}
			st.contains_evals[elem_idx] = cmask
		}
	}

	// 3. Judge `uniqueItems` on container element (adopting `doc` only if `adopt_doc` and needed until `]`).
	if fa.need_unique && (!fo.arr_unique_failed || (!fo.collect_errors && (fa.unique_parts & ~fo.failed) != 0)) {
		uniq, kept := check_arr_unique_ref(h, fo, local_doc, doc_ptr, node, adopt_doc)
		adopted = kept
		if h.fatal != .None {
			return false, adopted
		}
		fo = factored_at(h, fo_idx)
		if !uniq {
			fo.arr_unique_failed = true
			fo.failed |= fa.unique_parts
			if !fo.collect_errors && factored_can_record_first(h, fo) {
				if fa.spine_unique {
					record_first_factored_err(h, fo, .Not_Unique, fo.open_at, "uniqueItems", "", "", 0, false, nil, spine = true)
				} else if (fa.unique_parts & ~f.no_emit_mask) != 0 {
					up := fa.unique_parts & ~f.no_emit_mask
					b := u8(0)
					for b < f.n && (up & (u64(1) << b)) == 0 {
						b += 1
					}
					record_first_factored_err(h, fo, .Not_Unique, fo.open_at, "uniqueItems", "", "", 0, false, nil, b)
				}
			}
			if fa.spine_unique && can_doom_spine_unique(h) {
				return false, adopted
			}
		}
	}

	if can_doom_factored(h, f, fo.failed) {
		return false, adopted
	}
	return true, adopted
}

// Closes the innermost open `Factor_Array`.
@(private)
factored_arr_close :: proc(h: ^Checker, fo: ^Factored_Open) -> (passed: bool, owner: ^Record, open_at: u64, emitted: bool) {
	f := fo.factor
	fa := f.arr
	st := fo.arr_state
	defer factored_cleanup(h, fo)

	owner = fo.owner
	open_at = fo.open_at
	h.quiet = fo.saved_quiet
	h.sink = fo.saved_sink
	h.buffering_choice = fo.saved_buffering
	h.choice_sink_fo = fo.saved_choice_fo
	h.no_factor = fo.saved_no_factor
	h.failed = fo.saved_failed

	failed := fo.failed

	// 1. Settle `contains` bounds.
	if len(fa.contains) > 0 && st != nil {
		for c, ci in fa.contains {
			hits := st.contains_hits[ci]
			if hits < c.min_contains || hits > c.max_contains {
				failed |= u64(1) << c.part
			}
		}
	}

	// 2. Settle per-part `minItems` / `maxItems`.
	for cnt in fa.counts {
		if fo.seen_count < cnt.min_items || fo.seen_count > cnt.max_items {
			failed |= cnt.parts
		}
	}

	// 3. Inner `unevaluatedItems: false` closings (Stage 4).
	for cl in f.closings {
		cl_ok, cl_active := parts_of(f, failed, cl.root_op)
		if !cl_ok || !all_items_evaluated(fa, st, fo.seen_count, cl_active) {
			failed |= u64(1) << cl.part
		}
	}

	// 4. Spine `uniqueItems`, `minItems`/`maxItems`, final circuit verdict, & outer `unevaluatedItems: false`.
	spine_fail := (fa.spine_unique && fo.arr_unique_failed)
	if f.spine_leaf > 0 {
		l := &h.plan.leaves[f.spine_leaf - 1]
		if fo.seen_count < l.min_items || fo.seen_count > l.max_items {
			spine_fail = true
		}
	}
	circuit_ok := factor_eval(f, failed, 0)
	uneval_ok := true
	if f.uneval_false {
		ok, active := parts_of(f, failed, 0)
		if !ok || !all_items_evaluated(fa, st, fo.seen_count, active) {
			uneval_ok = false
		}
	}
	passed = !spine_fail && circuit_ok && uneval_ok
	if !passed {
		if fo.collect_errors {
			emit_factored_errors(h, fo, failed)
			emitted = true
		} else if factored_can_record_first_close(h, fo) {
			emit_factored_errors(h, fo, failed, first_only = true)
			emitted = h.first_recorded
		}
	}
	return passed, owner, open_at, emitted
}

@(private = "file")
all_items_evaluated :: proc "contextless" (fa: ^Factor_Array, st: ^Arr_Open_State, count: u64, active: u64) -> bool #no_bounds_check {
	if count == 0 {
		return true
	}
	eval_all := (active & fa.eval_all_items) != 0
	if eval_all && len(fa.prefix) == 0 {
		return true
	}
	active_contains := u64(0)
	for c, ci in fa.contains {
		if c.evals && ((u64(1) << c.part) & active) != 0 {
			active_contains |= u64(1) << uint(ci)
		}
	}
	if !eval_all && count > u64(len(fa.prefix)) && active_contains == 0 {
		return false
	}
	pref_n := int(min(count, u64(len(fa.prefix))))
	for i in 0 ..< pref_n {
		pe := u64(0)
		if st != nil && i < len(st.elem_evals) {
			pe = st.elem_evals[i]
		} else {
			pe = fa.prefix[i].evals
		}
		if (pe & active) != 0 {
			continue
		}
		if st != nil && i < len(st.contains_evals) && (st.contains_evals[i] & active_contains) != 0 {
			continue
		}
		return false
	}
	if eval_all {
		return true
	}
	for i := pref_n; i < int(count); i += 1 {
		if st != nil && i < len(st.contains_evals) && (st.contains_evals[i] & active_contains) != 0 {
			continue
		}
		return false
	}
	return true
}
