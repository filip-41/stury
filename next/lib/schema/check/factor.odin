// 4-stage factored held-object compiler & runtime (ported from stury v1 `lab/schema-held/`).
// Compiles flat & nested held objects (`allOf`, `anyOf`, `oneOf`, `not`, `if/then/else`, `$ref`,
// `dependentSchemas`, `patternProperties`, `additionalProperties: false`, `unevaluatedProperties: false`,
// multi-record choices, and spine counts) into a single factored `.Checked` record evaluated in one pass.
package check

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

// Maximum number of parts in one factored object (one bit per part in a `u64`).
@(private)
MAX_FACTOR_PARTS :: 64

// Maximum number of distinct `patternProperties` regexes in one factored object (4 bits -> 16 classes).
@(private)
MAX_FACTOR_PATTERNS :: 4

// Maximum number of open factored objects nested simultaneously before falling back to runs.
@(private)
MAX_FACTOR_DEPTH :: 64

// A boolean circuit node combining the pass/fail verdicts of the factored object's parts.
@(private)
Factor_Op_Kind :: enum u8 {
	Part,     // single part `bit`
	All,      // all children `first ..< first + count` must pass
	Any,      // at least one child must pass
	One,      // exactly one child must pass
	Not,      // child `first` must fail
	If,       // if child `first` passes then child `then_op` (if >= 0) else child `else_op` (if >= 0)
	Any_Mask, // flattened `anyOf` over single-bit parts in `mask` (Stage 4)
	One_Mask, // flattened `oneOf` over single-bit parts in `mask` (Stage 4)
}

@(private)
Factor_Op :: struct {
	kind:    Factor_Op_Kind,
	bit:     u8,  // for `.Part`
	first:   i16, // first child op index in `Factor.ops` (or test op for `.If`)
	count:   i16, // child count for `.All`/`.Any`/`.One`, or `then_op` for `.If` (-1 for none)
	else_op: i16, // `else_op` for `.If` (-1 for none)
	mask:    u64, // for `.Any_Mask` / `.One_Mask`
}

// A discriminator lookup table on a factored member: maps scalar enum/const keys to the parts that accept them.
@(private)
Factor_Table :: struct {
	keys:  []string, // sorted via `rules.enum_sort`
	parts: []u64,    // for each key, bitmask of parts accepting that key
	all:   u64,      // union of all parts participating in this discriminator table
}

// One scalar leaf constraint shared by `parts` on a factored member.
@(private)
Factor_Leaf :: struct {
	leaf:  i32, // 1 + index in `Plan.leaves`
	parts: u64,
}

// One non-leaf (container or complex) record choice shared by `parts` on a factored member (Stage 3).
@(private)
Factor_Choice :: struct {
	record: i32, // record index in `Plan.records`
	parts:  u64,
}

// How a factored object judges one member (either a named member in its block or one of the 16 pattern classes).
@(private)
Factor_Member :: struct {
	evals:   u64,           // parts that evaluate this member
	refuse:  u64,           // parts that unconditionally refuse this member (e.g. `false` schema)
	table:   ^Factor_Table, // optional scalar discriminator table (Stage 1)
	leaves:  []Factor_Leaf,
	choices: []Factor_Choice,
}

// Required member constraint: if `member` is NOT seen in the object, all bits in `parts` fail.
@(private)
Factor_Required :: struct {
	member: i32,
	parts:  u64,
}

// Presence trigger for `dependentSchemas` (Stage 4): `part` is a synthetic condition bit that passes
// iff `member` IS seen in the object.
@(private)
Factor_Presence :: struct {
	member: i32,
	part:   u8,
}

// Per-part property count constraint (`minProperties`/`maxProperties`).
@(private)
Factor_Count :: struct {
	min_members: u64,
	max_members: u64,
	parts:       u64,
}

// A part that has `unevaluatedProperties: false` over its own sub-circuit `root_op` (Stage 2/4).
@(private)
Factor_Closing :: struct {
	part:    u8,
	root_op: i16,
}

// Compiled 4-stage factored representation of a held object record.
@(private)
Factor :: struct {
	owner:        i32,                // index of the owning record in `Plan.records`
	n:            u8,                 // total number of parts (0..64)
	block:        i32,                // first named member record in `Plan.records`
	members:      i32,                // count of named members in the factored block
	ops:          []Factor_Op,        // boolean circuit; root is `ops[0]`
	monotone:     bool,               // true if `ops` has no `.Not`/`.If` (enables early `factor_doomed`)
	uneval_false: bool,               // outer `unevaluatedProperties: false`
	spine_leaf:   i32,                // 1 + leaf index for outer `minProperties`/`maxProperties` (Stage 3)
	patterns:     []^regex.Regex,     // up to `MAX_FACTOR_PATTERNS` regexes (Stage 2)
	classes:      [16]^Factor_Member, // dispatch by 4-bit pattern-match mask (Stage 2)
	required:     []Factor_Required,
	presence:     []Factor_Presence,  // `dependentSchemas` presence triggers (Stage 4)
	counts:       []Factor_Count,     // per-part `minProperties`/`maxProperties`
	closings:     []Factor_Closing,   // inner `unevaluatedProperties: false` parts (Stage 4)
	all_parts:    u64,                // `(u64(1) << n) - 1` (or `~u64(0)` when `n == 64`)
	eval_all:     u64,                // parts that have a non-false `additionalProperties` (evaluate every member)
}

// Runtime state of one open factored object on `Pool.factored`.
@(private)
Factored_Open :: struct {
	factor:          ^Factor,
	owner:           ^Record,
	failed:          u64,             // bitmask of parts that have failed so far
	seen_mask:       u64,             // bitmask of seen named members (for `members <= 64`)
	seen_wide:       []u64,           // heap bitmask of seen named members (for `members > 64`)
	seen_count:      u64,             // number of members seen in this object
	unknown_classes: u16,             // bitmask of pattern classes `0..15` seen among unnamed members
	active_member:   ^Factor_Member,  // current member being read
	active_choice:   int,             // -1 if no single choice open, else choice index
	parent_sp:       int,             // `h.sp` where this factored object opened
	saved_quiet:     bool,            // previous `h.quiet` state
	saved_no_factor: bool,
	saved_failed:    bool,            // previous `h.failed` state
	open_at:         u64,             // byte offset of `{`
	unk_tracker:     int,             // tracker index for unnamed keys under `.First`/`.Last`, -1 if none
}

// Compile-time builder state for gathering parts of a `Factor`.
@(private = "file")
Factor_Build :: struct {
	b:        ^Builder,
	d:        ^rules.Description,
	arena:    runtime.Allocator,
	tables:   runtime.Allocator,
	parts:    [dynamic]Part_Info,
	ops:      [dynamic]Factor_Op,
	patterns: [dynamic]string,
	pat_re:   [dynamic]^regex.Regex,
	closings: [dynamic]Factor_Closing,
	presence: [dynamic]Presence_Build,
	ok:       bool,
}

@(private = "file")
Part_Info :: struct {
	node:          rules.Node_Index,
	obj:           i32, // index in `d.objects`, or -1
	scope:         i32, // dynamic scope captured when this part was gathered (B-C6)
	min_members:   u64,
	max_members:   u64,
	eval_all:      bool,
	add_false:     bool, // `additionalProperties: false`
	add_node:      rules.Node_Index,
	is_presence:   bool,
	presence_name: string,
}

@(private = "file")
Presence_Build :: struct {
	name: string,
	part: u8,
}

// Attempts to compile held node `node` (with `edge`) into a 4-stage `Factor`.
// Returns nil if the node is not eligible for object factoring (e.g., > 64 parts, > 4 patterns,
// non-object-only applicators like `uniqueItems`/`contains`, `unevaluatedProperties` with non-false schema,
// or non-object-compatible `const`/`enum`).
@(private)
factor_of :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> ^Factor {
	if b.err.kind != .None || node == rules.NONE {
		return nil
	}
	n := &d.nodes[node]
	// Must be able to take an object and must not have array-specific/document-level constraints on the outer node
	// that factoring does not evaluate on objects.
	if .Object not_in n.kinds {
		return nil
	}
	if n.const_of != nil || n.has_enum || n.rules.unique {
		return nil
	}
	// Outer `unevaluatedProperties` is supported when it is `false` (i.e. `kinds == {}`).
	uneval_false := false
	if up, has := n.unevaluated_properties.?; has {
		up_end, _ := rules.ref_end(d, up)
		if up_end == rules.NONE {
			return nil
		}
		if d.nodes[up_end].kinds == {} {
			uneval_false = true
		} else {
			return nil
		}
	}

	fb := Factor_Build{
		b = b,
		d = d,
		arena = arena,
		tables = b.tables,
		parts = make([dynamic]Part_Info, b.tables),
		ops = make([dynamic]Factor_Op, b.tables),
		patterns = make([dynamic]string, b.tables),
		pat_re = make([dynamic]^regex.Regex, b.tables),
		closings = make([dynamic]Factor_Closing, b.tables),
		presence = make([dynamic]Presence_Build, b.tables),
		ok = true,
	}

	// Gather the boolean circuit and flat parts of `node`.
	root_op := gather(&fb, node, edge, 0)
	if !fb.ok || root_op < 0 || len(fb.parts) == 0 {
		return nil
	}
	if len(fb.parts) > MAX_FACTOR_PARTS || len(fb.patterns) > MAX_FACTOR_PATTERNS {
		return nil
	}

	// Must actually benefit from factoring (at least 2 parts, or patterns/unevaluated/closings).
	if len(fb.parts) == 1 && len(fb.patterns) == 0 && !uneval_false && len(fb.closings) == 0 {
		return nil
	}

	// Stage 4: flatten `ops` (`anyOf`/`oneOf` over single-bit parts -> bitmask ops, single-child `All` -> child).
	ops_slice := ops_flatten(&fb, root_op)
	if len(ops_slice) == 0 {
		return nil
	}

	// Collect union of all named members across all parts + presence triggers.
	name_to_idx := make(map[string]i32, 16, b.tables)
	names := make([dynamic]string, b.tables)
	add_name :: proc(b: ^Builder, arena: runtime.Allocator, name_to_idx: ^map[string]i32, names: ^[dynamic]string, nm: string) -> i32 {
		if idx, exists := name_to_idx[nm]; exists {
			return idx
		}
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
		if pt.obj >= 0 {
			o := &d.objects[pt.obj]
			for m in o.members {
				add_name(b, arena, &name_to_idx, &names, m.name)
			}
		}
	}

	// Allocate the factored struct block in `Builder` (one record per unioned member + 1 `.End` record).
	block_at, _ := block_of(b, len(names) + 1, {})
	if block_at < 0 {
		return nil
	}
	end_at := int(block_at) + len(names)
	b.ends[block_at] = i32(end_at)
	never(b, end_at)

	// Compile `Factor` struct in `arena`.
	f, ferr := new(Factor, arena)
	if ferr != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	f.n = u8(len(fb.parts))
	f.block = block_at
	f.members = i32(len(names))
	f.ops = ops_slice
	f.uneval_false = uneval_false
	f.all_parts = ~u64(0) if f.n == 64 else (u64(1) << f.n) - 1
	f.monotone = ops_monotone(f.ops)

	// Copy patterns.
	if len(fb.pat_re) > 0 {
		pats, perr := make([]^regex.Regex, len(fb.pat_re), arena)
		if perr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		copy(pats, fb.pat_re[:])
		f.patterns = pats
	}

	// Spine counts (outer `minProperties`/`maxProperties` when not already in a part).
	r_outer, clash := rules.merged(n, edge)
	if clash == "" && (r_outer.min_members > 0 || r_outer.max_members != nil) {
		cnt_node := rules.Node{
			kinds = rules.EVERY_KIND,
			rules = rules.Rules{min_members = r_outer.min_members, max_members = r_outer.max_members},
			array = -1,
			object = -1,
		}
		f.spine_leaf = checked_leaf(b, &cnt_node, {}, arena)
	}

	// Build required masks, per-part counts, eval_all, and presence triggers.
	req_masks := make([]u64, len(names), b.tables)
	counts_list := make([dynamic]Factor_Count, arena)
	for pt, pi in fb.parts {
		bit := u64(1) << uint(pi)
		if pt.is_presence {
			continue
		}
		if pt.eval_all {
			f.eval_all |= bit
		}
		if pt.min_members > 0 || pt.max_members < max(u64) {
			// Merge into an existing count entry with the same bounds if present.
			merged_cnt := false
			for &c in counts_list {
				if c.min_members == pt.min_members && c.max_members == pt.max_members {
					c.parts |= bit
					merged_cnt = true
					break
				}
			}
			if !merged_cnt {
				append(&counts_list, Factor_Count{min_members = pt.min_members, max_members = pt.max_members, parts = bit})
			}
		}
		if pt.obj >= 0 {
			o := &d.objects[pt.obj]
			for m in o.members {
				if m.required {
					idx := name_to_idx[m.name]
					req_masks[idx] |= bit
				}
			}
			// If a part has `dependentRequired`, bail out of factoring (rare; handled by runs).
			for dep in o.dependents {
				if len(dep.required) > 0 {
					return nil
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
	f.required = req_list[:]
	f.counts = counts_list[:]

	if len(fb.presence) > 0 {
		pres, prerr := make([]Factor_Presence, len(fb.presence), arena)
		if prerr != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		for pr, i in fb.presence {
			pres[i] = Factor_Presence{member = name_to_idx[pr.name], part = pr.part}
		}
		f.presence = pres
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

	// Build regex scratch for pattern matching against named members.
	re_scratch, re_err := regex.scratch_make(b.tables)
	if re_err.kind != .None {
		return nil
	}
	defer regex.scratch_destroy(&re_scratch)

	// Build each named member's `Factor_Member` and record in `block_at`.
	for nm, idx in names {
		pat_mask := u8(0)
		for re, pi in f.patterns {
			found, serr := regex.search(re, nm, 0, nil, &re_scratch)
			if serr.kind != .None {
				return nil
			}
			if found {
				pat_mask |= u8(1) << uint(pi)
			}
		}
		fm, ok := build_factor_member(&fb, nm, pat_mask, false)
		if !ok {
			return nil
		}
		rec_idx := int(block_at) + idx
		b.records[rec_idx] = Record{word = NO_KEY, meta = u32(rec_idx), kind = .Checked}
		b.meta[rec_idx] = Meta{name = nm, block = -1}
		b.uses[rec_idx] = Use{member = fm}
	}

	// Build the `1 << len(f.patterns)` pattern-class `Factor_Member`s for unnamed members (Stage 2).
	n_classes := 1 << uint(len(f.patterns))
	for c in 0 ..< n_classes {
		fm, ok := build_factor_member(&fb, "", u8(c), true)
		if !ok {
			return nil
		}
		f.classes[c] = fm
	}

	append(&b.factors, f)
	return f
}

// Recursively gathers a node's boolean circuit (`allOf`, `anyOf`, `oneOf`, `not`, `if/then/else`,
// `$ref`, `$dynamicRef`, `dependentSchemas`) and flat object parts into `fb`.
@(private = "file")
gather :: proc(fb: ^Factor_Build, node: rules.Node_Index, edge: rules.Rules, depth: int) -> i16 {
	if !fb.ok || depth > 32 {
		fb.ok = false
		return -1
	}
	if node == rules.NONE {
		// Trivial always-pass part.
		return add_trivial_part(fb)
	}
	b, d := fb.b, fb.d
	// Walk `$ref` hops with `enter_scope` so `$dynamicRef` resolves in the proper dynamic scope (B-C6)!
	saved_scope := b.scope
	defer b.scope = saved_scope
	end_node, hops := rules.ref_end(d, node)
	if end_node == rules.NONE {
		return add_trivial_part(fb)
	}
	for y, hop := node, 0; y != rules.NONE && hop <= hops; hop += 1 {
		enter_scope(b, d, fb.arena, y)
		y = d.nodes[y].ref.? or_else end_node
	}
	n := &d.nodes[end_node]
	if .Object not_in n.kinds {
		// This subschema rejects all objects -> always-fail part!
		return add_fail_part(fb)
	}
	if n.const_of != nil || n.has_enum || n.rules.unique {
		fb.ok = false
		return -1
	}
	// Part-level `unevaluatedProperties` (Stage 2/4): only `false` supported inside a factored part.
	part_uneval_false := false
	if up, has := n.unevaluated_properties.?; has {
		if depth > 0 {
			up_end, _ := rules.ref_end(d, up)
			if up_end == rules.NONE || d.nodes[up_end].kinds != {} {
				fb.ok = false
				return -1
			}
			part_uneval_false = true
		}
	}

	children := make([dynamic]i16, fb.tables)

	// Own object keywords (if any).
	has_own := false
	r_merged, clash := rules.merged(n, edge)
	if clash != "" {
		fb.ok = false
		return -1
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		if o.keys != rules.NONE {
			// `propertyNames` inside a factored part: bail out to runs so propertyNames errors/verdicts stay exact.
			fb.ok = false
			return -1
		}
		if len(o.members) > 0 || len(o.patterns) > 0 || o.additional != rules.NONE {
			has_own = true
		}
		// Register patterns in `fb.patterns` (up to `MAX_FACTOR_PATTERNS`).
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
				append(&fb.patterns, p.expression)
				append(&fb.pat_re, re)
			}
		}
	}
	if r_merged.min_members > 0 || r_merged.max_members != nil {
		has_own = true
	}

	if has_own {
		if len(fb.parts) >= MAX_FACTOR_PARTS {
			fb.ok = false
			return -1
		}
		pi := Part_Info{
			node = end_node,
			obj = n.object,
			scope = b.scope,
			min_members = r_merged.min_members,
			max_members = r_merged.max_members.? or_else max(u64),
			add_node = rules.NONE,
		}
		if n.object >= 0 {
			o := &d.objects[n.object]
			if o.additional != rules.NONE {
				add_end, _ := rules.ref_end(d, o.additional)
				if add_end != rules.NONE && d.nodes[add_end].kinds == {} {
					pi.add_false = true
				} else {
					pi.eval_all = true
					pi.add_node = o.additional
				}
			}
		}
		bit := u8(len(fb.parts))
		append(&fb.parts, pi)
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Part, bit = bit})
		append(&children, op_idx)
	}

	// Stage 4: `dependentSchemas` as `If(Presence(dep.name), gather(dep.node), none)`!
	if n.object >= 0 {
		o := &d.objects[n.object]
		for dep in o.dependents {
			if len(dep.required) > 0 {
				fb.ok = false
				return -1
			}
			dn, has := dep.node.?
			if !has {
				continue
			}
			if len(fb.parts) >= MAX_FACTOR_PARTS {
				fb.ok = false
				return -1
			}
			p_bit := u8(len(fb.parts))
			append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, is_presence = true, presence_name = dep.name})
			append(&fb.presence, Presence_Build{name = dep.name, part = p_bit})
			cond_op := i16(len(fb.ops))
			append(&fb.ops, Factor_Op{kind = .Part, bit = p_bit})
			then_op := gather(fb, dn, {}, depth + 1)
			if !fb.ok {
				return -1
			}
			if_op := i16(len(fb.ops))
			append(&fb.ops, Factor_Op{kind = .If, first = cond_op, count = then_op, else_op = -1})
			append(&children, if_op)
		}
	}

	// `$ref`
	if r, has := n.ref.?; has {
		saved := b.scope
		enter_scope(b, d, fb.arena, r)
		sub := gather(fb, r, {}, depth + 1)
		b.scope = saved
		if !fb.ok {
			return -1
		}
		append(&children, sub)
	}

	// `$dynamicRef`
	if dr, has := n.dynamic_ref.?; has {
		target := dynamic_target(b, d, n, dr)
		saved := b.scope
		enter_scope(b, d, fb.arena, target)
		sub := gather(fb, target, {}, depth + 1)
		b.scope = saved
		if !fb.ok {
			return -1
		}
		append(&children, sub)
	}

	// `allOf`
	for a in n.all_of {
		sub := gather(fb, a, {}, depth + 1)
		if !fb.ok {
			return -1
		}
		append(&children, sub)
	}

	// `anyOf`
	if len(n.any_of) > 0 {
		arms := make([dynamic]i16, fb.tables)
		for a in n.any_of {
			sub := gather(fb, a, {}, depth + 1)
			if !fb.ok {
				return -1
			}
			append(&arms, sub)
		}
		append(&children, emit_group_op(fb, .Any, arms[:]))
	}

	// `oneOf`
	if len(n.one_of) > 0 {
		arms := make([dynamic]i16, fb.tables)
		for a in n.one_of {
			sub := gather(fb, a, {}, depth + 1)
			if !fb.ok {
				return -1
			}
			append(&arms, sub)
		}
		append(&children, emit_group_op(fb, .One, arms[:]))
	}

	// `not`
	if nt, has := n.not.?; has {
		sub := gather(fb, nt, {}, depth + 1)
		if !fb.ok {
			return -1
		}
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Not, first = sub})
		append(&children, op_idx)
	}

	// `if` / `then` / `else`
	if test, has := n.cond.test.?; has && (n.cond.then != nil || n.cond.other != nil) {
		test_op := gather(fb, test, {}, depth + 1)
		then_op := i16(-1)
		if th, has_th := n.cond.then.?; has_th {
			then_op = gather(fb, th, {}, depth + 1)
		}
		else_op := i16(-1)
		if ot, has_ot := n.cond.other.?; has_ot {
			else_op = gather(fb, ot, {}, depth + 1)
		}
		if !fb.ok {
			return -1
		}
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .If, first = test_op, count = then_op, else_op = else_op})
		append(&children, op_idx)
	}

	if len(children) == 0 {
		return add_trivial_part(fb)
	}
	res := children[0] if len(children) == 1 else emit_group_op(fb, .All, children[:])

	// Stage 4: inner `unevaluatedProperties: false` on a sub-part records a `Factor_Closing`
	// guarded by a synthetic part bit settled in `closings_judge` at object close!
	if part_uneval_false {
		if len(fb.parts) >= MAX_FACTOR_PARTS {
			fb.ok = false
			return -1
		}
		c_bit := u8(len(fb.parts))
		append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, max_members = max(u64)})
		append(&fb.closings, Factor_Closing{part = c_bit, root_op = res})
		c_op := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Part, bit = c_bit})
		pair := [2]i16{res, c_op}
		res = emit_group_op(fb, .All, pair[:])
	}
	return res
}

@(private = "file")
add_trivial_part :: proc(fb: ^Factor_Build) -> i16 {
	if len(fb.parts) >= MAX_FACTOR_PARTS {
		fb.ok = false
		return -1
	}
	bit := u8(len(fb.parts))
	append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, max_members = max(u64)})
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Part, bit = bit})
	return op_idx
}

@(private = "file")
add_fail_part :: proc(fb: ^Factor_Build) -> i16 {
	// A part whose `min_members = max(u64)` always fails for any object (impossible to have `max(u64)` keys).
	if len(fb.parts) >= MAX_FACTOR_PARTS {
		fb.ok = false
		return -1
	}
	bit := u8(len(fb.parts))
	append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, min_members = max(u64), max_members = 0})
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Part, bit = bit})
	return op_idx
}

// Emits a contiguous group of child ops into `fb.ops` (copies children into a contiguous block at the end).
@(private = "file")
emit_group_op :: proc(fb: ^Factor_Build, kind: Factor_Op_Kind, children: []i16) -> i16 {
	// Stage 4 optimization: if every child of `.Any`/`.One` is a `.Part`, emit a single `.Any_Mask`/`.One_Mask`!
	if kind == .Any || kind == .One {
		all_parts := true
		mask := u64(0)
		dup := false
		for ch in children {
			op := fb.ops[ch]
			if op.kind != .Part {
				all_parts = false
				break
			}
			bit := u64(1) << op.bit
			if (mask & bit) != 0 {
				dup = true
				break
			}
			mask |= bit
		}
		if all_parts && !dup {
			op_idx := i16(len(fb.ops))
			append(&fb.ops, Factor_Op{kind = .Any_Mask if kind == .Any else .One_Mask, mask = mask})
			return op_idx
		}
	}
	// Flatten contiguous children block: append copies of children? No: children may already reference their own
	// sub-ops by index in `fb.ops`! So we store child indices only if contiguous, OR store a small indirection.
	// Wait: `ops_flatten` lays out the entire tree top-down in `out` so every `.All`/`.Any`/`.One` has
	// strictly contiguous children `first ..< first + count`!
	// During `gather`, we temporarily keep children in a flat index list? Let's just lay out `ops_flatten` from
	// a small `Gather_Node` tree! Even simpler: in `fb.ops`, for `.All`/`.Any`/`.One` we can store children
	// contiguously right now by placing `op` first? No, children are already emitted.
	// Let's keep `Gather_Children` in a tiny side array on `Factor_Build`? No, we can emit a copy of each child
	// `Factor_Op` contiguously right here! Wait: if a child is `.All`/`.Any`/`.One`, its `first` points to its own
	// already-contiguous children, so copying the `Factor_Op` struct value keeps its `first` 100% valid!
	// Let's verify that!
	// - Child `ch` is a `Factor_Op` whose own children (if any) are at `ch.first ..< ch.first + ch.count` (already placed!).
	// - Copying `fb.ops[ch]` to `start + i` preserves `ch.first`, `ch.count`, `ch.else_op`, `ch.bit`, `ch.mask`!
	// - The ONLY thing that breaks if `ch` is copied is if `Factor_Closing.root_op` points to an old index —
	//   and `Factor_Closing.root_op` STILL points to a valid index in `fb.ops` because we never overwrite old indices!
	start := i16(len(fb.ops))
	for ch in children {
		append(&fb.ops, fb.ops[ch])
	}
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = kind, first = start, count = i16(len(children))})
	return op_idx
}

// Re-roots `fb.ops` into a compact slice in `fb.arena` with `ops[0]` as the root op,
// updating `fb.closings[i].root_op` to match.
@(private = "file")
ops_flatten :: proc(fb: ^Factor_Build, root_op: i16) -> []Factor_Op {
	if root_op < 0 || int(root_op) >= len(fb.ops) {
		return nil
	}
	// Place root at index 0 by placing all `fb.ops` shifted by +1 and putting `fb.ops[root_op]` at index 0.
	n := len(fb.ops) + 1
	out, err := make([]Factor_Op, n, fb.arena)
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
			if res.count >= 0 {
				res.count += 1
			}
			if res.else_op >= 0 {
				res.else_op += 1
			}
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

@(private = "file")
ops_monotone :: proc "contextless" (ops: []Factor_Op) -> bool {
	for op in ops {
		if op.kind == .Not || op.kind == .If {
			return false
		}
	}
	return true
}

// Builds a `Factor_Member` for either a named member `name` (with its matching `pat_mask`)
// or an unnamed pattern class (`unnamed = true`, `pat_mask = class 0..15`).
@(private = "file")
Disc_Entry :: struct {
	key:  string,
	part: u8,
}

@(private = "file")
build_factor_member :: proc(fb: ^Factor_Build, name: string, pat_mask: u8, unnamed: bool) -> (^Factor_Member, bool) {
	b, d, arena, tables := fb.b, fb.d, fb.arena, fb.tables
	fm, err := new(Factor_Member, arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return nil, false
	}

	Node_Constraint :: struct {
		node:  rules.Node_Index,
		edge:  rules.Rules,
		part:  u8,
		scope: i32,
	}
	cons := make([dynamic]Node_Constraint, tables)

	for pt, pi in fb.parts {
		bit := u64(1) << uint(pi)
		if pt.is_presence || pt.obj < 0 {
			continue
		}
		o := &d.objects[pt.obj]
		matched := false
		if !unnamed {
			for m in o.members {
				if m.name == name && !m.only_required {
					matched = true
					fm.evals |= bit
					append(&cons, Node_Constraint{node = m.node, edge = m.rules, part = u8(pi), scope = pt.scope})
				}
			}
		}
		// Pattern properties matching this member/class.
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
				fm.evals |= bit
				append(&cons, Node_Constraint{node = p.node, part = u8(pi), scope = pt.scope})
			}
		}
		// Additional properties (applies only when no named property and no pattern matched in this part).
		if !matched {
			if pt.add_false {
				fm.refuse |= bit
			} else if pt.add_node != rules.NONE {
				fm.evals |= bit
				append(&cons, Node_Constraint{node = pt.add_node, part = u8(pi), scope = pt.scope})
			}
		}
	}

	if len(cons) == 0 {
		return fm, true
	}

	disc_entries := make([dynamic]Disc_Entry, tables)
	disc_parts := u64(0)
	leaf_list := make([dynamic]Factor_Leaf, tables)
	choice_nodes := make([dynamic]Choice_Node, tables)

	Choice_Node :: struct {
		node:  rules.Node_Index,
		edge:  rules.Rules,
		scope: i32,
		parts: u64,
	}

	for c in cons {
		bit := u64(1) << c.part
		if (fm.refuse & bit) != 0 {
			continue
		}
		saved_sc := b.scope
		b.scope = c.scope
		end_node, hops := rules.ref_end(d, c.node)
		if end_node == rules.NONE {
			b.scope = saved_sc
			continue
		}
		for y, hop := c.node, 0; y != rules.NONE && hop <= hops; hop += 1 {
			enter_scope(b, d, arena, y)
			y = d.nodes[y].ref.? or_else end_node
		}
		eff_scope := b.scope
		cn := &d.nodes[end_node]
		if cn.kinds == {} {
			fm.refuse |= bit
			b.scope = saved_sc
			continue
		}
		if c.edge == {} && judges_nothing(b, d, end_node) {
			b.scope = saved_sc
			continue
		}
		// Check if pure leaf (no container subschemas, no applicators/arms).
		is_plain_leaf := !holds(b, d, end_node, c.edge) && cn.object < 0 && cn.array < 0
		if is_plain_leaf {
			leaf_id := checked_leaf(b, cn, c.edge, arena)
			b.scope = saved_sc
			if b.err.kind != .None {
				return nil, false
			}
			if leaf_id == 0 {
				continue
			}
			l := &b.leaves[leaf_id - 1]
			// Promote to pure discriminator `Factor_Table` ONLY when every enum key satisfies `l.kinds` (B-C8)!
			is_disc := l.has_enum && !l.minimum.set && !l.maximum.set && l.multiple_of == nil && l.pattern == nil && l.formats == {} && l.min_length == 0 && l.max_length == max(u64) && l.min_items == 0 && l.max_items == max(u64) && l.min_members == 0 && l.max_members == max(u64) && !l.integer_spelled && (disc_parts & bit) == 0 && enum_keys_fit_kinds(l)
			if is_disc && len(l.enum_keys) > 0 {
				disc_parts |= bit
				for k in l.enum_keys {
					append(&disc_entries, Disc_Entry{key = k, part = c.part})
				}
				continue
			}
			merged_leaf := false
			for &fl in leaf_list {
				if fl.leaf == leaf_id {
					fl.parts |= bit
					merged_leaf = true
					break
				}
			}
			if !merged_leaf {
				append(&leaf_list, Factor_Leaf{leaf = leaf_id, parts = bit})
			}
			continue
		}
		b.scope = saved_sc
		// Container or complex held member -> `Factor_Choice` (group identical `(end_node, edge, scope)`).
		merged_ch := false
		for &ch in choice_nodes {
			if ch.node == end_node && ch.edge == c.edge && ch.scope == eff_scope {
				ch.parts |= bit
				merged_ch = true
				break
			}
		}
		if !merged_ch {
			append(&choice_nodes, Choice_Node{node = end_node, edge = c.edge, scope = eff_scope, parts = bit})
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
		copy(leaves, leaf_list[:])
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
			choices[i] = Factor_Choice{record = rec, parts = ch.parts}
		}
		b.scope = saved_sc
		fm.choices = choices
	}

	return fm, true
}

// Verifies every key in `l.enum_keys` satisfies `l.kinds` (B-C8: prevents mixed-type enum like `type:"string", enum:["a", 1]`
// or `type:"integer", enum:[1.5]` from matching invalid kinds in a pure `Factor_Table`).
@(private = "file")
enum_keys_fit_kinds :: proc "contextless" (l: ^rules.Leaf) -> bool {
	if l.kinds == rules.EVERY_KIND {
		return true
	}
	for k in l.enum_keys {
		if len(k) == 0 {
			return false
		}
		switch k[0] {
		case 's':
			if .String not_in l.kinds {
				return false
			}
		case 't', 'f':
			if .Bool not_in l.kinds {
				return false
			}
		case 'z':
			if .Null not_in l.kinds {
				return false
			}
		case 'n':
			if .Number not_in l.kinds {
				// If only `.Integer` is allowed, `enum_key` is `n[-]digits e point`: integer iff `point >= len(digits)`!
				if .Integer not_in l.kinds {
					return false
				}
				return false // Keep in `fm.leaves` so `integer` check runs cleanly!
			}
		case:
			return false
		}
	}
	return true
}

@(private = "file")
build_factor_table :: proc(b: ^Builder, arena, tables: runtime.Allocator, entries: []Disc_Entry, all_parts: u64) -> ^Factor_Table {
	// Collect unique keys sorted by `rules.enum_sort`.
	uniq := make([dynamic]string, tables)
	for e in entries {
		if !slice.contains(uniq[:], e.key) {
			append(&uniq, e.key)
		}
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

// Finalizes all compiled `Factor`s after `fill_pending` completes: ensures member records have `NO_KEY`
// (so every key hits `check_key` and repeats are detected) and copies hash table info onto `Factor`.
@(private)
factor_finish :: proc(b: ^Builder) {
	for f in b.factors {
		for k in 0 ..< int(f.members) {
			b.records[int(f.block) + k].word = NO_KEY
		}
	}
}

// Evaluates the boolean circuit `f.ops` starting at `op_idx` given the failed parts bitmask `failed`.
@(private)
factor_eval :: proc "contextless" (f: ^Factor, failed: u64, op_idx: i16 = 0) -> bool #no_bounds_check {
	op := f.ops[op_idx]
	switch op.kind {
	case .Part:
		return (failed & (u64(1) << op.bit)) == 0
	case .Any_Mask:
		return (op.mask & ~failed) != 0
	case .One_Mask:
		alive := op.mask & ~failed
		return alive != 0 && (alive & (alive - 1)) == 0
	case .All:
		for i in 0 ..< op.count {
			if !factor_eval(f, failed, op.first + i) {
				return false
			}
		}
		return true
	case .Any:
		for i in 0 ..< op.count {
			if factor_eval(f, failed, op.first + i) {
				return true
			}
		}
		return false
	case .One:
		hits := 0
		for i in 0 ..< op.count {
			if factor_eval(f, failed, op.first + i) {
				hits += 1
				if hits > 1 {
					return false
				}
			}
		}
		return hits == 1
	case .Not:
		return !factor_eval(f, failed, op.first)
	case .If:
		if factor_eval(f, failed, op.first) {
			return true if op.count < 0 else factor_eval(f, failed, op.count)
		}
		return true if op.else_op < 0 else factor_eval(f, failed, op.else_op)
	}
	return false
}

// Collects the bitmask of all parts that actively contributed to a passing evaluation of `f.ops` at `op_idx`,
// used for exact `unevaluatedProperties: false` settlement (Stage 1/2/4).
@(private)
parts_of :: proc "contextless" (f: ^Factor, failed: u64, op_idx: i16 = 0) -> (passed: bool, active: u64) #no_bounds_check {
	op := f.ops[op_idx]
	switch op.kind {
	case .Part:
		bit := u64(1) << op.bit
		if (failed & bit) == 0 {
			return true, bit
		}
		return false, 0
	case .Any_Mask:
		alive := op.mask & ~failed
		return alive != 0, alive
	case .One_Mask:
		alive := op.mask & ~failed
		if alive != 0 && (alive & (alive - 1)) == 0 {
			return true, alive
		}
		return false, 0
	case .All:
		acc := u64(0)
		for i in 0 ..< op.count {
			ok, sub := parts_of(f, failed, op.first + i)
			if !ok {
				return false, 0
			}
			acc |= sub
		}
		return true, acc
	case .Any:
		acc := u64(0)
		hit := false
		for i in 0 ..< op.count {
			ok, sub := parts_of(f, failed, op.first + i)
			if ok {
				hit = true
				acc |= sub
			}
		}
		return hit, acc
	case .One:
		acc := u64(0)
		hits := 0
		for i in 0 ..< op.count {
			ok, sub := parts_of(f, failed, op.first + i)
			if ok {
				hits += 1
				acc = sub
			}
		}
		return hits == 1, acc if hits == 1 else 0
	case .Not:
		// `not` never exports evaluated properties to outer `unevaluatedProperties`!
		return !factor_eval(f, failed, op.first), 0
	case .If:
		cond_ok, cond_parts := parts_of(f, failed, op.first)
		if cond_ok {
			if op.count < 0 {
				return true, cond_parts
			}
			th_ok, th_parts := parts_of(f, failed, op.count)
			return th_ok, (cond_parts | th_parts) if th_ok else 0
		}
		if op.else_op < 0 {
			return true, 0
		}
		return parts_of(f, failed, op.else_op)
	}
	return false, 0
}

// Stage 3: conservative early doom test. Returns true ONLY when `f.ops` can never pass regardless
// of future members or counts (used when `h.sink == nil` to abort immediately on a failing member).
@(private)
factor_doomed :: proc "contextless" (f: ^Factor, failed: u64) -> bool {
	if !f.monotone {
		return false
	}
	return !op_can_pass(f, failed, 0)
}

@(private = "file")
op_can_pass :: proc "contextless" (f: ^Factor, failed: u64, op_idx: i16) -> bool #no_bounds_check {
	op := f.ops[op_idx]
	switch op.kind {
	case .Part:
		return (failed & (u64(1) << op.bit)) == 0
	case .Any_Mask, .One_Mask:
		return (op.mask & ~failed) != 0
	case .All:
		for i in 0 ..< op.count {
			if !op_can_pass(f, failed, op.first + i) {
				return false
			}
		}
		return true
	case .Any, .One:
		for i in 0 ..< op.count {
			if op_can_pass(f, failed, op.first + i) {
				return true
			}
		}
		return false
	case .Not, .If:
		return true
	}
	return true
}

// Records an early-doomed factored-object failure properly even though `h.quiet` is true inside factored objects (B-C2).
@(private)
fail_doomed_factored :: proc(h: ^Checker, fo: ^Factored_Open) {
	if h.nf > 0 {
		h.quiet = factored_at(h, 0).saved_quiet
	}
	h.failed = true
	record_first_failure(h, .No_Arm, fo.open_at, "anyOf", "", fo.owner)
}

// Under `.Last`/`.Group` or inside a nested factored object / choice / subcheck, do not early-doom the whole walk!
@(private)
can_doom_factored :: #force_inline proc "contextless" (h: ^Checker, f: ^Factor, failed: u64) -> bool {
	return h.sink == nil && h.dups != .Last && h.dups != .Group && h.nest_depth == 0 && h.nf == 1 && h.choice_depth == 0 && factor_doomed(f, failed)
}

@(private)
INLINE_FACTORED :: 4

@(private)
factored_at :: #force_inline proc "contextless" (h: ^Checker, idx: int) -> ^Factored_Open #no_bounds_check {
	if idx < INLINE_FACTORED {
		return &h.factored_buf[idx]
	}
	return &h.pool.factored[idx - INLINE_FACTORED]
}

// Opens a factored object on `h.factored_buf` (zero allocs for depth <= 4!) or `h.pool.factored`.
@(private)
factored_open :: proc(h: ^Checker, owner: ^Record, f: ^Factor, at: u64) -> bool {
	if h.nf >= MAX_FACTOR_DEPTH {
		return false
	}
	fo: ^Factored_Open
	if h.nf < INLINE_FACTORED {
		fo = &h.factored_buf[h.nf]
	} else {
		pool := pool_ensure(h)
		if pool == nil {
			return false
		}
		pidx := h.nf - INLINE_FACTORED
		if pidx >= len(pool.factored) {
			if resize(&pool.factored, pidx + 1) != nil {
				h.fatal = .No_Memory
				return false
			}
		}
		fo = &pool.factored[pidx]
	}
	fo^ = {
		factor = f,
		owner = owner,
		active_choice = -1,
		parent_sp = h.sp,
		saved_quiet = h.quiet,
		saved_no_factor = h.no_factor,
		saved_failed = h.failed,
		open_at = at,
		unk_tracker = -1,
	}
	if f.members > 64 {
		pool := pool_ensure(h)
		if pool == nil {
			return false
		}
		words := (int(f.members) + 63) / 64
		buf := pool_seen_wide(h, pool, h.nf, words)
		if buf == nil {
			return false
		}
		fo.seen_wide = buf
	}
	h.nf += 1
	// Mute sink and isolate failure flag while inside a factored object (Stage 1/4: on failure with a sink, we reread via runs).
	h.quiet = true
	h.failed = false
	return true
}

// Marks member `idx` as seen in `fo`. Returns true if it was ALREADY seen (duplicate key!).
@(private)
factored_mark_seen :: #force_inline proc "contextless" (fo: ^Factored_Open, idx: i32) -> bool #no_bounds_check {
	if fo.factor.members <= 64 {
		bit := u64(1) << uint(idx)
		if (fo.seen_mask & bit) != 0 {
			return true
		}
		fo.seen_mask |= bit
		return false
	}
	w := idx >> 6
	bit := u64(1) << uint(idx & 63)
	if (fo.seen_wide[w] & bit) != 0 {
		return true
	}
	fo.seen_wide[w] |= bit
	return false
}

@(private)
factored_is_seen :: #force_inline proc "contextless" (fo: ^Factored_Open, idx: i32) -> bool #no_bounds_check {
	if fo.factor.members <= 64 {
		return (fo.seen_mask & (u64(1) << uint(idx))) != 0
	}
	return (fo.seen_wide[idx >> 6] & (u64(1) << uint(idx & 63))) != 0
}

// Handles a key token for the innermost open factored object.
// Looks up the key in the factored member block (or dispatches via Stage 2 `pattern_class` for unnamed keys),
// applies unconditional `refuse`, and returns whether the member's value can be skipped!
@(private)
factored_key :: proc(h: ^Checker, fo: ^Factored_Open, key: string, key_owned: bool, at: u64) -> (skip: bool, doomed: bool) {
	f := fo.factor
	fo.seen_count += 1

	// Look up in the factored block's hash table (O(1)).
	m := &h.plan.meta[f.block + f.members]
	idx := member_find(h.plan, m, key)
	fm: ^Factor_Member
	if idx >= 0 {
		if factored_mark_seen(fo, idx) {
			if h.dups == .First || h.dups == .Last || (h.dups == .Group && !h.in_doc_group) {
				h.need_reread = true
				return false, true
			}
		}
		fm = h.plan.uses[f.block + idx].member
	} else {
		// Track duplicate unnamed keys under `.First`/`.Last`/streaming `.Group` (B-H2)!
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
		if h.fatal != .None {
			return false, true
		}
		fo.unknown_classes |= u16(1) << cls
		fm = f.classes[cls]
	}

	fo.active_member = fm
	if fm == nil {
		return true, false
	}
	fo.failed |= fm.refuse
	if can_doom_factored(h, f, fo.failed) {
		return false, true
	}
	// If no discriminator, no leaves, and no choices remain for any still-alive part, we can `.Skip` the value!
	alive := f.all_parts & ~fo.failed
	need_val := false
	if fm.table != nil && (fm.table.all & alive) != 0 {
		need_val = true
	}
	if !need_val {
		for fl in fm.leaves {
			if (fl.parts & alive) != 0 {
				need_val = true
				break
			}
		}
	}
	if !need_val {
		for ch in fm.choices {
			if (ch.parts & alive) != 0 {
				need_val = true
				break
			}
		}
	}
	if !need_val && len(fm.choices) == 0 && fm.table == nil && len(fm.leaves) == 0 {
		return true, false
	}
	// Note: if `f.monotone` is false (has `.Not`/`.If`), even parts currently alive or potentially relevant must be checked.
	if !f.monotone && (fm.table != nil || len(fm.leaves) > 0 || len(fm.choices) > 0) {
		need_val = true
	}
	return !need_val, false
}

// Computes the 4-bit pattern-match bitmask for an unnamed key in a Stage 2 factored object.
@(private = "file")
pattern_class :: proc(h: ^Checker, f: ^Factor, key: string) -> u8 {
	if len(f.patterns) == 0 {
		return 0
	}
	cls := u8(0)
	for re, i in f.patterns {
		found, ok := run_regex_search(h, re, key)
		if !ok {
			return 0
		}
		if found {
			cls |= u8(1) << uint(i)
		}
	}
	return cls
}

// Judges a scalar value token on the active member of `fo` (discriminator table + leaves + scalar choices).
// Returns `doomed = true` if the object is already doomed under `h.sink == nil` (non-`.Last`).
@(private)
factored_scalar :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (doomed: bool) {
	fm := fo.active_member
	fo.active_member = nil
	if fm == nil {
		return false
	}
	f := fo.factor

	// 1. Discriminator table lookup (Stage 1) with full OOM propagation and `.Plain`/non-plain number normalization (B-C8).
	if tbl := fm.table; tbl != nil {
		buf: [128]u8 = ---
		text, owned, ok := token_decoded_scalar(h, t, buf[:])
		if !ok {
			if t.kind != .Number {
				h.fatal = .No_Memory
				return true
			}
			// Non-finite float / unspellable CBOR bignum cannot match any finite scalar discriminator.
			fo.failed |= tbl.all
		} else {
			defer if owned {
				delete(text, checker_scratch(h))
			}
			tk := token_effective_kind(h, t)
			num_buf: [64]u8 = ---
			lookup_text := text
			lookup_owned := false
			valid_scalar := true
			if tk == .Number {
				nt, nown, nok := normalize_token_number(h, t, text, num_buf[:])
				if !nok {
					valid_scalar = false
				} else {
					lookup_text, lookup_owned = nt, nown
				}
			} else if t.kind == .Plain {
				// For DSV/XML `.Plain` tokens, try string first, then natural inferred kind if not found!
				if idx, found := rules.enum_find(tbl.keys, .String, text, checker_scratch(h)); found {
					fo.failed |= tbl.all & ~tbl.parts[idx]
					valid_scalar = false // already handled
				} else {
					tk, lookup_text = infer_plain_scalar_kind(text)
				}
			}
			if valid_scalar {
				idx, found := rules.enum_find(tbl.keys, tk, lookup_text, checker_scratch(h))
				if found {
					fo.failed |= tbl.all & ~tbl.parts[idx]
				} else {
					fo.failed |= tbl.all
				}
			}
			if lookup_owned {
				delete(lookup_text, checker_scratch(h))
			}
		}
	}

	// 2. Scalar leaves.
	for fl in fm.leaves {
		if f.monotone && (fl.parts & ~fo.failed) == 0 {
			continue
		}
		l := &h.plan.leaves[fl.leaf - 1]
		if !scalar_passes_leaf(h, l, t) {
			fo.failed |= fl.parts
		}
		if h.fatal != .None {
			return true
		}
	}

	// 3. Choices (a complex choice record might still accept scalars, e.g. `anyOf: [{type: "string"}, {type: "object"}]`!).
	for ch in fm.choices {
		if f.monotone && (ch.parts & ~fo.failed) == 0 {
			continue
		}
		if !scalar_passes_record(h, ch.record, t) {
			fo.failed |= ch.parts
		}
		if h.fatal != .None {
			return true
		}
	}

	if can_doom_factored(h, f, fo.failed) {
		return true
	}
	return false
}

@(private = "file")
infer_plain_scalar_kind :: proc "contextless" (text: string) -> (tape.Kind, string) {
	if len(text) == 0 || text == "null" {
		return .Null, ""
	}
	if text == "true" {
		return .True, ""
	}
	if text == "false" {
		return .False, ""
	}
	if rules.valid_decimal_text(text) {
		return .Number, text
	}
	return .String, text
}

// Judges a container opening token on the active member of `fo`.
@(private)
factored_container :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (choice_rec: ^Record, use_fork: bool, skip: bool, doomed: bool) {
	fm := fo.active_member
	if fm == nil {
		fo.active_member = nil
		return nil, false, true, false
	}
	f := fo.factor

	// 1. Discriminator table only holds scalars -> every table part fails on a container.
	if tbl := fm.table; tbl != nil {
		fo.failed |= tbl.all
	}

	// 2. Scalar leaves: fail any leaf that rejects this container kind or requires a scalar enum.
	want_kind := rules.Kind.Object if t.kind == .Object else rules.Kind.Array
	for fl in fm.leaves {
		l := &h.plan.leaves[fl.leaf - 1]
		if want_kind not_in l.kinds || l.has_enum {
			fo.failed |= fl.parts
		}
	}

	if can_doom_factored(h, f, fo.failed) {
		fo.active_member = nil
		return nil, false, false, true
	}

	// 3. Choices: count how many choices are still relevant.
	live_count := 0
	live_idx := -1
	for ch, i in fm.choices {
		if f.monotone && (ch.parts & ~fo.failed) == 0 {
			continue
		}
		live_count += 1
		live_idx = i
	}
	if live_count == 0 {
		for fl in fm.leaves {
			l := &h.plan.leaves[fl.leaf - 1]
			if (t.kind == .Object && (l.min_members > 0 || l.max_members < max(u64))) || (t.kind == .Array && (l.min_items > 0 || l.max_items < max(u64))) {
				return nil, true, false, false
			}
		}
		fo.active_member = nil
		return nil, false, true, false
	}
	if live_count == 1 {
		has_cnt_leaf := false
		for fl in fm.leaves {
			l := &h.plan.leaves[fl.leaf - 1]
			if (t.kind == .Object && (l.min_members > 0 || l.max_members < max(u64))) || (t.kind == .Array && (l.min_items > 0 || l.max_items < max(u64))) {
				has_cnt_leaf = true
				break
			}
		}
		if !has_cnt_leaf {
			fo.active_choice = live_idx
			return &h.plan.records[fm.choices[live_idx].record], false, false, false
		}
	}
	return nil, true, false, false
}

// Closes the innermost open factored object, settling required members, presence triggers (`dependentSchemas`),
// per-part & spine property counts, inner `unevaluatedProperties: false` closings, and outer `unevaluatedProperties: false`.
@(private)
factored_close :: proc(h: ^Checker) -> (passed: bool, owner: ^Record, open_at: u64) {
	h.nf -= 1
	fo := factored_at(h, h.nf)
	if fo.unk_tracker >= 0 {
		close_tracker(h)
		fo.unk_tracker = -1
	}
	f := fo.factor
	owner = fo.owner
	open_at = fo.open_at
	h.quiet = fo.saved_quiet
	h.no_factor = fo.saved_no_factor
	h.failed = fo.saved_failed

	failed := fo.failed

	// 1. Required members.
	for req in f.required {
		if !factored_is_seen(fo, req.member) {
			failed |= req.parts
		}
	}

	// 2. `dependentSchemas` presence triggers (Stage 4).
	for pr in f.presence {
		if !factored_is_seen(fo, pr.member) {
			failed |= u64(1) << pr.part
		}
	}

	// 3. Per-part `minProperties` / `maxProperties`.
	for cnt in f.counts {
		if fo.seen_count < cnt.min_members || fo.seen_count > cnt.max_members {
			failed |= cnt.parts
		}
	}

	// 4. Inner `unevaluatedProperties: false` closings (Stage 4): ONLY `cl_active` (NOT `f.eval_all` from sibling arms — B-C3!).
	for cl in f.closings {
		cl_ok, cl_active := parts_of(f, failed, cl.root_op)
		if !cl_ok || !all_members_evaluated(h.plan, fo, cl_active) {
			failed |= u64(1) << cl.part
		}
	}

	// 5. Spine `minProperties` / `maxProperties` (Stage 3).
	if f.spine_leaf > 0 {
		l := &h.plan.leaves[f.spine_leaf - 1]
		if fo.seen_count < l.min_members || fo.seen_count > l.max_members {
			return false, owner, open_at
		}
	}

	// 6. Final circuit verdict & outer `unevaluatedProperties: false`.
	if !f.uneval_false {
		return factor_eval(f, failed, 0), owner, open_at
	}
	ok, active := parts_of(f, failed, 0)
	if !ok {
		return false, owner, open_at
	}
	if !all_members_evaluated(h.plan, fo, active) {
		return false, owner, open_at
	}
	return true, owner, open_at
}

// Verifies that every seen named member and every seen unnamed pattern-class in `fo` is evaluated
// by at least one part in `active`.
@(private = "file")
all_members_evaluated :: proc "contextless" (p: ^Plan, fo: ^Factored_Open, active: u64) -> bool #no_bounds_check {
	f := fo.factor
	if (active & f.eval_all) != 0 {
		return true
	}
	if f.members <= 64 {
		mask := fo.seen_mask
		for mask != 0 {
			idx := int(intrinsics.count_trailing_zeros(mask))
			mask &= mask - 1
			fm := p.uses[int(f.block) + idx].member
			if fm == nil || (fm.evals & active) == 0 {
				return false
			}
		}
	} else {
		for word, w in fo.seen_wide {
			m := word
			for m != 0 {
				bit := int(intrinsics.count_trailing_zeros(m))
				m &= m - 1
				idx := w * 64 + bit
				fm := p.uses[int(f.block) + idx].member
				if fm == nil || (fm.evals & active) == 0 {
					return false
				}
			}
		}
	}
	cls_mask := fo.unknown_classes
	for cls_mask != 0 {
		c := int(intrinsics.count_trailing_zeros(cls_mask))
		cls_mask &= cls_mask - 1
		fm := f.classes[c]
		if fm == nil || (fm.evals & active) == 0 {
			return false
		}
	}
	return true
}
