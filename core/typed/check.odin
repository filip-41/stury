package typed

import "base:runtime"
import "core:strconv"
import "core:strings"
import regex "../regex"
import spell "../spell"
import core ".."
import rules "../rules"

// A read that reports every refusal to its sink as a `core.Error_Entry` with the full path, a `Reader` with the hook the
// checks of a model add to. `check_start` starts one.
Check :: struct {
	using reader: Reader,
}

// A format's read of a whole text into `target`, a value of `plan`'s type `T`, under the handle `as`.
Text_Read :: #type proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Error

// A format's read of a node of a built document into `target`.
Node_Read :: #type proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Error

// What a format reads typed values with, where its `Services.reads` points. A plan copies the procedures. `check` and
// `node_check` are the reads that report to a `Sink`'s `entries`, nil for a format that has none.
Format_Reads :: struct {
	read, check:           Text_Read,
	node_read, node_check: Node_Read,
	build:                 Text_Build,
}

// Builds `src` as a document of the format `as` names, as a format's `Format_Reads` does for `write.marshal_value`.
Text_Build :: #type proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error)

// Starts a `Check` read, as `read_start` starts a read of the plan's own type. Its sink takes `core.Error_Entry`s.
check_start :: proc(c: ^Check, src: []u8, plan: ^Plan, as: core.As, T: typeid, target: rawptr, read: Read_Options, frames: []Frame, allocator: runtime.Allocator) -> (regs: core.Hook_Regs, err: core.Typed_Error) {
	regs, err = read_start(&c.reader, src, plan, as, T, target, read, frames, allocator)
	c.wide = true
	return
}

// Reads `src` into `target` as the plan's format does, `.Plan_Mismatch` when the plan has no read.
unmarshal_text :: proc(src: []u8, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator := context.allocator) -> core.Error {
	if plan == nil || plan.read == nil {
		return core.error_of(plan_mismatch(plan, nil, T))
	}
	return core.error_of(plan.read(src, plan.as, target, T, plan, read, allocator))
}

// Reads `src` into `target` as `unmarshal_text` does, with every refusal in `read.sink.entries`. Returns the first.
check_text :: proc(src: []u8, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator := context.allocator) -> core.Error {
	if plan == nil || plan.check == nil {
		return core.error_of(plan_mismatch(plan, nil, T))
	}
	return core.error_of(plan.check(src, plan.as, target, T, plan, read, allocator))
}

// The check of a description's plan, which `on_token_check` hands every token: the record before `regs.b` judges the
// value, and `regs.c` counts the values of the open container. A container no rule reads inside is skipped, unless it
// fails its kind or enum, which its close reports so that the failure spans it. A
// container's frame keeps the registers of its value, its open byte in `data` and its kind, and an object's frame its
// last key in `owner` and `target`, as its text and length.
@(private)
check_token :: proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if t.role == .Key {
		return check_key(h, regs, t)
	}
	if t.role != .Value {
		return regs, .Next
	}
	if t.kind == .End {
		return check_close(h, regs, t)
	}
	fld := field_at(regs.b)
	u := &h.plan.uses[fld.meta]
	next := core.Hook_Regs{regs.a, regs.b + (size_of(Field) if u.step else 0), regs.c + 1}
	l: ^rules.Leaf
	if u.leaf != 0 {
		l = &h.plan.leaves[u.leaf - 1]
		if check_value(h, regs, t, l) == .Stop {
			return next, .Stop
		}
	}
	inner: ^Field
	#partial switch t.kind {
	case .Object:
		if block := h.plan.meta[fld.meta].block; block >= 0 {
			inner = &h.plan.fields[block]
		} else if u.additional != 0 || u.keys != 0 || l != nil && (l.min_members > 0 || l.max_members < max(u64)) {
			inner = &h.plan.fields[ANY_RECORD + 1]
		}
	case .Array:
		if u.array != 0 {
			inner = &h.plan.fields[u.array]
		} else if l != nil && (l.min_items > 0 || l.max_items < max(u64)) {
			inner = &h.plan.fields[ANY_RECORD + 1]
		}
	case:
		return next, .Next
	}
	if inner == nil && l != nil && container_fails(l, t.kind) != {} {
		inner = &h.plan.fields[ANY_RECORD + 1]
	}
	if inner == nil {
		return next, .Skip
	}
	f := &h.frames[h.sp]
	h.sp += 1
	f.a, f.b, f.c, f.seen, f.run, f.extra = regs.a, regs.b, regs.c, 0, nil, nil
	f.data, f.kind, f.target = rawptr(uintptr(t.lo)), t.kind, 0
	return {0, u64(uintptr(inner)), 0}, .Next
}

// The record of `root_block` that reads a value whole, which judges nothing in a description's plan, so a container
// read only for its count gives each value to it.
@(private)
ANY_RECORD :: 2

// Judges the scalar `t` by `l`: its kind, its enum and the rules of its kind. A container is judged at its close.
@(private)
check_value :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, l: ^rules.Leaf) -> core.Action {
	fails: rules.Failures
	ok: bool
	#partial switch t.kind {
	case .Null:
		ok = .Null in l.kinds
	case .True, .False:
		ok = .Bool in l.kinds
	case .String:
		ok = .String in l.kinds
		if l.has_enum || l.min_length > 0 || l.max_length < max(u64) || l.pattern != nil {
			fails = check_string(h, t, l)
		}
	case .Number:
		ok = .Number in l.kinds
		if !ok && .Integer in l.kinds || l.has_enum || l.minimum.set || l.maximum.set || l.multiple_of != nil {
			fails = check_number(h, t, l, &ok)
		}
	case .Object, .Array:
		return .Next
	}
	if !ok {
		fails += {.Not_Allowed} if l.kinds == {} else {.Wrong_Kind}
	}
	if l.has_enum && t.kind != .String && t.kind != .Number {
		fails += check_operand(h, t, l)
	}
	if fails == {} {
		return .Next
	}
	return check_fails(h, regs, t, l, fails)
}

// Whether a value that is no string and no number fails `l`'s enum index.
@(cold)
@(private)
check_operand :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> rules.Failures {
	context = h.ctx
	return {} if rules.enum_has(l, t.kind, "") else {.Not_A_Member}
}

// The rules of `l` a string fails, from its decoded text.
@(cold)
@(private)
check_string :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> (fails: rules.Failures) {
	context = h.ctx
	context.allocator = context.temp_allocator
	text, ok := core.token_text(h.plan.readers, &h.view, t, context.temp_allocator)
	if !ok {
		return {.No_Memory}
	}
	if l.has_enum && !rules.enum_has(l, .String, text) {
		fails += {.Not_A_Member}
	}
	// The matcher's stack lives in the read's temp allocator, which the read's caller frees.
	scratch: regex.Scratch
	return fails + rules.judge_string(l, text, &scratch)
}

// The rules of `l` a number fails, and in `integer` whether it passes `l`'s integer kind. A plain decimal is judged by
// its text, and a number a format spells otherwise by the decimal its value writes as. Past binary64 such a number
// fails every bound.
@(cold)
@(private)
check_number :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf, kind_ok: ^bool) -> (fails: rules.Failures) {
	context = h.ctx
	text := string(raw_data(h.src)[t.lo:][:t.n])
	small: Maybe(i64)
	plain := core.number_shape(t.spelling) < 32
	if t.spelling & core.NUMBER_KIND_MASK > core.NUMBER_DECIMAL {
		n, read := h.plan.readers.number(&h.view, t)
		buf := make([]u8, max(spell.F64_ROOM, 24), context.temp_allocator)
		switch {
		case !read:
			return {.Wrong_Kind}
		case n.kind == .Int:
			text, small = strconv.write_int(buf, i64(n.bits), 10), i64(n.bits)
		case n.kind == .Uint:
			text = strconv.write_uint(buf, n.bits, 10)
		case n.kind == .Float && abs(transmute(f64)n.bits) <= max(f64):
			text = string(buf[:spell.f64_text(raw_data(buf), transmute(f64)n.bits)])
			plain = false
		case:
			// NaN and the infinities are numbers no bound, divisor or operand takes.
			kind_ok^ ||= .Number in l.kinds
			if l.minimum.set {
				fails += {.Below_Minimum}
			}
			if l.maximum.set {
				fails += {.Above_Maximum}
			}
			if l.multiple_of != nil {
				fails += {.Not_Multiple}
			}
			if l.has_enum {
				fails += {.Not_A_Member}
			}
			return
		}
		plain ||= n.kind != .Float
	} else if t.spelling & core.NUMBER_KIND_MASK == 0 && core.number_shape(t.spelling) <= 19 && h.mant >> 63 == 0 {
		small = -i64(h.mant) if text[0] == '-' else i64(h.mant)
	}
	if !kind_ok^ && .Integer in l.kinds {
		kind_ok^ = plain || !l.integer_spelled && rules.integral(spell.decimal_of(text))
	}
	if l.has_enum && !rules.enum_has(l, .Number, text) {
		fails += {.Not_A_Member}
	}
	return fails + rules.judge_number(l, text, small)
}

// Reports each of `fails`, the rules value `t` fails, under the keyword that holds the rule.
@(cold)
@(private)
check_fails :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, l: ^rules.Leaf, fails: rules.Failures) -> core.Action {
	lo, hi := core.scalar_ends(t)
	for kind in fails {
		if check_report(h, regs, kind, fail_keyword(l, kind, t.kind), lo, hi) == .Stop {
			return .Stop
		}
	}
	return .Next
}

// The keyword of `l` that holds the rule a value of kind `of` fails as `kind`.
@(private)
fail_keyword :: proc "contextless" (l: ^rules.Leaf, kind: core.Typed_Error_Kind, of: core.Kind) -> string {
	#partial switch kind {
	case .Wrong_Kind:
		return "type"
	case .Not_A_Member:
		return "const" if l.constant else "enum"
	case .Below_Minimum:
		return "exclusiveMinimum" if l.minimum.exclusive else "minimum"
	case .Above_Maximum:
		return "exclusiveMaximum" if l.maximum.exclusive else "maximum"
	case .Not_Multiple:
		return "multipleOf"
	case .Too_Short:
		return "minLength"
	case .Too_Long:
		return "maxLength"
	case .No_Match:
		return "pattern"
	case .Too_Few:
		return "minProperties" if of == .Object else "minItems"
	case .Too_Many:
		return "maxProperties" if of == .Object else "maxItems"
	}
	return ""
}

// The rules of `l` a container of kind `kind` fails before its count: its kind, and an enum, which holds no container.
@(private)
container_fails :: #force_inline proc "contextless" (l: ^rules.Leaf, kind: core.Kind) -> (fails: rules.Failures) {
	if (rules.Kind.Object if kind == .Object else rules.Kind.Array) not_in l.kinds {
		fails += {.Not_Allowed} if l.kinds == {} else {.Wrong_Kind}
	}
	if l.has_enum {
		fails += {.Not_A_Member}
	}
	return
}

// A key of the open object: moves the cursor to the member it names, to the record of the members no record names, or
// past the member, and judges the key by the object's `keys` rules.
@(private)
check_key :: proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	regs := regs
	f := &h.frames[h.sp - 1]
	owner := field_at(f.b)
	u := &h.plan.uses[owner.meta]
	key := string(raw_data(h.src)[t.lo:][:t.n])
	if t.spelling & core.SPELLING_DECODE != 0 {
		context = h.ctx
		ok: bool
		if key, ok = core.token_text(h.plan.readers, &h.view, t, context.temp_allocator); !ok {
			return regs, .Stop
		}
	}
	f.owner, f.target = (^Field)(raw_data(key)), uintptr(len(key))
	if u.keys != 0 {
		h.sp -= 1
		action := check_key_rules(h, {f.a, f.b, f.c}, t, &h.plan.leaves[u.keys - 1], key)
		h.sp += 1
		if action == .Stop {
			return regs, .Stop
		}
	}
	m := &h.plan.meta[owner.meta]
	if m.block >= 0 && (len(key) == 0 || m.names & name_bit(key) != 0) {
		at := ([^]Field)(owner.first)
		for i in 0 ..< int(m.members) {
			if h.plan.meta[at[i].meta].name == key {
				mark_run(h, f, owner, (^Field)(uintptr(regs.b)))
				f.seen |= SEEN_ON
				seen_set(h, f, owner, i)
				regs.b = u64(uintptr(&at[i + 1]))
				f.run = &at[i + 1]
				if h.plan.uses[at[i].meta].only_required && u.additional != 0 {
					regs.b = u64(uintptr(&h.plan.fields[u.additional]))
				}
				return regs, .Next
			}
		}
	}
	if m.block >= 0 {
		// The cursor leaves the block, so the members it passed are marked first.
		mark_run(h, f, owner, (^Field)(uintptr(regs.b)))
		f.seen |= SEEN_ON
	}
	if u.additional != 0 {
		regs.b = u64(uintptr(&h.plan.fields[u.additional]))
		return regs, .Next
	}
	regs.c += 1
	return regs, .Skip
}

// Judges an object's key `key` by the rules `l` of its names, as a string. The object is the value a failure names.
@(cold)
@(private)
check_key_rules :: #force_no_inline proc "contextless" (h: ^Check, at: core.Hook_Regs, t: core.Token, l: ^rules.Leaf, key: string) -> core.Action {
	context = h.ctx
	context.allocator = context.temp_allocator
	fails := rules.judge_string(l, key, &regex.Scratch{}) if .String in l.kinds else {.Wrong_Kind}
	if l.has_enum && !rules.enum_has(l, .String, key) {
		fails += {.Not_A_Member}
	}
	lo, hi := core.scalar_ends(t)
	for kind in fails {
		if check_report(h, at, kind, "propertyNames", lo, hi) == .Stop {
			return .Stop
		}
	}
	return .Next
}

// The close of a container: judges an object's required members and its count, or an array's, then gives back the
// registers past the container.
@(private)
check_close :: proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	h.sp -= 1
	f := &h.frames[h.sp]
	owner := field_at(f.b)
	u := &h.plan.uses[owner.meta]
	at := core.Hook_Regs{f.a, f.b, f.c}
	back := core.Hook_Regs{f.a, f.b + (size_of(Field) if u.step else 0), f.c + 1}
	lo, hi := u64(uintptr(f.data)), t.lo + u64(t.n)
	if f.kind == .Object && owner.kind == .Required {
		for i := missing_member(h, f, owner, regs, 0); i >= 0; i = missing_member(h, f, owner, regs, i + 1) {
			if check_report(h, at, .Missing_Field, "required", lo, hi, h.plan.meta[int(h.plan.meta[owner.meta].block) + int(i)].name) == .Stop {
				return back, .Stop
			}
		}
	}
	if u.leaf == 0 {
		return back, .Next
	}
	l := &h.plan.leaves[u.leaf - 1]
	fails := container_fails(l, f.kind)
	fails += rules.judge_count(regs.c, l.min_members, l.max_members) if f.kind == .Object else rules.judge_count(regs.c, l.min_items, l.max_items)
	for kind in fails {
		if check_report(h, at, kind, fail_keyword(l, kind, f.kind), lo, hi) == .Stop {
			return back, .Stop
		}
	}
	return back, .Next
}

// Reports that the value at `regs` fails the rule `keyword` as `kind`, spanning `lo` to `hi`, with `named` a member
// the path adds past the value, for one that is absent. Returns `.Stop` for a read with no sink.
@(cold)
@(private)
check_report :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, kind: core.Typed_Error_Kind, keyword: string, lo, hi: u64, named := "") -> core.Action {
	context = h.ctx
	steps := make([dynamic]core.Step, context.temp_allocator)
	words := make([dynamic]core.Step, context.temp_allocator)
	check_steps(h, regs, &steps, &words)
	if named != "" {
		append(&steps, core.Name(named))
	}
	if keyword != "" {
		append(&words, core.Name(keyword))
	}
	if h.first.kind == .None {
		h.first = {kind = kind, at = lo}
		for s in steps[max(0, len(steps) - core.MAX_ERROR_STEPS):] {
			path_add(&h.first, s)
		}
		h.first.truncated = len(steps) > core.MAX_ERROR_STEPS
		own_names(&h.first)
	}
	c := h.sink
	if c == nil {
		return .Stop
	}
	if len(c.entries) >= (c.max_errors if c.max_errors != 0 else 100) {
		c.truncated = true
		return .Next
	}
	if c.entries.allocator.procedure == nil {
		c.entries.allocator = h.ctx.allocator
	}
	e := core.Error_Entry{kind = kind, start = lo, end = max(hi, lo), record = c.record}
	e.path, e.keyword_path = owned_steps(steps[:], c.entries.allocator), owned_steps(words[:], c.entries.allocator)
	if e.path == nil && len(steps) > 0 || e.keyword_path == nil && len(words) > 0 {
		entry_destroy(&e, c.entries.allocator)
		c.truncated = true
	} else if _, grown := append(&c.entries, e); grown != nil {
		entry_destroy(&e, c.entries.allocator)
		c.truncated = true
	}
	return .Next
}

// The steps from the root to the value at `regs` into `path`, and in `words` the keywords that lead to its record.
@(private)
check_steps :: proc(h: ^Check, regs: core.Hook_Regs, path, words: ^[dynamic]core.Step) {
	for i in 1 ..< h.sp {
		f := &h.frames[i]
		at := regs if i == h.sp - 1 else core.Hook_Regs{h.frames[i + 1].a, h.frames[i + 1].b, h.frames[i + 1].c}
		owner, rec := field_at(f.b), field_at(at.b)
		if f.kind == .Array {
			append(path, core.Index(at.c))
			if h.plan.uses[rec.meta].step {
				append(words, core.Name("prefixItems"), core.Index(int(rec.meta) + 1 - int(h.plan.uses[owner.meta].array)))
			} else {
				append(words, core.Name("items"))
			}
			continue
		}
		m := &h.plan.meta[owner.meta]
		if m.block >= 0 && i32(rec.meta) >= m.block && i32(rec.meta) < m.block + m.members {
			append(path, core.Name(h.plan.meta[rec.meta].name))
			append(words, core.Name("properties"), core.Name(h.plan.meta[rec.meta].name))
		} else {
			append(path, core.Name(string(([^]u8)(f.owner)[:f.target])))
			append(words, core.Name("additionalProperties"))
		}
	}
}

// A copy of `steps` from `allocator` with its names copied, nil when it does not fit in memory.
@(private)
owned_steps :: proc(steps: []core.Step, allocator: runtime.Allocator) -> []core.Step {
	out, failed := make([]core.Step, len(steps), allocator)
	if failed != nil {
		return nil
	}
	for s, i in steps {
		out[i] = s
		if name, named := s.(core.Name); named {
			text, cloned := strings.clone(string(name), allocator)
			if cloned != nil {
				entry_destroy(&core.Error_Entry{path = out[:i]}, allocator)
				delete(out, allocator)
				return nil
			}
			out[i] = core.Name(text)
		}
	}
	return out
}

// Stores into the integer record `fld` a number spelled with a fraction or an exponent that is an integer, `1.0` or
// `1e2`, which a check takes where a read refuses it.
@(cold)
@(private)
store_integral :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, fld: ^Field, dest: uintptr) -> core.Typed_Error_Kind {
	if t.spelling & core.NUMBER_KIND_MASK != 0 {
		return .Wrong_Kind
	}
	context = h.ctx
	d := spell.decimal_of(string(raw_data(h.src)[t.lo:][:t.n]))
	if !rules.integral(d) {
		return .Wrong_Kind
	}
	v, fits := rules.decimal_i64(d)
	if !fits {
		return .Out_Of_Range
	}
	return store_int(u64(v) if v >= 0 else u64(-(v + 1)) + 1, v < 0, fld.kind, dest)
}

// Judges a scalar a type's plan stored at `dest` by its record's rules, which the record's `Meta.rule_set` names.
@(cold)
@(private)
check_rules :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, fld: ^Field, dest: uintptr) -> core.Action {
	context = h.ctx
	l := &h.plan.leaves[h.plan.meta[fld.meta].rule_set - 1]
	fails: rules.Failures
	#partial switch t.kind {
	case .String:
		text := (^string)(dest)^ if fld.kind == .String else ""
		if fld.kind != .String {
			ok: bool
			if text, ok = core.token_text(h.plan.readers, &h.view, t, context.temp_allocator); !ok {
				return .Stop
			}
		}
		context.allocator = context.temp_allocator
		fails = rules.judge_string(l, text, &regex.Scratch{})
	case .Number:
		kind_ok := true
		fails = check_number(h, t, l, &kind_ok)
	}
	lo, hi := core.scalar_ends(t)
	for kind in fails {
		note(h, regs, {kind = kind, at = lo}, hi)
		if h.sink == nil {
			return .Stop
		}
	}
	return .Next
}
