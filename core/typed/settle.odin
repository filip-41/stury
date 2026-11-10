package typed

import "base:runtime"
import core ".."
import rules "../rules"

// What a load does when one of a model's structs has been read: it records which members the input had and gives each
// member the input left out its default. Both read the struct's frame through `member_seen`.

// Judges the element or member count of the list, fixed array or map at the type record `owner`, which closes at `t`, by
// the record's rules.
@(cold)
@(private)
count_rules :: #force_no_inline proc "contextless" (h: ^Check, f: ^Frame, owner: ^Field, regs: core.Hook_Regs, t: core.Token) -> core.Action {
	m := &h.plan.meta[owner.meta]
	l := &h.plan.leaves[m.rule_set - 1]
	fails: rules.Failures
	#partial switch owner.kind {
	case .Slice, .Dynamic, .Fixed_List:
		n := u64(0)
		if f.data != nil {
			n = (regs.c - u64(uintptr(f.data))) / u64(m.elem_size)
		}
		fails = rules.judge_count(n, l.min_items, l.max_items)
	case .Array:
		fails = rules.judge_count(u64(m.count), l.min_items, l.max_items)
	case .Map:
		fails = rules.judge_count(u64((^runtime.Raw_Map)(f.data).len), l.min_members, l.max_members)
	}
	context = h.ctx
	for kind in fails {
		note(h, {f.a, f.b, f.c}, {kind = kind, at = t.lo}, t.lo + u64(t.n))
		if h.sink == nil {
			return .Stop
		}
	}
	return .Next
}

// Records what a load does with struct `owner`, whose block is at `at` and whose members are `members`: the read_only
// members' names, its `Fields_Set` and its members' defaults. A struct with a set or defaults closes through `settle`,
// as a cursor never reaches the record past its members. Refuses a struct that holds a set and loads more members
// than a set holds.
load_struct :: proc(b: ^Builder, owner: typeid, at: i32, f: ^Field, m: ^Meta, members: []Member, layout: ^Struct_Layout) {
	if layout.fields_set != 0 && len(members) > 8 * size_of(Fields_Set) {
		refuse_plan(b, .Bad_Tag, layout.set_name, "Fields_Set")
		b.err.want.type = owner
		return
	}
	n := 0
	for x in members {
		n += 1 if !x.required && x.make != nil else 0
	}
	if n == 0 && layout.fields_set == 0 && len(layout.read_only) == 0 {
		return
	}
	memory, made := plan_arena(b.p)
	if !made {
		refuse_plan(b, .No_Memory)
		return
	}
	sm := new(Struct_Model, memory)
	defaults, no_defaults := make([]Default, n, memory)
	read_only, no_names := make([]string, len(layout.read_only), memory)
	if sm == nil || no_defaults != nil || no_names != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	n = 0
	for x, i in members {
		if !x.required && x.make != nil {
			defaults[n] = {i32(i), x.make, x.data}
			n += 1
		}
	}
	copy(read_only, layout.read_only[:])
	sm^ = {fields_set = layout.fields_set, defaults = defaults, read_only = read_only}
	end := &b.meta[int(at) + len(members)]
	end.model, m.model = sm, sm
	if len(defaults) > 0 || layout.fields_set != 0 {
		sm.settle = settle
		f.kind = .Required
		m.required_end, end.required_end = i32(len(members)) + 1, i32(len(members)) + 1
	}
}

// Closes a struct of model `sm`: fills its `Fields_Set` and its defaults. Returns the refusal, if memory ran out.
@(cold)
@(private)
settle :: #force_no_inline proc "contextless" (h: ^Reader, sm: ^Struct_Model, f: ^Frame, owner: ^Field, regs: core.Hook_Regs) -> core.Typed_Error_Kind {
	context = h.ctx
	base := uintptr(f.data) if f.seen != 0 else uintptr(regs.c)
	at := ([^]Field)(owner.first)
	if sm.fields_set != 0 {
		set := (^Fields_Set)(base + uintptr(sm.fields_set - 1))
		for i in 0 ..< h.plan.meta[owner.meta].members {
			if member_seen(h, f, owner, regs, i) {
				set.bits[i / 64] |= 1 << uint(i % 64)
			}
		}
	}
	for d in sm.defaults {
		if !member_seen(h, f, owner, regs, d.member) && d.make(rawptr(base + uintptr(at[d.member].offset)), d.data, context.allocator) != nil {
			return .No_Memory
		}
	}
	return .None
}

// Whether `key` names a read_only member of the struct of `m`, which a load leaves out.
@(private)
read_only_key :: proc "contextless" (m: ^Meta, key: string) -> bool {
	if m.model != nil {
		for name in m.model.read_only {
			if name == key {
				return true
			}
		}
	}
	return false
}
