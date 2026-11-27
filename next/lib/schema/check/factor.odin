// 4-stage factored held-object/array compiler & runtime.
// Compiles flat & nested held containers (`allOf`, `anyOf`, `oneOf`, `not`, `if/then/else`, `$ref`,
// `$dynamicRef`, `dependentSchemas`, `dependentRequired`, `patternProperties`, `additionalProperties: false`,
// `unevaluatedProperties`/`unevaluatedItems: false`, multi-record choices, and spine counts) into a single
// factored `.Checked` record evaluated in one pass.
package check

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

@(private)
MAX_FACTOR_PARTS :: 64

@(private)
MAX_FACTOR_PATTERNS :: 4

@(private)
MAX_FACTOR_DEPTH :: 64

@(private)
Factor_Op_Kind :: enum u8 {
	Part,
	All,
	Any,
	One,
	Not,
	If,
	Any_Mask,
	One_Mask,
}

@(private)
Factor_Op :: struct {
	kind:    Factor_Op_Kind,
	bit:     u8,
	is_enum: bool,
	first:   i16,
	count:   i16,
	else_op: i16,
	mask:    u64,
	site:    []tape.Step,
}

@(private)
Member_Site :: struct {
	parts: u64,
	site:  []tape.Step,
}

@(private)
Factor_Table :: struct {
	keys:  []string,
	parts: []u64,
	all:   u64,
}

@(private)
Factor_Leaf :: struct {
	leaf:  i32,
	parts: u64,
	sites: []Member_Site,
}

@(private)
Factor_Choice :: struct {
	record: i32,
	parts:  u64,
	sites:  []Member_Site,
}

@(private)
Factor_Member :: struct {
	evals:        u64,
	refuse:       u64,
	table:        ^Factor_Table,
	table_leaves: []Factor_Leaf,
	leaves:       []Factor_Leaf,
	choices:      []Factor_Choice,
	refuse_sites: []Member_Site,
}

@(private)
Part_Const_Kind :: enum u8 {
	None,
	Const,
	Enum,
}

@(private)
Part_Meta :: struct {
	site:       []tape.Step,
	fail_leaf:  i32,
	const_kind: Part_Const_Kind,
	uneval_kw:  string,
	no_emit:    bool,
}

@(private)
Factored_Err_Kind :: enum u8 {
	Direct,
	Choice_Span,
}

@(private)
Factored_Err :: struct {
	kind:         Factored_Err_Kind,
	no_emit_mask: u64,
	err_kind:     Error_Kind,
	at:           u64,
	keyword:      string,
	expected:     string,
	member_name:  string,
	member_owned: bool,
	elem_idx:     u64,
	has_member:   bool,
	sites:        []Member_Site,
	part:         u8,
	extra_kw:     string,
	choice_from:  int,
	choice_to:    int,
	base_kw_len:  int,
}

@(private)
Seen_Member_Pos :: struct {
	name:       string,
	name_owned: bool,
	val_at:     u64,
	member_idx: i32,
	cls:        u8,
}

@(private)
Factor_Required :: struct {
	member: i32,
	parts:  u64,
}

@(private)
Factor_Presence :: struct {
	member: i32,
	part:   u8,
}

// Per-part count constraint (`minProperties`/`maxProperties` or `minItems`/`maxItems`).
@(private)
Factor_Count :: struct {
	min_n: u64,
	max_n: u64,
	parts: u64,
}

@(private)
Factor_Closing :: struct {
	part:    u8,
	root_op: i16,
}

@(private)
Factor_Dep_Required :: struct {
	trigger: i32,
	wants:   []i32,
	parts:   u64,
	keyword: string,
}

@(private)
Factor_Keys :: struct {
	leaf:  i32,
	parts: u64,
}

@(private)
Factor :: struct {
	owner:         i32,
	n:             u8,
	block:         i32,
	members:       i32,
	ops:           []Factor_Op,
	monotone:      bool,
	direct_errors: bool,
	uneval_false:  bool,
	spine_leaf:    i32,
	patterns:      []^regex.Regex,
	classes:       [16]^Factor_Member,
	required:      []Factor_Required,
	dep_required:  []Factor_Dep_Required,
	keys:          []Factor_Keys,
	presence:      []Factor_Presence,
	counts:        []Factor_Count,
	closings:      []Factor_Closing,
	part_meta:     []Part_Meta,
	all_parts:     u64,
	eval_all:      u64,
	no_emit_mask:  u64,
	arr:           ^Factor_Array,
}

@(private)
Factored_Open :: struct {
	factor:            ^Factor,
	owner:             ^Record,
	failed:            u64,
	seen_mask:         u64,
	seen_wide:         []u64,
	seen_count:        u64,
	unknown_classes:   u16,
	active_member:     ^Factor_Member,
	active_choice:     int,
	parent_sp:         int,
	saved_quiet:       bool,
	saved_sink:        ^Sink,
	saved_buffering:   bool,
	saved_choice_fo:   i16,
	saved_no_factor:   bool,
	saved_failed:      bool,
	open_at:           u64,
	unk_tracker:       int,
	using_inline_uniq: bool,
	arr_unique_failed: bool,
	arr_state:         ^Arr_Open_State,
	doc:               ^tape.Document,
	doc_node:          tape.Node_Index,
	collect_errors:    bool,
	err_entries:       [dynamic]Factored_Err,
	seen_pos:          [dynamic]Seen_Member_Pos,
	choice_sink:       Sink,
	choice_no_member:  [dynamic]bool,
	choice_mark:       int,
	choice_base_kw:    int,
	cur_seen_idx:      i32,
	cur_seen_cls:      u8,
	last_cls:          u8,
}

@(private)
Factor_Build :: struct {
	b:            ^Builder,
	d:            ^rules.Description,
	arena:        runtime.Allocator,
	tables:       runtime.Allocator,
	parts:        [dynamic]Part_Info,
	ops:          [dynamic]Factor_Op,
	patterns:     [dynamic]string,
	pat_re:       [dynamic]^regex.Regex,
	closings:     [dynamic]Factor_Closing,
	presence:     [dynamic]Presence_Build,
	contains:     [dynamic]Contains_Build,
	spine_unique: bool,
	ok:           bool,
}

@(private)
Part_Info :: struct {
	node:          rules.Node_Index,
	obj:           i32,
	arr:           i32,
	scope:         i32,
	site:          []tape.Step,
	fail_leaf:     i32,
	const_kind:    Part_Const_Kind,
	uneval_kw:     string,
	min_members:   u64,
	max_members:   u64,
	eval_all:      bool,
	add_false:     bool,
	add_uneval:    bool,
	add_node:      rules.Node_Index,
	keys_node:     rules.Node_Index,
	keys_scope:    i32,
	no_eval:       bool,
	is_const:      bool,
	const_vals:    []rules.Member_Value,
	const_arr:     []rules.Value,
	unique_items:  bool,
	is_contains:   bool,
	is_presence:   bool,
	presence_name: string,
}

@(private)
Presence_Build :: struct {
	name: string,
	part: u8,
}

@(private)
Contains_Build :: struct {
	record: i32,
	min_c:  u64,
	max_c:  u64,
	evals:  bool,
	part:   u8,
}

@(private)
Choice_Sink_Guard :: struct {
	sink:      ^Sink,
	quiet:     bool,
	buffering: bool,
	choice_fo: i16,
}

@(private)
choice_sink_enter :: proc(h: ^Checker, fo: ^Factored_Open, fo_idx: int) -> (g: Choice_Sink_Guard, mark, outer_kw: int) {
	choice_sink_ensure(h, fo)
	g = {h.sink, h.quiet, h.buffering_choice, h.choice_sink_fo}
	mark = len(fo.choice_sink.entries)
	outer_kw = factored_outer_kw_len(h, fo)
	h.sink, h.quiet, h.buffering_choice, h.choice_sink_fo = &fo.choice_sink, false, true, i16(fo_idx)
	return
}

@(private)
choice_sink_leave :: #force_inline proc(h: ^Checker, g: Choice_Sink_Guard) {
	h.sink, h.quiet, h.buffering_choice, h.choice_sink_fo = g.sink, g.quiet, g.buffering, g.choice_fo
}

@(private)
choice_sink_enter_open :: proc(h: ^Checker, fo: ^Factored_Open, fo_idx: int) {
	choice_sink_ensure(h, fo)
	fo.choice_mark = len(fo.choice_sink.entries)
	fo.choice_base_kw = factored_outer_kw_len(h, fo)
	h.sink, h.quiet, h.buffering_choice, h.choice_sink_fo = &fo.choice_sink, false, true, i16(fo_idx)
}

@(private)
choice_sink_restore_fo :: #force_inline proc(h: ^Checker, fo: ^Factored_Open, quiet := true) {
	h.sink, h.quiet, h.buffering_choice, h.choice_sink_fo = fo.saved_sink, quiet, fo.saved_buffering, fo.saved_choice_fo
}

@(private)
merge_factor_count :: proc(list: ^[dynamic]Factor_Count, lo, hi, bit: u64) {
	for &c in list^ {
		if c.min_n == lo && c.max_n == hi {
			c.parts |= bit
			return
		}
	}
	append(list, Factor_Count{min_n = lo, max_n = hi, parts = bit})
}

@(private)
factor_init_common :: proc(fb: ^Factor_Build, root_op: i16, uneval_false: bool) -> ^Factor {
	b, arena := fb.b, fb.arena
	ops_slice := ops_flatten(fb, root_op)
	if len(ops_slice) == 0 { return nil }
	f, ferr := new(Factor, arena)
	if ferr != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	f.n = u8(len(fb.parts))
	f.ops = ops_slice
	f.uneval_false = uneval_false
	f.all_parts = ~u64(0) if f.n == 64 else (u64(1) << f.n) - 1
	f.monotone = ops_monotone(f.ops)
	f.direct_errors = ops_conjunctive_only(f.ops) && len(fb.closings) == 0
	f.part_meta, f.no_emit_mask = finalize_part_meta(b, arena, fb.parts[:])
	if len(fb.closings) > 0 {
		cl, clerr := make([]Factor_Closing, len(fb.closings), arena)
		if clerr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		copy(cl, fb.closings[:])
		f.closings = cl
	}
	return f
}

// Compiles held node `node` (with `edge`) into a 4-stage object `Factor`, or returns nil if ineligible.
@(private)
factor_of :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> ^Factor {
	if b.err.kind != .None || node == rules.NONE { return nil }
	n := &d.nodes[node]
	if .Object not_in n.kinds || n.rules.unique { return nil }
	uneval_false := false
	if up, has := n.unevaluated_properties.?; has {
		up_end := resolve_end_ro(b, d, arena, up)
		if up_end == rules.NONE || d.nodes[up_end].kinds != {} { return nil }
		uneval_false = true
	}

	fb := Factor_Build{
		b = b, d = d, arena = arena, tables = b.tables,
		parts = make([dynamic]Part_Info, b.tables),
		ops = make([dynamic]Factor_Op, b.tables),
		patterns = make([dynamic]string, b.tables),
		pat_re = make([dynamic]^regex.Regex, b.tables),
		closings = make([dynamic]Factor_Closing, b.tables),
		presence = make([dynamic]Presence_Build, b.tables),
		ok = true,
	}

	root_op := gather_container(&fb, node, edge, 0, nil, false)
	if !fb.ok || root_op < 0 || len(fb.parts) == 0 || len(fb.parts) > MAX_FACTOR_PARTS || len(fb.patterns) > MAX_FACTOR_PATTERNS {
		return nil
	}

	r_outer, clash := rules.merged(n, edge)
	has_spine := clash == "" && (r_outer.min_members > 0 || r_outer.max_members != nil)
	has_const_part := false
	for pt in fb.parts {
		if pt.is_const {
			has_const_part = true
			break
		}
	}
	if len(fb.parts) == 1 && ops_monotone(fb.ops[:]) && len(fb.patterns) == 0 && !uneval_false && len(fb.closings) == 0 && !has_const_part && !has_spine && fb.parts[0].keys_node == rules.NONE {
		return nil
	}

	f := factor_init_common(&fb, root_op, uneval_false)
	if f == nil { return nil }

	name_to_idx := make(map[string]i32, 16, b.tables)
	names := make([dynamic]string, b.tables)
	add_name :: proc(b: ^Builder, arena: runtime.Allocator, name_to_idx: ^map[string]i32, names: ^[dynamic]string, nm: string) -> i32 {
		if idx, exists := name_to_idx[nm]; exists { return idx }
		idx := i32(len(names))
		cloned := clone_str(b, arena, nm)
		name_to_idx[cloned] = idx
		append(names, cloned)
		return idx
	}
	for pt in fb.parts {
		if pt.is_presence {
			add_name(b, arena, &name_to_idx, &names, pt.presence_name)
			continue
		}
		if pt.is_const {
			for mv in pt.const_vals {
				add_name(b, arena, &name_to_idx, &names, mv.key)
			}
		}
		if pt.obj >= 0 {
			o := &d.objects[pt.obj]
			for m in o.members {
				add_name(b, arena, &name_to_idx, &names, m.name)
			}
			for dep in o.dependents {
				if len(dep.required) > 0 {
					add_name(b, arena, &name_to_idx, &names, dep.name)
					for w in dep.required {
						add_name(b, arena, &name_to_idx, &names, w)
					}
				}
			}
		}
	}

	block_at, _ := block_of(b, len(names) + 1, {})
	if block_at < 0 { return nil }
	end_at := int(block_at) + len(names)
	b.ends[block_at] = i32(end_at)
	never(b, end_at)
	f.block, f.members = block_at, i32(len(names))

	if len(fb.pat_re) > 0 {
		pats, perr := make([]^regex.Regex, len(fb.pat_re), arena)
		if perr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		copy(pats, fb.pat_re[:])
		f.patterns = pats
	}
	if has_spine {
		cnt_node := rules.Node{kinds = rules.EVERY_KIND, rules = {min_members = r_outer.min_members, max_members = r_outer.max_members}, array = -1, object = -1}
		f.spine_leaf = checked_leaf(b, &cnt_node, {}, arena)
	}

	req_masks := make([]u64, len(names), b.tables)
	counts_list := make([dynamic]Factor_Count, arena)
	dep_req_list := make([dynamic]Factor_Dep_Required, arena)
	keys_list := make([dynamic]Factor_Keys, arena)
	for pt, pi in fb.parts {
		bit := u64(1) << uint(pi)
		if pt.is_presence { continue }
		if pt.eval_all && !pt.no_eval { f.eval_all |= bit }
		if pt.min_members > 0 || pt.max_members < max(u64) {
			merge_factor_count(&counts_list, pt.min_members, pt.max_members, bit)
		}
		for mv in pt.const_vals {
			req_masks[name_to_idx[mv.key]] |= bit
		}
		if pt.keys_node != rules.NONE {
			sv := b.scope
			b.scope = pt.keys_scope
			kl := checked_leaf(b, &d.nodes[pt.keys_node], {}, arena)
			b.scope = sv
			if b.err.kind != .None { return nil }
			if kl > 0 {
				merged_k := false
				for &fk in keys_list {
					if fk.leaf == kl {
						fk.parts |= bit
						merged_k = true
						break
					}
				}
				if !merged_k {
					append(&keys_list, Factor_Keys{leaf = kl, parts = bit})
				}
			}
		}
		if pt.obj >= 0 {
			o := &d.objects[pt.obj]
			for m in o.members {
				if m.required { req_masks[name_to_idx[m.name]] |= bit }
			}
			kw := "dependencies" if o.dependencies else "dependentRequired"
			for dep in o.dependents {
				if len(dep.required) > 0 {
					wants, werr := make([]i32, len(dep.required), arena)
					if werr != nil {
						refuse_plan(b, .No_Memory)
						return nil
					}
					for wnm, j in dep.required {
						wants[j] = name_to_idx[wnm]
					}
					append(&dep_req_list, Factor_Dep_Required{trigger = name_to_idx[dep.name], wants = wants, parts = bit, keyword = kw})
				}
			}
		}
	}
	req_list := make([dynamic]Factor_Required, arena)
	for mask, idx in req_masks {
		if mask != 0 {
			append(&req_list, Factor_Required{member = i32(idx), parts = mask})
		}
	}
	f.required, f.dep_required, f.keys, f.counts = req_list[:], dep_req_list[:], keys_list[:], counts_list[:]

	if len(fb.presence) > 0 {
		pres, prerr := make([]Factor_Presence, len(fb.presence), arena)
		if prerr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		for pr, i in fb.presence {
			pres[i] = {member = name_to_idx[pr.name], part = pr.part}
		}
		f.presence = pres
	}

	re_scratch, re_err := regex.scratch_make(b.tables)
	if re_err.kind != .None { return nil }
	defer regex.scratch_destroy(&re_scratch)

	for nm, idx in names {
		pat_mask := u8(0)
		for re, pi in f.patterns {
			found, serr := regex.search(re, nm, 0, nil, &re_scratch)
			if serr.kind != .None { return nil }
			if found { pat_mask |= u8(1) << uint(pi) }
		}
		fm, ok := build_factor_member(&fb, nm, pat_mask, false)
		if !ok { return nil }
		rec_idx := int(block_at) + idx
		b.records[rec_idx] = Record{word = NO_KEY, meta = u32(rec_idx), kind = .Checked}
		b.meta[rec_idx] = Meta{name = nm, block = -1}
		b.uses[rec_idx] = Use{member = fm}
	}
	for c in 0 ..< (1 << uint(len(f.patterns))) {
		fm, ok := build_factor_member(&fb, "", u8(c), true)
		if !ok { return nil }
		f.classes[c] = fm
	}
	append(&b.factors, f)
	return f
}

@(private)
site_concat :: proc(b: ^Builder, arena: runtime.Allocator, base: []tape.Step, extra: ..tape.Step) -> []tape.Step {
	if len(base) == 0 && len(extra) == 0 { return nil }
	out, err := make([]tape.Step, len(base) + len(extra), arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	copy(out, base)
	for s, i in extra {
		#partial switch v in s {
		case tape.Name:  out[len(base) + i] = tape.Name(clone_str(b, arena, string(v)))
		case tape.Index: out[len(base) + i] = v
		}
	}
	return out
}

@(private)
site_with_words :: proc(b: ^Builder, arena: runtime.Allocator, base: []tape.Step, words: []string) -> []tape.Step {
	if len(words) == 0 { return base if len(base) > 0 else nil }
	out, err := make([]tape.Step, len(base) + len(words), arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	copy(out, base)
	for w, i in words {
		out[len(base) + i] = tape.Name(w)
	}
	return out
}

@(private)
finalize_part_meta :: proc(b: ^Builder, arena: runtime.Allocator, parts: []Part_Info) -> (meta: []Part_Meta, no_emit: u64) {
	m, err := make([]Part_Meta, len(parts), arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return nil, 0
	}
	for pt, i in parts {
		ne := pt.is_const || pt.is_presence || pt.fail_leaf > 0 || pt.uneval_kw != ""
		m[i] = {site = pt.site, fail_leaf = pt.fail_leaf, const_kind = pt.const_kind, uneval_kw = pt.uneval_kw, no_emit = ne}
		if ne { no_emit |= u64(1) << uint(i) }
	}
	return m, no_emit
}

// Unified recursive circuit gatherer for both object (`is_array = false`) and array (`is_array = true`) factoring.
@(private)
gather_container :: proc(fb: ^Factor_Build, node: rules.Node_Index, edge: rules.Rules, depth: int, site_prefix: []tape.Step, $is_array: bool) -> i16 {
	if !fb.ok || depth > 32 {
		fb.ok = false
		return -1
	}
	if node == rules.NONE { return add_trivial_part(fb, site_prefix) }
	b, d := fb.b, fb.d
	saved_scope := b.scope
	defer b.scope = saved_scope
	words := make([dynamic]string, fb.tables)
	end_node := resolve_end(b, d, fb.arena, node, &words)
	site := site_with_words(b, fb.arena, site_prefix, words[:])
	if end_node == rules.NONE { return add_trivial_part(fb, site) }
	n := &d.nodes[end_node]
	want_kind := rules.Kind.Array if is_array else rules.Kind.Object
	if want_kind not_in n.kinds { return add_fail_part(fb, end_node, edge, site) }
	when !is_array {
		if n.rules.unique {
			fb.ok = false
			return -1
		}
	}
	part_uneval_false := false
	uneval_node := n.unevaluated_items if is_array else n.unevaluated_properties
	if u_n, has := uneval_node.?; has && depth > 0 {
		u_end := resolve_end_ro(b, d, fb.arena, u_n)
		if u_end == rules.NONE || d.nodes[u_end].kinds != {} {
			fb.ok = false
			return -1
		}
		part_uneval_false = true
	}

	children := make([dynamic]i16, fb.tables)
	if n.const_of != nil {
		cand_op := gather_const_container(fb, n, site, is_array)
		if !fb.ok { return -1 }
		append(&children, cand_op)
	}
	if n.has_enum {
		enum_op := gather_enum_container(fb, n, site, is_array)
		if !fb.ok { return -1 }
		append(&children, enum_op)
	}

	r_merged, clash := rules.merged(n, edge)
	if clash != "" {
		fb.ok = false
		return -1
	}

	when is_array {
		if depth == 0 && r_merged.unique { fb.spine_unique = true }
		has_own := (n.array >= 0 && (len(d.arrays[n.array].prefix) > 0 || d.arrays[n.array].items != rules.NONE)) || (depth > 0 && (r_merged.min_items > 0 || r_merged.max_items != nil || r_merged.unique))
		if has_own {
			p := empty_part(site)
			p.node, p.arr, p.scope = end_node, n.array, b.scope
			p.min_members = r_merged.min_items if depth > 0 else 0
			p.max_members = (r_merged.max_items.? or_else max(u64)) if depth > 0 else max(u64)
			p.unique_items = depth > 0 && r_merged.unique
			p.add_uneval = n.array >= 0 && b.unevaluated[{1, n.array}]
			op_idx := add_part_op(fb, p)
			if op_idx < 0 { return -1 }
			append(&children, op_idx)
		}
		if n.array >= 0 {
			a := &d.arrays[n.array]
			if c, has_c := a.contains.?; has_c {
				csite := [1]tape.Step{tape.Name("contains")}
				p := empty_part(site)
				p.max_members, p.is_contains = max(u64), true
				c_bit := u8(len(fb.parts))
				op_idx := add_part_op(fb, p)
				if op_idx < 0 { return -1 }
				append(&fb.contains, Contains_Build{record = arm_record(b, d, fb.arena, c, csite[:]), min_c = a.min_contains.? or_else 1, max_c = a.max_contains.? or_else max(u64), evals = a.evaluates_contains, part = c_bit})
				append(&children, op_idx)
			}
		}
	} else {
		has_own := depth > 0 && (r_merged.min_members > 0 || r_merged.max_members != nil)
		keys_node := rules.Node_Index(rules.NONE)
		keys_scope := b.scope
		if n.object >= 0 {
			o := &d.objects[n.object]
			if o.keys != rules.NONE {
				sv_ks := b.scope
				k_end := resolve_end(b, d, fb.arena, o.keys)
				k_scope := b.scope
				b.scope = sv_ks
				if k_end == rules.NONE {
					fb.ok = false
					return -1
				}
				if !judges_nothing(b, d, k_end) {
					if holds(b, d, k_end, {}) {
						fb.ok = false
						return -1
					}
					keys_node, keys_scope, has_own = k_end, k_scope, true
				}
			}
			for dep in o.dependents {
				if len(dep.required) > 0 {
					has_own = true
					break
				}
			}
			if len(o.members) > 0 || len(o.patterns) > 0 || o.additional != rules.NONE { has_own = true }
			for p in o.patterns {
				if !slice.contains(fb.patterns[:], p.expression) {
					if len(fb.patterns) >= MAX_FACTOR_PATTERNS {
						fb.ok = false
						return -1
					}
					re, rerr := rules.program_of(&b.programs, p.expression, fb.arena, fb.tables)
					if rerr.kind != .None {
						fb.ok = false
						return -1
					}
					append(&fb.patterns, clone_str(b, fb.arena, p.expression))
					append(&fb.pat_re, re)
				}
			}
		}
		if has_own {
			pi := empty_part(site)
			pi.node, pi.obj, pi.scope = end_node, n.object, b.scope
			pi.min_members = r_merged.min_members if depth > 0 else 0
			pi.max_members = (r_merged.max_members.? or_else max(u64)) if depth > 0 else max(u64)
			pi.keys_node, pi.keys_scope = keys_node, keys_scope
			if n.object >= 0 {
				o := &d.objects[n.object]
				pi.add_uneval = b.unevaluated[{0, n.object}]
				if o.additional != rules.NONE {
					add_end := resolve_end_ro(b, d, fb.arena, o.additional)
					if add_end != rules.NONE && d.nodes[add_end].kinds == {} {
						pi.add_false = true
					} else {
						pi.eval_all, pi.add_node = true, o.additional
					}
				}
			}
			op_idx := add_part_op(fb, pi)
			if op_idx < 0 { return -1 }
			append(&children, op_idx)
		}
		if n.object >= 0 {
			o := &d.objects[n.object]
			kw := "dependencies" if o.dependencies else "dependentSchemas"
			for dep in o.dependents {
				dn, has := dep.node.?
				if !has { continue }
				p_bit := u8(len(fb.parts))
				p := empty_part(site)
				p.is_presence, p.presence_name = true, dep.name
				cond_op := add_part_op(fb, p)
				if cond_op < 0 { return -1 }
				append(&fb.presence, Presence_Build{name = dep.name, part = p_bit})
				then_op := gather_container(fb, dn, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name(kw), tape.Name(dep.name)), false)
				if !fb.ok { return -1 }
				if_op := i16(len(fb.ops))
				append(&fb.ops, Factor_Op{kind = .If, first = cond_op, count = then_op, else_op = -1})
				append(&children, if_op)
			}
		}
	}

	if r, has := n.ref.?; has {
		sv := b.scope
		enter_scope(b, d, fb.arena, r)
		sub := gather_container(fb, r, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name(rules.ref_keyword(n))), is_array)
		b.scope = sv
		if !fb.ok { return -1 }
		append(&children, sub)
	}
	if dr, has := n.dynamic_ref.?; has {
		target := dynamic_target(b, d, n, dr)
		sv := b.scope
		enter_scope(b, d, fb.arena, target)
		sub := gather_container(fb, target, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name(rules.dynamic_keyword(n))), is_array)
		b.scope = sv
		if !fb.ok { return -1 }
		append(&children, sub)
	}
	for a, idx in n.all_of {
		sub := gather_container(fb, a, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name("allOf"), tape.Index(idx)), is_array)
		if !fb.ok { return -1 }
		append(&children, sub)
	}
	for grp in ([2]struct { kind: Factor_Op_Kind, kw: string, list: []rules.Node_Index }{{.Any, "anyOf", n.any_of}, {.One, "oneOf", n.one_of}}) {
		if len(grp.list) == 0 { continue }
		arms := make([dynamic]i16, fb.tables)
		for a, idx in grp.list {
			sub := gather_container(fb, a, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name(grp.kw), tape.Index(idx)), is_array)
			if !fb.ok { return -1 }
			append(&arms, sub)
		}
		append(&children, emit_group_op(fb, grp.kind, arms[:], site))
	}
	if nt, has := n.not.?; has {
		sub := gather_container(fb, nt, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name("not")), is_array)
		if !fb.ok { return -1 }
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Not, first = sub, site = site})
		append(&children, op_idx)
	}
	if test, has := n.cond.test.?; has {
		test_op := gather_container(fb, test, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name("if")), is_array)
		then_op := gather_container(fb, n.cond.then.?, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name("then")), is_array) if n.cond.then != nil else -1
		else_op := gather_container(fb, n.cond.other.?, {}, depth + 1, site_concat(b, fb.arena, site, tape.Name("else")), is_array) if n.cond.other != nil else -1
		if !fb.ok { return -1 }
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .If, first = test_op, count = then_op, else_op = else_op, site = site})
		append(&children, op_idx)
	}

	if len(children) == 0 { return add_trivial_part(fb, site) }
	res := children[0] if len(children) == 1 else emit_group_op(fb, .All, children[:], site)

	if part_uneval_false {
		u_kw := "unevaluatedItems" if is_array else "unevaluatedProperties"
		c_bit := u8(len(fb.parts))
		p := empty_part(site_concat(b, fb.arena, site, tape.Name(u_kw)))
		p.uneval_kw, p.max_members = u_kw, max(u64)
		c_op := add_part_op(fb, p)
		if c_op < 0 { return -1 }
		append(&fb.closings, Factor_Closing{part = c_bit, root_op = res})
		pair := [2]i16{res, c_op}
		res = emit_group_op(fb, .All, pair[:], site)
	}
	return res
}

@(private = "file")
empty_part :: #force_inline proc "contextless" (site: []tape.Step) -> Part_Info {
	return {node = rules.NONE, obj = -1, arr = -1, site = site, add_node = rules.NONE, keys_node = rules.NONE}
}

@(private = "file")
add_part_op :: proc(fb: ^Factor_Build, part: Part_Info, is_enum := false, op_site: []tape.Step = nil) -> i16 {
	if len(fb.parts) >= MAX_FACTOR_PARTS {
		fb.ok = false
		return -1
	}
	bit := u8(len(fb.parts))
	append(&fb.parts, part)
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Part, bit = bit, is_enum = is_enum, site = op_site})
	return op_idx
}

@(private)
gather_const_container :: proc(fb: ^Factor_Build, n: ^rules.Node, site: []tape.Step, $is_array: bool) -> i16 {
	b := fb.b
	c := n.const_of.?
	want: rules.Value_Kind = .Array if is_array else .Object
	if rules.value_kind(c) != want { return add_const_fail_part(fb, .Const, site) }
	cloned := clone_value(b, c, fb.arena, fb.tables)
	if b.err.kind != .None {
		fb.ok = false
		return -1
	}
	part := empty_part(site)
	part.scope, part.const_kind, part.no_eval, part.is_const = b.scope, .Const, true, true
	when is_array {
		av, ok := cloned.([]rules.Value)
		if !ok { fb.ok = false; return -1 }
		part.min_members, part.max_members, part.const_arr = u64(len(av)), u64(len(av)), av
	} else {
		mv, ok := cloned.([]rules.Member_Value)
		if !ok { fb.ok = false; return -1 }
		part.min_members, part.max_members, part.const_vals = u64(len(mv)), u64(len(mv)), mv
	}
	return add_part_op(fb, part)
}

@(private)
gather_enum_container :: proc(fb: ^Factor_Build, n: ^rules.Node, site: []tape.Step, $is_array: bool) -> i16 {
	b := fb.b
	want: rules.Value_Kind = .Array if is_array else .Object
	Elem :: []rules.Value when is_array else []rules.Member_Value
	cands := make([dynamic]Elem, fb.tables)
	for ev in n.enum_of {
		if rules.value_kind(ev) != want { continue }
		if len(cands) >= 16 { fb.ok = false; return -1 }
		cloned := clone_value(b, ev, fb.arena, fb.tables)
		if b.err.kind != .None { fb.ok = false; return -1 }
		if v, ok := cloned.(Elem); ok { append(&cands, v) }
	}
	if len(cands) == 0 { return add_const_fail_part(fb, .Enum, site) }
	mask := u64(0)
	for v in cands {
		if len(fb.parts) >= MAX_FACTOR_PARTS { fb.ok = false; return -1 }
		bit := u8(len(fb.parts))
		part := empty_part(site)
		part.scope, part.const_kind, part.min_members, part.max_members, part.no_eval, part.is_const = b.scope, .Enum, u64(len(v)), u64(len(v)), true, true
		when is_array { part.const_arr = v } else { part.const_vals = v }
		append(&fb.parts, part)
		mask |= u64(1) << bit
	}
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Any_Mask, mask = mask, is_enum = true, site = site})
	return op_idx
}

@(private)
add_const_fail_part :: proc(fb: ^Factor_Build, ck: Part_Const_Kind, site: []tape.Step) -> i16 {
	p := empty_part(site)
	p.const_kind, p.no_eval, p.min_members = ck, true, max(u64)
	return add_part_op(fb, p, is_enum = (ck == .Enum), op_site = site)
}

@(private)
add_trivial_part :: proc(fb: ^Factor_Build, site: []tape.Step) -> i16 {
	p := empty_part(site)
	p.max_members = max(u64)
	return add_part_op(fb, p)
}

@(private)
add_fail_part :: proc(fb: ^Factor_Build, end_node: rules.Node_Index, edge: rules.Rules, site: []tape.Step) -> i16 {
	fl := i32(0)
	if end_node != rules.NONE {
		judged := fb.d.nodes[end_node]
		if arm_operands(&judged) { judged.has_enum, judged.enum_of, judged.const_of = false, nil, nil }
		fl = checked_leaf(fb.b, &judged, edge, fb.arena)
		if fb.b.err.kind != .None { fb.ok = false; return -1 }
	}
	p := empty_part(site)
	p.fail_leaf, p.min_members = fl, max(u64)
	return add_part_op(fb, p)
}

@(private)
emit_group_op :: proc(fb: ^Factor_Build, kind: Factor_Op_Kind, children: []i16, site: []tape.Step) -> i16 {
	if kind == .Any || kind == .One {
		all_parts := true
		mask := u64(0)
		for ch in children {
			op := fb.ops[ch]
			bit := u64(1) << op.bit
			if op.kind != .Part || op.is_enum || (mask & bit) != 0 {
				all_parts = false
				break
			}
			mask |= bit
		}
		if all_parts {
			op_idx := i16(len(fb.ops))
			append(&fb.ops, Factor_Op{kind = .Any_Mask if kind == .Any else .One_Mask, mask = mask, site = site})
			return op_idx
		}
	}
	start := i16(len(fb.ops))
	for ch in children {
		append(&fb.ops, fb.ops[ch])
	}
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = kind, first = start, count = i16(len(children)), site = site})
	return op_idx
}

@(private)
ops_flatten :: proc(fb: ^Factor_Build, root_op: i16) -> []Factor_Op {
	if root_op < 0 || int(root_op) >= len(fb.ops) { return nil }
	out, err := make([]Factor_Op, len(fb.ops) + 1, fb.arena)
	if err != nil {
		refuse_plan(fb.b, .No_Memory)
		return nil
	}
	shift_op :: proc(op: Factor_Op) -> Factor_Op {
		res := op
		#partial switch res.kind {
		case .All, .Any, .One, .Not:
			res.first += 1
		case .If:
			res.first += 1
			if res.count >= 0 { res.count += 1 }
			if res.else_op >= 0 { res.else_op += 1 }
		}
		return res
	}
	out[0] = shift_op(fb.ops[root_op])
	for op, i in fb.ops {
		out[i + 1] = shift_op(op)
	}
	for &cl in fb.closings {
		cl.root_op += 1
	}
	return out
}

@(private)
ops_monotone :: proc "contextless" (ops: []Factor_Op) -> bool {
	for op in ops {
		if op.kind == .Not || op.kind == .If { return false }
	}
	return true
}

@(private)
ops_conjunctive_only :: proc "contextless" (ops: []Factor_Op) -> bool {
	for op in ops {
		if op.kind != .Part && op.kind != .All { return false }
	}
	return true
}

@(private = "file")
Disc_Entry :: struct {
	key:  string,
	part: u8,
}

@(private)
Factored_Constraint :: struct {
	node:     rules.Node_Index,
	edge:     rules.Rules,
	part:     u8,
	scope:    i32,
	k_step:   tape.Step,
	k_arg:    string,
	elem_idx: int,
}

@(private = "file")
build_factor_member :: proc(fb: ^Factor_Build, name: string, pat_mask: u8, unnamed: bool) -> (^Factor_Member, bool) {
	d := fb.d
	fm, err := new(Factor_Member, fb.arena)
	if err != nil {
		refuse_plan(fb.b, .No_Memory)
		return nil, false
	}
	cons := make([dynamic]Factored_Constraint, fb.tables)
	refuse_sites := make([dynamic]Member_Site, fb.tables)

	for pt, pi in fb.parts {
		bit := u64(1) << uint(pi)
		if pt.is_presence || pt.is_contains { continue }
		if !unnamed && pt.is_const {
			for mv in pt.const_vals {
				if mv.key == name {
					c_node := const_member_node(fb.b, d, fb.arena, fb.tables, mv.value)
					if c_node == rules.NONE { return nil, false }
					append(&cons, Factored_Constraint{node = c_node, part = u8(pi), scope = pt.scope, k_step = tape.Name("properties"), k_arg = name, elem_idx = -1})
				}
			}
			continue
		}
		if pt.obj < 0 { continue }
		o := &d.objects[pt.obj]
		matched := false
		if !unnamed {
			for m in o.members {
				if m.name == name && !m.only_required {
					matched = true
					if !pt.no_eval { fm.evals |= bit }
					append(&cons, Factored_Constraint{node = m.node, edge = m.rules, part = u8(pi), scope = pt.scope, k_step = tape.Name("properties"), k_arg = name, elem_idx = -1})
				}
			}
		}
		for p in o.patterns {
			pidx := -1
			for expr, k in fb.patterns {
				if expr == p.expression {
					pidx = k
					break
				}
			}
			if pidx >= 0 && (pat_mask & (u8(1) << uint(pidx))) != 0 {
				matched = true
				if !pt.no_eval { fm.evals |= bit }
				append(&cons, Factored_Constraint{node = p.node, part = u8(pi), scope = pt.scope, k_step = tape.Name("patternProperties"), k_arg = p.expression, elem_idx = -1})
			}
		}
		if !matched {
			add_kw := "unevaluatedProperties" if pt.add_uneval else "additionalProperties"
			if pt.add_false {
				fm.refuse |= bit
				add_site := make([]tape.Step, 1, fb.arena)
				add_site[0] = tape.Name(add_kw)
				append(&refuse_sites, Member_Site{parts = bit, site = add_site})
			} else if pt.add_node != rules.NONE {
				if !pt.no_eval { fm.evals |= bit }
				append(&cons, Factored_Constraint{node = pt.add_node, part = u8(pi), scope = pt.scope, k_step = tape.Name(add_kw), elem_idx = -1})
			}
		}
	}
	return compile_member_constraints(fb, fm, cons[:], refuse_sites[:])
}

@(private = "file")
constraint_site :: proc(b: ^Builder, arena: runtime.Allocator, c: Factored_Constraint, words: []string) -> []tape.Step {
	has_arg := len(c.k_arg) > 0 || c.elem_idx >= 0
	out, err := make([]tape.Step, 1 + len(words) + (1 if has_arg else 0), arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	out[0] = c.k_step
	at := 1
	if len(c.k_arg) > 0 {
		out[at] = tape.Name(clone_str(b, arena, c.k_arg))
		at += 1
	} else if c.elem_idx >= 0 {
		out[at] = tape.Index(c.elem_idx)
		at += 1
	}
	for w, i in words {
		out[at + i] = tape.Name(w)
	}
	return out
}

@(private = "file")
steps_equal :: proc "contextless" (a, b: []tape.Step) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		#partial switch va in a[i] {
		case tape.Name:
			vb, ok := b[i].(tape.Name)
			if !ok || string(va) != string(vb) { return false }
		case tape.Index:
			vb, ok := b[i].(tape.Index)
			if !ok || va != vb { return false }
		}
	}
	return true
}

@(private = "file")
append_member_site :: proc(list: ^[dynamic]Member_Site, bit: u64, site: []tape.Step) {
	for &ms in list^ {
		if steps_equal(ms.site, site) {
			ms.parts |= bit
			return
		}
	}
	append(list, Member_Site{parts = bit, site = site})
}

@(private)
compile_member_constraints :: proc(fb: ^Factor_Build, fm: ^Factor_Member, cons: []Factored_Constraint, pre_refuse_sites: []Member_Site = nil) -> (^Factor_Member, bool) {
	b, d, arena, tables := fb.b, fb.d, fb.arena, fb.tables
	if len(cons) == 0 && len(pre_refuse_sites) == 0 { return fm, true }
	ref_sites := make([dynamic]Member_Site, arena)
	for rs in pre_refuse_sites {
		append_member_site(&ref_sites, rs.parts, rs.site)
	}
	disc_entries := make([dynamic]Disc_Entry, tables)
	disc_parts := u64(0)
	table_leaf_list := make([dynamic]Factor_Leaf, tables)
	Leaf_Build :: struct {
		leaf:  i32,
		parts: u64,
		sites: [dynamic]Member_Site,
	}
	leaf_list := make([dynamic]Leaf_Build, tables)
	Resolved_Cons :: struct {
		end_node: rules.Node_Index,
		edge:     rules.Rules,
		part:     u8,
		scope:    i32,
		site:     []tape.Step,
		is_keys:  bool,
	}
	res_cons := make([dynamic]Resolved_Cons, tables)

	for c in cons {
		bit := u64(1) << c.part
		if (fm.refuse & bit) != 0 { continue }
		saved_sc := b.scope
		b.scope = c.scope
		words := make([dynamic]string, tables)
		end_node := resolve_end(b, d, arena, c.node, &words)
		eff_scope := b.scope
		b.scope = saved_sc
		if end_node == rules.NONE { continue }
		c_site := constraint_site(b, arena, c, words[:])
		if b.err.kind != .None { return nil, false }
		cn := &d.nodes[end_node]
		if cn.kinds == {} {
			fm.refuse |= bit
			append_member_site(&ref_sites, bit, c_site)
			continue
		}
		b.scope = eff_scope
		if c.edge == {} && judges_nothing(b, d, end_node) {
			b.scope = saved_sc
			continue
		}
		is_plain_leaf := !holds(b, d, end_node, c.edge) && cn.object < 0 && cn.array < 0
		if is_plain_leaf {
			leaf_id := checked_leaf(b, cn, c.edge, arena)
			b.scope = saved_sc
			if b.err.kind != .None { return nil, false }
			if leaf_id == 0 { continue }
			l := &b.leaves[leaf_id - 1]
			is_disc := l.has_enum && !l.minimum.set && !l.maximum.set && l.multiple_of == nil && l.pattern == nil && l.formats == {} && l.min_length == 0 && l.max_length == max(u64) && l.min_items == 0 && l.max_items == max(u64) && l.min_members == 0 && l.max_members == max(u64) && !l.integer_spelled && (disc_parts & bit) == 0 && enum_keys_fit_kinds(l)
			if is_disc && len(l.enum_keys) > 0 {
				disc_parts |= bit
				for k in l.enum_keys {
					append(&disc_entries, Disc_Entry{key = k, part = c.part})
				}
				ms, merr := make([]Member_Site, 1, arena)
				if merr != nil {
					refuse_plan(b, .No_Memory)
					return nil, false
				}
				ms[0] = {parts = bit, site = c_site}
				append(&table_leaf_list, Factor_Leaf{leaf = leaf_id, parts = bit, sites = ms})
				continue
			}
			merged_leaf := false
			for &fl in leaf_list {
				if fl.leaf == leaf_id {
					fl.parts |= bit
					append_member_site(&fl.sites, bit, c_site)
					merged_leaf = true
					break
				}
			}
			if !merged_leaf {
				slist := make([dynamic]Member_Site, arena)
				append(&slist, Member_Site{parts = bit, site = c_site})
				append(&leaf_list, Leaf_Build{leaf = leaf_id, parts = bit, sites = slist})
			}
			continue
		}
		keys_only := is_keys_only_node(b, d, arena, end_node, c.edge)
		b.scope = saved_sc
		append(&res_cons, Resolved_Cons{end_node = end_node, edge = c.edge, part = c.part, scope = eff_scope, site = c_site, is_keys = keys_only})
	}

	if len(ref_sites) > 0 { fm.refuse_sites = ref_sites[:] }
	if len(table_leaf_list) > 0 {
		tl, tlerr := make([]Factor_Leaf, len(table_leaf_list), arena)
		if tlerr != nil {
			refuse_plan(b, .No_Memory)
			return nil, false
		}
		copy(tl, table_leaf_list[:])
		fm.table_leaves = tl
	}

	Choice_Node :: struct {
		node:  rules.Node_Index,
		edge:  rules.Rules,
		scope: i32,
		parts: u64,
		sites: [dynamic]Member_Site,
	}
	choice_nodes := make([dynamic]Choice_Node, tables)
	add_choice_node :: proc(list: ^[dynamic]Choice_Node, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules, scope: i32, bit: u64, site: []tape.Step) {
		for &ch in list^ {
			if ch.node == node && ch.edge == edge && ch.scope == scope {
				ch.parts |= bit
				append_member_site(&ch.sites, bit, site)
				return
			}
		}
		sl := make([dynamic]Member_Site, arena)
		append(&sl, Member_Site{parts = bit, site = site})
		append(list, Choice_Node{node = node, edge = edge, scope = scope, parts = bit, sites = sl})
	}

	for p in 0 ..< len(fb.parts) {
		bit := u64(1) << uint(p)
		val_idx, val_n, key_idx, key_n := -1, 0, -1, 0
		for rc, ri in res_cons {
			if int(rc.part) != p { continue }
			if rc.is_keys {
				key_idx, key_n = ri, key_n + 1
			} else {
				val_idx, val_n = ri, val_n + 1
			}
		}
		if val_n == 1 && key_n == 1 {
			vc, kc := res_cons[val_idx], res_cons[key_idx]
			vn, kn := &d.nodes[vc.end_node], &d.nodes[kc.end_node]
			sv_h := b.scope
			b.scope = vc.scope
			v_holds := holds(b, d, vc.end_node, vc.edge)
			b.scope = sv_h
			if !v_holds && vc.edge == {} && vc.scope == kc.scope && .Object in vn.kinds && !vn.has_enum && vn.const_of == nil && vn.unevaluated_properties == nil && vn.unevaluated_items == nil && (vn.object < 0 || d.objects[vn.object].keys == rules.NONE) && (len(d.anchors) == 0 || vn.resource == kn.resource) {
				new_o := d.objects[vn.object] if vn.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
				new_o.keys = d.objects[kn.object].keys
				new_o_idx := i32(len(d.objects))
				append(&d.objects, new_o)
				new_vn := vn^
				new_vn.object = new_o_idx
				new_v_idx := rules.Node_Index(len(d.nodes))
				append(&d.nodes, new_vn)
				ks, kserr := make([]tape.Step, len(kc.site) + 1, arena)
				if kserr != nil {
					refuse_plan(b, .No_Memory)
					return nil, false
				}
				copy(ks, kc.site)
				ks[len(kc.site)] = tape.Name("propertyNames")
				b.keys_sites[new_v_idx] = ks
				add_choice_node(&choice_nodes, arena, new_v_idx, {}, vc.scope, bit, vc.site)
				continue
			}
		}
		for rc in res_cons {
			if int(rc.part) == p {
				add_choice_node(&choice_nodes, arena, rc.end_node, rc.edge, rc.scope, bit, rc.site)
			}
		}
	}

	if len(disc_entries) > 0 {
		fm.table = build_factor_table(b, arena, tables, disc_entries[:], disc_parts)
	}
	if len(leaf_list) > 0 {
		leaves, lerr := make([]Factor_Leaf, len(leaf_list), arena)
		if lerr != nil {
			refuse_plan(b, .No_Memory)
			return nil, false
		}
		for fl, i in leaf_list {
			leaves[i] = {leaf = fl.leaf, parts = fl.parts, sites = fl.sites[:]}
		}
		fm.leaves = leaves
	}
	if len(choice_nodes) > 0 {
		choices, cerr := make([]Factor_Choice, len(choice_nodes), arena)
		if cerr != nil {
			refuse_plan(b, .No_Memory)
			return nil, false
		}
		saved_sc := b.scope
		for ch, i in choice_nodes {
			b.scope = ch.scope
			rec := arm_record(b, d, arena, ch.node, nil, ch.edge)
			if b.err.kind != .None {
				b.scope = saved_sc
				return nil, false
			}
			choices[i] = {record = rec, parts = ch.parts, sites = ch.sites[:]}
		}
		b.scope = saved_sc
		fm.choices = choices
	}
	return fm, true
}

@(private = "file")
is_keys_only_node :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, end_node: rules.Node_Index, edge: rules.Rules) -> bool {
	if edge != {} || holds(b, d, end_node, {}) { return false }
	n := &d.nodes[end_node]
	if n.kinds != rules.EVERY_KIND || n.rules != {} || n.has_enum || n.const_of != nil || n.array >= 0 || n.object < 0 {
		return false
	}
	o := &d.objects[n.object]
	if len(o.members) > 0 || len(o.patterns) > 0 || o.additional != rules.NONE || len(o.dependents) > 0 || o.keys == rules.NONE {
		return false
	}
	sv := b.scope
	k_end := resolve_end(b, d, arena, o.keys)
	k_ok := k_end != rules.NONE && !holds(b, d, k_end, {})
	b.scope = sv
	return k_ok
}

@(private)
const_member_node :: proc(b: ^Builder, d: ^rules.Description, arena, tables: runtime.Allocator, val: rules.Value) -> rules.Node_Index {
	k := rules.value_kind(val)
	idx := rules.Node_Index(len(d.nodes))
	if k != .Array && k != .Object {
		ev, err := make([]rules.Value, 1, tables)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return rules.NONE
		}
		ev[0] = val
		append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, has_enum = true, enum_of = ev, array = -1, object = -1})
		return idx
	}
	append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, const_of = val, array = -1, object = -1})
	return idx
}

@(private = "file")
enum_keys_fit_kinds :: proc "contextless" (l: ^rules.Leaf) -> bool {
	if l.kinds == rules.EVERY_KIND { return true }
	for k in l.enum_keys {
		if len(k) == 0 { return false }
		switch k[0] {
		case 's':      if .String not_in l.kinds { return false }
		case 't', 'f': if .Bool not_in l.kinds { return false }
		case 'z':      if .Null not_in l.kinds { return false }
		case 'n':      if .Number not_in l.kinds { return false }
		case:          return false
		}
	}
	return true
}

@(private = "file")
build_factor_table :: proc(b: ^Builder, arena, tables: runtime.Allocator, entries: []Disc_Entry, all_parts: u64) -> ^Factor_Table {
	uniq := make([dynamic]string, tables)
	for e in entries {
		if !slice.contains(uniq[:], e.key) { append(&uniq, e.key) }
	}
	rules.enum_sort(uniq[:])
	keys, kerr := make([]string, len(uniq), arena)
	parts, perr := make([]u64, len(uniq), arena)
	tbl, terr := new(Factor_Table, arena)
	if kerr != nil || perr != nil || terr != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	copy(keys, uniq[:])
	for e in entries {
		for k, i in keys {
			if k == e.key {
				parts[i] |= u64(1) << e.part
				break
			}
		}
	}
	tbl^ = {keys = keys, parts = parts, all = all_parts}
	return tbl
}

@(private)
factor_finish :: proc(b: ^Builder) {
	for f in b.factors {
		for k in 0 ..< int(f.members) {
			b.records[int(f.block) + k].word = NO_KEY
		}
	}
}

@(private)
factor_eval :: #force_inline proc "contextless" (f: ^Factor, failed: u64, op_idx: i16 = 0) -> bool #no_bounds_check {
	ok, _ := eval_parts(f, failed, op_idx, false)
	return ok
}

// Collects active parts for `unevaluated*` settlement (`for_errors = false`) or error-mode annotation gathering (`for_errors = true`).
@(private)
eval_parts :: proc "contextless" (f: ^Factor, failed: u64, op_idx: i16, $for_errors: bool) -> (passed: bool, active: u64) #no_bounds_check {
	op := f.ops[op_idx]
	switch op.kind {
	case .Part:
		bit := u64(1) << op.bit
		ok := (failed & bit) == 0
		return ok, bit if (ok || for_errors) else 0
	case .Any_Mask:
		alive := op.mask & ~failed
		return alive != 0, alive
	case .One_Mask:
		alive := op.mask & ~failed
		ok := alive != 0 && (alive & (alive - 1)) == 0
		return ok, alive if ok else 0
	case .All:
		acc, all_ok := u64(0), true
		for i in 0 ..< op.count {
			ok, sub := eval_parts(f, failed, op.first + i, for_errors)
			if !ok {
				if !for_errors { return false, 0 }
				all_ok = false
			}
			acc |= sub
		}
		return all_ok, acc
	case .Any:
		acc, hit := u64(0), false
		for i in 0 ..< op.count {
			if ok, sub := eval_parts(f, failed, op.first + i, for_errors); ok { hit, acc = true, acc | sub }
		}
		return hit, acc
	case .One:
		acc, hits := u64(0), 0
		for i in 0 ..< op.count {
			if ok, sub := eval_parts(f, failed, op.first + i, for_errors); ok { hits, acc = hits + 1, sub }
		}
		return hits == 1, acc if hits == 1 else 0
	case .Not:
		ok, _ := eval_parts(f, failed, op.first, false)
		return !ok, 0
	case .If:
		cond_ok, cond_parts := eval_parts(f, failed, op.first, for_errors)
		if cond_ok {
			if op.count < 0 { return true, cond_parts }
			th_ok, th_parts := eval_parts(f, failed, op.count, for_errors)
			when for_errors { return th_ok, cond_parts | (th_parts if th_ok else 0) }
			else { return th_ok, (cond_parts | th_parts) if th_ok else 0 }
		}
		if op.else_op < 0 { return true, 0 }
		el_ok, el_parts := eval_parts(f, failed, op.else_op, for_errors)
		return el_ok, el_parts if el_ok else 0
	}
	return false, 0
}

@(private)
factor_doomed :: proc "contextless" (f: ^Factor, failed: u64) -> bool {
	return f.monotone && !op_can_pass(f, failed, 0)
}

@(private = "file")
op_can_pass :: proc "contextless" (f: ^Factor, failed: u64, op_idx: i16) -> bool #no_bounds_check {
	op := f.ops[op_idx]
	switch op.kind {
	case .Part:               return (failed & (u64(1) << op.bit)) == 0
	case .Any_Mask, .One_Mask: return (op.mask & ~failed) != 0
	case .All:
		for i in 0 ..< op.count {
			if !op_can_pass(f, failed, op.first + i) { return false }
		}
		return true
	case .Any, .One:
		for i in 0 ..< op.count {
			if op_can_pass(f, failed, op.first + i) { return true }
		}
		return false
	case .Not, .If:
		return true
	}
	return true
}

@(private)
fail_doomed_factored :: proc(h: ^Checker, fo: ^Factored_Open) {
	if h.nf > 0 { h.quiet = factored_at(h, 0).saved_quiet }
	h.failed = true
	if fo.arr_unique_failed {
		record_first_failure(h, .Not_Unique, fo.open_at, "uniqueItems", "", fo.owner)
		return
	}
	kind, kw := factored_circuit_first_err(fo.factor, fo.failed)
	record_first_failure(h, kind, fo.open_at, kw, "", fo.owner)
}

@(private)
factored_circuit_first_err :: proc "contextless" (f: ^Factor, failed: u64) -> (kind: Error_Kind, kw: string) #no_bounds_check {
	if len(f.ops) > 0 {
		op := f.ops[0]
		#partial switch op.kind {
		case .One_Mask:
			return (.Many_Arms if intrinsics.count_ones(op.mask & ~failed) > 1 else .No_Arm), "oneOf"
		case .One:
			hits := 0
			for i in 0 ..< op.count {
				if factor_eval(f, failed, op.first + i) { hits += 1 }
			}
			return (.Many_Arms if hits > 1 else .No_Arm), "oneOf"
		case .Not:
			return .Not_Allowed, "not"
		}
	}
	return .No_Arm, "anyOf"
}

@(private)
factored_can_record_first :: proc "contextless" (h: ^Checker, fo: ^Factored_Open, stop_at_fo := true) -> bool #no_bounds_check {
	if h.sink != nil || h.first_recorded || !fo.factor.direct_errors || fo.saved_quiet || h.choice_depth > 0 {
		return false
	}
	for i in 0 ..< h.nf {
		afi := factored_at(h, i)
		if stop_at_fo && afi == fo { break }
		if afi.saved_quiet || !afi.factor.direct_errors { return false }
	}
	return true
}

@(private)
can_doom_factored :: #force_inline proc "contextless" (h: ^Checker, f: ^Factor, failed: u64) -> bool {
	if h.sink != nil || h.dups == .Last || h.dups == .Group || h.nest_depth != 0 || h.nf != 1 || h.choice_depth != 0 || !factor_doomed(f, failed) {
		return false
	}
	if !h.first_recorded && f.direct_errors && !factored_at(h, 0).saved_quiet && (h.subwalk_fn != nil || factored_at(h, 0).doc != nil) {
		return false
	}
	return true
}

@(private)
INLINE_FACTORED :: 4

@(private)
factored_at :: #force_inline proc "contextless" (h: ^Checker, idx: int) -> ^Factored_Open #no_bounds_check {
	return &h.factored_buf[idx] if idx < INLINE_FACTORED else &h.pool.factored[idx - INLINE_FACTORED]
}

@(private)
factored_open :: proc(h: ^Checker, owner: ^Record, f: ^Factor, at: u64) -> bool {
	if h.nf >= MAX_FACTOR_DEPTH { return false }
	fo: ^Factored_Open
	if h.nf < INLINE_FACTORED {
		fo = &h.factored_buf[h.nf]
	} else {
		pool := pool_ensure(h)
		if pool == nil { return false }
		pidx := h.nf - INLINE_FACTORED
		if pidx >= len(pool.factored) && resize(&pool.factored, pidx + 1) != nil {
			h.fatal = .No_Memory
			return false
		}
		fo = &pool.factored[pidx]
	}
	collect := h.sink != nil && !h.quiet && f.direct_errors
	fo^ = {
		factor = f, owner = owner, active_choice = -1, parent_sp = h.sp,
		saved_quiet = h.quiet, saved_sink = h.sink, saved_buffering = h.buffering_choice,
		saved_choice_fo = h.choice_sink_fo, saved_no_factor = h.no_factor, saved_failed = h.failed,
		open_at = at, unk_tracker = -1, collect_errors = collect,
	}
	if collect {
		fo.err_entries.allocator = h.scratch
		fo.seen_pos.allocator = h.scratch
		fo.choice_no_member.allocator = h.scratch
	}
	if f.members > 64 {
		pool := pool_ensure(h)
		if pool == nil { return false }
		buf := pool_seen_wide(h, pool, h.nf, (int(f.members) + 63) / 64)
		if buf == nil { return false }
		fo.seen_wide = buf
	}
	if f.arr != nil && !factored_arr_open(h, fo) { return false }
	h.nf += 1
	h.quiet, h.failed = true, false
	return true
}

@(private)
factored_cleanup :: proc(h: ^Checker, fo: ^Factored_Open) {
	if fo.unk_tracker >= 0 {
		close_tracker(h)
		fo.unk_tracker = -1
	}
	if fo.using_inline_uniq { h.arr_uniq_in_use, fo.using_inline_uniq = false, false }
	if fo.arr_state != nil {
		free_arr_state(h, fo.arr_state)
		fo.arr_state = nil
	}
	if cap(fo.err_entries) > 0 {
		for &e in fo.err_entries {
			if len(e.expected) > 0 { delete(e.expected, h.scratch) }
			if e.member_owned { delete(e.member_name, h.scratch) }
		}
		delete(fo.err_entries)
		fo.err_entries = nil
	}
	if cap(fo.seen_pos) > 0 {
		for &sp in fo.seen_pos {
			if sp.name_owned { delete(sp.name, h.scratch) }
		}
		delete(fo.seen_pos)
		fo.seen_pos = nil
	}
	if cap(fo.choice_no_member) > 0 {
		delete(fo.choice_no_member)
		fo.choice_no_member = nil
	}
	sink_destroy(&fo.choice_sink)
}

@(private)
choice_sink_ensure :: proc(h: ^Checker, fo: ^Factored_Open) {
	if !fo.choice_sink.arena_ready { sink_init(&fo.choice_sink, h.scratch) }
}

@(private)
factored_outer_kw_len :: proc(h: ^Checker, fo: ^Factored_Open) -> int {
	tmp := make([dynamic]tape.Step, h.scratch)
	defer delete(tmp)
	append_current_keyword_path(h, &tmp, fo.owner)
	return len(tmp)
}

@(private)
factored_buf_err :: proc(h: ^Checker, fo: ^Factored_Open, e: Factored_Err) {
	if _, err := append(&fo.err_entries, e); err != nil {
		if len(e.expected) > 0 { delete(e.expected, h.scratch) }
		if e.member_owned { delete(e.member_name, h.scratch) }
		h.fatal = .No_Memory
	}
}

@(private)
factored_note_leaf_fails :: proc(
	h: ^Checker,
	fo: ^Factored_Open,
	l: ^rules.Leaf,
	fails: rules.Failures,
	at: u64,
	members: bool,
	sites: []Member_Site,
	part: u8,
	member_name: string,
	member_need_clone: bool,
	elem_idx: u64,
	has_member: bool,
	rec_first: ^bool,
	extra_kw := "",
) {
	if fo.collect_errors {
		for k in fails {
			kw := keyword_of_kind(k, l, members)
			exp := rules.operand_text(l, k, members, h.scratch)
			nm, nm_owned := member_name, false
			if has_member && fo.factor.arr == nil && member_need_clone && len(member_name) > 0 {
				cp, cerr := strings.clone(member_name, h.scratch)
				if cerr != nil {
					if len(exp) > 0 { delete(exp, h.scratch) }
					h.fatal = .No_Memory
					return
				}
				nm, nm_owned = cp, true
			}
			factored_buf_err(h, fo, Factored_Err{
				kind = .Direct, no_emit_mask = fo.factor.no_emit_mask, err_kind = k, at = at,
				keyword = kw, expected = exp, member_name = nm, member_owned = nm_owned,
				elem_idx = elem_idx, has_member = has_member, sites = sites, part = part, extra_kw = extra_kw,
			})
			if h.fatal != .None { return }
		}
		return
	}
	if rec_first != nil && rec_first^ && !h.first_recorded {
		for k in fails {
			kw := keyword_of_kind(k, l, members)
			exp := rules.operand_text(l, k, members, h.scratch)
			record_first_factored_err(h, fo, k, at, kw, exp, member_name, elem_idx, has_member, sites, part, extra_kw)
			if len(exp) > 0 { delete(exp, h.scratch) }
			rec_first^ = false
			return
		}
	}
}

@(private)
factored_mark_seen :: #force_inline proc "contextless" (fo: ^Factored_Open, idx: i32) -> bool #no_bounds_check {
	if fo.factor.members <= 64 {
		bit := u64(1) << uint(idx)
		if (fo.seen_mask & bit) != 0 { return true }
		fo.seen_mask |= bit
		return false
	}
	w, bit := idx >> 6, u64(1) << uint(idx & 63)
	if (fo.seen_wide[w] & bit) != 0 { return true }
	fo.seen_wide[w] |= bit
	return false
}

@(private)
factored_is_seen :: #force_inline proc "contextless" (fo: ^Factored_Open, idx: i32) -> bool #no_bounds_check {
	if fo.factor.members <= 64 { return (fo.seen_mask & (u64(1) << uint(idx))) != 0 }
	return (fo.seen_wide[idx >> 6] & (u64(1) << uint(idx & 63))) != 0
}

@(private)
factored_key :: proc(h: ^Checker, fo: ^Factored_Open, key: string, key_owned: bool, at: u64) -> (skip: bool, doomed: bool) {
	if !charge_step_one(h) { return false, true }
	f := fo.factor
	fo.seen_count += 1

	m := &h.plan.meta[f.block + f.members]
	idx := member_find(h.plan, m, key)
	fm: ^Factor_Member
	if idx >= 0 {
		if factored_mark_seen(fo, idx) && (h.dups == .First || h.dups == .Last || (h.dups == .Group && !h.in_doc_group)) {
			h.need_reread = true
			return false, true
		}
		fm = h.plan.uses[f.block + idx].member
	} else {
		if h.dups == .First || h.dups == .Last || (h.dups == .Group && !h.in_doc_group) {
			if fo.unk_tracker < 0 {
				fo.unk_tracker = open_tracker(h)
				if fo.unk_tracker < 0 {
					h.fatal = .No_Memory
					return false, true
				}
			}
			tr := tracker_at(h, fo.unk_tracker)
			if tracker_has(tr, key) {
				h.need_reread = true
				return false, true
			}
			if !tracker_add(h, tr, key, key_owned) {
				h.fatal = .No_Memory
				return false, true
			}
		}
		cls := pattern_class(h, f, key)
		if h.fatal != .None { return false, true }
		fo.last_cls = cls
		fo.unknown_classes |= u16(1) << cls
		fm = f.classes[cls]
	}

	if len(f.keys) > 0 {
		rec_first := !fo.collect_errors && factored_can_record_first(h, fo)
		for fk in f.keys {
			if !charge_step_one(h) { return false, true }
			if !fo.collect_errors && f.monotone && (fk.parts & ~fo.failed) == 0 { continue }
			l := &h.plan.leaves[fk.leaf - 1]
			kfails := key_fails_leaf(h, l, key)
			if h.fatal != .None { return false, true }
			if kfails != {} {
				fo.failed |= fk.parts
				if (fo.collect_errors || rec_first) && (fk.parts & ~f.no_emit_mask) != 0 {
					for b := 0; b < int(f.n); b += 1 {
						bit := u64(1) << uint(b)
						if (fk.parts & bit) != 0 && (f.no_emit_mask & bit) == 0 {
							factored_note_leaf_fails(h, fo, l, kfails, at, false, nil, u8(b), key, key_owned, 0, true, &rec_first, "propertyNames")
							if h.fatal != .None { return false, true }
							if !fo.collect_errors { break }
						}
					}
				}
			}
		}
		if can_doom_factored(h, f, fo.failed) {
			fo.active_member = nil
			return false, true
		}
	}

	fo.active_member = fm
	if fo.collect_errors && f.arr == nil { fo.cur_seen_idx, fo.cur_seen_cls = idx, fo.last_cls }
	need_uneval := f.uneval_false && f.eval_all == 0 && (fm == nil || fm.evals == 0)
	need_err_val := fo.collect_errors && ((fm != nil && fm.refuse != 0) || need_uneval || len(f.closings) > 0)
	if fm == nil { return !need_err_val, false }
	fo.failed |= fm.refuse
	need_refuse_val_err := fm.refuse != 0 && !fo.collect_errors && factored_can_record_first(h, fo) && (fm.refuse & ~f.no_emit_mask) != 0
	if !need_refuse_val_err && can_doom_factored(h, f, fo.failed) { return false, true }
	if need_refuse_val_err { return false, false }
	alive := f.all_parts if (fo.collect_errors || !f.monotone) else (f.all_parts & ~fo.failed)
	need_val := fm.table != nil && (fm.table.all & alive) != 0
	for fl in fm.leaves {
		if need_val { break }
		need_val = (fl.parts & alive) != 0
	}
	for ch in fm.choices {
		if need_val { break }
		need_val = (ch.parts & alive) != 0
	}
	return !(need_val || need_err_val), false
}

@(private = "file")
pattern_class :: proc(h: ^Checker, f: ^Factor, key: string) -> u8 {
	cls := u8(0)
	for re, i in f.patterns {
		found, ok := run_regex_search(h, re, key)
		if !ok { return 0 }
		if found { cls |= u8(1) << uint(i) }
	}
	return cls
}

@(private)
factored_begin_value :: proc(h: ^Checker, fo: ^Factored_Open, fm: ^Factor_Member, val_at: u64) {
	if !fo.collect_errors || fo.factor.arr != nil { return }
	f := fo.factor
	has_key := h.sp > 0 && h.frames[h.sp - 1].has_key
	cur_key := h.frames[h.sp - 1].key_name if has_key else ""
	cur_owned := h.frames[h.sp - 1].key_owned if has_key else false
	clone_if :: proc(h: ^Checker, s: string, need: bool) -> (string, bool, bool) {
		if !need || len(s) == 0 { return s, false, true }
		cp, err := strings.clone(s, h.scratch)
		if err != nil {
			h.fatal = .No_Memory
			return "", false, false
		}
		return cp, true, true
	}
	need_uneval := f.uneval_false && f.eval_all == 0 && (fm == nil || fm.evals == 0)
	if (need_uneval || len(f.closings) > 0) && has_key {
		nm, nm_owned, ok := clone_if(h, cur_key, cur_owned)
		if !ok { return }
		if _, aerr := append(&fo.seen_pos, Seen_Member_Pos{name = nm, name_owned = nm_owned, val_at = val_at, member_idx = fo.cur_seen_idx, cls = fo.cur_seen_cls}); aerr != nil {
			if nm_owned { delete(nm, h.scratch) }
			h.fatal = .No_Memory
			return
		}
	}
	if fm != nil && fm.refuse != 0 && (fm.refuse & ~f.no_emit_mask) != 0 {
		nm, nm_owned, ok := clone_if(h, cur_key, cur_owned)
		if !ok { return }
		factored_buf_err(h, fo, Factored_Err{
			kind = .Direct, no_emit_mask = f.no_emit_mask, err_kind = .Wrong_Kind, at = val_at,
			keyword = "type", member_name = nm, member_owned = nm_owned, has_member = true, sites = fm.refuse_sites,
		})
	}
}

@(private)
factored_scalar :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (doomed: bool) {
	fm := fo.active_member
	fo.active_member = nil
	if fo.collect_errors && fo.factor.arr == nil {
		factored_begin_value(h, fo, fm, t.lo)
		if h.fatal != .None { return true }
	}
	if fm == nil { return false }
	f := fo.factor
	collect := fo.collect_errors
	is_arr := f.arr != nil
	cur_key := h.frames[h.sp - 1].key_name if (!is_arr && h.sp > 0) else ""
	cur_owned := h.frames[h.sp - 1].key_owned if (!is_arr && h.sp > 0) else false
	elem_idx := fo.seen_count - 1 if is_arr else 0
	rec_first := !collect && factored_can_record_first(h, fo)
	if rec_first && fm.refuse != 0 && (fm.refuse & ~f.no_emit_mask) != 0 {
		record_first_factored_err(h, fo, .Wrong_Kind, t.lo, "type", "", cur_key, elem_idx, true, fm.refuse_sites)
		rec_first = !h.first_recorded
	}

	if tbl := fm.table; tbl != nil {
		if !charge_step_one(h) { return true }
		matched_parts := u64(0)
		buf: [128]u8 = ---
		text, owned, ok := token_decoded_scalar(h, t, buf[:])
		if !ok {
			if t.kind != .Number {
				h.fatal = .No_Memory
				return true
			}
			fo.failed |= tbl.all
		} else {
			defer if owned {
				delete(text, h.scratch)
			}
			tk := token_effective_kind(h, t)
			num_buf: [64]u8 = ---
			lookup_text, lookup_owned, valid_scalar := text, false, true
			if tk == .Number {
				nt, nown, nok := normalize_token_number(h, t, text, num_buf[:])
				if !nok {
					valid_scalar = false
				} else {
					lookup_text, lookup_owned = nt, nown
				}
			} else if t.kind == .Plain {
				if idx, found := rules.enum_find(tbl.keys, .String, text, h.scratch); found {
					matched_parts = tbl.parts[idx]
					fo.failed |= tbl.all & ~matched_parts
					valid_scalar = false
				} else {
					tk, lookup_text = infer_plain_scalar_kind(text)
				}
			}
			if valid_scalar {
				if idx, found := rules.enum_find(tbl.keys, tk, lookup_text, h.scratch); found {
					matched_parts = tbl.parts[idx]
					fo.failed |= tbl.all & ~matched_parts
				} else {
					fo.failed |= tbl.all
				}
			}
			if lookup_owned { delete(lookup_text, h.scratch) }
		}
		bad_tbl := tbl.all & ~matched_parts
		if (collect || (rec_first && bad_tbl != 0)) && (bad_tbl & ~f.no_emit_mask) != 0 {
			for tfl in fm.table_leaves {
				if (tfl.parts & bad_tbl & ~f.no_emit_mask) == 0 { continue }
				l := &h.plan.leaves[tfl.leaf - 1]
				fails := eval_scalar_leaf(h, l, t)
				if h.fatal != .None { return true }
				if fails != {} {
					factored_note_leaf_fails(h, fo, l, fails, t.lo, false, tfl.sites, 0, cur_key, cur_owned, elem_idx, true, &rec_first)
					if h.fatal != .None { return true }
					if !collect { break }
				}
			}
		}
	}

	for fl in fm.leaves {
		if !charge_step_one(h) { return true }
		if !collect && f.monotone && (fl.parts & ~fo.failed) == 0 { continue }
		l := &h.plan.leaves[fl.leaf - 1]
		need_detail := (collect || rec_first) && (fl.parts & ~f.no_emit_mask) != 0
		if !need_detail && collect && f.monotone && (fl.parts & ~fo.failed) == 0 { continue }
		fails := eval_scalar_leaf(h, l, t) if need_detail else (rules.Failures{} if scalar_passes_leaf(h, l, t) else rules.Failures{.Wrong_Kind})
		if h.fatal != .None { return true }
		if fails != {} {
			fo.failed |= fl.parts
			if need_detail {
				factored_note_leaf_fails(h, fo, l, fails, t.lo, false, fl.sites, 0, cur_key, cur_owned, elem_idx, true, &rec_first)
				if h.fatal != .None { return true }
			}
		}
	}

	if len(fm.choices) > 0 {
		fo_idx := h.nf - 1
		for ch in fm.choices {
			if !charge_step_one(h) { return true }
			if !collect && f.monotone && (ch.parts & ~fo.failed) == 0 { continue }
			if (collect || rec_first) && (ch.parts & ~f.no_emit_mask) != 0 {
				guard, mark, outer_kw := choice_sink_enter(h, fo, fo_idx)
				passed := scalar_passes_record_emit(h, ch.record, t, fo.owner)
				choice_sink_leave(h, guard)
				if !passed {
					fo.failed |= ch.parts
					if end := len(fo.choice_sink.entries); end > mark {
						if collect {
							factored_buf_err(h, fo, Factored_Err{
								kind = .Choice_Span, no_emit_mask = f.no_emit_mask,
								choice_from = mark, choice_to = end, base_kw_len = outer_kw, sites = ch.sites,
							})
						} else {
							emit_first_choice_span_entry(h, fo, mark, outer_kw, ch.sites)
							rec_first = false
						}
					}
				}
			} else if !scalar_passes_record(h, ch.record, t) {
				fo.failed |= ch.parts
			}
			if h.fatal != .None { return true }
		}
	}
	return can_doom_factored(h, f, fo.failed)
}

@(private)
scalar_passes_record_emit :: proc(h: ^Checker, rec_idx: i32, t: tape.Token, owner: ^Record) -> bool {
	r := &h.plan.records[rec_idx]
	if .Held in r.flags { return eval_held_scalar(h, r, t) }
	return true if r.rule_set == 0 else judge_scalar_token(h, &h.plan.leaves[r.rule_set - 1], t, r)
}

@(private = "file")
infer_plain_scalar_kind :: proc "contextless" (text: string) -> (tape.Kind, string) {
	if len(text) == 0 || text == "null" { return .Null, "" }
	if text == "true" { return .True, "" }
	if text == "false" { return .False, "" }
	if rules.valid_decimal_text(text) { return .Number, text }
	return .String, text
}

@(private)
factored_container :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (choice_rec: ^Record, use_fork: bool, skip: bool, doomed: bool) {
	fm := fo.active_member
	if fo.collect_errors && fo.factor.arr == nil {
		factored_begin_value(h, fo, fm, t.lo)
		if h.fatal != .None {
			fo.active_member = nil
			return nil, false, false, true
		}
	}
	if fm == nil {
		fo.active_member = nil
		return nil, false, true, false
	}
	f := fo.factor
	collect := fo.collect_errors
	is_arr := f.arr != nil
	cur_key := h.frames[h.sp - 1].key_name if (!is_arr && h.sp > 0) else ""
	cur_owned := h.frames[h.sp - 1].key_owned if (!is_arr && h.sp > 0) else false
	elem_idx := fo.seen_count - 1 if is_arr else 0
	rec_first := !collect && factored_can_record_first(h, fo)
	if rec_first && fm.refuse != 0 && (fm.refuse & ~f.no_emit_mask) != 0 {
		record_first_factored_err(h, fo, .Wrong_Kind, t.lo, "type", "", cur_key, elem_idx, true, fm.refuse_sites)
		rec_first = !h.first_recorded
	}

	want_kind := rules.Kind.Object if t.kind == .Object else rules.Kind.Array
	if tbl := fm.table; tbl != nil {
		fo.failed |= tbl.all
		if (collect || rec_first) && (tbl.all & ~f.no_emit_mask) != 0 {
			for tfl in fm.table_leaves {
				if (tfl.parts & ~f.no_emit_mask) == 0 { continue }
				l := &h.plan.leaves[tfl.leaf - 1]
				if want_kind not_in l.kinds || l.has_enum {
					fails := rules.Failures{.Wrong_Kind} if want_kind not_in l.kinds else rules.Failures{.Not_A_Member}
					factored_note_leaf_fails(h, fo, l, fails, t.lo, false, tfl.sites, 0, cur_key, cur_owned, elem_idx, true, &rec_first)
					if h.fatal != .None { return nil, false, false, true }
					if !collect { break }
				}
			}
		}
	}
	for fl in fm.leaves {
		if !charge_step_one(h) { return nil, false, false, true }
		l := &h.plan.leaves[fl.leaf - 1]
		if want_kind not_in l.kinds || l.has_enum {
			fo.failed |= fl.parts
			if (collect || rec_first) && (fl.parts & ~f.no_emit_mask) != 0 {
				fails := rules.Failures{.Wrong_Kind} if want_kind not_in l.kinds else rules.Failures{.Not_A_Member}
				factored_note_leaf_fails(h, fo, l, fails, t.lo, false, fl.sites, 0, cur_key, cur_owned, elem_idx, true, &rec_first)
				if h.fatal != .None { return nil, false, false, true }
			}
		}
	}
	if can_doom_factored(h, f, fo.failed) {
		fo.active_member = nil
		return nil, false, false, true
	}

	live_count, live_idx := 0, -1
	for ch, i in fm.choices {
		if !charge_step_one(h) { return nil, false, false, true }
		if !collect && f.monotone && (ch.parts & ~fo.failed) == 0 { continue }
		live_count, live_idx = live_count + 1, i
	}
	if live_count == 0 {
		if fm_has_count_leaves(h.plan, fm, t.kind == .Object) {
			fo.active_choice = -1
			return &h.plan.records[h.plan.nothing - 1], false, false, false
		}
		fo.active_member = nil
		return nil, false, true, false
	}
	if live_count == 1 {
		fo.active_choice = live_idx
		return &h.plan.records[fm.choices[live_idx].record], false, false, false
	}
	return nil, true, false, false
}

@(private)
fm_has_count_leaves :: proc "contextless" (p: ^Plan, fm: ^Factor_Member, is_obj: bool) -> bool #no_bounds_check {
	if fm == nil { return false }
	for fl in fm.leaves {
		l := &p.leaves[fl.leaf - 1]
		if is_obj ? (l.min_members > 0 || l.max_members < max(u64)) : (l.min_items > 0 || l.max_items < max(u64)) {
			return true
		}
	}
	return false
}

@(private)
finish_choice_leaf_counts :: proc "contextless" (h: ^Checker, outer_fo: ^Factored_Open, is_object: bool, cnt: u64, open_at: u64) #no_bounds_check {
	if outer_fo.active_member == nil { return }
	f := outer_fo.factor
	collect := outer_fo.collect_errors
	cur_key := h.frames[h.sp - 1].key_name if (f.arr == nil && h.sp > 0) else ""
	cur_owned := h.frames[h.sp - 1].key_owned if (f.arr == nil && h.sp > 0) else false
	elem_idx := outer_fo.seen_count - 1 if f.arr != nil else 0
	rec_first := !collect && factored_can_record_first(h, outer_fo)
	for fl in outer_fo.active_member.leaves {
		l := &h.plan.leaves[fl.leaf - 1]
		fails := rules.judge_count(cnt, l.min_members, l.max_members) if is_object else rules.judge_count(cnt, l.min_items, l.max_items)
		if fails != {} {
			outer_fo.failed |= fl.parts
			if (collect || rec_first) && (fl.parts & ~f.no_emit_mask) != 0 {
				context = h.ctx^
				factored_note_leaf_fails(h, outer_fo, l, fails, open_at, is_object, fl.sites, 0, cur_key, cur_owned, elem_idx, true, &rec_first)
			}
		}
	}
}

// Closes the innermost open factored container (object OR array), settling all deferred constraints.
@(private)
factored_close :: proc(h: ^Checker) -> (passed: bool, owner: ^Record, open_at: u64, arr_unique_failed: bool, emitted: bool) {
	h.nf -= 1
	fo := factored_at(h, h.nf)
	f := fo.factor
	defer factored_cleanup(h, fo)

	owner, open_at = fo.owner, fo.open_at
	arr_unique_failed = fo.arr_unique_failed
	choice_sink_restore_fo(h, fo, fo.saved_quiet)
	h.no_factor, h.failed = fo.saved_no_factor, fo.saved_failed

	if h.budget.steps > 0 {
		work := u64(len(f.ops) + len(f.required) + len(f.dep_required) + len(f.presence) + len(f.counts) + len(f.closings))
		if f.arr != nil { work += u64(len(f.arr.counts) + len(f.arr.contains)) }
		charge_steps(h, max(work, 1))
		if h.fatal != .None { return false, owner, open_at, arr_unique_failed, false }
	}

	failed := fo.failed
	spine_fail := false
	is_arr := f.arr != nil
	if is_arr {
		fa, st := f.arr, fo.arr_state
		if len(fa.contains) > 0 && st != nil {
			for c, ci in fa.contains {
				if hits := st.contains_hits[ci]; hits < c.min_contains || hits > c.max_contains {
					failed |= u64(1) << c.part
				}
			}
		}
		for cnt in fa.counts {
			if fo.seen_count < cnt.min_n || fo.seen_count > cnt.max_n { failed |= cnt.parts }
		}
		for cl in f.closings {
			cl_ok, cl_active := eval_parts(f, failed, cl.root_op, false)
			if !cl_ok || !all_items_evaluated(fa, st, fo.seen_count, cl_active) {
				failed |= u64(1) << cl.part
			}
		}
		spine_fail = fa.spine_unique && fo.arr_unique_failed
	} else {
		for req in f.required {
			if !factored_is_seen(fo, req.member) { failed |= req.parts }
		}
		for dr in f.dep_required {
			if factored_is_seen(fo, dr.trigger) {
				for w in dr.wants {
					if !factored_is_seen(fo, w) {
						failed |= dr.parts
						break
					}
				}
			}
		}
		for pr in f.presence {
			if !factored_is_seen(fo, pr.member) { failed |= u64(1) << pr.part }
		}
		for cnt in f.counts {
			if fo.seen_count < cnt.min_n || fo.seen_count > cnt.max_n { failed |= cnt.parts }
		}
		for cl in f.closings {
			cl_ok, cl_active := eval_parts(f, failed, cl.root_op, false)
			if !cl_ok || !all_members_evaluated(h.plan, fo, cl_active) { failed |= u64(1) << cl.part }
		}
	}

	if f.spine_leaf > 0 {
		l := &h.plan.leaves[f.spine_leaf - 1]
		lo := l.min_items if is_arr else l.min_members
		hi := l.max_items if is_arr else l.max_members
		if fo.seen_count < lo || fo.seen_count > hi { spine_fail = true }
	}
	circuit_ok := factor_eval(f, failed, 0)
	uneval_ok := true
	if f.uneval_false {
		ok, active := eval_parts(f, failed, 0, false)
		all_ev := all_items_evaluated(f.arr, fo.arr_state, fo.seen_count, active) if is_arr else all_members_evaluated(h.plan, fo, active)
		if !ok || !all_ev { uneval_ok = false }
	}
	passed = !spine_fail && circuit_ok && uneval_ok
	if !passed {
		if fo.collect_errors {
			emit_factored_errors(h, fo, failed)
			emitted = true
		} else if factored_can_record_first(h, fo, stop_at_fo = false) {
			emit_factored_errors(h, fo, failed, first_only = true)
			emitted = h.first_recorded
		}
	}
	return passed, owner, open_at, arr_unique_failed, emitted
}

// ============================================================================
// Stage 5: Single-pass factored error emission
// ============================================================================

@(private = "file")
factored_outer_paths :: proc(h: ^Checker, fo: ^Factored_Open, outer_inst, outer_kw: ^[dynamic]tape.Step) {
	saved_sp := h.sp
	h.sp = fo.parent_sp
	defer h.sp = saved_sp
	inst_owner := fo.owner
	alt_site: []tape.Step
	if fo.parent_sp >= 0 && fo.parent_sp < len(h.frames) {
		fr := &h.frames[fo.parent_sp]
		inst_owner, alt_site = resolve_err_owner(h, fo.owner, fr.parent_b, fr.is_choice)
	}
	append_current_instance_path(h, outer_inst, inst_owner)
	append_current_keyword_path(h, outer_kw, inst_owner, alt_site)
}

@(private)
record_first_factored_err :: proc(
	h: ^Checker,
	fo: ^Factored_Open,
	kind: Error_Kind,
	at: u64,
	keyword, expected, member_name: string,
	elem_idx: u64,
	has_member: bool,
	sites: []Member_Site,
	part: u8 = 0,
	extra_kw := "",
	spine := false,
) {
	if h.first_recorded { return }
	f := fo.factor
	outer_inst := make([dynamic]tape.Step, h.scratch)
	outer_kw := make([dynamic]tape.Step, h.scratch)
	inst_buf := make([dynamic]tape.Step, h.scratch)
	kw_buf := make([dynamic]tape.Step, h.scratch)
	defer {
		delete(outer_inst)
		delete(outer_kw)
		delete(inst_buf)
		delete(kw_buf)
	}
	factored_outer_paths(h, fo, &outer_inst, &outer_kw)
	append(&inst_buf, ..outer_inst[:])
	if has_member {
		append(&inst_buf, tape.Step(tape.Name(member_name)) if f.arr == nil else tape.Step(tape.Index(int(elem_idx))))
	}
	if len(sites) > 0 {
		for ms in sites {
			alive := ms.parts & ~f.no_emit_mask
			if alive == 0 { continue }
			b := u8(intrinsics.count_trailing_zeros(alive))
			append_kw_tail(&kw_buf, outer_kw[:], f.part_meta[b].site, ms.site, extra_kw, keyword)
			emit_built_factored_err(h, fo, nil, kind, at, keyword, expected, inst_buf[:], kw_buf[:])
			return
		}
		return
	}
	if !spine && (f.no_emit_mask & (u64(1) << part)) != 0 { return }
	append_kw_tail(&kw_buf, outer_kw[:], nil if spine else f.part_meta[part].site, nil, extra_kw, keyword)
	emit_built_factored_err(h, fo, nil, kind, at, keyword, expected, inst_buf[:], kw_buf[:])
}

@(private = "file")
append_kw_tail :: proc(dst: ^[dynamic]tape.Step, base, mid1, mid2: []tape.Step, extra_kw, keyword: string) {
	clear(dst)
	append(dst, ..base)
	append(dst, ..mid1)
	append(dst, ..mid2)
	if len(extra_kw) > 0 { append(dst, tape.Name(extra_kw)) }
	if len(keyword) > 0 { append(dst, tape.Name(keyword)) }
}

@(private = "file")
emit_choice_span_entry :: proc(h: ^Checker, fo: ^Factored_Open, target: ^Sink, ce: ^Check_Error, no_ms: bool, base_kw_len: int, part_site, ms_site: []tape.Step, kw_buf: ^[dynamic]tape.Step, raw_at: bool) {
	clear(kw_buf)
	split := min(base_kw_len, len(ce.keyword_path))
	append(kw_buf, ..ce.keyword_path[:split])
	append(kw_buf, ..part_site)
	if !no_ms { append(kw_buf, ..ms_site) }
	append(kw_buf, ..ce.keyword_path[split:])
	emit_built_factored_err(h, fo, target, ce.kind, ce.at - h.at_bias if raw_at else ce.at, ce.keyword, ce.expected, ce.path, kw_buf[:])
}

@(private = "file")
emit_first_choice_span_entry :: proc(h: ^Checker, fo: ^Factored_Open, mark, base_kw_len: int, sites: []Member_Site) {
	if h.first_recorded || mark >= len(fo.choice_sink.entries) { return }
	f := fo.factor
	ce := &fo.choice_sink.entries[mark]
	no_ms := mark < len(fo.choice_no_member) && fo.choice_no_member[mark]
	kw_buf := make([dynamic]tape.Step, h.scratch)
	defer delete(kw_buf)
	for ms in sites {
		alive := ms.parts & ~f.no_emit_mask
		if alive == 0 { continue }
		b := u8(intrinsics.count_trailing_zeros(alive))
		emit_choice_span_entry(h, fo, nil, ce, no_ms, base_kw_len, f.part_meta[b].site, ms.site, &kw_buf, true)
		return
	}
}

@(private = "file")
stop_emit :: #force_inline proc "contextless" (h: ^Checker, first_only: bool) -> bool {
	return h.fatal != .None || (first_only && h.first_recorded)
}

@(private = "file")
emit_factored_count_fails :: proc(h: ^Checker, fo: ^Factored_Open, target: ^Sink, lo, hi: u64, is_obj: bool, outer_inst, outer_kw, mid_site: []tape.Step, first_only: bool) -> bool {
	fails := rules.judge_count(fo.seen_count, lo, hi)
	if fails == {} { return false }
	fake := rules.Leaf{min_members = lo, max_members = hi, min_items = lo, max_items = hi}
	for k in fails {
		kw := keyword_of_kind(k, &fake, is_obj)
		exp := rules.operand_text(&fake, k, is_obj, h.scratch)
		emit_built_factored_err(h, fo, target, k, fo.open_at, kw, exp, outer_inst, outer_kw, mid_site = mid_site, extra_step = tape.Name(kw))
		if len(exp) > 0 { delete(exp, h.scratch) }
		if stop_emit(h, first_only) { return true }
	}
	return false
}

@(private)
emit_factored_errors :: proc(h: ^Checker, fo: ^Factored_Open, failed: u64, first_only := false) {
	f := fo.factor
	target := fo.saved_sink
	if target == nil && !first_only { return }
	outer_inst := make([dynamic]tape.Step, h.scratch)
	outer_kw := make([dynamic]tape.Step, h.scratch)
	defer { delete(outer_inst); delete(outer_kw) }
	factored_outer_paths(h, fo, &outer_inst, &outer_kw)

	is_obj := f.arr == nil
	if f.spine_leaf > 0 {
		l := &h.plan.leaves[f.spine_leaf - 1]
		lo := l.min_members if is_obj else l.min_items
		hi := l.max_members if is_obj else l.max_items
		if emit_factored_count_fails(h, fo, target, lo, hi, is_obj, outer_inst[:], outer_kw[:], nil, first_only) { return }
	}
	if f.arr != nil && f.arr.spine_unique && fo.arr_unique_failed {
		emit_built_factored_err(h, fo, target, .Not_Unique, fo.open_at, "uniqueItems", "", outer_inst[:], outer_kw[:], extra_step = tape.Name("uniqueItems"))
		if stop_emit(h, first_only) { return }
	}
	if !factor_eval(f, failed, 0) {
		emit_op_errors(h, fo, target, failed, 0, outer_inst[:], outer_kw[:], first_only)
		if stop_emit(h, first_only) { return }
	}
	if !first_only && f.uneval_false {
		_, active := eval_parts(f, failed, 0, true)
		u_kw := "unevaluatedProperties" if is_obj else "unevaluatedItems"
		emit_uneval_errors(h, fo, target, active, failed, outer_inst[:], outer_kw[:], {tape.Name(u_kw), tape.Name("type")})
	}
}

@(private = "file")
emit_op_errors :: proc(h: ^Checker, fo: ^Factored_Open, target: ^Sink, failed: u64, op_idx: i16, outer_inst, outer_kw: []tape.Step, first_only := false) #no_bounds_check {
	if stop_emit(h, first_only) { return }
	f := fo.factor
	op := f.ops[op_idx]
	switch op.kind {
	case .Part:
		if (failed & (u64(1) << op.bit)) != 0 {
			emit_part_errors(h, fo, target, failed, op.bit, outer_inst, outer_kw, first_only)
		}
	case .Any_Mask, .One_Mask, .Any, .One:
		is_mask := op.kind == .Any_Mask || op.kind == .One_Mask
		is_one := op.kind == .One_Mask || op.kind == .One
		if op.kind == .Any_Mask && op.is_enum {
			if (op.mask & ~failed) == 0 {
				emit_built_factored_err(h, fo, target, .Not_A_Member, fo.open_at, "enum", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("enum"))
			}
			return
		}
		hits := 0
		if is_mask {
			hits = int(intrinsics.count_ones(op.mask & ~failed))
		} else {
			for i in 0 ..< op.count {
				if factor_eval(f, failed, op.first + i) { hits += 1 }
			}
		}
		if (!is_one && hits > 0) || (is_one && hits == 1) { return }
		kw := "oneOf" if is_one else "anyOf"
		if hits == 0 {
			if is_mask {
				for b := 0; b < int(f.n); b += 1 {
					if (op.mask & (u64(1) << uint(b))) != 0 {
						emit_part_errors(h, fo, target, failed, u8(b), outer_inst, outer_kw, first_only)
						if stop_emit(h, first_only) { return }
					}
				}
			} else {
				for i in 0 ..< op.count {
					emit_op_errors(h, fo, target, failed, op.first + i, outer_inst, outer_kw, first_only)
					if stop_emit(h, first_only) { return }
				}
			}
			emit_built_factored_err(h, fo, target, .No_Arm, fo.open_at, kw, "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name(kw))
		} else {
			emit_built_factored_err(h, fo, target, .Many_Arms, fo.open_at, kw, "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name(kw))
		}
	case .All:
		for i in 0 ..< op.count {
			if ch := op.first + i; !factor_eval(f, failed, ch) {
				emit_op_errors(h, fo, target, failed, ch, outer_inst, outer_kw, first_only)
				if stop_emit(h, first_only) { return }
			}
		}
	case .Not:
		if factor_eval(f, failed, op.first) {
			emit_built_factored_err(h, fo, target, .Not_Allowed, fo.open_at, "not", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("not"))
		}
	case .If:
		branch := op.count if factor_eval(f, failed, op.first) else op.else_op
		if branch >= 0 && !factor_eval(f, failed, branch) {
			emit_op_errors(h, fo, target, failed, branch, outer_inst, outer_kw, first_only)
		}
	}
}

@(private = "file")
emit_part_errors :: proc(h: ^Checker, fo: ^Factored_Open, target: ^Sink, failed: u64, b: u8, outer_inst, outer_kw: []tape.Step, first_only := false) #no_bounds_check {
	f := fo.factor
	pm := f.part_meta[b]
	bit := u64(1) << b
	is_obj := f.arr == nil

	if pm.const_kind != .None {
		kw := "const" if pm.const_kind == .Const else "enum"
		emit_built_factored_err(h, fo, target, .Not_A_Member, fo.open_at, kw, "", outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name(kw))
		return
	}
	if pm.fail_leaf > 0 {
		l := &h.plan.leaves[pm.fail_leaf - 1]
		want := rules.Kind.Object if is_obj else rules.Kind.Array
		kind := Error_Kind.Wrong_Kind if want not_in l.kinds else Error_Kind.Not_A_Member
		kw := keyword_of_kind(kind, l, is_obj)
		exp := rules.operand_text(l, kind, is_obj, h.scratch) if kind == .Wrong_Kind else ""
		emit_built_factored_err(h, fo, target, kind, fo.open_at, kw, exp, outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name(kw))
		if len(exp) > 0 { delete(exp, h.scratch) }
		return
	}
	if pm.uneval_kw != "" {
		if !first_only {
			for cl in f.closings {
				if cl.part == b {
					_, active_cl := eval_parts(f, failed, cl.root_op, true)
					emit_uneval_errors(h, fo, target, active_cl, failed, outer_inst, outer_kw, pm.site, append_type = true)
					break
				}
			}
		}
		return
	}

	inst_buf := make([dynamic]tape.Step, h.scratch)
	kw_buf := make([dynamic]tape.Step, h.scratch)
	defer { delete(inst_buf); delete(kw_buf) }

	for &e in fo.err_entries {
		if (e.no_emit_mask & bit) != 0 { continue }
		switch e.kind {
		case .Direct:
			clear(&inst_buf)
			append(&inst_buf, ..outer_inst)
			if e.has_member {
				append(&inst_buf, tape.Step(tape.Name(e.member_name)) if is_obj else tape.Step(tape.Index(int(e.elem_idx))))
			}
			if len(e.sites) > 0 {
				for ms in e.sites {
					if (ms.parts & bit) == 0 { continue }
					append_kw_tail(&kw_buf, outer_kw, pm.site, ms.site, e.extra_kw, e.keyword)
					emit_built_factored_err(h, fo, target, e.err_kind, e.at, e.keyword, e.expected, inst_buf[:], kw_buf[:])
					if stop_emit(h, first_only) { return }
				}
			} else if e.part == b {
				append_kw_tail(&kw_buf, outer_kw, pm.site, nil, e.extra_kw, e.keyword)
				emit_built_factored_err(h, fo, target, e.err_kind, e.at, e.keyword, e.expected, inst_buf[:], kw_buf[:])
				if stop_emit(h, first_only) { return }
			}
		case .Choice_Span:
			for ms in e.sites {
				if (ms.parts & bit) == 0 { continue }
				for ci in e.choice_from ..< e.choice_to {
					no_ms := ci < len(fo.choice_no_member) && fo.choice_no_member[ci]
					emit_choice_span_entry(h, fo, target, &fo.choice_sink.entries[ci], no_ms, e.base_kw_len, pm.site, ms.site, &kw_buf, false)
					if stop_emit(h, first_only) { return }
				}
			}
		}
	}

	if is_obj {
		for req in f.required {
			if (req.parts & bit) != 0 && !factored_is_seen(fo, req.member) {
				emit_built_factored_err(h, fo, target, .Missing_Field, fo.open_at, "required", h.plan.meta[f.block + req.member].name, outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name("required"))
				if stop_emit(h, first_only) { return }
			}
		}
		for dr in f.dep_required {
			if (dr.parts & bit) != 0 && factored_is_seen(fo, dr.trigger) {
				for w in dr.wants {
					if !factored_is_seen(fo, w) {
						emit_built_factored_err(h, fo, target, .Missing_Field, fo.open_at, dr.keyword, h.plan.meta[f.block + w].name, outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name(dr.keyword))
						if stop_emit(h, first_only) { return }
					}
				}
			}
		}
	} else {
		fa, st := f.arr, fo.arr_state
		if (fa.unique_parts & bit) != 0 && fo.arr_unique_failed {
			emit_built_factored_err(h, fo, target, .Not_Unique, fo.open_at, "uniqueItems", "", outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name("uniqueItems"))
			if stop_emit(h, first_only) { return }
		}
		for c, ci in fa.contains {
			if c.part != b { continue }
			hits := st.contains_hits[ci] if (st != nil && ci < len(st.contains_hits)) else 0
			if hits < c.min_contains {
				kw := "minContains" if c.min_contains > 1 else "contains"
				emit_built_factored_err(h, fo, target, .Too_Few, fo.open_at, kw, "", outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name(kw))
				if stop_emit(h, first_only) { return }
			}
			if hits > c.max_contains {
				emit_built_factored_err(h, fo, target, .Too_Many, fo.open_at, "maxContains", "", outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name("maxContains"))
				if stop_emit(h, first_only) { return }
			}
		}
	}
	for cnt in (f.counts if is_obj else f.arr.counts) {
		if (cnt.parts & bit) != 0 && emit_factored_count_fails(h, fo, target, cnt.min_n, cnt.max_n, is_obj, outer_inst, outer_kw, pm.site, first_only) {
			return
		}
	}
}

@(private = "file")
emit_uneval_errors :: proc(h: ^Checker, fo: ^Factored_Open, target: ^Sink, active, failed: u64, outer_inst, outer_kw, u_site: []tape.Step, append_type := false) #no_bounds_check {
	f := fo.factor
	kw_buf := make([dynamic]tape.Step, h.scratch)
	inst_buf := make([dynamic]tape.Step, h.scratch)
	defer {
		delete(kw_buf)
		delete(inst_buf)
	}
	append(&kw_buf, ..outer_kw)
	append(&kw_buf, ..u_site)
	if append_type { append(&kw_buf, tape.Name("type")) }

	if f.arr == nil {
		if (active & f.eval_all) != 0 { return }
		for &sp in fo.seen_pos {
			fm := h.plan.uses[int(f.block) + int(sp.member_idx)].member if sp.member_idx >= 0 else f.classes[sp.cls]
			if fm != nil && (fm.evals & active) != 0 { continue }
			clear(&inst_buf)
			append(&inst_buf, ..outer_inst)
			append(&inst_buf, tape.Name(sp.name))
			emit_built_factored_err(h, fo, target, .Wrong_Kind, sp.val_at, "type", "", inst_buf[:], kw_buf[:])
			if h.fatal != .None { return }
		}
		return
	}

	fa := f.arr
	eval_all := (active & fa.eval_all_items) != 0
	if fo.seen_count == 0 || (eval_all && len(fa.prefix) == 0) { return }
	active_contains := u64(0)
	for c, ci in fa.contains {
		c_bit := u64(1) << c.part
		if c.evals && ((c_bit & active) != 0) && ((c_bit & failed) == 0) {
			active_contains |= u64(1) << uint(ci)
		}
	}
	st := fo.arr_state
	for i in 0 ..< int(fo.seen_count) {
		if i < len(fa.prefix) {
			pe := st.elem_evals[i] if (st != nil && i < len(st.elem_evals)) else fa.prefix[i].evals
			if (pe & active) != 0 { continue }
		} else if eval_all {
			continue
		}
		if st != nil && i < len(st.contains_evals) && (st.contains_evals[i] & active_contains) != 0 {
			continue
		}
		clear(&inst_buf)
		append(&inst_buf, ..outer_inst)
		append(&inst_buf, tape.Index(i))
		vat := st.elem_at[i] if (st != nil && i < len(st.elem_at)) else fo.open_at
		emit_built_factored_err(h, fo, target, .Wrong_Kind, vat, "type", "", inst_buf[:], kw_buf[:])
		if h.fatal != .None { return }
	}
}

@(private = "file")
emit_built_factored_err :: proc(
	h: ^Checker,
	fo: ^Factored_Open,
	target: ^Sink,
	kind: Error_Kind,
	at: u64,
	keyword, expected: string,
	inst_steps, kw_base: []tape.Step,
	mid_site: []tape.Step = nil,
	extra_step: Maybe(tape.Step) = nil,
) {
	if target == nil && h.first_recorded { return }
	kw_steps_dyn: [dynamic]tape.Step
	kw_steps := kw_base
	if len(mid_site) > 0 || extra_step != nil {
		kw_steps_dyn.allocator = h.scratch
		append(&kw_steps_dyn, ..kw_base)
		append(&kw_steps_dyn, ..mid_site)
		if ex, has_ex := extra_step.?; has_ex { append(&kw_steps_dyn, ex) }
		kw_steps = kw_steps_dyn[:]
	}
	defer delete(kw_steps_dyn)
	emit_check_error_steps(h, target, kind, at, keyword, expected, inst_steps, kw_steps, fo.saved_buffering)
}

@(private = "file")
all_members_evaluated :: proc "contextless" (p: ^Plan, fo: ^Factored_Open, active: u64) -> bool #no_bounds_check {
	f := fo.factor
	if (active & f.eval_all) != 0 { return true }
	if f.members <= 64 {
		for mask := fo.seen_mask; mask != 0; mask &= mask - 1 {
			fm := p.uses[int(f.block) + int(intrinsics.count_trailing_zeros(mask))].member
			if fm == nil || (fm.evals & active) == 0 { return false }
		}
	} else {
		for word, w in fo.seen_wide {
			for m := word; m != 0; m &= m - 1 {
				fm := p.uses[int(f.block) + w * 64 + int(intrinsics.count_trailing_zeros(m))].member
				if fm == nil || (fm.evals & active) == 0 { return false }
			}
		}
	}
	for cls_mask := fo.unknown_classes; cls_mask != 0; cls_mask &= cls_mask - 1 {
		fm := f.classes[int(intrinsics.count_trailing_zeros(cls_mask))]
		if fm == nil || (fm.evals & active) == 0 { return false }
	}
	return true
}
