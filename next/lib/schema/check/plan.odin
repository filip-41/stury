// Immutable, thread-safe compiled schema check plan (`Plan`) and its compiler (`compile`).
package check

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

Record_Kind :: enum u8 {
	End,
	Checked,
}

// Hot per-record flags packed into `Record` so the hot streaming path rarely touches cold `Meta`/`Use`.
Record_Flag :: enum u8 {
	Step,           // prefixItems record: moves cursor on to next element's record
	Held,           // has `Use.applies` (non-trivial applicators/arms/unique/container-enum)
	Factored,       // has `Use.factor` or `Use.arr_factor`
	Counted,        // object leaf bounds `minProperties` or `maxProperties`
	Required,       // object has `required` members or `dependentRequired`
	Inside,         // array has `prefixItems` or `items`
	Has_Keys,       // object has `propertyNames` leaf
	Has_Additional, // object has `additionalProperties` or inline `patternProperties`
}

Record_Flags :: bit_set[Record_Flag; u8]

Record_Fast_Flag :: enum u8 {
	Pure_String,    // string check needs only `.String in leaf_kinds`
	Pure_Number,    // number check needs only `.Number`/`.Integer` in `leaf_kinds`
	Pure_Scalar,    // null/bool check needs only `.Null`/`.Bool` in `leaf_kinds`
	Pure_Array,     // array check needs only `.Array in leaf_kinds`
	Trivial_Object, // object can `.Skip` immediately
	Trivial_Array,  // array can `.Skip` immediately
	Has_Deps,       // object has `dependentRequired`
}

Record_Fast_Flags :: bit_set[Record_Fast_Flag; u8]

// One record in a compiled check plan. Exactly `hook.EXPECTED_STRIDE` (48) bytes so `.Expects` walks
// match member keys in schema order directly against `expected` without calling the hook.
Record :: struct {
	using expected: hook.Expected_Key,
	first:          ^Record,
	meta:           u32,
	rule_set:       i32, // 1 + index in `Plan.leaves`, 0 for none
	kind:           Record_Kind,
	flags:          Record_Flags,
	leaf_kinds:     rules.Kinds,
	fast_flags:     Record_Fast_Flags,
	members_u16:    u16,
	req_end_u16:    u16,
}

#assert(size_of(Record) == hook.EXPECTED_STRIDE)

@(private)
NO_KEY :: max(u64)

Meta :: struct {
	name:          string,
	block:         i32,   // first member record of an object's block, -1 for none
	members:       i32,   // count of named members in the object's block
	slots:         u32,   // offset in `Plan.slots` of this block's hash table
	slots_n:       u32,   // power-of-two capacity of this block's hash table (0 if none)
	name_bits:     u64,   // 64-bit bloom mask over named member keys for O(1) unknown-key rejection
	required:      []i32, // on the block's `End` record: member indices that are required
	required_mask: u64,   // bitmask of required members when `members <= 64`
	required_end:  i32,   // 1 + max required member index
	rule_set:      i32,   // 1 + index in `Plan.leaves`, 0 for none
	counted:       bool,  // object leaf has minProperties / maxProperties
}

Use :: struct {
	items:       i32, // `b` offset (1 past first record) for array elements, 0 for none
	additional:  i32, // `b` offset (1 past record) for `additionalProperties`, 0 for none
	keys:        i32, // 1 + leaf index for `propertyNames`, 0 for none
	pattern:     i32, // `b` offset (1 past record) for inlined single `patternProperties`, 0 for none
	verdict_rec: i32, // single conjoined record index (`1 + idx`) for verdict-only streaming (`0` for none)
	obj_arm:     i32, // for single `.One`/`.Any`: `1 + idx` if unique arm accepts `.Object`, `-1` if none, `0` if 2+
	arr_arm:     i32, // for single `.One`/`.Any`: `1 + idx` if unique arm accepts `.Array`, `-1` if none, `0` if 2+
	regex:       ^regex.Regex,
	site:        []tape.Step,
	keys_site:   []tape.Step, // replacement site relative to parent Factor when `propertyNames` came from merged `patternProperties`
	step:        bool,
	inside:      bool,
	add_false:   bool,
	applies:     []Apply,
	verdict:     []Apply,
	requires:    []Requires,
	factor:      ^Factor,
	arr_factor:  ^Factor,
	member:      ^Factor_Member,
}

@(private)
factor_for_token :: #force_inline proc "contextless" (u: ^Use, k: tape.Kind) -> ^Factor {
	if k == .Object { return u.factor }
	return u.arr_factor if k == .Array else nil
}

Requires :: struct {
	trigger: i32,
	wants:   []i32,
	keyword: string,
}

// An immutable, self-contained, thread-safe compiled schema check plan.
Plan :: struct {
	records:     []Record,
	solo:        []Record, // 2 records per record: `[copy, End{NO_KEY}]`
	meta:        []Meta,
	uses:        []Use,
	leaves:      []rules.Leaf,
	slots:       []u32,
	root:        ^Record, // `&records[1]`: `root[-1]` is the root record, `root[0]` is `.End{NO_KEY}`
	nothing:     i32,     // `b` offset (1 past record) of the trivial accept-everything record
	base_uri:    string,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
	allocator:   runtime.Allocator,
}

plan_destroy :: proc(p: ^Plan) {
	if p == nil { return }
	if p.allocator.procedure != nil {
		delete(p.records, p.allocator)
		delete(p.solo, p.allocator)
		delete(p.meta, p.allocator)
		delete(p.uses, p.allocator)
		delete(p.leaves, p.allocator)
		delete(p.slots, p.allocator)
	}
	if p.arena_ready { mem.dynamic_arena_destroy(&p.arena) }
	p^ = {}
}

// Compiles `d` into an immutable, self-contained, thread-safe `Plan` allocated from `allocator`.
@(require_results)
compile :: proc(d: ^rules.Description, allocator := context.allocator) -> (p: Plan, err: Compile_Error) {
	if d == nil || d.root < 0 || int(d.root) >= len(d.nodes) {
		return {}, {kind = .Bad_Option, keyword = "root"}
	}
	p.allocator = allocator
	mem.dynamic_arena_init(&p.arena, allocator, allocator)
	p.arena_ready = true
	arena := mem.dynamic_arena_allocator(&p.arena)

	tables_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&tables_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&tables_arena)
	tables := mem.dynamic_arena_allocator(&tables_arena)

	b := Builder{
		p = &p,
		arena = arena,
		tables = tables,
		blocks = make(map[Block_Key]i32, 32, tables),
		arm_cache = make(map[Arm_Key]i32, 32, tables),
		ends = make(map[i32]i32, 32, tables),
		scopes = make([dynamic]Scope, tables),
		evaluated = make(map[Block_Key]^Evaluates, 16, tables),
		conjoined = make(map[Block_Key]Conjoined, 16, tables),
		pairs = make(map[[2]rules.Node_Index]rules.Node_Index, 16, tables),
		keys_sites = make(map[rules.Node_Index][]tape.Step, 8, tables),
		inline = make(map[i32]Inline_Pattern, 8, tables),
		programs = make(rules.Programs, 16, tables),
		unevaluated = make(map[[2]i32]bool, 8, tables),
		nothing = make(map[rules.Node_Index]Nothing, 32, tables),
		factors = make([dynamic]^Factor, tables),
		fills = make([dynamic]Fill, tables),
	}
	b.records.allocator = allocator
	b.meta.allocator = allocator
	b.uses.allocator = allocator
	b.leaves.allocator = allocator
	b.slots.allocator = allocator

	p.base_uri = clone_str(&b, arena, d.uri)

	if root_block(&b) {
		work := conjoin_description(&b, d, arena, tables)
		if b.err.kind == .None {
			p.nothing = checked_block(&b, &work, arena, block_key(typeid_of(rules.Array), -1, 0), nil, rules.NONE, ITEMS[:])
			fill_checked(&b, &work, arena, 0, work.root, "", {}, nil)
			fill_pending(&b, &work, arena)
			factor_finish(&b)
		}
	}
	if b.err.kind == .None { plan_finish(&b) }
	if b.err.kind != .None {
		delete(b.records)
		delete(b.meta)
		delete(b.uses)
		delete(b.leaves)
		delete(b.slots)
		p.records, p.meta, p.uses, p.leaves, p.slots = nil, nil, nil, nil, nil
		plan_destroy(&p)
		return {}, b.err
	}
	return p, {}
}

@(private)
MAX_FILL :: 2 * int(tape.DEFAULT_DEPTH)

@(private)
Block_Key :: struct {
	type: typeid,
	of:   i64,
}

@(private)
block_key :: #force_inline proc "contextless" (type: typeid, of, scope: i32) -> Block_Key {
	return {type, i64(u32(of)) | i64(scope) << 32}
}

@(private)
Inline_Pattern :: struct {
	expression: string,
	node:       rules.Node_Index,
	regex:      ^regex.Regex,
}

@(private)
Scope :: struct {
	outer:    i32,
	resource: rules.Node_Index,
}

@(private)
Fill :: struct {
	at:    i32,
	use:   rules.Node_Index,
	name:  string,
	edge:  rules.Rules,
	steps: []tape.Step,
	scope: i32,
	nest:  i32,
	bare:  bool,
	step:  bool,
}

@(private)
Arm_Key :: struct {
	node:     rules.Node_Index,
	scope:    i32,
	bare:     bool,
	site_tag: u64,
}

@(private)
Builder :: struct {
	p:           ^Plan,
	arena:       runtime.Allocator,
	tables:      runtime.Allocator,
	records:     [dynamic]Record,
	meta:        [dynamic]Meta,
	uses:        [dynamic]Use,
	leaves:      [dynamic]rules.Leaf,
	slots:       [dynamic]u32,
	blocks:      map[Block_Key]i32,
	arm_cache:   map[Arm_Key]i32,
	ends:        map[i32]i32,
	scope:       i32,
	scopes:      [dynamic]Scope,
	evaluated:   map[Block_Key]^Evaluates,
	conjoined:   map[Block_Key]Conjoined,
	pairs:       map[[2]rules.Node_Index]rules.Node_Index,
	keys_sites:  map[rules.Node_Index][]tape.Step,
	inline:      map[i32]Inline_Pattern,
	programs:    rules.Programs,
	unevaluated: map[[2]i32]bool,
	nothing:     map[rules.Node_Index]Nothing,
	factors:     [dynamic]^Factor,
	fills:       [dynamic]Fill,
	nest:        int,
	err:         Compile_Error,
}

@(private)
refuse_plan :: proc(b: ^Builder, kind: Error_Kind, keyword := "") {
	if b.err.kind == .None {
		b.err = {kind = kind, keyword = keyword}
	}
}

@(private)
clone_str :: proc(b: ^Builder, arena: runtime.Allocator, s: string) -> string {
	if len(s) == 0 { return "" }
	cp, err := strings.clone(s, arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return ""
	}
	return cp
}

// Deep-clones a `rules.Value` (materializing any `Node_Ref` from a schema `tape.Document`) into `arena`.
@(private)
clone_value :: proc(b: ^Builder, v: rules.Value, arena, scratch: runtime.Allocator) -> rules.Value {
	Work :: struct {
		src: rules.Value,
		dst: ^rules.Value,
	}
	Group_Slot :: struct {
		key:  string,
		vals: [dynamic]rules.Value,
	}
	root_out: rules.Value
	stack := make([dynamic]Work, scratch)
	append(&stack, Work{src = v, dst = &root_out})
	buf: [128]u8 = ---
	for len(stack) > 0 && b.err.kind == .None {
		w := pop(&stack)
		switch rules.value_kind(w.src) {
		case .Null:
			w.dst^ = rules.Null{}
		case .True:
			w.dst^ = true
		case .False:
			w.dst^ = false
		case .Number:
			txt, owned, ok := rules.value_number_text(w.src, buf[:], scratch)
			if !ok {
				refuse_plan(b, .No_Memory)
				return {}
			}
			w.dst^ = rules.Number_Text{text = clone_str(b, arena, txt)}
			if owned { delete(txt, scratch) }
		case .String:
			txt, owned, ok := rules.value_string(w.src, buf[:], scratch)
			if !ok {
				refuse_plan(b, .No_Memory)
				return {}
			}
			w.dst^ = clone_str(b, arena, txt)
			if owned { delete(txt, scratch) }
		case .Array:
			#partial switch av in w.src {
			case []rules.Value:
				out, err := make([]rules.Value, len(av), arena)
				if err != nil {
					refuse_plan(b, .No_Memory)
					return {}
				}
				w.dst^ = out
				for i := len(av) - 1; i >= 0; i -= 1 {
					append(&stack, Work{src = av[i], dst = &out[i]})
				}
			case rules.Node_Ref:
				r := tape.Reader{doc = av.doc}
				it, p, cerr := tape.children(r, av.node, scratch)
				if cerr != nil {
					refuse_plan(b, .No_Memory)
					return {}
				}
				children := make([dynamic]tape.Node_Index, scratch)
				if p == .Found {
					for {
						_, ch, cp := tape.next_child(r, &it)
						if cp != .Found { break }
						append(&children, ch)
					}
				}
				tape.destroy_children(&it)
				out, err := make([]rules.Value, len(children), arena)
				if err != nil {
					refuse_plan(b, .No_Memory)
					return {}
				}
				w.dst^ = out
				for i := len(children) - 1; i >= 0; i -= 1 {
					append(&stack, Work{src = rules.Node_Ref{doc = av.doc, node = children[i]}, dst = &out[i]})
				}
			case:
				w.dst^ = nil
			}
		case .Object:
			#partial switch ov in w.src {
			case []rules.Member_Value:
				out, err := make([]rules.Member_Value, len(ov), arena)
				if err != nil {
					refuse_plan(b, .No_Memory)
					return {}
				}
				w.dst^ = out
				for i := len(ov) - 1; i >= 0; i -= 1 {
					out[i].key = clone_str(b, arena, ov[i].key)
					append(&stack, Work{src = ov[i].value, dst = &out[i].value})
				}
			case rules.Node_Ref:
				r := tape.Reader{doc = ov.doc}
				it, p, cerr := tape.children(r, ov.node, scratch)
				if cerr != nil {
					refuse_plan(b, .No_Memory)
					return {}
				}
				is_group := ov.doc.format != nil && ov.doc.format.dups == .Group
				grouped := make([dynamic]Group_Slot, scratch)
				seen := make(map[string]int, 16, scratch)
				if p == .Found {
					for {
						k, val, cp := tape.next_child(r, &it, .Group if is_group else .Default)
						if cp != .Found { break }
						if k == tape.NO_NODE && it.keys_n == 0 { continue }
						kt := tape.cell_key(r, it) if (k == tape.NO_NODE && it.keys_n != 0) else ov.doc.nodes[k]
						key_str, key_owned, kok := doc_token_text(ov.doc, kt, scratch)
						if !kok {
							refuse_plan(b, .No_Memory)
							break
						}
						cloned_key := clone_str(b, arena, key_str)
						if key_owned { delete(key_str, scratch) }
						if b.err.kind != .None { break }
						ref := rules.Value(rules.Node_Ref{doc = ov.doc, node = val})
						if idx, dup := seen[cloned_key]; dup {
							if is_group {
								if _, aerr := append(&grouped[idx].vals, ref); aerr != nil {
									refuse_plan(b, .No_Memory)
									break
								}
							} else {
								grouped[idx].vals[0] = ref
							}
						} else {
							vl, verr := make([dynamic]rules.Value, 0, 1, scratch)
							_, a1 := append(&vl, ref)
							_, a2 := append(&grouped, Group_Slot{key = cloned_key, vals = vl})
							if verr != nil || a1 != nil || a2 != nil {
								refuse_plan(b, .No_Memory)
								break
							}
							seen[cloned_key] = len(grouped) - 1
						}
					}
				}
				tape.destroy_children(&it)
				if b.err.kind != .None {
					return {}
				}
				out, err := make([]rules.Member_Value, len(grouped), arena)
				if err != nil {
					refuse_plan(b, .No_Memory)
					return {}
				}
				w.dst^ = out
				for i := len(grouped) - 1; i >= 0; i -= 1 {
					out[i].key = grouped[i].key
					if len(grouped[i].vals) == 1 {
						append(&stack, Work{src = grouped[i].vals[0], dst = &out[i].value})
					} else {
						// XML `.Group` with 2+ repeated children -> virtual array of values (A-C5).
						arr_out, aerr := make([]rules.Value, len(grouped[i].vals), arena)
						if aerr != nil {
							refuse_plan(b, .No_Memory)
							return {}
						}
						out[i].value = arr_out
						for j := len(grouped[i].vals) - 1; j >= 0; j -= 1 {
							append(&stack, Work{src = grouped[i].vals[j], dst = &arr_out[j]})
						}
					}
				}
			case:
				w.dst^ = nil
			}
		}
	}
	return root_out
}

@(private)
root_block :: proc(b: ^Builder) -> bool {
	at, _ := block_of(b, 2, {})
	if at < 0 { return false }
	never(b, 1)
	return true
}

@(private)
block_of :: proc(b: ^Builder, count: int, key: Block_Key) -> (at: i32, fresh: bool) {
	if key.type != nil {
		if existing, ok := b.blocks[key]; ok { return existing, false }
	}
	at = i32(len(b.records))
	new_len := len(b.records) + count
	if resize(&b.records, new_len) != nil || resize(&b.meta, new_len) != nil || resize(&b.uses, new_len) != nil {
		refuse_plan(b, .No_Memory)
		return -1, false
	}
	for i in int(at) ..< new_len {
		b.records[i] = Record{word = NO_KEY, meta = u32(i)}
		b.meta[i] = Meta{block = -1}
	}
	if key.type != nil { b.blocks[key] = at }
	return at, true
}

@(private)
never :: proc(b: ^Builder, at: int) {
	b.records[at] = Record{word = NO_KEY, meta = u32(at), kind = .End}
	b.meta[at] = Meta{block = -1}
}

@(private)
known_struct :: proc(b: ^Builder, key: Block_Key, m: ^Meta) -> bool {
	at, ok := b.blocks[key]
	if !ok { return false }
	end := b.ends[at]
	m.block, m.members = at, end - at
	m.required_end, m.required_mask = b.meta[end].required_end, b.meta[end].required_mask
	return true
}

@(private)
struct_block :: proc(b: ^Builder, key: Block_Key, m: ^Meta, members: []rules.Member) -> i32 {
	n := len(members)
	at, _ := block_of(b, n + 1, key)
	if at < 0 { return -1 }
	end := int(at) + n
	b.ends[at] = i32(end)
	m.block, m.members = at, i32(n)
	never(b, end)
	req := make([dynamic]i32, b.arena)
	req_mask := u64(0)
	for x, i in members {
		if x.required {
			if _, err := append(&req, i32(i)); err != nil {
				refuse_plan(b, .No_Memory)
				return -1
			}
			if i < 64 { req_mask |= u64(1) << uint(i) }
		}
	}
	b.meta[end].required = req[:]
	b.meta[end].required_mask = req_mask
	m.required_mask = req_mask
	if len(req) > 0 {
		m.required_end = req[len(req) - 1] + 1
		b.meta[end].required_end = m.required_end
	}
	return at
}

@(private)
dynamic_ref_only :: proc "contextless" (n: ^rules.Node) -> bool {
	return n.dynamic_ref != nil && n.ref == nil && n.kinds == rules.EVERY_KIND && n.rules == {} && n.array < 0 && n.object < 0 && !n.has_enum && n.const_of == nil && len(n.any_of) == 0 && len(n.all_of) == 0 && len(n.one_of) == 0 && n.not == nil && n.cond == {} && n.unevaluated_items == nil && n.unevaluated_properties == nil
}

// Follows pure `$ref` and `$dynamicRef`/`$recursiveRef` chains while updating `b.scope`.
@(private)
resolve_end :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, use: rules.Node_Index, step_words: ^[dynamic]string = nil) -> rules.Node_Index {
	if use == rules.NONE { return rules.NONE }
	cur := use
	inline_seen: [8]u64 = ---
	seen_n := 0
	wide_seen: map[u64]bool
	for cur != rules.NONE && int(cur) < len(d.nodes) {
		enter_scope(b, d, arena, cur)
		key := u64(u32(cur)) | (u64(b.scope) << 32)
		if seen_n < len(inline_seen) {
			for j in 0 ..< seen_n {
				if inline_seen[j] == key { return rules.NONE }
			}
			inline_seen[seen_n] = key
			seen_n += 1
		} else {
			if len(wide_seen) == 0 {
				wide_seen = make(map[u64]bool, 16, b.tables)
				for j in 0 ..< seen_n {
					wide_seen[inline_seen[j]] = true
				}
			}
			if wide_seen[key] { return rules.NONE }
			wide_seen[key] = true
		}
		n := &d.nodes[cur]
		if rules.ref_only(n) {
			if step_words != nil { append(step_words, rules.ref_keyword(n)) }
			cur = n.ref.?
			continue
		}
		if dynamic_ref_only(n) {
			if step_words != nil { append(step_words, rules.dynamic_keyword(n)) }
			cur = dynamic_target(b, d, n, n.dynamic_ref.?)
			continue
		}
		return cur
	}
	return rules.NONE
}

@(private)
resolve_end_ro :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, use: rules.Node_Index) -> rules.Node_Index {
	saved := b.scope
	defer b.scope = saved
	return resolve_end(b, d, arena, use)
}

@(private)
fill_checked :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, at: int, use: rules.Node_Index, name: string, edge: rules.Rules, site: []tape.Step, bare := false, step := false) {
	saved_scope := b.scope
	words := make([dynamic]string, b.tables)
	_ = resolve_end(b, d, arena, use, &words)
	b.scope = saved_scope
	steps, err := make([]tape.Step, len(site) + len(words), arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	for s, i in site {
		#partial switch v in s {
		case tape.Name:  steps[i] = tape.Name(clone_str(b, arena, string(v)))
		case tape.Index: steps[i] = v
		}
	}
	for w, i in words {
		steps[len(site) + i] = tape.Name(w)
	}
	if _, ferr := append(&b.fills, Fill{
		at = i32(at),
		use = use,
		name = clone_str(b, arena, name),
		edge = edge,
		steps = steps,
		scope = saved_scope,
		nest = i32(b.nest),
		bare = bare,
		step = step,
	}); ferr != nil {
		refuse_plan(b, .No_Memory)
	}
}

@(private)
fill_pending :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator) {
	for len(b.fills) > 0 && b.err.kind == .None {
		fill_one(b, d, arena, pop(&b.fills))
	}
	clear(&b.fills)
	b.nest, b.scope = 0, 0
}

@(private, rodata)
ADDITIONAL := [1]tape.Step{tape.Name("additionalProperties")}
@(private, rodata)
ITEMS := [1]tape.Step{tape.Name("items")}
@(private, rodata)
ADDITIONAL_ITEMS := [1]tape.Step{tape.Name("additionalItems")}
@(private, rodata)
UNEVALUATED_PROPERTIES := [1]tape.Step{tape.Name("unevaluatedProperties")}
@(private, rodata)
UNEVALUATED_ITEMS := [1]tape.Step{tape.Name("unevaluatedItems")}

@(private = "file")
fill_one :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, x: Fill) {
	b.scope, b.nest = x.scope, int(x.nest)
	if b.nest >= MAX_FILL {
		refuse_plan(b, .Exceeded, "depth")
		return
	}
	b.nest += 1
	at, use, name, edge, bare := int(x.at), x.use, x.name, x.edge, x.bare
	node := resolve_end(b, d, arena, use)

	f := Record{word = NO_KEY, meta = u32(at), kind = .Checked}
	m := Meta{name = name, block = -1}
	u := Use{site = x.steps, step = x.step}
	if x.step {
		f.flags += {.Step}
	}
	if len(name) > 0 { key_of(&f, name) }

	if node != rules.NONE && !bare && holds(b, d, node, edge) {
		u.applies, u.verdict = checked_applies(b, d, arena, node, edge)
		if len(u.verdict) == 1 && u.verdict[0].kind == .Own && u.verdict[0].record != i32(at) {
			u.verdict_rec = u.verdict[0].record + 1
		}
		u.factor = factor_of(b, d, arena, node, edge)
		u.arr_factor = array_factor_of(b, d, arena, node, edge)
		if len(u.applies) > 0 {
			f.flags += {.Held}
		}
		if u.factor != nil || u.arr_factor != nil {
			f.flags += {.Factored}
		}
	} else if node != rules.NONE {
		n := &d.nodes[node]
		judged := n^
		if arm_operands(n) { judged.has_enum, judged.enum_of, judged.const_of = false, nil, nil }
		m.rule_set = checked_leaf(b, &judged, edge, arena)
		f.rule_set = m.rule_set
		if m.rule_set > 0 {
			l := &b.leaves[m.rule_set - 1]
			m.counted = l.min_members > 0 || l.max_members < max(u64)
			if m.counted {
				f.flags += {.Counted}
			}
		}
		if .Object in n.kinds || n.object >= 0 {
			o := d.objects[n.object] if n.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
			if len(o.patterns) > 0 && n.object not_in b.inline { o.additional = rules.NONE }
			o.members, u.requires = dependent_members(b, arena, o)
			obj_key := block_key(typeid_of(rules.Object), n.object, b.scope)
			other := UNEVALUATED_PROPERTIES[:] if b.unevaluated[{0, n.object}] else ADDITIONAL[:]
			if !known_struct(b, obj_key, &m) && struct_block(b, obj_key, &m, o.members) >= 0 {
				checked_members(b, d, arena, m.block, o, other)
			}
			if m.required_end > 0 || len(u.requires) > 0 {
				f.flags += {.Required}
			}
			if o.additional != rules.NONE {
				u.additional = checked_block(b, d, arena, block_key(typeid_of(Maybe(rules.Object)), n.object, b.scope), nil, o.additional, other)
				add_end := resolve_end_ro(b, d, arena, o.additional)
				u.add_false = add_end != rules.NONE && d.nodes[add_end].kinds == {}
				f.flags += {.Has_Additional}
			}
			if p, inline := b.inline[n.object]; inline {
				site := [2]tape.Step{tape.Name("patternProperties"), tape.Name(p.expression)}
				u.pattern = checked_block(b, d, arena, block_key(typeid_of(rules.Pattern), n.object, b.scope), nil, p.node, site[:])
				u.regex = p.regex
				f.flags += {.Has_Additional}
			}
			saved_kscope := b.scope
			if keys := resolve_end(b, d, arena, o.keys); keys != rules.NONE && !holds(b, d, keys, {}) {
				u.keys = checked_leaf(b, &d.nodes[keys], {}, arena)
				if u.keys > 0 {
					f.flags += {.Has_Keys}
					if ks, has_ks := b.keys_sites[node]; has_ks { u.keys_site = ks }
				}
			}
			b.scope = saved_kscope
		}
		if .Array in n.kinds || n.array >= 0 {
			a := d.arrays[n.array] if n.array >= 0 else rules.Array{items = rules.NONE}
			rest := UNEVALUATED_ITEMS[:] if b.unevaluated[{1, n.array}] else ADDITIONAL_ITEMS[:] if a.tuple else ITEMS[:]
			u.items = checked_block(b, d, arena, block_key(typeid_of(rules.Array), n.array, b.scope), a.prefix, a.items, rest, "items" if a.tuple else "prefixItems")
			u.inside = len(a.prefix) > 0 || resolve_end_ro(b, d, arena, a.items) != rules.NONE
			if u.inside {
				f.flags += {.Inside}
			}
		}
	}

	if m.block < 0 || u.items == 0 {
		nothing := checked_block(b, d, arena, block_key(typeid_of(rules.Array), -1, 0), nil, rules.NONE, ITEMS[:])
		if m.block < 0 { m.block = nothing }
		if u.items == 0 { u.items = nothing }
	}
	b.records[at], b.meta[at], b.uses[at] = f, m, u
}

@(private)
dependent_members :: proc(b: ^Builder, arena: runtime.Allocator, o: rules.Object) -> ([]rules.Member, []Requires) {
	place :: proc(b: ^Builder, arena: runtime.Allocator, members: ^[dynamic]rules.Member, name: string) -> i32 {
		for x, i in members {
			if x.name == name { return i32(i) }
		}
		append(members, rules.Member{name = clone_str(b, arena, name), node = rules.NONE, only_required = true})
		return i32(len(members) - 1)
	}
	members := make([dynamic]rules.Member, b.tables)
	requires := make([dynamic]Requires, arena)
	for x in o.dependents {
		if len(x.required) == 0 { continue }
		if len(members) == 0 { append(&members, ..o.members) }
		wants, err := make([]i32, len(x.required), arena)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return o.members, nil
		}
		r := Requires{trigger = place(b, arena, &members, x.name), wants = wants, keyword = "dependencies" if o.dependencies else "dependentRequired"}
		for name, i in x.required {
			r.wants[i] = place(b, arena, &members, name)
		}
		if _, aerr := append(&requires, r); aerr != nil { refuse_plan(b, .No_Memory) }
	}
	if len(requires) == 0 { return o.members, nil }
	return members[:], requires[:]
}

@(private)
checked_members :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, at: i32, o: rules.Object, other: []tape.Step) {
	for x, i in o.members {
		if x.only_required {
			fill_checked(b, d, arena, int(at) + i, o.additional, x.name, {}, other)
			continue
		}
		site := [2]tape.Step{tape.Name("properties"), tape.Name(x.name)}
		fill_checked(b, d, arena, int(at) + i, x.node, x.name, x.rules, site[:])
	}
}

@(private)
enter_scope :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index) {
	if node == rules.NONE || len(d.anchors) == 0 { return }
	if len(b.scopes) == 0 {
		append(&b.scopes, Scope{resource = rules.NONE})
	}
	resource := d.nodes[node].resource
	fresh := false
	for x in d.anchors {
		if x.resource == resource && !scope_bound(b, d, x.name) {
			fresh = true
			break
		}
	}
	if !fresh { return }
	for x, i in b.scopes {
		if x.outer == b.scope && x.resource == resource {
			b.scope = i32(i)
			return
		}
	}
	append(&b.scopes, Scope{b.scope, resource})
	b.scope = i32(len(b.scopes) - 1)
}

@(private = "file")
scope_bound :: proc(b: ^Builder, d: ^rules.Description, name: string) -> bool {
	for at := b.scope; at != 0; at = b.scopes[at].outer {
		for x in d.anchors {
			if x.name == name && x.resource == b.scopes[at].resource { return true }
		}
	}
	return false
}

@(private)
dynamic_target :: proc(b: ^Builder, d: ^rules.Description, n: ^rules.Node, node: rules.Node_Index) -> rules.Node_Index {
	name, named := "", false
	for x in d.anchors {
		if x.node == node && .Dynamic_Static not_in n.spelled {
			name, named = x.name, true
			break
		}
	}
	target := node
	for at := b.scope; named && at != 0; at = b.scopes[at].outer {
		for x in d.anchors {
			if x.name == name && x.resource == b.scopes[at].resource { target = x.node }
		}
	}
	return target
}

@(private)
checked_leaf :: proc(b: ^Builder, n: ^rules.Node, edge: rules.Rules, arena: runtime.Allocator) -> i32 {
	l, refused := rules.leaf_of(n, edge, arena, &b.programs, b.tables)
	if refused != "" {
		refuse_plan(b, .Unsupported, refused)
		return 0
	}
	if rules.trivial(&l) { return 0 }
	if _, err := append(&b.leaves, l); err != nil {
		refuse_plan(b, .No_Memory)
		return 0
	}
	return i32(len(b.leaves))
}

@(private)
checked_block :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, key: Block_Key, prefix: []rules.Node_Index, rest: rules.Node_Index, site: []tape.Step, word := "prefixItems") -> i32 {
	at, fresh := block_of(b, len(prefix) + 2, key)
	if !fresh { return at + 1 }
	never(b, int(at) + len(prefix) + 1)
	for x, i in prefix {
		steps := [2]tape.Step{tape.Name(word), tape.Index(i)}
		fill_checked(b, d, arena, int(at) + i, x, "", {}, steps[:], step = true)
	}
	fill_checked(b, d, arena, int(at) + len(prefix), rest, "", {}, site)
	return at + 1
}

@(private)
plan_finish :: proc(b: ^Builder) {
	p := b.p
	for block, end in b.ends {
		count := int(end - block)
		if count <= 0 { continue }
		cap_n := u32(4)
		for int(cap_n) < count * 2 {
			cap_n <<= 1
		}
		off := u32(len(b.slots))
		if resize(&b.slots, len(b.slots) + int(cap_n)) != nil {
			refuse_plan(b, .No_Memory)
			return
		}
		table := b.slots[off:][:cap_n]
		bits := u64(0)
		for k in 0 ..< count {
			name := b.meta[int(block) + k].name
			if len(name) > 0 { bits |= name_bit(name) }
			at := member_hash(name) & (cap_n - 1)
			for table[at] != 0 {
				at = (at + 1) & (cap_n - 1)
			}
			table[at] = u32(k + 1)
		}
		b.meta[end].block, b.meta[end].slots, b.meta[end].slots_n, b.meta[end].name_bits = block, off, cap_n, bits
	}
	for &m in b.meta {
		if m.block >= 0 && m.members > 0 {
			if end, ok := b.ends[m.block]; ok {
				m.slots, m.slots_n, m.name_bits = b.meta[end].slots, b.meta[end].slots_n, b.meta[end].name_bits
			}
		}
	}
	solo, serr := make([]Record, len(b.records) * 2, p.allocator)
	if serr != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	shrink(&b.records)
	shrink(&b.meta)
	shrink(&b.uses)
	shrink(&b.leaves)
	shrink(&b.slots)
	p.records, p.solo, p.meta, p.uses, p.leaves, p.slots = b.records[:], solo, b.meta[:], b.uses[:], b.leaves[:], b.slots[:]

	for &r, i in p.records {
		m := &p.meta[i]
		u := &p.uses[i]
		if r.kind == .Checked {
			if m.block >= 0 { r.first = &p.records[m.block] }
			r.members_u16 = u16(min(m.members, 65535)) if m.members > 0 else 0
			r.req_end_u16 = u16(min(m.required_end, 65535)) if m.required_end > 0 else 0
			ff: Record_Fast_Flags
			if r.rule_set == 0 {
				r.leaf_kinds = rules.EVERY_KIND
				ff += {.Pure_String, .Pure_Number, .Pure_Scalar, .Pure_Array}
			} else {
				l := &p.leaves[r.rule_set - 1]
				r.leaf_kinds = l.kinds
				if !l.has_enum {
					ff += {.Pure_Scalar}
					if l.min_length == 0 && l.max_length == max(u64) && l.pattern == nil && l.formats == {} {
						ff += {.Pure_String}
					}
					if !l.minimum.set && !l.maximum.set && l.multiple_of == nil && !l.integer_spelled {
						ff += {.Pure_Number}
					}
					if l.min_items == 0 && l.max_items == max(u64) {
						ff += {.Pure_Array}
					}
				}
			}
			if len(u.requires) > 0 {
				ff += {.Has_Deps}
			}
			if m.members == 0 && u.additional == 0 && u.pattern == 0 && u.keys == 0 && !m.counted && len(u.requires) == 0 {
				ff += {.Trivial_Object}
			}
			if !u.inside && .Pure_Array in ff {
				ff += {.Trivial_Array}
			}
			r.fast_flags = ff
		}
		solo[2 * i] = r
		solo[2 * i].word = NO_KEY
		solo[2 * i + 1] = Record{word = NO_KEY, meta = u32(i), kind = .End}
	}
	for &r, i in p.records {
		if .Held not_in r.flags { continue }
		u := &p.uses[i]
		aps := u.verdict if len(u.verdict) > 0 else u.applies
		if len(aps) == 1 && (aps[0].kind == .One || aps[0].kind == .Any) {
			u.obj_arm = unique_kind_arm(p, aps[0].arms, .Object)
			u.arr_arm = unique_kind_arm(p, aps[0].arms, .Array)
		}
	}
	p.root = &p.records[1]
}

@(private = "file")
unique_kind_arm :: proc(p: ^Plan, arms: []i32, kind: rules.Kind) -> i32 {
	hits := 0
	which := i32(-1)
	for arm in arms {
		if record_accepts_kind(p, arm, kind, 0) {
			hits += 1
			which = arm
			if hits > 1 { return 0 }
		}
	}
	return -1 if hits == 0 else which + 1
}

@(private)
record_accepts_kind :: proc(p: ^Plan, rec_idx: i32, kind: rules.Kind, depth: int) -> bool {
	if depth >= 8 || rec_idx < 0 || int(rec_idx) >= len(p.records) { return true }
	r := &p.records[rec_idx]
	if .Held not_in r.flags { return kind in r.leaf_kinds }
	u := &p.uses[rec_idx]
	if u.verdict_rec > 0 { return record_accepts_kind(p, u.verdict_rec - 1, kind, depth + 1) }
	for &ap in u.applies {
		#partial switch ap.kind {
		case .Own, .Ref:
			if !record_accepts_kind(p, ap.record, kind, depth + 1) { return false }
		case .All:
			for arm in ap.arms {
				if !record_accepts_kind(p, arm, kind, depth + 1) { return false }
			}
		case .Any, .One:
			any_ok := false
			for arm in ap.arms {
				if record_accepts_kind(p, arm, kind, depth + 1) {
					any_ok = true
					break
				}
			}
			if !any_ok { return false }
		}
	}
	return true
}

@(private)
key_of :: proc "contextless" (r: ^Record, name: string) {
	word, head, tail, ok := tape.expected_key(name)
	if !ok {
		r.word = NO_KEY
		return
	}
	r.word, r.head, r.tail = word, head, tail
}

@(private)
name_bit :: #force_inline proc "contextless" (name: string) -> u64 #no_bounds_check {
	return u64(1) << ((u32(name[0]) * 31 + u32(name[len(name) - 1]) * 5 + u32(len(name))) & 63)
}

@(private)
member_hash :: #force_inline proc "contextless" (name: string) -> u32 #no_bounds_check {
	p, n := raw_data(name), len(name)
	h := u64(0x9E3779B97F4A7C15) ~ u64(n)
	if n >= 8 {
		if n <= 16 {
			a := intrinsics.unaligned_load((^u64)(p))
			b := intrinsics.unaligned_load((^u64)(p[n - 8:]))
			h = (h ~ a) * 0xBF58476D1CE4E5B9
			h = (h ~ b) * 0x94D049BB133111EB
			return u32(h ~ (h >> 32))
		}
		i := 0
		for ; i + 8 <= n; i += 8 {
			h = (h ~ intrinsics.unaligned_load((^u64)(p[i:]))) * 0xBF58476D1CE4E5B9
		}
		if i < n { h = (h ~ intrinsics.unaligned_load((^u64)(p[n - 8:]))) * 0x94D049BB133111EB }
		return u32(h ~ (h >> 32))
	}
	if n >= 4 {
		a := u64(intrinsics.unaligned_load((^u32)(p)))
		b := u64(intrinsics.unaligned_load((^u32)(p[n - 4:])))
		h = (h ~ a ~ (b << 32)) * 0xBF58476D1CE4E5B9
		return u32(h ~ (h >> 32))
	}
	tail := u64(0)
	for j in 0 ..< n {
		tail |= u64(p[j]) << (8 * uint(j))
	}
	h = (h ~ tail) * 0xBF58476D1CE4E5B9
	return u32(h ~ (h >> 32))
}

@(private)
member_find :: #force_inline proc "contextless" (p: ^Plan, m: ^Meta, name: string) -> i32 #no_bounds_check {
	if m.slots_n == 0 { return -1 }
	if len(name) > 0 && (m.name_bits & name_bit(name)) == 0 { return -1 }
	mask := m.slots_n - 1
	table := p.slots[m.slots:]
	at := member_hash(name) & mask
	for {
		slot := table[at]
		if slot == 0 { return -1 }
		idx := i32(slot - 1)
		if p.meta[m.block + idx].name == name { return idx }
		at = (at + 1) & mask
	}
}
