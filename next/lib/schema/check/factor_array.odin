// Compiled & streaming factored held-array support (`Factor_Array`) for `uniqueItems`,
// `contains`/`minContains`/`maxContains`, `unevaluatedItems: false`, combinators,
// array `const`/`enum`, `prefixItems`/`items`, and per-part `minItems`/`maxItems`.
package check

import "base:intrinsics"
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
Factor_Array :: struct {
	unique_parts:   u64,
	spine_unique:   bool,
	need_unique:    bool,
	eval_all_items: u64,
	prefix:         []^Factor_Member,
	rest:           ^Factor_Member,
	contains:       []Factor_Contains,
	counts:         []Factor_Count,
}

@(private)
Unique_Entry :: struct {
	hash:      u64,
	is_scalar: bool,
	tok:       tape.Token,
	ref:       rules.Node_Ref,
}

@(private)
Arr_Open_State :: struct {
	contains_hits:  []u64,
	contains_evals: [dynamic]u64,
	elem_evals:     [dynamic]u64,
	elem_at:        [dynamic]u64,
	spilled_uniq:   bool,
	uniq_buckets:   map[u64][dynamic]Unique_Entry,
	cap_docs:       [dynamic]^tape.Document,
}

@(private)
array_factor_of :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> ^Factor {
	if b.err.kind != .None || node == rules.NONE { return nil }
	n := &d.nodes[node]
	if .Array not_in n.kinds { return nil }
	uneval_false := false
	if ui, has := n.unevaluated_items.?; has {
		ui_end := resolve_end_ro(b, d, arena, ui)
		if ui_end == rules.NONE || d.nodes[ui_end].kinds != {} { return nil }
		uneval_false = true
	}

	fb := Factor_Build{
		b = b, d = d, arena = arena, tables = b.tables,
		parts = make([dynamic]Part_Info, b.tables),
		ops = make([dynamic]Factor_Op, b.tables),
		closings = make([dynamic]Factor_Closing, b.tables),
		contains = make([dynamic]Contains_Build, b.tables),
		ok = true,
	}

	root_op := gather_container(&fb, node, edge, 0, nil, true)
	if !fb.ok || root_op < 0 || len(fb.parts) == 0 || len(fb.parts) > MAX_FACTOR_PARTS { return nil }

	r_outer, clash := rules.merged(n, edge)
	has_spine := clash == "" && (r_outer.min_items > 0 || r_outer.max_items != nil)
	has_const_part, has_inner_uniq := false, false
	max_prefix := 0
	for pt in fb.parts {
		has_const_part ||= pt.is_const
		has_inner_uniq ||= pt.unique_items
		if !pt.is_contains && !pt.is_presence {
			if pt.is_const {
				max_prefix = max(max_prefix, len(pt.const_arr))
			} else if pt.arr >= 0 {
				max_prefix = max(max_prefix, len(d.arrays[pt.arr].prefix))
			}
		}
	}
	need_unique := fb.spine_unique || has_inner_uniq
	if len(fb.parts) == 1 && ops_monotone(fb.ops[:]) && !need_unique && len(fb.contains) == 0 && !uneval_false && len(fb.closings) == 0 && !has_const_part && !has_spine {
		return nil
	}

	f := factor_init_common(&fb, root_op, uneval_false)
	if f == nil { return nil }
	fa, faerr := new(Factor_Array, arena)
	if faerr != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	f.arr = fa
	if has_spine {
		cnt_node := rules.Node{kinds = rules.EVERY_KIND, rules = {min_items = r_outer.min_items, max_items = r_outer.max_items}, array = -1, object = -1}
		f.spine_leaf = checked_leaf(b, &cnt_node, {}, arena)
	}

	fa.spine_unique, fa.need_unique = fb.spine_unique, need_unique
	counts_list := make([dynamic]Factor_Count, arena)
	for pt, pi in fb.parts {
		bit := u64(1) << uint(pi)
		if pt.is_presence || pt.is_contains { continue }
		if pt.unique_items { fa.unique_parts |= bit }
		if pt.min_members > 0 || pt.max_members < max(u64) {
			merge_factor_count(&counts_list, pt.min_members, pt.max_members, bit)
		}
		if pt.arr >= 0 && !pt.no_eval && d.arrays[pt.arr].items != rules.NONE { fa.eval_all_items |= bit }
	}
	fa.counts = counts_list[:]

	if len(fb.contains) > 0 {
		if len(fb.contains) > 64 { return nil }
		clist, cerr := make([]Factor_Contains, len(fb.contains), arena)
		if cerr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		for cb, i in fb.contains {
			clist[i] = {record = cb.record, min_contains = cb.min_c, max_contains = cb.max_c, evals = cb.evals, part = cb.part}
		}
		fa.contains = clist
	}

	if max_prefix > 0 {
		pref, perr := make([]^Factor_Member, max_prefix, arena)
		if perr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		for i in 0 ..< max_prefix {
			fm, ok := build_array_member(&fb, i)
			if !ok { return nil }
			pref[i] = fm
		}
		fa.prefix = pref
	}
	rest_fm, ok := build_array_member(&fb, -1)
	if !ok { return nil }
	fa.rest = rest_fm
	append(&b.factors, f)
	return f
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
		if pt.is_presence || pt.is_contains { continue }
		if pt.is_const {
			if elem_idx >= 0 && elem_idx < len(pt.const_arr) {
				c_node := const_member_node(fb.b, d, fb.arena, fb.tables, pt.const_arr[elem_idx])
				if c_node == rules.NONE { return nil, false }
				append(&cons, Factored_Constraint{node = c_node, part = u8(pi), scope = pt.scope, k_step = tape.Index(elem_idx), elem_idx = -1})
			}
			continue
		}
		if pt.arr < 0 { continue }
		a := &d.arrays[pt.arr]
		if elem_idx >= 0 && elem_idx < len(a.prefix) {
			if !pt.no_eval { fm.evals |= bit }
			append(&cons, Factored_Constraint{node = a.prefix[elem_idx], part = u8(pi), scope = pt.scope, k_step = tape.Name("items" if a.tuple else "prefixItems"), elem_idx = elem_idx})
		} else if a.items != rules.NONE {
			if !pt.no_eval { fm.evals |= bit }
			rest_kw := "unevaluatedItems" if pt.add_uneval else "additionalItems" if a.tuple else "items"
			append(&cons, Factored_Constraint{node = a.items, part = u8(pi), scope = pt.scope, k_step = tape.Name(rest_kw), elem_idx = -1})
		}
	}
	return compile_member_constraints(fb, fm, cons[:])
}

@(private)
factored_arr_open :: proc(h: ^Checker, fo: ^Factored_Open) -> bool {
	f := fo.factor
	fa := f.arr
	if fa.need_unique && !h.arr_uniq_in_use {
		h.arr_uniq_in_use = true
		fo.using_inline_uniq = true
		runtime.mem_zero(&h.arr_uniq_slots[0], size_of(h.arr_uniq_slots))
		h.arr_uniq_n = 0
		if len(fa.contains) == 0 && !f.uneval_false && len(f.closings) == 0 { return true }
	}
	if !fa.need_unique && len(fa.contains) == 0 && !f.uneval_false && len(f.closings) == 0 { return true }
	return ensure_arr_state(h, fo) != nil
}

@(private = "file")
ensure_arr_state :: proc(h: ^Checker, fo: ^Factored_Open) -> ^Arr_Open_State {
	if fo.arr_state != nil { return fo.arr_state }
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
	if st == nil { return }
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
			if d.ext == h.xml_ext { d.ext = nil }
			tape.destroy(d)
			free(d, h.scratch)
		}
	}
	delete(st.cap_docs)
	free(st, h.scratch)
}

@(private)
factored_arr_elem_member :: #force_inline proc "contextless" (fa: ^Factor_Array, elem_idx: u64) -> ^Factor_Member #no_bounds_check {
	return fa.prefix[elem_idx] if elem_idx < u64(len(fa.prefix)) else fa.rest
}

@(private = "file")
spill_inline_unique :: proc(h: ^Checker, fo: ^Factored_Open) -> ^Arr_Open_State {
	st := ensure_arr_state(h, fo)
	if st == nil || st.spilled_uniq { return st }
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
			if !uniq_bucket_add(h, st, hv, true, tok, {}) { return nil }
		}
		h.arr_uniq_in_use, fo.using_inline_uniq = false, false
	}
	return st
}

@(private = "file")
uniq_bucket_add :: proc(h: ^Checker, st: ^Arr_Open_State, hv: u64, is_scalar: bool, tok: tape.Token, ref: rules.Node_Ref) -> bool {
	entry := Unique_Entry{hash = hv, is_scalar = is_scalar, tok = tok, ref = ref}
	if prevs, exists := &st.uniq_buckets[hv]; exists {
		if _, aerr := append(prevs, entry); aerr != nil {
			h.fatal = .No_Memory
			return false
		}
		return true
	}
	list, lerr := make([dynamic]Unique_Entry, 0, 2, h.scratch)
	_, aerr := append(&list, entry)
	_, _, _, merr := map_entry(&st.uniq_buckets, hv)
	if lerr != nil || aerr != nil || merr != nil {
		delete(list)
		h.fatal = .No_Memory
		return false
	}
	st.uniq_buckets[hv] = list
	return true
}

@(private = "file")
uniq_bucket_check :: proc(h: ^Checker, st: ^Arr_Open_State, val: rules.Value) -> (hv: u64, is_dup: bool, ok: bool) {
	herr: runtime.Allocator_Error
	hv, herr = rules.value_hash(val, h.dups, h.scratch)
	if herr != nil {
		h.fatal = .No_Memory
		return 0, false, false
	}
	if prevs, exists := &st.uniq_buckets[hv]; exists {
		pnodes: [1]tape.Node = ---
		pdoc: tape.Document = ---
		for &p in prevs^ {
			if !charge_step_one(h) { return 0, false, false }
			pval: rules.Value
			if p.is_scalar {
				pnodes[0] = tape.Node(p.tok)
				pdoc = tape.Document{src = h.src, nodes = pnodes[:], format = h.format, ext = h.xml_ext}
				pval = rules.Node_Ref{doc = &pdoc, node = 0}
			} else {
				if p.ref.doc.ext == nil && h.xml_ext != nil { p.ref.doc.ext = h.xml_ext }
				pval = p.ref
			}
			eq, eerr := rules.value_equal(val, pval, h.dups, h.scratch)
			if eerr != nil {
				h.fatal = .No_Memory
				return 0, false, false
			}
			if eq { return hv, true, true }
		}
	}
	return hv, false, true
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
			if h.arr_uniq_strs[slot - 1] == s { return false }
			hv = (hv + 1) & 63
		}
	}
	st := spill_inline_unique(h, fo)
	if st == nil { return false }
	nodes := [1]tape.Node{tape.Node(t)}
	doc := tape.Document{src = h.src, nodes = nodes[:], format = h.format, ext = h.xml_ext}
	hv, is_dup, ok := uniq_bucket_check(h, st, rules.Node_Ref{doc = &doc, node = 0})
	if !ok || is_dup { return false }
	_ = uniq_bucket_add(h, st, hv, true, t, {})
	return true
}

@(private = "file")
check_arr_unique_ref :: proc(h: ^Checker, fo: ^Factored_Open, doc_val: tape.Document, doc_ptr: ^tape.Document, node: tape.Node_Index, adopted_copy: bool) -> (unique: bool, kept: bool) {
	st := spill_inline_unique(h, fo)
	if st == nil { return false, false }
	local_doc := doc_val
	cur_doc := doc_ptr if doc_ptr != nil else &local_doc
	if cur_doc.ext == nil && h.xml_ext != nil { cur_doc.ext = h.xml_ext }
	hv, is_dup, ok := uniq_bucket_check(h, st, rules.Node_Ref{doc = cur_doc, node = node})
	if !ok || is_dup { return false, false }
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
set_u64_slot :: proc(arr: ^[dynamic]u64, idx: u64, val: u64) {
	for len(arr^) <= int(idx) {
		append(arr, 0)
	}
	arr^[idx] = val
}

@(private = "file")
record_arr_elem_pos_and_refuse :: proc(h: ^Checker, fo: ^Factored_Open, fm: ^Factor_Member, elem_idx: u64, val_at: u64) {
	f := fo.factor
	if f.uneval_false || len(f.closings) > 0 {
		st := ensure_arr_state(h, fo)
		if st == nil { return }
		set_u64_slot(&st.elem_at, elem_idx, val_at)
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

@(private = "file")
record_arr_unique_fail :: proc(h: ^Checker, fo: ^Factored_Open) -> bool {
	f := fo.factor
	fa := f.arr
	fo.arr_unique_failed = true
	fo.failed |= fa.unique_parts
	if !fo.collect_errors && factored_can_record_first(h, fo) {
		if fa.spine_unique {
			record_first_factored_err(h, fo, .Not_Unique, fo.open_at, "uniqueItems", "", "", 0, false, nil, spine = true)
		} else if up := fa.unique_parts & ~f.no_emit_mask; up != 0 {
			record_first_factored_err(h, fo, .Not_Unique, fo.open_at, "uniqueItems", "", "", 0, false, nil, u8(intrinsics.count_trailing_zeros(up)))
		}
	}
	return fa.spine_unique && h.sink == nil && h.dups != .Last && h.dups != .Group && h.nest_depth == 0 && h.nf == 1 && h.choice_depth == 0
}

@(private = "file")
record_prefix_eval :: proc(h: ^Checker, fo: ^Factored_Open, fm: ^Factor_Member, elem_idx: u64) -> bool {
	f := fo.factor
	if fm == nil || (!f.uneval_false && len(f.closings) == 0) || elem_idx >= u64(len(f.arr.prefix)) {
		return true
	}
	st := ensure_arr_state(h, fo)
	if st == nil { return false }
	set_u64_slot(&st.elem_evals, elem_idx, fm.evals)
	return true
}

@(private)
factored_arr_scalar :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (doomed: bool) {
	if !charge_step_one(h) { return true }
	f := fo.factor
	fa := f.arr
	elem_idx := fo.seen_count
	fo.seen_count += 1

	if fa.need_unique && (!fo.arr_unique_failed || (!fo.collect_errors && (fa.unique_parts & ~fo.failed) != 0)) {
		if !check_arr_unique_scalar(h, fo, t) {
			if h.fatal != .None || record_arr_unique_fail(h, fo) { return true }
		}
		if h.fatal != .None { return true }
	}

	fm := factored_arr_elem_member(fa, elem_idx)
	fo.active_member = fm
	if fo.collect_errors {
		record_arr_elem_pos_and_refuse(h, fo, fm, elem_idx, t.lo)
		if h.fatal != .None { return true }
	}
	if fm != nil {
		fo.failed |= fm.refuse
		if !record_prefix_eval(h, fo, fm, elem_idx) || factored_scalar(h, fo, t) || h.fatal != .None {
			return true
		}
	}

	if len(fa.contains) > 0 {
		st := ensure_arr_state(h, fo)
		if st == nil { return true }
		cmask := u64(0)
		for c, ci in fa.contains {
			if !charge_step_one(h) { return true }
			if scalar_passes_record(h, c.record, t) {
				st.contains_hits[ci] += 1
				if c.evals { cmask |= u64(1) << uint(ci) }
			}
			if h.fatal != .None { return true }
		}
		if f.uneval_false || len(f.closings) > 0 { set_u64_slot(&st.contains_evals, elem_idx, cmask) }
	}
	return can_doom_factored(h, f, fo.failed)
}

@(private)
factored_arr_container :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (choice_rec: ^Record, use_fork: bool, for_elem: bool, skip: bool, doomed: bool) {
	if !charge_step_one(h) { return nil, false, false, false, true }
	fa := fo.factor.arr
	elem_idx := fo.seen_count
	fo.seen_count += 1

	fm := factored_arr_elem_member(fa, elem_idx)
	fo.active_member = fm
	if !record_prefix_eval(h, fo, fm, elem_idx) { return nil, false, false, false, true }
	if fo.collect_errors {
		record_arr_elem_pos_and_refuse(h, fo, fm, elem_idx, t.lo)
		if h.fatal != .None { return nil, false, false, false, true }
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
	if need_uniq || need_contains { return nil, false, true, false, false }
	crec, ufork, sk, dm := factored_container(h, fo, t)
	return crec, ufork, false, sk, dm
}

@(private)
factored_arr_finish_elem_capture :: proc(h: ^Checker, doc_val: tape.Document, owner: ^Record, fo_idx: int, fm: ^Factor_Member, at: u64) -> (ok: bool, adopted: bool) {
	fo := factored_at(h, fo_idx)
	return factored_arr_eval_elem_node(h, doc_val, nil, 0, fo_idx, fm, fo.seen_count - 1, adopt_doc = true)
}

@(private)
factored_arr_eval_elem_node :: proc(h: ^Checker, doc_val: tape.Document, doc_ptr: ^tape.Document, node: tape.Node_Index, fo_idx: int, fm: ^Factor_Member, elem_idx: u64, adopt_doc: bool) -> (ok: bool, adopted: bool) {
	local_doc := doc_val
	cur_doc := doc_ptr if doc_ptr != nil else &local_doc
	fo := factored_at(h, fo_idx)
	f := fo.factor
	fa := f.arr

	if fm != nil {
		fo.failed |= fm.refuse
		if eval_factored_fork_node(h, cur_doc, node, fo_idx, fm) || h.fatal != .None { return false, false }
		fo = factored_at(h, fo_idx)
	}

	if len(fa.contains) > 0 {
		st := ensure_arr_state(h, fo)
		if st == nil { return false, false }
		cmask := u64(0)
		for c, ci in fa.contains {
			if !charge_step_one(h) { return false, false }
			if subcheck_node(h, cur_doc, node, c.record, nil, nil, quiet = true) {
				st.contains_hits[ci] += 1
				if c.evals { cmask |= u64(1) << uint(ci) }
			}
			if h.fatal != .None { return false, false }
			fo = factored_at(h, fo_idx)
		}
		if f.uneval_false || len(f.closings) > 0 { set_u64_slot(&st.contains_evals, elem_idx, cmask) }
	}

	if fa.need_unique && (!fo.arr_unique_failed || (!fo.collect_errors && (fa.unique_parts & ~fo.failed) != 0)) {
		uniq, kept := check_arr_unique_ref(h, fo, local_doc, doc_ptr, node, adopt_doc)
		adopted = kept
		if h.fatal != .None { return false, adopted }
		fo = factored_at(h, fo_idx)
		if !uniq && record_arr_unique_fail(h, fo) { return false, adopted }
	}
	return !can_doom_factored(h, f, fo.failed), adopted
}

@(private)
all_items_evaluated :: proc "contextless" (fa: ^Factor_Array, st: ^Arr_Open_State, count: u64, active: u64) -> bool #no_bounds_check {
	if count == 0 { return true }
	eval_all := (active & fa.eval_all_items) != 0
	if eval_all && len(fa.prefix) == 0 { return true }
	active_contains := u64(0)
	for c, ci in fa.contains {
		if c.evals && ((u64(1) << c.part) & active) != 0 { active_contains |= u64(1) << uint(ci) }
	}
	if !eval_all && count > u64(len(fa.prefix)) && active_contains == 0 { return false }
	pref_n := int(min(count, u64(len(fa.prefix))))
	for i in 0 ..< int(count) {
		if i < pref_n {
			pe := st.elem_evals[i] if (st != nil && i < len(st.elem_evals)) else fa.prefix[i].evals
			if (pe & active) != 0 { continue }
		} else if eval_all {
			return true
		}
		if st != nil && i < len(st.contains_evals) && (st.contains_evals[i] & active_contains) != 0 {
			continue
		}
		return false
	}
	return true
}
