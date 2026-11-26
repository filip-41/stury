// 4-stage factored held-object compiler & runtime (ported from stury v1 `lab/schema-held/`).
// Compiles flat & nested held objects (`allOf`, `anyOf`, `oneOf`, `not`, `if/then/else`, `$ref`,
// `dependentSchemas`, `patternProperties`, `additionalProperties: false`, `unevaluatedProperties: false`,
// multi-record choices, and spine counts) into a single factored `.Checked` record evaluated in one pass.
package check

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:strings"
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
	bit:     u8,          // for `.Part`
	is_enum: bool,        // true when `.Any_Mask` or `.Part` represents a container `enum`
	first:   i16,         // first child op index in `Factor.ops` (or test op for `.If`)
	count:   i16,         // child count for `.All`/`.Any`/`.One`, or `then_op` for `.If` (-1 for none)
	else_op: i16,         // `else_op` for `.If` (-1 for none)
	mask:    u64,         // for `.Any_Mask` / `.One_Mask`
	site:    []tape.Step, // keyword steps from `Factor` root to this combinator / `enum`
}

// One keyword site origin contributing to a leaf, choice, or refuse check on a factored member.
@(private)
Member_Site :: struct {
	parts: u64,
	site:  []tape.Step,
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
	sites: []Member_Site,
}

// One non-leaf (container or complex) record choice shared by `parts` on a factored member (Stage 3).
@(private)
Factor_Choice :: struct {
	record: i32, // record index in `Plan.records`
	parts:  u64,
	sites:  []Member_Site,
}

// How a factored object judges one member (either a named member in its block or one of the 16 pattern classes).
@(private)
Factor_Member :: struct {
	evals:        u64,           // parts that evaluate this member
	refuse:       u64,           // parts that unconditionally refuse this member (e.g. `false` schema)
	table:        ^Factor_Table, // optional scalar discriminator table (Stage 1)
	table_leaves: []Factor_Leaf, // original enum/const leaves (for exact single-pass errors on failure)
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
	site:       []tape.Step,     // keyword steps from `Factor` root to this part
	fail_leaf:  i32,             // 1 + leaf index when part always fails kind/false/enum check on container
	const_kind: Part_Const_Kind, // `.Const` or `.Enum` for container `const`/`enum` part
	uneval_kw:  string,          // non-empty for inner `unevaluatedProperties`/`unevaluatedItems` closing part
	no_emit:    bool,            // true for synthetic `const`, `enum`, `presence`, `closing`, and `fail_leaf` parts
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

// Per-part `dependentRequired` (or Draft 4/7 array `dependencies`) constraint.
@(private)
Factor_Dep_Required :: struct {
	trigger: i32,
	wants:   []i32,
	parts:   u64,
	keyword: string,
}

// Per-part non-held `propertyNames` constraint.
@(private)
Factor_Keys :: struct {
	leaf:  i32, // 1 + index in `Plan.leaves`
	parts: u64,
}

// Compiled 4-stage factored representation of a held object or array record.
@(private)
Factor :: struct {
	owner:        i32,                // index of the owning record in `Plan.records`
	n:            u8,                 // total number of parts (0..64)
	block:        i32,                // first named member record in `Plan.records`
	members:      i32,                // count of named members in the factored block
	ops:          []Factor_Op,        // boolean circuit; root is `ops[0]`
	monotone:      bool,               // true if `ops` has no `.Not`/`.If` (enables early `factor_doomed`)
	direct_errors: bool,               // true when conjunctive-only without closings (1-pass direct error emission has zero valid regression)
	uneval_false:  bool,               // outer `unevaluatedProperties: false` / `unevaluatedItems: false`
	spine_leaf:   i32,                // 1 + leaf index for outer `min*`/`max*` (Stage 3)
	patterns:     []^regex.Regex,     // up to `MAX_FACTOR_PATTERNS` regexes (Stage 2)
	classes:      [16]^Factor_Member, // dispatch by 4-bit pattern-match mask (Stage 2)
	required:     []Factor_Required,
	dep_required: []Factor_Dep_Required,
	keys:         []Factor_Keys,
	presence:     []Factor_Presence,  // `dependentSchemas` presence triggers (Stage 4)
	counts:       []Factor_Count,     // per-part `minProperties`/`maxProperties`
	closings:     []Factor_Closing,   // inner `unevaluatedProperties: false` / `unevaluatedItems: false` parts (Stage 4)
	part_meta:    []Part_Meta,        // compile-time keyword metadata per part bit `0 ..< n`
	all_parts:    u64,                // `(u64(1) << n) - 1` (or `~u64(0)` when `n == 64`)
	eval_all:     u64,                // parts that have a non-false `additionalProperties` (evaluate every member)
	no_emit_mask: u64,                // bitmask of parts whose `Part_Meta.no_emit` is true
	arr:          ^Factor_Array,      // non-nil when this Factor represents a held array
}

// Runtime state of one open factored object or array on `Pool.factored`.
@(private)
Factored_Open :: struct {
	factor:             ^Factor,
	owner:              ^Record,
	failed:             u64,             // bitmask of parts that have failed so far
	seen_mask:          u64,             // bitmask of seen named members (for `members <= 64`)
	seen_wide:          []u64,           // heap bitmask of seen named members (for `members > 64`)
	seen_count:         u64,             // number of members/elements seen in this container
	unknown_classes:    u16,             // bitmask of pattern classes `0..15` seen among unnamed members
	active_member:      ^Factor_Member,  // current member/element `Factor_Member` being read
	active_choice:      int,             // -1 if no single choice open, else choice index
	parent_sp:          int,             // `h.sp` where this factored container opened
	saved_quiet:        bool,            // previous `h.quiet` state
	saved_sink:         ^Sink,           // previous `h.sink` when `collect_errors` is active
	saved_buffering:    bool,
	saved_choice_fo:    i16,
	saved_no_factor:    bool,
	saved_failed:       bool,            // previous `h.failed` state
	open_at:            u64,             // byte offset of `{` or `[`
	unk_tracker:        int,             // tracker index for unnamed keys under `.First`/`.Last`, -1 if none
	using_inline_uniq:  bool,            // array `uniqueItems` inline stack hash fast path active
	arr_unique_failed:  bool,            // array `uniqueItems` failed on outer/any part
	arr_state:          ^Arr_Open_State, // heap/scratch state for complex factored array tracking
	doc:                ^tape.Document,  // non-nil when opened from `walk_document_node` (enables zero-reread error fallback)
	doc_node:           tape.Node_Index,
	collect_errors:     bool,            // single-pass buffered error collection active (`h.sink != nil && !h.quiet && f.direct_errors`)
	err_entries:        [dynamic]Factored_Err,
	seen_pos:           [dynamic]Seen_Member_Pos,
	choice_sink:        Sink,
	choice_no_member:   [dynamic]bool,
	choice_mark:        int,
	choice_base_kw:     int,
	cur_seen_idx:       i32,
	cur_seen_cls:       u8,
	last_cls:           u8,
}

// Compile-time builder state for gathering parts of a `Factor`.
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
	obj:           i32, // index in `d.objects`, or -1
	arr:           i32, // index in `d.arrays`, or -1
	scope:         i32, // dynamic scope captured when this part was gathered (B-C6)
	site:          []tape.Step,
	fail_leaf:     i32,
	const_kind:    Part_Const_Kind,
	uneval_kw:     string,
	min_members:   u64,
	max_members:   u64,
	eval_all:      bool,
	add_false:     bool, // `additionalProperties: false`
	add_uneval:    bool, // `additional` came from `settle_unevaluated`
	add_node:      rules.Node_Index,
	keys_node:     rules.Node_Index, // non-held `propertyNames` leaf node, or `rules.NONE`
	keys_scope:    i32,
	no_eval:       bool, // true for synthetic `const`/`enum` parts (must NOT evaluate properties/items)
	is_const:      bool, // true for synthetic `const`/`enum` candidate (even `{}` or `[]`)
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
	if n.rules.unique {
		return nil
	}
	// Outer `unevaluatedProperties` is supported when it is `false` (i.e. `kinds == {}`).
	uneval_false := false
	if up, has := n.unevaluated_properties.?; has {
		up_end := resolve_end_ro(b, d, arena, up)
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
	root_op := gather(&fb, node, edge, 0, nil)
	if !fb.ok || root_op < 0 || len(fb.parts) == 0 {
		return nil
	}
	if len(fb.parts) > MAX_FACTOR_PARTS || len(fb.patterns) > MAX_FACTOR_PATTERNS {
		return nil
	}

	r_outer, clash := rules.merged(n, edge)
	has_spine := clash == "" && (r_outer.min_members > 0 || r_outer.max_members != nil)

	// Must actually benefit from factoring (at least 2 parts, or patterns/unevaluated/closings/const/spine/keys).
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

	// Stage 4: flatten `ops` (`anyOf`/`oneOf` over single-bit parts -> bitmask ops, single-child `All` -> child).
	ops_slice := ops_flatten(&fb, root_op)
	if len(ops_slice) == 0 {
		return nil
	}

	// Collect union of all named members across all parts, `dependentRequired`, `const`/`enum`, and presence triggers.
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
	f.direct_errors = ops_conjunctive_only(f.ops) && len(fb.closings) == 0

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
	if has_spine {
		cnt_node := rules.Node{
			kinds = rules.EVERY_KIND,
			rules = rules.Rules{min_members = r_outer.min_members, max_members = r_outer.max_members},
			array = -1,
			object = -1,
		}
		f.spine_leaf = checked_leaf(b, &cnt_node, {}, arena)
	}
	f.part_meta, f.no_emit_mask = finalize_part_meta(b, arena, fb.parts[:])

	// Build required masks, dependentRequired, propertyNames, per-part counts, eval_all, and presence triggers.
	req_masks := make([]u64, len(names), b.tables)
	counts_list := make([dynamic]Factor_Count, arena)
	dep_req_list := make([dynamic]Factor_Dep_Required, arena)
	keys_list := make([dynamic]Factor_Keys, arena)
	for pt, pi in fb.parts {
		bit := u64(1) << uint(pi)
		if pt.is_presence {
			continue
		}
		if pt.eval_all && !pt.no_eval {
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
		for mv in pt.const_vals {
			idx := name_to_idx[mv.key]
			req_masks[idx] |= bit
		}
		if pt.keys_node != rules.NONE {
			sv := b.scope
			b.scope = pt.keys_scope
			kl := checked_leaf(b, &d.nodes[pt.keys_node], {}, arena)
			b.scope = sv
			if b.err.kind != .None {
				return nil
			}
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
				if m.required {
					idx := name_to_idx[m.name]
					req_masks[idx] |= bit
				}
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
					append(&dep_req_list, Factor_Dep_Required{
						trigger = name_to_idx[dep.name],
						wants = wants,
						parts = bit,
						keyword = kw,
					})
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
	f.dep_required = dep_req_list[:]
	f.keys = keys_list[:]
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

// Clones `base` + `extra` steps into `arena`.
@(private)
site_concat :: proc(b: ^Builder, arena: runtime.Allocator, base: []tape.Step, extra: ..tape.Step) -> []tape.Step {
	if len(base) == 0 && len(extra) == 0 {
		return nil
	}
	out, err := make([]tape.Step, len(base) + len(extra), arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	copy(out, base)
	for s, i in extra {
		#partial switch v in s {
		case tape.Name:
			out[len(base) + i] = tape.Name(clone_str(b, arena, string(v)))
		case tape.Index:
			out[len(base) + i] = v
		}
	}
	return out
}

// Appends pure `$ref`/`$dynamicRef` hop keyword names from `words` onto `base` in `arena`.
@(private)
site_with_words :: proc(b: ^Builder, arena: runtime.Allocator, base: []tape.Step, words: []string) -> []tape.Step {
	if len(base) == 0 && len(words) == 0 {
		return nil
	}
	if len(words) == 0 {
		return base
	}
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

// Builds `Factor.part_meta` and `Factor.no_emit_mask` from compiled `Part_Info`s.
@(private)
finalize_part_meta :: proc(b: ^Builder, arena: runtime.Allocator, parts: []Part_Info) -> (meta: []Part_Meta, no_emit: u64) {
	m, err := make([]Part_Meta, len(parts), arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return nil, 0
	}
	for pt, i in parts {
		ne := pt.is_const || pt.is_presence || pt.fail_leaf > 0 || pt.uneval_kw != ""
		m[i] = Part_Meta{
			site = pt.site,
			fail_leaf = pt.fail_leaf,
			const_kind = pt.const_kind,
			uneval_kw = pt.uneval_kw,
			no_emit = ne,
		}
		if ne {
			no_emit |= u64(1) << uint(i)
		}
	}
	return m, no_emit
}

// Recursively gathers a node's boolean circuit (`allOf`, `anyOf`, `oneOf`, `not`, `if/then/else`,
// `$ref`, `$dynamicRef`, `dependentSchemas`) and flat object parts into `fb`.
@(private = "file")
gather :: proc(fb: ^Factor_Build, node: rules.Node_Index, edge: rules.Rules, depth: int, site_prefix: []tape.Step) -> i16 {
	if !fb.ok || depth > 32 {
		fb.ok = false
		return -1
	}
	if node == rules.NONE {
		// Trivial always-pass part.
		return add_trivial_part(fb, site_prefix)
	}
	b, d := fb.b, fb.d
	// Walk `$ref` & `$dynamicRef` hops with `enter_scope` so dynamic anchors resolve in scope (B-C6)!
	saved_scope := b.scope
	defer b.scope = saved_scope
	words := make([dynamic]string, fb.tables)
	end_node := resolve_end(b, d, fb.arena, node, &words)
	site := site_with_words(b, fb.arena, site_prefix, words[:])
	if end_node == rules.NONE {
		return add_trivial_part(fb, site)
	}
	n := &d.nodes[end_node]
	if .Object not_in n.kinds {
		// This subschema rejects all objects -> always-fail part with `fail_leaf`!
		return add_fail_part(fb, end_node, edge, site)
	}
	if n.rules.unique {
		fb.ok = false
		return -1
	}
	// Part-level `unevaluatedProperties` (Stage 2/4): only `false` supported inside a factored part.
	part_uneval_false := false
	if up, has := n.unevaluated_properties.?; has {
		if depth > 0 {
			up_end := resolve_end_ro(b, d, fb.arena, up)
			if up_end == rules.NONE || d.nodes[up_end].kinds != {} {
				fb.ok = false
				return -1
			}
			part_uneval_false = true
		}
	}

	children := make([dynamic]i16, fb.tables)

	// Per-part or outer `const` / `enum` object candidates.
	if n.const_of != nil {
		cand_op := gather_const_objects(fb, n, depth, site)
		if !fb.ok {
			return -1
		}
		append(&children, cand_op)
	}
	if n.has_enum {
		enum_op := gather_enum_objects(fb, n, depth, site)
		if !fb.ok {
			return -1
		}
		append(&children, enum_op)
	}

	// Own object keywords (if any).
	has_own := false
	keys_node := rules.Node_Index(rules.NONE)
	keys_scope := b.scope
	r_merged, clash := rules.merged(n, edge)
	if clash != "" {
		fb.ok = false
		return -1
	}
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
				keys_node = k_end
				keys_scope = k_scope
				has_own = true
			}
		}
		has_dep_req := false
		for dep in o.dependents {
			if len(dep.required) > 0 {
				has_dep_req = true
				break
			}
		}
		if len(o.members) > 0 || len(o.patterns) > 0 || o.additional != rules.NONE || has_dep_req {
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
				append(&fb.patterns, clone_str(b, fb.arena, p.expression))
				append(&fb.pat_re, re)
			}
		}
	}
	// Outer `depth == 0` counts go into `f.spine_leaf`; inner `depth > 0` counts go into per-part `f.counts`.
	if depth > 0 && (r_merged.min_members > 0 || r_merged.max_members != nil) {
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
			arr = -1,
			scope = b.scope,
			site = site,
			min_members = r_merged.min_members if depth > 0 else 0,
			max_members = (r_merged.max_members.? or_else max(u64)) if depth > 0 else max(u64),
			add_node = rules.NONE,
			keys_node = keys_node,
			keys_scope = keys_scope,
		}
		if n.object >= 0 {
			o := &d.objects[n.object]
			pi.add_uneval = b.unevaluated[{0, n.object}]
			if o.additional != rules.NONE {
				add_end := resolve_end_ro(b, d, fb.arena, o.additional)
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

	// Stage 4: `dependentSchemas` (or Draft 4/7 schema `dependencies`) as `If(Presence(dep.name), gather(dep.node), none)`!
	if n.object >= 0 {
		o := &d.objects[n.object]
		kw := "dependencies" if o.dependencies else "dependentSchemas"
		for dep in o.dependents {
			dn, has := dep.node.?
			if !has {
				continue
			}
			if len(fb.parts) >= MAX_FACTOR_PARTS {
				fb.ok = false
				return -1
			}
			p_bit := u8(len(fb.parts))
			append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, arr = -1, site = site, add_node = rules.NONE, keys_node = rules.NONE, is_presence = true, presence_name = dep.name})
			append(&fb.presence, Presence_Build{name = dep.name, part = p_bit})
			cond_op := i16(len(fb.ops))
			append(&fb.ops, Factor_Op{kind = .Part, bit = p_bit})
			dep_site := site_concat(b, fb.arena, site, tape.Name(kw), tape.Name(dep.name))
			then_op := gather(fb, dn, {}, depth + 1, dep_site)
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
		ref_site := site_concat(b, fb.arena, site, tape.Name(rules.ref_keyword(n)))
		sub := gather(fb, r, {}, depth + 1, ref_site)
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
		dr_site := site_concat(b, fb.arena, site, tape.Name(rules.dynamic_keyword(n)))
		sub := gather(fb, target, {}, depth + 1, dr_site)
		b.scope = saved
		if !fb.ok {
			return -1
		}
		append(&children, sub)
	}

	// `allOf`
	for a, idx in n.all_of {
		sub_site := site_concat(b, fb.arena, site, tape.Name("allOf"), tape.Index(idx))
		sub := gather(fb, a, {}, depth + 1, sub_site)
		if !fb.ok {
			return -1
		}
		append(&children, sub)
	}

	// `anyOf`
	if len(n.any_of) > 0 {
		arms := make([dynamic]i16, fb.tables)
		for a, idx in n.any_of {
			sub_site := site_concat(b, fb.arena, site, tape.Name("anyOf"), tape.Index(idx))
			sub := gather(fb, a, {}, depth + 1, sub_site)
			if !fb.ok {
				return -1
			}
			append(&arms, sub)
		}
		append(&children, emit_group_op(fb, .Any, arms[:], site))
	}

	// `oneOf`
	if len(n.one_of) > 0 {
		arms := make([dynamic]i16, fb.tables)
		for a, idx in n.one_of {
			sub_site := site_concat(b, fb.arena, site, tape.Name("oneOf"), tape.Index(idx))
			sub := gather(fb, a, {}, depth + 1, sub_site)
			if !fb.ok {
				return -1
			}
			append(&arms, sub)
		}
		append(&children, emit_group_op(fb, .One, arms[:], site))
	}

	// `not`
	if nt, has := n.not.?; has {
		not_site := site_concat(b, fb.arena, site, tape.Name("not"))
		sub := gather(fb, nt, {}, depth + 1, not_site)
		if !fb.ok {
			return -1
		}
		op_idx := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Not, first = sub, site = site})
		append(&children, op_idx)
	}

	// `if` / `then` / `else`
	if test, has := n.cond.test.?; has {
		if_site := site_concat(b, fb.arena, site, tape.Name("if"))
		test_op := gather(fb, test, {}, depth + 1, if_site)
		then_op := i16(-1)
		if th, has_th := n.cond.then.?; has_th {
			then_site := site_concat(b, fb.arena, site, tape.Name("then"))
			then_op = gather(fb, th, {}, depth + 1, then_site)
		}
		else_op := i16(-1)
		if ot, has_ot := n.cond.other.?; has_ot {
			else_site := site_concat(b, fb.arena, site, tape.Name("else"))
			else_op = gather(fb, ot, {}, depth + 1, else_site)
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

	// Stage 4: inner `unevaluatedProperties: false` on a sub-part records a `Factor_Closing`
	// guarded by a synthetic part bit settled in `closings_judge` at object close!
	if part_uneval_false {
		if len(fb.parts) >= MAX_FACTOR_PARTS {
			fb.ok = false
			return -1
		}
		c_bit := u8(len(fb.parts))
		up_site := site_concat(b, fb.arena, site, tape.Name("unevaluatedProperties"))
		append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, arr = -1, site = up_site, uneval_kw = "unevaluatedProperties", max_members = max(u64), add_node = rules.NONE, keys_node = rules.NONE})
		append(&fb.closings, Factor_Closing{part = c_bit, root_op = res})
		c_op := i16(len(fb.ops))
		append(&fb.ops, Factor_Op{kind = .Part, bit = c_bit})
		pair := [2]i16{res, c_op}
		res = emit_group_op(fb, .All, pair[:], site)
	}
	return res
}

@(private = "file")
gather_const_objects :: proc(fb: ^Factor_Build, n: ^rules.Node, depth: int, site: []tape.Step) -> i16 {
	b := fb.b
	c := n.const_of.?
	if rules.value_kind(c) != .Object {
		return add_const_fail_part(fb, .Const, site)
	}
	cloned := clone_value(b, c, fb.arena, fb.tables)
	if b.err.kind != .None {
		fb.ok = false
		return -1
	}
	mv, is_obj := cloned.([]rules.Member_Value)
	if !is_obj {
		fb.ok = false
		return -1
	}
	if len(fb.parts) >= MAX_FACTOR_PARTS {
		fb.ok = false
		return -1
	}
	bit := u8(len(fb.parts))
	append(&fb.parts, Part_Info{
		node = rules.NONE,
		obj = -1,
		arr = -1,
		scope = b.scope,
		site = site,
		const_kind = .Const,
		min_members = u64(len(mv)),
		max_members = u64(len(mv)),
		add_node = rules.NONE,
		keys_node = rules.NONE,
		no_eval = true,
		is_const = true,
		const_vals = mv,
	})
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Part, bit = bit})
	return op_idx
}

@(private = "file")
gather_enum_objects :: proc(fb: ^Factor_Build, n: ^rules.Node, depth: int, site: []tape.Step) -> i16 {
	b := fb.b
	cands := make([dynamic][]rules.Member_Value, fb.tables)
	for ev in n.enum_of {
		if rules.value_kind(ev) != .Object {
			continue
		}
		if len(cands) >= 16 {
			fb.ok = false
			return -1
		}
		cloned := clone_value(b, ev, fb.arena, fb.tables)
		if b.err.kind != .None {
			fb.ok = false
			return -1
		}
		if mv, is_obj := cloned.([]rules.Member_Value); is_obj {
			append(&cands, mv)
		}
	}
	if len(cands) == 0 {
		return add_const_fail_part(fb, .Enum, site)
	}
	mask := u64(0)
	for mv in cands {
		if len(fb.parts) >= MAX_FACTOR_PARTS {
			fb.ok = false
			return -1
		}
		bit := u8(len(fb.parts))
		append(&fb.parts, Part_Info{
			node = rules.NONE,
			obj = -1,
			arr = -1,
			scope = b.scope,
			site = site,
			const_kind = .Enum,
			min_members = u64(len(mv)),
			max_members = u64(len(mv)),
			add_node = rules.NONE,
			keys_node = rules.NONE,
			no_eval = true,
			is_const = true,
			const_vals = mv,
		})
		mask |= u64(1) << bit
	}
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Any_Mask, mask = mask, is_enum = true, site = site})
	return op_idx
}

@(private)
add_const_fail_part :: proc(fb: ^Factor_Build, ck: Part_Const_Kind, site: []tape.Step) -> i16 {
	if len(fb.parts) >= MAX_FACTOR_PARTS {
		fb.ok = false
		return -1
	}
	bit := u8(len(fb.parts))
	append(&fb.parts, Part_Info{
		node = rules.NONE,
		obj = -1,
		arr = -1,
		site = site,
		const_kind = ck,
		no_eval = true,
		min_members = max(u64),
		max_members = 0,
		add_node = rules.NONE,
		keys_node = rules.NONE,
	})
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Part, bit = bit, is_enum = (ck == .Enum), site = site})
	return op_idx
}

@(private)
add_trivial_part :: proc(fb: ^Factor_Build, site: []tape.Step) -> i16 {
	if len(fb.parts) >= MAX_FACTOR_PARTS {
		fb.ok = false
		return -1
	}
	bit := u8(len(fb.parts))
	append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, arr = -1, site = site, max_members = max(u64), add_node = rules.NONE, keys_node = rules.NONE})
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Part, bit = bit})
	return op_idx
}

@(private)
add_fail_part :: proc(fb: ^Factor_Build, end_node: rules.Node_Index, edge: rules.Rules, site: []tape.Step) -> i16 {
	// A part whose `min_members = max(u64)` always fails for any container (impossible to have `max(u64)` items),
	// with `fail_leaf` preserved for exact single-pass error reporting.
	if len(fb.parts) >= MAX_FACTOR_PARTS {
		fb.ok = false
		return -1
	}
	fl := i32(0)
	if end_node != rules.NONE {
		judged := fb.d.nodes[end_node]
		if arm_operands(&judged) {
			judged.has_enum, judged.enum_of, judged.const_of = false, nil, nil
		}
		fl = checked_leaf(fb.b, &judged, edge, fb.arena)
		if fb.b.err.kind != .None {
			fb.ok = false
			return -1
		}
	}
	bit := u8(len(fb.parts))
	append(&fb.parts, Part_Info{node = rules.NONE, obj = -1, arr = -1, site = site, fail_leaf = fl, min_members = max(u64), max_members = 0, add_node = rules.NONE, keys_node = rules.NONE})
	op_idx := i16(len(fb.ops))
	append(&fb.ops, Factor_Op{kind = .Part, bit = bit})
	return op_idx
}

// Emits a contiguous group of child ops into `fb.ops` (copies children into a contiguous block at the end).
@(private)
emit_group_op :: proc(fb: ^Factor_Build, kind: Factor_Op_Kind, children: []i16, site: []tape.Step) -> i16 {
	// Stage 4 optimization: if every child of `.Any`/`.One` is a `.Part`, emit a single `.Any_Mask`/`.One_Mask`!
	if kind == .Any || kind == .One {
		all_parts := true
		mask := u64(0)
		dup := false
		for ch in children {
			op := fb.ops[ch]
			if op.kind != .Part || op.is_enum {
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

// Re-roots `fb.ops` into a compact slice in `fb.arena` with `ops[0]` as the root op,
// updating `fb.closings[i].root_op` to match.
@(private)
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

@(private)
ops_monotone :: proc "contextless" (ops: []Factor_Op) -> bool {
	for op in ops {
		if op.kind == .Not || op.kind == .If {
			return false
		}
	}
	return true
}

@(private)
ops_conjunctive_only :: proc "contextless" (ops: []Factor_Op) -> bool {
	for op in ops {
		#partial switch op.kind {
		case .Part, .All:
		case:
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

@(private)
Factored_Constraint :: struct {
	node:      rules.Node_Index,
	edge:      rules.Rules,
	part:      u8,
	scope:     i32,
	k_step:    tape.Step,
	k_arg:     string,
	elem_idx:  int, // >= 0 for indexed array tuple position, else -1
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
		if pt.is_presence || pt.is_contains {
			continue
		}
		if !unnamed && pt.is_const {
			for mv in pt.const_vals {
				if mv.key == name {
					c_node := const_member_node(fb.b, d, fb.arena, fb.tables, mv.value)
					if c_node == rules.NONE {
						return nil, false
					}
					append(&cons, Factored_Constraint{node = c_node, part = u8(pi), scope = pt.scope, k_step = tape.Name("properties"), k_arg = name, elem_idx = -1})
				}
			}
			continue
		}
		if pt.obj < 0 {
			continue
		}
		o := &d.objects[pt.obj]
		matched := false
		if !unnamed {
			for m in o.members {
				if m.name == name && !m.only_required {
					matched = true
					if !pt.no_eval {
						fm.evals |= bit
					}
					append(&cons, Factored_Constraint{node = m.node, edge = m.rules, part = u8(pi), scope = pt.scope, k_step = tape.Name("properties"), k_arg = name, elem_idx = -1})
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
				if !pt.no_eval {
					fm.evals |= bit
				}
				append(&cons, Factored_Constraint{node = p.node, part = u8(pi), scope = pt.scope, k_step = tape.Name("patternProperties"), k_arg = p.expression, elem_idx = -1})
			}
		}
		// Additional properties (applies only when no named property and no pattern matched in this part).
		if !matched {
			add_kw := "unevaluatedProperties" if pt.add_uneval else "additionalProperties"
			if pt.add_false {
				fm.refuse |= bit
				add_site := make([]tape.Step, 1, fb.arena)
				add_site[0] = tape.Name(add_kw)
				append(&refuse_sites, Member_Site{parts = bit, site = add_site})
			} else if pt.add_node != rules.NONE {
				if !pt.no_eval {
					fm.evals |= bit
				}
				append(&cons, Factored_Constraint{node = pt.add_node, part = u8(pi), scope = pt.scope, k_step = tape.Name(add_kw), elem_idx = -1})
			}
		}
	}

	return compile_member_constraints(fb, fm, cons[:], refuse_sites[:])
}

@(private = "file")
constraint_site :: proc(b: ^Builder, arena: runtime.Allocator, c: Factored_Constraint, words: []string) -> []tape.Step {
	n := 1 + len(words)
	has_arg := len(c.k_arg) > 0 || c.elem_idx >= 0
	if has_arg {
		n += 1
	}
	out, err := make([]tape.Step, n, arena)
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
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		#partial switch va in a[i] {
		case tape.Name:
			vb, ok := b[i].(tape.Name)
			if !ok || string(va) != string(vb) {
				return false
			}
		case tape.Index:
			vb, ok := b[i].(tape.Index)
			if !ok || va != vb {
				return false
			}
		}
	}
	return true
}

@(private = "file")
append_member_site :: proc(list: ^[dynamic]Member_Site, arena: runtime.Allocator, bit: u64, site: []tape.Step) {
	for &ms in list^ {
		if steps_equal(ms.site, site) {
			ms.parts |= bit
			return
		}
	}
	append(list, Member_Site{parts = bit, site = site})
}

// Compiles a list of raw `Factored_Constraint`s (from an object member or an array element slot)
// into a finished `Factor_Member` (`table`, `leaves`, `choices`, `refuse`, plus origin sites for 1-pass errors).
@(private)
compile_member_constraints :: proc(fb: ^Factor_Build, fm: ^Factor_Member, cons: []Factored_Constraint, pre_refuse_sites: []Member_Site = nil) -> (^Factor_Member, bool) {
	b, d, arena, tables := fb.b, fb.d, fb.arena, fb.tables
	if len(cons) == 0 && len(pre_refuse_sites) == 0 {
		return fm, true
	}

	ref_sites := make([dynamic]Member_Site, arena)
	for rs in pre_refuse_sites {
		append_member_site(&ref_sites, arena, rs.parts, rs.site)
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
		k_step:   tape.Step,
		k_arg:    string,
		site:     []tape.Step,
		is_keys:  bool,
	}
	res_cons := make([dynamic]Resolved_Cons, tables)

	for c in cons {
		bit := u64(1) << c.part
		if (fm.refuse & bit) != 0 {
			continue
		}
		saved_sc := b.scope
		b.scope = c.scope
		words := make([dynamic]string, tables)
		end_node := resolve_end(b, d, arena, c.node, &words)
		if end_node == rules.NONE {
			b.scope = saved_sc
			continue
		}
		eff_scope := b.scope
		c_site := constraint_site(b, arena, c, words[:])
		if b.err.kind != .None {
			b.scope = saved_sc
			return nil, false
		}
		cn := &d.nodes[end_node]
		if cn.kinds == {} {
			fm.refuse |= bit
			append_member_site(&ref_sites, arena, bit, c_site)
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
					append_member_site(&fl.sites, arena, bit, c_site)
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
		b.scope = saved_sc
		keys_only := is_keys_only_node(b, d, arena, end_node, c.edge)
		append(&res_cons, Resolved_Cons{
			end_node = end_node,
			edge = c.edge,
			part = c.part,
			scope = eff_scope,
			k_step = c.k_step,
			k_arg = c.k_arg,
			site = c_site,
			is_keys = keys_only,
		})
	}

	if len(ref_sites) > 0 {
		fm.refuse_sites = ref_sites[:]
	}
	if len(table_leaf_list) > 0 {
		tl, tlerr := make([]Factor_Leaf, len(table_leaf_list), arena)
		if tlerr != nil {
			refuse_plan(b, .No_Memory)
			return nil, false
		}
		copy(tl, table_leaf_list[:])
		fm.table_leaves = tl
	}

	// Combine same-part `{single non-held container + single keys-only pattern constraint}` (e.g. OpenAPI `components.*`)
	// into ONE combined `Choice_Node` with `b.keys_sites`, keeping exact keyword paths and eliminating captures!
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
				append_member_site(&ch.sites, arena, bit, site)
				return
			}
		}
		sl := make([dynamic]Member_Site, arena)
		append(&sl, Member_Site{parts = bit, site = site})
		append(list, Choice_Node{node = node, edge = edge, scope = scope, parts = bit, sites = sl})
	}

	for p in 0 ..< len(fb.parts) {
		bit := u64(1) << uint(p)
		val_idx := -1
		val_n := 0
		key_idx := -1
		key_n := 0
		for rc, ri in res_cons {
			if int(rc.part) != p {
				continue
			}
			if rc.is_keys {
				key_idx = ri
				key_n += 1
			} else {
				val_idx = ri
				val_n += 1
			}
		}
		if val_n == 1 && key_n == 1 {
			vc := res_cons[val_idx]
			kc := res_cons[key_idx]
			vn := &d.nodes[vc.end_node]
			kn := &d.nodes[kc.end_node]
			sv_h := b.scope
			b.scope = vc.scope
			v_holds := holds(b, d, vc.end_node, vc.edge)
			b.scope = sv_h
			can_merge := !v_holds && vc.edge == {} && vc.scope == kc.scope && .Object in vn.kinds && !vn.has_enum && vn.const_of == nil && vn.unevaluated_properties == nil && vn.unevaluated_items == nil && (vn.object < 0 || d.objects[vn.object].keys == rules.NONE) && (len(d.anchors) == 0 || vn.resource == kn.resource)
			if can_merge {
				k_keys := d.objects[kn.object].keys
				new_o := d.objects[vn.object] if vn.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
				new_o.keys = k_keys
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
			choices[i] = Factor_Choice{record = rec, parts = ch.parts, sites = ch.sites[:]}
		}
		b.scope = saved_sc
		fm.choices = choices
	}

	return fm, true
}

@(private = "file")
is_keys_only_node :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, end_node: rules.Node_Index, edge: rules.Rules) -> bool {
	if edge != {} || holds(b, d, end_node, {}) {
		return false
	}
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
	if k != .Array && k != .Object {
		ev, err := make([]rules.Value, 1, tables)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return rules.NONE
		}
		ev[0] = val
		idx := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{
			kinds = rules.EVERY_KIND,
			has_enum = true,
			enum_of = ev,
			array = -1,
			object = -1,
		})
		return idx
	}
	idx := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{
		kinds = rules.EVERY_KIND,
		const_of = val,
		array = -1,
		object = -1,
	})
	return idx
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

// Records an early-doomed factored failure properly even though `h.quiet` is true inside factored containers (B-C2).
@(private)
fail_doomed_factored :: proc(h: ^Checker, fo: ^Factored_Open) {
	if h.nf > 0 {
		h.quiet = factored_at(h, 0).saved_quiet
	}
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
			alive := op.mask & ~failed
			if intrinsics.count_ones(alive) > 1 {
				return .Many_Arms, "oneOf"
			}
			return .No_Arm, "oneOf"
		case .One:
			hits := 0
			for i in 0 ..< op.count {
				if factor_eval(f, failed, op.first + i) {
					hits += 1
				}
			}
			if hits > 1 {
				return .Many_Arms, "oneOf"
			}
			return .No_Arm, "oneOf"
		case .Not:
			return .Not_Allowed, "not"
		}
	}
	return .No_Arm, "anyOf"
}

@(private)
factored_can_record_first :: proc "contextless" (h: ^Checker, fo: ^Factored_Open) -> bool #no_bounds_check {
	if h.sink != nil || h.first_recorded || !fo.factor.direct_errors || fo.saved_quiet || h.choice_depth > 0 {
		return false
	}
	for i := 0; i < h.nf; i += 1 {
		afi := factored_at(h, i)
		if afi == fo {
			break
		}
		if afi.saved_quiet || !afi.factor.direct_errors {
			return false
		}
	}
	return true
}

@(private)
factored_can_record_first_close :: proc "contextless" (h: ^Checker, fo: ^Factored_Open) -> bool #no_bounds_check {
	if h.sink != nil || h.first_recorded || !fo.factor.direct_errors || fo.saved_quiet || h.choice_depth > 0 {
		return false
	}
	for i in 0 ..< h.nf {
		afi := factored_at(h, i)
		if afi.saved_quiet || !afi.factor.direct_errors {
			return false
		}
	}
	return true
}

// Under `.Last`/`.Group` or inside a nested factored object / choice / subcheck, do not early-doom the whole walk!
// Also wait to close direct-error containers in verdict mode if a sub-container failed before setting `h.first_err`.
@(private)
can_doom_factored :: #force_inline proc "contextless" (h: ^Checker, f: ^Factor, failed: u64) -> bool {
	if h.sink != nil || h.dups == .Last || h.dups == .Group || h.nest_depth != 0 || h.nf != 1 || h.choice_depth != 0 {
		return false
	}
	if !factor_doomed(f, failed) {
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
	collect := h.sink != nil && !h.quiet && f.direct_errors
	fo^ = {
		factor = f,
		owner = owner,
		active_choice = -1,
		parent_sp = h.sp,
		saved_quiet = h.quiet,
		saved_sink = h.sink,
		saved_buffering = h.buffering_choice,
		saved_choice_fo = h.choice_sink_fo,
		saved_no_factor = h.no_factor,
		saved_failed = h.failed,
		open_at = at,
		unk_tracker = -1,
		collect_errors = collect,
	}
	if collect {
		fo.err_entries.allocator = h.scratch
		fo.seen_pos.allocator = h.scratch
		fo.choice_no_member.allocator = h.scratch
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
	if f.arr != nil {
		if !factored_arr_open(h, fo) {
			return false
		}
	}
	h.nf += 1
	// Mute direct sink emission while inside a factored container (`collect_errors` buffers in-place for 1-pass emission).
	h.quiet = true
	h.failed = false
	return true
}

@(private)
factored_cleanup :: proc(h: ^Checker, fo: ^Factored_Open) {
	if fo.unk_tracker >= 0 {
		close_tracker(h)
		fo.unk_tracker = -1
	}
	if fo.using_inline_uniq {
		h.arr_uniq_in_use = false
		fo.using_inline_uniq = false
	}
	if fo.arr_state != nil {
		free_arr_state(h, fo.arr_state)
		fo.arr_state = nil
	}
	if len(fo.err_entries) > 0 || cap(fo.err_entries) > 0 {
		for &e in fo.err_entries {
			if len(e.expected) > 0 {
				delete(e.expected, h.scratch)
			}
			if e.member_owned {
				delete(e.member_name, h.scratch)
			}
		}
		delete(fo.err_entries)
		fo.err_entries = nil
	}
	if len(fo.seen_pos) > 0 || cap(fo.seen_pos) > 0 {
		for &sp in fo.seen_pos {
			if sp.name_owned {
				delete(sp.name, h.scratch)
			}
		}
		delete(fo.seen_pos)
		fo.seen_pos = nil
	}
	if len(fo.choice_no_member) > 0 || cap(fo.choice_no_member) > 0 {
		delete(fo.choice_no_member)
		fo.choice_no_member = nil
	}
	sink_destroy(&fo.choice_sink)
}

@(private)
choice_sink_ensure :: proc(h: ^Checker, fo: ^Factored_Open) {
	if !fo.choice_sink.arena_ready {
		sink_init(&fo.choice_sink, h.scratch)
	}
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
		if len(e.expected) > 0 {
			delete(e.expected, h.scratch)
		}
		if e.member_owned {
			delete(e.member_name, h.scratch)
		}
		h.fatal = .No_Memory
	}
}

@(private)
factored_buf_leaf_fails :: proc(
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
	extra_kw := "",
) {
	for k in fails {
		kw := keyword_of_kind(k, l, members)
		exp := rules.operand_text(l, k, members, h.scratch)
		nm := member_name
		nm_owned := false
		if has_member && fo.factor.arr == nil && member_need_clone && len(member_name) > 0 {
			cp, cerr := strings.clone(member_name, h.scratch)
			if cerr != nil {
				if len(exp) > 0 {
					delete(exp, h.scratch)
				}
				h.fatal = .No_Memory
				return
			}
			nm = cp
			nm_owned = true
		}
		factored_buf_err(h, fo, Factored_Err{
			kind = .Direct,
			no_emit_mask = fo.factor.no_emit_mask,
			err_kind = k,
			at = at,
			keyword = kw,
			expected = exp,
			member_name = nm,
			member_owned = nm_owned,
			elem_idx = elem_idx,
			has_member = has_member,
			sites = sites,
			part = part,
			extra_kw = extra_kw,
		})
		if h.fatal != .None {
			return
		}
	}
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
		fo.last_cls = cls
		fo.unknown_classes |= u16(1) << cls
		fm = f.classes[cls]
	}

	// Per-part non-held `propertyNames` checks on this key (applies to every key, even if `fm == nil`).
	if len(f.keys) > 0 {
		for fk in f.keys {
			if !fo.collect_errors && f.monotone && (fk.parts & ~fo.failed) == 0 {
				continue
			}
			kfails := key_fails_leaf(h, &h.plan.leaves[fk.leaf - 1], key)
			if h.fatal != .None {
				return false, true
			}
			if kfails != {} {
				fo.failed |= fk.parts
				if fo.collect_errors {
					l := &h.plan.leaves[fk.leaf - 1]
					for b := 0; b < int(f.n); b += 1 {
						bit := u64(1) << uint(b)
						if (fk.parts & bit) != 0 && (f.no_emit_mask & bit) == 0 {
							factored_buf_leaf_fails(h, fo, l, kfails, at, false, nil, u8(b), key, key_owned, 0, has_member = true, extra_kw = "propertyNames")
							if h.fatal != .None {
								return false, true
							}
						}
					}
				} else if factored_can_record_first(h, fo) && (fk.parts & ~f.no_emit_mask) != 0 {
					l := &h.plan.leaves[fk.leaf - 1]
					for b := 0; b < int(f.n); b += 1 {
						bit := u64(1) << uint(b)
						if (fk.parts & bit) != 0 && (f.no_emit_mask & bit) == 0 {
							record_first_factored_leaf_fails(h, fo, l, kfails, at, false, nil, u8(b), key, 0, has_member = true, extra_kw = "propertyNames")
							break
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
	if fo.collect_errors && f.arr == nil {
		fo.cur_seen_idx = idx
		fo.cur_seen_cls = fo.last_cls
	}
	need_uneval := f.uneval_false && f.eval_all == 0 && (fm == nil || fm.evals == 0)
	need_err_val := fo.collect_errors && ((fm != nil && fm.refuse != 0) || need_uneval || len(f.closings) > 0)
	if fm == nil {
		return !need_err_val, false
	}
	fo.failed |= fm.refuse
	need_refuse_val_err := fm.refuse != 0 && !fo.collect_errors && factored_can_record_first(h, fo) && (fm.refuse & ~f.no_emit_mask) != 0
	if !need_refuse_val_err && can_doom_factored(h, f, fo.failed) {
		return false, true
	}
	if need_refuse_val_err {
		return false, false
	}
	// If no discriminator, no leaves, and no choices remain for any still-alive part, we can `.Skip` the value
	// (when collecting errors, never skip any still-relevant or refused/uneval-tracked parts!).
	alive := f.all_parts if fo.collect_errors else (f.all_parts & ~fo.failed)
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
		return !need_err_val, false
	}
	if !f.monotone && (fm.table != nil || len(fm.leaves) > 0 || len(fm.choices) > 0) {
		need_val = true
	}
	return !(need_val || need_err_val), false
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

@(private)
factored_begin_value :: proc(h: ^Checker, fo: ^Factored_Open, fm: ^Factor_Member, val_at: u64) {
	if !fo.collect_errors || fo.factor.arr != nil {
		return
	}
	f := fo.factor
	has_key := h.sp > 0 && h.frames[h.sp - 1].has_key
	cur_key := h.frames[h.sp - 1].key_name if has_key else ""
	cur_owned := h.frames[h.sp - 1].key_owned if has_key else false
	need_uneval := f.uneval_false && f.eval_all == 0 && (fm == nil || fm.evals == 0)
	if (need_uneval || len(f.closings) > 0) && has_key {
		nm := cur_key
		nm_owned := false
		if cur_owned {
			cp, cerr := strings.clone(cur_key, h.scratch)
			if cerr != nil {
				h.fatal = .No_Memory
				return
			}
			nm = cp
			nm_owned = true
		}
		if _, aerr := append(&fo.seen_pos, Seen_Member_Pos{
			name = nm,
			name_owned = nm_owned,
			val_at = val_at,
			member_idx = fo.cur_seen_idx,
			cls = fo.cur_seen_cls,
		}); aerr != nil {
			if nm_owned {
				delete(nm, h.scratch)
			}
			h.fatal = .No_Memory
			return
		}
	}
	if fm != nil && fm.refuse != 0 && (fm.refuse & ~f.no_emit_mask) != 0 {
		nm := cur_key
		nm_owned := false
		if cur_owned && len(cur_key) > 0 {
			cp, cerr := strings.clone(cur_key, h.scratch)
			if cerr != nil {
				h.fatal = .No_Memory
				return
			}
			nm = cp
			nm_owned = true
		}
		factored_buf_err(h, fo, Factored_Err{
			kind = .Direct,
			no_emit_mask = f.no_emit_mask,
			err_kind = .Wrong_Kind,
			at = val_at,
			keyword = "type",
			member_name = nm,
			member_owned = nm_owned,
			has_member = true,
			sites = fm.refuse_sites,
		})
	}
}

// Judges a scalar value token on the active member of `fo` (discriminator table + leaves + scalar choices).
// Returns `doomed = true` if the object is already doomed under `h.sink == nil` (non-`.Last`).
@(private)
factored_scalar :: proc(h: ^Checker, fo: ^Factored_Open, t: tape.Token) -> (doomed: bool) {
	fm := fo.active_member
	fo.active_member = nil
	if fo.collect_errors && fo.factor.arr == nil {
		factored_begin_value(h, fo, fm, t.lo)
		if h.fatal != .None {
			return true
		}
	}
	if fm == nil {
		return false
	}
	f := fo.factor
	collect := fo.collect_errors
	is_arr := f.arr != nil
	cur_key := h.frames[h.sp - 1].key_name if (!is_arr && h.sp > 0) else ""
	cur_owned := h.frames[h.sp - 1].key_owned if (!is_arr && h.sp > 0) else false
	elem_idx := fo.seen_count - 1 if is_arr else 0
	rec_first := !collect && factored_can_record_first(h, fo)
	if rec_first && fm.refuse != 0 && (fm.refuse & ~f.no_emit_mask) != 0 {
		record_first_factored_err(h, fo, .Wrong_Kind, t.lo, "type", "", cur_key, elem_idx, has_member = true, sites = fm.refuse_sites)
		rec_first = !h.first_recorded
	}

	// 1. Discriminator table lookup (Stage 1) with full OOM propagation and `.Plain`/non-plain number normalization (B-C8).
	if tbl := fm.table; tbl != nil {
		matched_parts := u64(0)
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
					matched_parts = tbl.parts[idx]
					fo.failed |= tbl.all & ~matched_parts
					valid_scalar = false // already handled
				} else {
					tk, lookup_text = infer_plain_scalar_kind(text)
				}
			}
			if valid_scalar {
				idx, found := rules.enum_find(tbl.keys, tk, lookup_text, checker_scratch(h))
				if found {
					matched_parts = tbl.parts[idx]
					fo.failed |= tbl.all & ~matched_parts
				} else {
					fo.failed |= tbl.all
				}
			}
			if lookup_owned {
				delete(lookup_text, checker_scratch(h))
			}
		}
		bad_tbl := tbl.all & ~matched_parts
		if (collect || (rec_first && bad_tbl != 0)) && (bad_tbl & ~f.no_emit_mask) != 0 {
			for tfl in fm.table_leaves {
				if (tfl.parts & bad_tbl & ~f.no_emit_mask) == 0 {
					continue
				}
				l := &h.plan.leaves[tfl.leaf - 1]
				fails := eval_scalar_leaf(h, l, t)
				if h.fatal != .None {
					return true
				}
				if fails != {} {
					if collect {
						factored_buf_leaf_fails(h, fo, l, fails, t.lo, false, tfl.sites, 0, cur_key, cur_owned, elem_idx, has_member = true)
						if h.fatal != .None {
							return true
						}
					} else {
						record_first_factored_leaf_fails(h, fo, l, fails, t.lo, false, tfl.sites, 0, cur_key, elem_idx, has_member = true)
						rec_first = false
						break
					}
				}
			}
		}
	}

	// 2. Scalar leaves.
	for fl in fm.leaves {
		if !collect && f.monotone && (fl.parts & ~fo.failed) == 0 {
			continue
		}
		l := &h.plan.leaves[fl.leaf - 1]
		if collect {
			if (fl.parts & ~f.no_emit_mask) == 0 {
				if f.monotone && (fl.parts & ~fo.failed) == 0 {
					continue
				}
				if !scalar_passes_leaf(h, l, t) {
					fo.failed |= fl.parts
				}
			} else {
				fails := eval_scalar_leaf(h, l, t)
				if h.fatal != .None {
					return true
				}
				if fails != {} {
					fo.failed |= fl.parts
					factored_buf_leaf_fails(h, fo, l, fails, t.lo, false, fl.sites, 0, cur_key, cur_owned, elem_idx, has_member = true)
				}
			}
		} else {
			fails := eval_scalar_leaf(h, l, t) if (rec_first && (fl.parts & ~f.no_emit_mask) != 0) else (rules.Failures{} if scalar_passes_leaf(h, l, t) else rules.Failures{.Wrong_Kind})
			if h.fatal != .None {
				return true
			}
			if fails != {} {
				fo.failed |= fl.parts
				if rec_first && (fl.parts & ~f.no_emit_mask) != 0 {
					record_first_factored_leaf_fails(h, fo, l, fails, t.lo, false, fl.sites, 0, cur_key, elem_idx, has_member = true)
					rec_first = false
				}
			}
		}
		if h.fatal != .None {
			return true
		}
	}

	// 3. Choices (a complex choice record might still accept scalars, e.g. `anyOf: [{type: "string"}, {type: "object"}]`!).
	if len(fm.choices) > 0 {
		outer_kw := 0
		if collect {
			outer_kw = factored_outer_kw_len(h, fo)
			choice_sink_ensure(h, fo)
		}
		fo_idx := -1
		if collect {
			// Find `fo` index (top-of-stack `h.nf - 1` when called from streaming/doc).
			fo_idx = h.nf - 1
		}
		for ch in fm.choices {
			if !collect && f.monotone && (ch.parts & ~fo.failed) == 0 {
				continue
			}
			if collect && (ch.parts & ~f.no_emit_mask) != 0 {
				mark := len(fo.choice_sink.entries)
				saved_sink := h.sink
				saved_quiet := h.quiet
				saved_buf := h.buffering_choice
				saved_cfo := h.choice_sink_fo
				h.sink = &fo.choice_sink
				h.quiet = false
				h.buffering_choice = true
				h.choice_sink_fo = i16(fo_idx)
				passed := scalar_passes_record_emit(h, ch.record, t, fo.owner)
				h.sink = saved_sink
				h.quiet = saved_quiet
				h.buffering_choice = saved_buf
				h.choice_sink_fo = saved_cfo
				if !passed {
					fo.failed |= ch.parts
					end := len(fo.choice_sink.entries)
					if end > mark {
						factored_buf_err(h, fo, Factored_Err{
							kind = .Choice_Span,
							no_emit_mask = f.no_emit_mask,
							choice_from = mark,
							choice_to = end,
							base_kw_len = outer_kw,
							sites = ch.sites,
						})
					}
				}
			} else if rec_first && (ch.parts & ~f.no_emit_mask) != 0 {
				choice_sink_ensure(h, fo)
				mark := len(fo.choice_sink.entries)
				fo_idx = h.nf - 1
				outer_kw = factored_outer_kw_len(h, fo)
				saved_sink := h.sink
				saved_quiet := h.quiet
				saved_buf := h.buffering_choice
				saved_cfo := h.choice_sink_fo
				h.sink = &fo.choice_sink
				h.quiet = false
				h.buffering_choice = true
				h.choice_sink_fo = i16(fo_idx)
				passed := scalar_passes_record_emit(h, ch.record, t, fo.owner)
				h.sink = saved_sink
				h.quiet = saved_quiet
				h.buffering_choice = saved_buf
				h.choice_sink_fo = saved_cfo
				if !passed {
					fo.failed |= ch.parts
					end := len(fo.choice_sink.entries)
					if end > mark {
						emit_first_choice_span_entry(h, fo, mark, outer_kw, ch.sites)
						rec_first = false
					}
				}
			} else {
				if !scalar_passes_record(h, ch.record, t) {
					fo.failed |= ch.parts
				}
			}
			if h.fatal != .None {
				return true
			}
		}
	}

	if can_doom_factored(h, f, fo.failed) {
		return true
	}
	return false
}

@(private)
scalar_passes_record_emit :: proc(h: ^Checker, rec_idx: i32, t: tape.Token, owner: ^Record) -> bool {
	r := &h.plan.records[rec_idx]
	if .Held in r.flags {
		nodes := [1]tape.Node{tape.Node(t)}
		doc := tape.Document{src = h.src, nodes = nodes[:], format = h.format, ext = h.xml_ext}
		return eval_held_node(h, &doc, 0, r, t.lo)
	}
	if r.rule_set == 0 {
		return true
	}
	return judge_scalar_token(h, &h.plan.leaves[r.rule_set - 1], t, r)
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
		record_first_factored_err(h, fo, .Wrong_Kind, t.lo, "type", "", cur_key, elem_idx, has_member = true, sites = fm.refuse_sites)
		rec_first = !h.first_recorded
	}

	// 1. Discriminator table only holds scalars -> every table part fails on a container.
	if tbl := fm.table; tbl != nil {
		fo.failed |= tbl.all
		if (collect || rec_first) && (tbl.all & ~f.no_emit_mask) != 0 {
			want_kind := rules.Kind.Object if t.kind == .Object else rules.Kind.Array
			for tfl in fm.table_leaves {
				if (tfl.parts & ~f.no_emit_mask) == 0 {
					continue
				}
				l := &h.plan.leaves[tfl.leaf - 1]
				if want_kind not_in l.kinds || l.has_enum {
					fails := rules.Failures{.Wrong_Kind} if want_kind not_in l.kinds else rules.Failures{.Not_A_Member}
					if collect {
						factored_buf_leaf_fails(h, fo, l, fails, t.lo, false, tfl.sites, 0, cur_key, cur_owned, elem_idx, has_member = true)
						if h.fatal != .None {
							return nil, false, false, true
						}
					} else if rec_first {
						record_first_factored_leaf_fails(h, fo, l, fails, t.lo, false, tfl.sites, 0, cur_key, elem_idx, has_member = true)
						rec_first = false
						break
					}
				}
			}
		}
	}

	// 2. Scalar leaves: fail any leaf that rejects this container kind or requires a scalar enum.
	want_kind := rules.Kind.Object if t.kind == .Object else rules.Kind.Array
	for fl in fm.leaves {
		l := &h.plan.leaves[fl.leaf - 1]
		if want_kind not_in l.kinds || l.has_enum {
			fo.failed |= fl.parts
			if (collect || rec_first) && (fl.parts & ~f.no_emit_mask) != 0 {
				fails := rules.Failures{.Wrong_Kind} if want_kind not_in l.kinds else rules.Failures{.Not_A_Member}
				if collect {
					factored_buf_leaf_fails(h, fo, l, fails, t.lo, false, fl.sites, 0, cur_key, cur_owned, elem_idx, has_member = true)
					if h.fatal != .None {
						return nil, false, false, true
					}
				} else if rec_first {
					record_first_factored_leaf_fails(h, fo, l, fails, t.lo, false, fl.sites, 0, cur_key, elem_idx, has_member = true)
					rec_first = false
				}
			}
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
		if !collect && f.monotone && (ch.parts & ~fo.failed) == 0 {
			continue
		}
		live_count += 1
		live_idx = i
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
	if fm == nil {
		return false
	}
	for fl in fm.leaves {
		l := &p.leaves[fl.leaf - 1]
		if is_obj {
			if l.min_members > 0 || l.max_members < max(u64) {
				return true
			}
		} else if l.min_items > 0 || l.max_items < max(u64) {
			return true
		}
	}
	return false
}

// Applies any container count leaves (`minProperties`/`maxProperties` or `minItems`/`maxItems`) on `fo.active_member`
// when closing an uncaptured single-choice (`is_choice`) container.
@(private)
finish_choice_leaf_counts :: proc "contextless" (h: ^Checker, outer_fo: ^Factored_Open, is_object: bool, cnt: u64, open_at: u64) #no_bounds_check {
	if outer_fo.active_member == nil {
		return
	}
	f := outer_fo.factor
	collect := outer_fo.collect_errors
	cur_key := h.frames[h.sp - 1].key_name if (!is_arr_check(f) && h.sp > 0) else ""
	cur_owned := h.frames[h.sp - 1].key_owned if (!is_arr_check(f) && h.sp > 0) else false
	elem_idx := outer_fo.seen_count - 1 if f.arr != nil else 0
	rec_first := !collect && factored_can_record_first(h, outer_fo)

	for fl in outer_fo.active_member.leaves {
		l := &h.plan.leaves[fl.leaf - 1]
		fails: rules.Failures
		if is_object {
			fails = rules.judge_count(cnt, l.min_members, l.max_members)
		} else {
			fails = rules.judge_count(cnt, l.min_items, l.max_items)
		}
		if fails != {} {
			outer_fo.failed |= fl.parts
			if (collect || rec_first) && (fl.parts & ~f.no_emit_mask) != 0 {
				context = h.ctx^
				if collect {
					factored_buf_leaf_fails(h, outer_fo, l, fails, open_at, is_object, fl.sites, 0, cur_key, cur_owned, elem_idx, has_member = true)
				} else if rec_first {
					record_first_factored_leaf_fails(h, outer_fo, l, fails, open_at, is_object, fl.sites, 0, cur_key, elem_idx, has_member = true)
					rec_first = false
				}
			}
		}
	}
}

@(private = "file")
is_arr_check :: #force_inline proc "contextless" (f: ^Factor) -> bool {
	return f.arr != nil
}

// Closes the innermost open factored container, settling required members, `dependentRequired`, presence triggers,
// per-part & spine counts, `uniqueItems`, `contains`, inner `unevaluated*` closings, and outer `unevaluated*`.
@(private)
factored_close :: proc(h: ^Checker) -> (passed: bool, owner: ^Record, open_at: u64, arr_unique_failed: bool, emitted: bool) {
	h.nf -= 1
	fo := factored_at(h, h.nf)
	f := fo.factor
	if f.arr != nil {
		passed, owner, open_at, emitted = factored_arr_close(h, fo)
		return passed, owner, open_at, fo.arr_unique_failed, emitted
	}
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

	// 1. Required members.
	for req in f.required {
		if !factored_is_seen(fo, req.member) {
			failed |= req.parts
		}
	}

	// 1b. Per-part `dependentRequired` (and Draft 4/7 array `dependencies`).
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

	// 5. Spine `minProperties` / `maxProperties` (Stage 3), circuit verdict, & outer `unevaluatedProperties: false`.
	spine_fail := false
	if f.spine_leaf > 0 {
		l := &h.plan.leaves[f.spine_leaf - 1]
		if fo.seen_count < l.min_members || fo.seen_count > l.max_members {
			spine_fail = true
		}
	}
	circuit_ok := factor_eval(f, failed, 0)
	uneval_ok := true
	if f.uneval_false {
		ok, active := parts_of(f, failed, 0)
		if !ok || !all_members_evaluated(h.plan, fo, active) {
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
	return passed, owner, open_at, false, emitted
}

// ============================================================================
// Stage 5 / Wave B3: Single-pass factored error emission
// ============================================================================

@(private = "file")
factored_outer_paths :: proc(h: ^Checker, fo: ^Factored_Open, outer_inst, outer_kw: ^[dynamic]tape.Step) {
	saved_sp := h.sp
	h.sp = fo.parent_sp
	defer h.sp = saved_sp
	inst_owner := fo.owner
	alt_site: []tape.Step
	if fo.parent_sp >= 0 && fo.parent_sp < len(h.frames) {
		pb := h.frames[fo.parent_sp].parent_b
		if !h.frames[fo.parent_sp].is_choice && pb != 0 && pb != u64(uintptr(&DEAD_RECORD)) {
			orig := (^Record)(uintptr(pb) - size_of(Record))
			if orig.meta != fo.owner.meta {
				alt_site = h.plan.uses[fo.owner.meta].site
			}
			inst_owner = orig
		}
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
	keyword: string,
	expected: string,
	member_name: string,
	elem_idx: u64,
	has_member: bool,
	sites: []Member_Site,
	part: u8 = 0,
	extra_kw := "",
	spine := false,
) {
	if h.first_recorded {
		return
	}
	f := fo.factor
	is_obj := f.arr == nil
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
		if is_obj {
			append(&inst_buf, tape.Name(member_name))
		} else {
			append(&inst_buf, tape.Index(int(elem_idx)))
		}
	}
	if len(sites) > 0 {
		for ms in sites {
			alive := ms.parts & ~f.no_emit_mask
			if alive == 0 {
				continue
			}
			b := u8(intrinsics.count_trailing_zeros(alive))
			clear(&kw_buf)
			append(&kw_buf, ..outer_kw[:])
			append(&kw_buf, ..f.part_meta[b].site)
			append(&kw_buf, ..ms.site)
			if len(extra_kw) > 0 {
				append(&kw_buf, tape.Name(extra_kw))
			}
			if len(keyword) > 0 {
				append(&kw_buf, tape.Name(keyword))
			}
			emit_built_factored_err(h, fo, nil, kind, at, keyword, expected, inst_buf[:], kw_buf[:])
			return
		}
		return
	}
	append(&kw_buf, ..outer_kw[:])
	if !spine {
		if (f.no_emit_mask & (u64(1) << part)) != 0 {
			return
		}
		append(&kw_buf, ..f.part_meta[part].site)
	}
	if len(extra_kw) > 0 {
		append(&kw_buf, tape.Name(extra_kw))
	}
	if len(keyword) > 0 {
		append(&kw_buf, tape.Name(keyword))
	}
	emit_built_factored_err(h, fo, nil, kind, at, keyword, expected, inst_buf[:], kw_buf[:])
}

@(private)
record_first_factored_leaf_fails :: proc(
	h: ^Checker,
	fo: ^Factored_Open,
	l: ^rules.Leaf,
	fails: rules.Failures,
	at: u64,
	members: bool,
	sites: []Member_Site,
	part: u8,
	member_name: string,
	elem_idx: u64,
	has_member: bool,
	extra_kw := "",
) {
	if h.first_recorded {
		return
	}
	for k in fails {
		kw := keyword_of_kind(k, l, members)
		exp := rules.operand_text(l, k, members, h.scratch)
		record_first_factored_err(h, fo, k, at, kw, exp, member_name, elem_idx, has_member, sites, part, extra_kw)
		if len(exp) > 0 {
			delete(exp, h.scratch)
		}
		return
	}
}

@(private = "file")
emit_first_choice_span_entry :: proc(h: ^Checker, fo: ^Factored_Open, mark, base_kw_len: int, sites: []Member_Site) {
	if h.first_recorded || mark >= len(fo.choice_sink.entries) {
		return
	}
	f := fo.factor
	ce := &fo.choice_sink.entries[mark]
	no_ms := mark < len(fo.choice_no_member) && fo.choice_no_member[mark]
	kw_buf := make([dynamic]tape.Step, h.scratch)
	defer delete(kw_buf)
	for ms in sites {
		alive := ms.parts & ~f.no_emit_mask
		if alive == 0 {
			continue
		}
		b := u8(intrinsics.count_trailing_zeros(alive))
		clear(&kw_buf)
		split := min(base_kw_len, len(ce.keyword_path))
		append(&kw_buf, ..ce.keyword_path[:split])
		append(&kw_buf, ..f.part_meta[b].site)
		if !no_ms {
			append(&kw_buf, ..ms.site)
		}
		append(&kw_buf, ..ce.keyword_path[split:])
		emit_built_factored_err(h, fo, nil, ce.kind, ce.at - h.at_bias, ce.keyword, ce.expected, ce.path, kw_buf[:])
		return
	}
}

@(private)
emit_factored_errors :: proc(h: ^Checker, fo: ^Factored_Open, failed: u64, first_only := false) {
	f := fo.factor
	target := fo.saved_sink
	if target == nil && !first_only {
		return
	}
	outer_inst := make([dynamic]tape.Step, h.scratch)
	outer_kw := make([dynamic]tape.Step, h.scratch)
	defer {
		delete(outer_inst)
		delete(outer_kw)
	}
	factored_outer_paths(h, fo, &outer_inst, &outer_kw)

	// 1. Spine count (`minProperties`/`maxProperties` or `minItems`/`maxItems`).
	is_obj := f.arr == nil
	if f.spine_leaf > 0 {
		l := &h.plan.leaves[f.spine_leaf - 1]
		fails := rules.judge_count(fo.seen_count, l.min_members, l.max_members) if is_obj else rules.judge_count(fo.seen_count, l.min_items, l.max_items)
		for k in fails {
			kw := keyword_of_kind(k, l, is_obj)
			exp := rules.operand_text(l, k, is_obj, h.scratch)
			emit_built_factored_err(h, fo, target, k, fo.open_at, kw, exp, outer_inst[:], outer_kw[:], extra_step = tape.Name(kw))
			if len(exp) > 0 {
				delete(exp, h.scratch)
			}
			if h.fatal != .None || (first_only && h.first_recorded) {
				return
			}
		}
	}

	// 2. Spine `uniqueItems`.
	if f.arr != nil && f.arr.spine_unique && fo.arr_unique_failed {
		emit_built_factored_err(h, fo, target, .Not_Unique, fo.open_at, "uniqueItems", "", outer_inst[:], outer_kw[:], extra_step = tape.Name("uniqueItems"))
		if h.fatal != .None || (first_only && h.first_recorded) {
			return
		}
	}

	// 3. Circuit `f.ops` errors.
	if !factor_eval(f, failed, 0) {
		emit_op_errors(h, fo, target, failed, 0, outer_inst[:], outer_kw[:], first_only)
		if h.fatal != .None || (first_only && h.first_recorded) {
			return
		}
	}

	// 4. Outer `unevaluatedProperties: false` / `unevaluatedItems: false`.
	if !first_only && f.uneval_false {
		active := eval_parts_for_errors(f, failed, 0)
		u_kw := "unevaluatedProperties" if is_obj else "unevaluatedItems"
		emit_uneval_errors(h, fo, target, active, failed, outer_inst[:], outer_kw[:], {tape.Name(u_kw), tape.Name("type")})
	}
}

@(private = "file")
eval_parts_for_errors :: proc "contextless" (f: ^Factor, failed: u64, op_idx: i16) -> u64 #no_bounds_check {
	op := f.ops[op_idx]
	switch op.kind {
	case .Part:
		return u64(1) << op.bit
	case .Any_Mask:
		return op.mask & ~failed
	case .One_Mask:
		alive := op.mask & ~failed
		return alive if (alive != 0 && (alive & (alive - 1)) == 0) else 0
	case .All:
		acc := u64(0)
		for i in 0 ..< op.count {
			acc |= eval_parts_for_errors(f, failed, op.first + i)
		}
		return acc
	case .Any:
		acc := u64(0)
		for i in 0 ..< op.count {
			ch := op.first + i
			if factor_eval(f, failed, ch) {
				acc |= eval_parts_for_errors(f, failed, ch)
			}
		}
		return acc
	case .One:
		hits := 0
		win := i16(-1)
		for i in 0 ..< op.count {
			ch := op.first + i
			if factor_eval(f, failed, ch) {
				hits += 1
				win = ch
			}
		}
		return eval_parts_for_errors(f, failed, win) if hits == 1 else 0
	case .Not:
		return 0
	case .If:
		if factor_eval(f, failed, op.first) {
			acc := eval_parts_for_errors(f, failed, op.first)
			if op.count >= 0 && factor_eval(f, failed, op.count) {
				acc |= eval_parts_for_errors(f, failed, op.count)
			}
			return acc
		}
		if op.else_op >= 0 && factor_eval(f, failed, op.else_op) {
			return eval_parts_for_errors(f, failed, op.else_op)
		}
		return 0
	}
	return 0
}

@(private = "file")
emit_op_errors :: proc(h: ^Checker, fo: ^Factored_Open, target: ^Sink, failed: u64, op_idx: i16, outer_inst, outer_kw: []tape.Step, first_only := false) #no_bounds_check {
	if h.fatal != .None || (first_only && h.first_recorded) {
		return
	}
	f := fo.factor
	op := f.ops[op_idx]
	switch op.kind {
	case .Part:
		if (failed & (u64(1) << op.bit)) != 0 {
			emit_part_errors(h, fo, target, failed, op.bit, outer_inst, outer_kw, first_only)
		}
	case .Any_Mask:
		if op.is_enum {
			if (op.mask & ~failed) == 0 {
				emit_built_factored_err(h, fo, target, .Not_A_Member, fo.open_at, "enum", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("enum"))
			}
			return
		}
		if (op.mask & ~failed) == 0 {
			for b := 0; b < int(f.n); b += 1 {
				if (op.mask & (u64(1) << uint(b))) != 0 {
					emit_part_errors(h, fo, target, failed, u8(b), outer_inst, outer_kw, first_only)
					if h.fatal != .None || (first_only && h.first_recorded) {
						return
					}
				}
			}
			emit_built_factored_err(h, fo, target, .No_Arm, fo.open_at, "anyOf", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("anyOf"))
		}
	case .One_Mask:
		alive := op.mask & ~failed
		hits := intrinsics.count_ones(alive)
		if hits == 1 {
			return
		}
		if hits == 0 {
			for b := 0; b < int(f.n); b += 1 {
				if (op.mask & (u64(1) << uint(b))) != 0 {
					emit_part_errors(h, fo, target, failed, u8(b), outer_inst, outer_kw, first_only)
					if h.fatal != .None || (first_only && h.first_recorded) {
						return
					}
				}
			}
			emit_built_factored_err(h, fo, target, .No_Arm, fo.open_at, "oneOf", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("oneOf"))
		} else {
			emit_built_factored_err(h, fo, target, .Many_Arms, fo.open_at, "oneOf", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("oneOf"))
		}
	case .All:
		for i in 0 ..< op.count {
			ch := op.first + i
			if !factor_eval(f, failed, ch) {
				emit_op_errors(h, fo, target, failed, ch, outer_inst, outer_kw, first_only)
				if h.fatal != .None || (first_only && h.first_recorded) {
					return
				}
			}
		}
	case .Any:
		if !factor_eval(f, failed, op_idx) {
			for i in 0 ..< op.count {
				emit_op_errors(h, fo, target, failed, op.first + i, outer_inst, outer_kw, first_only)
				if h.fatal != .None || (first_only && h.first_recorded) {
					return
				}
			}
			emit_built_factored_err(h, fo, target, .No_Arm, fo.open_at, "anyOf", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("anyOf"))
		}
	case .One:
		hits := 0
		for i in 0 ..< op.count {
			if factor_eval(f, failed, op.first + i) {
				hits += 1
			}
		}
		if hits == 1 {
			return
		}
		if hits == 0 {
			for i in 0 ..< op.count {
				emit_op_errors(h, fo, target, failed, op.first + i, outer_inst, outer_kw, first_only)
				if h.fatal != .None || (first_only && h.first_recorded) {
					return
				}
			}
			emit_built_factored_err(h, fo, target, .No_Arm, fo.open_at, "oneOf", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("oneOf"))
		} else {
			emit_built_factored_err(h, fo, target, .Many_Arms, fo.open_at, "oneOf", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("oneOf"))
		}
	case .Not:
		if factor_eval(f, failed, op.first) {
			emit_built_factored_err(h, fo, target, .Not_Allowed, fo.open_at, "not", "", outer_inst, outer_kw, mid_site = op.site, extra_step = tape.Name("not"))
		}
	case .If:
		if factor_eval(f, failed, op.first) {
			if op.count >= 0 && !factor_eval(f, failed, op.count) {
				emit_op_errors(h, fo, target, failed, op.count, outer_inst, outer_kw, first_only)
			}
		} else if op.else_op >= 0 && !factor_eval(f, failed, op.else_op) {
			emit_op_errors(h, fo, target, failed, op.else_op, outer_inst, outer_kw, first_only)
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
		if len(exp) > 0 {
			delete(exp, h.scratch)
		}
		return
	}

	if pm.uneval_kw != "" {
		if !first_only {
			for cl in f.closings {
				if cl.part == b {
					active_cl := eval_parts_for_errors(f, failed, cl.root_op)
					emit_uneval_errors(h, fo, target, active_cl, failed, outer_inst, outer_kw, pm.site, append_type = true)
					break
				}
			}
		}
		return
	}

	// Buffered member / element / choice errors for part `b`.
	inst_buf := make([dynamic]tape.Step, h.scratch)
	kw_buf := make([dynamic]tape.Step, h.scratch)
	defer {
		delete(inst_buf)
		delete(kw_buf)
	}

	for &e in fo.err_entries {
		if (e.no_emit_mask & bit) != 0 {
			continue
		}
		switch e.kind {
		case .Direct:
			clear(&inst_buf)
			append(&inst_buf, ..outer_inst)
			if e.has_member {
				if is_obj {
					append(&inst_buf, tape.Name(e.member_name))
				} else {
					append(&inst_buf, tape.Index(int(e.elem_idx)))
				}
			}
			if len(e.sites) > 0 {
				for ms in e.sites {
					if (ms.parts & bit) == 0 {
						continue
					}
					clear(&kw_buf)
					append(&kw_buf, ..outer_kw)
					append(&kw_buf, ..pm.site)
					append(&kw_buf, ..ms.site)
					if len(e.extra_kw) > 0 {
						append(&kw_buf, tape.Name(e.extra_kw))
					}
					if len(e.keyword) > 0 {
						append(&kw_buf, tape.Name(e.keyword))
					}
					emit_built_factored_err(h, fo, target, e.err_kind, e.at, e.keyword, e.expected, inst_buf[:], kw_buf[:])
					if h.fatal != .None || (first_only && h.first_recorded) {
						return
					}
				}
			} else if e.part == b {
				clear(&kw_buf)
				append(&kw_buf, ..outer_kw)
				append(&kw_buf, ..pm.site)
				if len(e.extra_kw) > 0 {
					append(&kw_buf, tape.Name(e.extra_kw))
				}
				if len(e.keyword) > 0 {
					append(&kw_buf, tape.Name(e.keyword))
				}
				emit_built_factored_err(h, fo, target, e.err_kind, e.at, e.keyword, e.expected, inst_buf[:], kw_buf[:])
				if h.fatal != .None || (first_only && h.first_recorded) {
					return
				}
			}
		case .Choice_Span:
			for ms in e.sites {
				if (ms.parts & bit) == 0 {
					continue
				}
				for ci in e.choice_from ..< e.choice_to {
					ce := &fo.choice_sink.entries[ci]
					no_ms := ci < len(fo.choice_no_member) && fo.choice_no_member[ci]
					clear(&kw_buf)
					split := min(e.base_kw_len, len(ce.keyword_path))
					append(&kw_buf, ..ce.keyword_path[:split])
					append(&kw_buf, ..pm.site)
					if !no_ms {
						append(&kw_buf, ..ms.site)
					}
					append(&kw_buf, ..ce.keyword_path[split:])
					emit_built_factored_err(h, fo, target, ce.kind, ce.at, ce.keyword, ce.expected, ce.path, kw_buf[:])
					if h.fatal != .None || (first_only && h.first_recorded) {
						return
					}
				}
			}
		}
	}

	if is_obj {
		// Required members.
		for req in f.required {
			if (req.parts & bit) != 0 && !factored_is_seen(fo, req.member) {
				req_name := h.plan.meta[f.block + req.member].name
				emit_built_factored_err(h, fo, target, .Missing_Field, fo.open_at, "required", req_name, outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name("required"))
				if h.fatal != .None || (first_only && h.first_recorded) {
					return
				}
			}
		}
		// dependentRequired / dependencies.
		for dr in f.dep_required {
			if (dr.parts & bit) != 0 && factored_is_seen(fo, dr.trigger) {
				for w in dr.wants {
					if !factored_is_seen(fo, w) {
						want_name := h.plan.meta[f.block + w].name
						emit_built_factored_err(h, fo, target, .Missing_Field, fo.open_at, dr.keyword, want_name, outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name(dr.keyword))
						if h.fatal != .None || (first_only && h.first_recorded) {
							return
						}
					}
				}
			}
		}
		// Per-part minProperties / maxProperties.
		for cnt in f.counts {
			if (cnt.parts & bit) != 0 {
				fails := rules.judge_count(fo.seen_count, cnt.min_members, cnt.max_members)
				if fails != {} {
					emit_count_leaf_err(h, fo, target, fails, cnt.min_members, cnt.max_members, true, outer_inst, outer_kw, pm.site)
					if h.fatal != .None || (first_only && h.first_recorded) {
						return
					}
				}
			}
		}
	} else {
		fa := f.arr
		if (fa.unique_parts & bit) != 0 && fo.arr_unique_failed {
			emit_built_factored_err(h, fo, target, .Not_Unique, fo.open_at, "uniqueItems", "", outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name("uniqueItems"))
			if h.fatal != .None || (first_only && h.first_recorded) {
				return
			}
		}
		st := fo.arr_state
		for c, ci in fa.contains {
			if c.part != b {
				continue
			}
			hits := st.contains_hits[ci] if (st != nil && ci < len(st.contains_hits)) else 0
			if hits < c.min_contains {
				kw := "minContains" if c.min_contains > 1 else "contains"
				emit_built_factored_err(h, fo, target, .Too_Few, fo.open_at, kw, "", outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name(kw))
				if h.fatal != .None || (first_only && h.first_recorded) {
					return
				}
			}
			if hits > c.max_contains {
				emit_built_factored_err(h, fo, target, .Too_Many, fo.open_at, "maxContains", "", outer_inst, outer_kw, mid_site = pm.site, extra_step = tape.Name("maxContains"))
				if h.fatal != .None || (first_only && h.first_recorded) {
					return
				}
			}
		}
		for cnt in fa.counts {
			if (cnt.parts & bit) != 0 {
				fails := rules.judge_count(fo.seen_count, cnt.min_items, cnt.max_items)
				if fails != {} {
					emit_count_leaf_err(h, fo, target, fails, cnt.min_items, cnt.max_items, false, outer_inst, outer_kw, pm.site)
					if h.fatal != .None || (first_only && h.first_recorded) {
						return
					}
				}
			}
		}
	}
}

@(private = "file")
emit_count_leaf_err :: proc(h: ^Checker, fo: ^Factored_Open, target: ^Sink, fails: rules.Failures, lo, hi: u64, members: bool, outer_inst, outer_kw, mid_site: []tape.Step) {
	fake := rules.Leaf{min_members = lo, max_members = hi, min_items = lo, max_items = hi}
	for k in fails {
		kw := keyword_of_kind(k, &fake, members)
		exp := rules.operand_text(&fake, k, members, h.scratch)
		emit_built_factored_err(h, fo, target, k, fo.open_at, kw, exp, outer_inst, outer_kw, mid_site = mid_site, extra_step = tape.Name(kw))
		if len(exp) > 0 {
			delete(exp, h.scratch)
		}
		if h.fatal != .None || (target == nil && h.first_recorded) {
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
	if append_type {
		append(&kw_buf, tape.Name("type"))
	}

	if f.arr == nil {
		if (active & f.eval_all) != 0 {
			return
		}
		for &sp in fo.seen_pos {
			fm := h.plan.uses[int(f.block) + int(sp.member_idx)].member if sp.member_idx >= 0 else f.classes[sp.cls]
			if fm != nil && (fm.evals & active) != 0 {
				continue
			}
			clear(&inst_buf)
			append(&inst_buf, ..outer_inst)
			append(&inst_buf, tape.Name(sp.name))
			emit_built_factored_err(h, fo, target, .Wrong_Kind, sp.val_at, "type", "", inst_buf[:], kw_buf[:])
			if h.fatal != .None {
				return
			}
		}
		return
	}

	fa := f.arr
	if fo.seen_count == 0 {
		return
	}
	eval_all := (active & fa.eval_all_items) != 0
	if eval_all && len(fa.prefix) == 0 {
		return
	}
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
			if (pe & active) != 0 {
				continue
			}
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
		if h.fatal != .None {
			return
		}
	}
}

@(private = "file")
emit_built_factored_err :: proc(
	h: ^Checker,
	fo: ^Factored_Open,
	target: ^Sink,
	kind: Error_Kind,
	at: u64,
	keyword: string,
	expected: string,
	inst_steps: []tape.Step,
	kw_base: []tape.Step,
	mid_site: []tape.Step = nil,
	extra_step: Maybe(tape.Step) = nil,
) {
	if target == nil && h.first_recorded {
		return
	}
	kw_steps_dyn: [dynamic]tape.Step
	kw_steps := kw_base
	if len(mid_site) > 0 || extra_step != nil {
		kw_steps_dyn.allocator = h.scratch
		append(&kw_steps_dyn, ..kw_base)
		append(&kw_steps_dyn, ..mid_site)
		if ex, has_ex := extra_step.?; has_ex {
			append(&kw_steps_dyn, ex)
		}
		kw_steps = kw_steps_dyn[:]
	}
	defer delete(kw_steps_dyn)

	if !fo.saved_buffering {
		est_bytes := u64(size_of(Check_Error)) + u64(len(expected) + len(keyword)) + u64(len(inst_steps) + len(kw_steps)) * u64(size_of(tape.Step) + 16)
		if !charge_output_budget(h, est_bytes) {
			if target != nil {
				target.oom = true
			}
			return
		}
	}

	arena: runtime.Allocator
	if target == nil {
		a, aok := checker_first_arena_ensure(h, charge_budget = !fo.saved_buffering)
		if !aok {
			return
		}
		arena = a
	} else {
		arena = sink_ensure(target, h.scratch if fo.saved_buffering else h.allocator)
	}
	inst_ptr, ierr := format_pointer(inst_steps, arena)
	kw_ptr, kerr := format_pointer(kw_steps, arena)
	path_cp, perr := clone_steps(inst_steps, arena)
	kw_cp, kperr := clone_steps(kw_steps, arena)
	if ierr != nil || kerr != nil || perr != nil || kperr != nil {
		if target != nil {
			target.oom = true
		}
		h.fatal = .No_Memory
		return
	}
	exp_cp := ""
	if len(expected) > 0 {
		ec, eerr := strings.clone(expected, arena)
		if eerr != nil {
			if target != nil {
				target.oom = true
			}
			h.fatal = .No_Memory
			return
		}
		exp_cp = ec
	}
	kw_str := ""
	if len(keyword) > 0 {
		kc, kserr := strings.clone(keyword, arena)
		if kserr != nil {
			if target != nil {
				target.oom = true
			}
			h.fatal = .No_Memory
			return
		}
		kw_str = kc
	}
	entry := Check_Error{
		kind = kind,
		at = at + h.at_bias,
		instance_location = inst_ptr,
		keyword_location = kw_ptr,
		keyword = kw_str,
		expected = exp_cp,
		path = path_cp,
		keyword_path = kw_cp,
	}
	if target == nil {
		h.first_err = entry
		h.first_recorded = true
		return
	}
	if _, err := append(&target.entries, entry); err != nil {
		target.oom = true
		h.fatal = .No_Memory
		return
	}
	if fo.saved_buffering {
		cfo_h := h
		for cfo_h != nil && cfo_h.choice_sink_fo < 0 {
			cfo_h = cfo_h.parent
		}
		if cfo_h != nil && int(cfo_h.choice_sink_fo) < cfo_h.nf {
			cfo := factored_at(cfo_h, int(cfo_h.choice_sink_fo))
			for len(cfo.choice_no_member) < len(cfo.choice_sink.entries) - 1 {
				append(&cfo.choice_no_member, false)
			}
			append(&cfo.choice_no_member, false)
		}
	}
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
