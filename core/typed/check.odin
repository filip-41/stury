package typed

import "base:runtime"
import "core:strconv"
import regex "../regex"
import spell "../spell"
import core ".."
import rules "../rules"

// A read that reports every refusal to its sink as a `core.Error_Entry` with the full path, a `Reader` with the hook the
// checks of a model add to. `check_start` starts one.
Check :: struct {
	using reader: Reader,
	// The matcher's stack, which a pattern's search grows in the read's temp allocator once and reuses.
	scratch: regex.Scratch,
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

// The value `t` at a `Checked` record: judges a scalar by the record's leaf, and opens a container a rule reads inside,
// which its close judges, so a container's failure spans it. A container's frame keeps its open byte in `data` and its
// kind, and an object's frame its last key's span and spelling in `owner` and `target`. `c` counts the values of the
// open container.
@(private)
check_value :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	fld := field_at(regs.b)
	m, u := &h.plan.meta[fld.meta], &h.plan.uses[fld.meta]
	next := core.Hook_Regs{regs.a, regs.b + (size_of(Field) if u.step else 0), regs.c + 1}
	l: ^rules.Leaf
	if m.rule_set > 0 {
		l = &h.plan.leaves[m.rule_set - 1]
	}
	first: ^Field
	#partial switch t.kind {
	case .Object:
		if m.members > 0 || u.additional != 0 || u.keys != 0 || l != nil && (l.min_members > 0 || l.max_members < max(u64) || container_fails(l, .Object) != {}) {
			// The block's `Never` record predicts no key, so each key reaches `check_key` and its name rules.
			first = &h.plan.fields[m.block + m.members] if u.keys != 0 else fld.first
		}
	case .Array:
		if u.inside || l != nil && (l.min_items > 0 || l.max_items < max(u64) || container_fails(l, .Array) != {}) {
			first = &h.plan.fields[u.items]
		}
	case:
		if l != nil && judge_value(h, regs, t, l) == .Stop {
			return next, .Stop
		}
		return next, .Next
	}
	if first == nil {
		return next, .Skip
	}
	f := &h.frames[h.sp]
	h.sp += 1
	f.a, f.b, f.c, f.seen, f.run, f.extra = regs.a, regs.b, regs.c, 0, nil, nil
	f.data, f.kind, f.owner, f.target = rawptr(uintptr(t.lo)), t.kind, nil, 0
	return {NO_LIMIT, u64(uintptr(first)), 0}, .Next
}

// Judges the scalar `t` by `l`: its kind, its enum and the rules of its kind. A plain integer an i64 holds is judged here
// when `l.fast` says its bounds are whole, and the other rules are cold.
@(private)
judge_value :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, l: ^rules.Leaf) -> core.Action {
	fails: rules.Failures
	ok: bool
	#partial switch t.kind {
	case .Null:
		ok = .Null in l.kinds
	case .True, .False:
		ok = .Bool in l.kinds
	case .String:
		ok = .String in l.kinds
		if l.has_enum || l.min_length > 0 || l.max_length < max(u64) || l.pattern != nil || l.formats != {} {
			fails = judge_string(h, t, l, nil)
		}
	case .Number:
		if l.fast && t.spelling & core.NUMBER_KIND_MASK == 0 && core.number_shape(t.spelling) <= 19 && h.mant >> 63 == 0 {
			v := -i64(h.mant) if raw_data(h.src)[t.lo] == '-' else i64(h.mant)
			ok = l.kinds & {.Integer, .Number} != {}
			if l.minimum.set && (v < l.minimum.int || v == l.minimum.int && l.minimum.exclusive) {
				fails += {.Below_Minimum}
			}
			if l.maximum.set && (v > l.maximum.int || v == l.maximum.int && l.maximum.exclusive) {
				fails += {.Above_Maximum}
			}
		} else {
			ok = .Number in l.kinds
			if !ok && .Integer in l.kinds || l.has_enum || l.minimum.set || l.maximum.set || l.multiple_of != nil {
				fails = judge_number(h, t, l, &ok)
			}
		}
	}
	if !ok {
		fails += {.Not_Allowed} if l.kinds == {} else {.Wrong_Kind}
	}
	if l.has_enum && t.kind != .String && t.kind != .Number {
		fails += judge_operand(h, t, l)
	}
	if fails == {} {
		return .Next
	}
	lo, hi := core.scalar_ends(t)
	return check_report(h, regs, l, t.kind, fails, lo, hi)
}

// Whether a value that is no string and no number fails `l`'s enum index.
@(cold)
@(private)
judge_operand :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> rules.Failures {
	context = h.ctx
	return {} if rules.enum_has(l, t.kind, "") else {.Not_A_Member}
}

// The rules of `l` a string fails, from its decoded text: `key` when it is read already, else `t`'s.
@(cold)
@(private)
judge_string :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf, key: Maybe(string)) -> (fails: rules.Failures) {
	context = h.ctx
	context.allocator = context.temp_allocator
	buf: [TEXT_ROOM]u8 = ---
	text, read := key.?
	if !read {
		if text, read = decoded_text(h, t, buf[:]); !read {
			return {.No_Memory}
		}
	}
	if l.has_enum && !rules.enum_has(l, .String, text) {
		fails += {.Not_A_Member}
	}
	return fails + rules.judge_string(l, text, &h.scratch)
}

// The text a decoded string up to this long is decoded into on the stack. A longer one goes to the temp allocator.
@(private)
TEXT_ROOM :: 256

// `t`'s decoded text, into `buf` when it fits there.
@(private)
decoded_text :: proc "contextless" (h: ^Check, t: core.Token, buf: []u8) -> (string, bool) {
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(raw_data(h.src)[t.lo:][:t.n]), true
	}
	context = h.ctx
	if 3 * int(t.n) + 4 <= len(buf) {
		return h.plan.readers.text(&h.view, t, buf)
	}
	return core.token_text(h.plan.readers, &h.view, t, context.temp_allocator)
}

// The rules of `l` a number fails, and in `kind_ok` whether it passes `l`'s integer kind. A plain decimal is judged by
// its text, and a number a format spells otherwise by the decimal its value writes as. NaN and the infinities fail
// every bound.
@(cold)
@(private)
judge_number :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf, kind_ok: ^bool) -> (fails: rules.Failures) {
	context = h.ctx
	text := string(raw_data(h.src)[t.lo:][:t.n])
	small: Maybe(i64)
	plain := core.number_shape(t.spelling) < 32
	buf: [max(spell.F64_ROOM, 24)]u8 = ---
	if t.spelling & core.NUMBER_KIND_MASK > core.NUMBER_DECIMAL {
		n, read := h.plan.readers.number(&h.view, t)
		switch {
		case !read:
			return {.Wrong_Kind}
		case n.kind == .Int:
			text, small = strconv.write_int(buf[:], i64(n.bits), 10), i64(n.bits)
		case n.kind == .Uint:
			text = strconv.write_uint(buf[:], n.bits, 10)
		case n.kind == .Float && abs(transmute(f64)n.bits) <= max(f64):
			text = string(buf[:spell.f64_text(&buf[0], transmute(f64)n.bits)])
			plain = false
		case:
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

// Reports each of `fails`, the rules a value of kind `of` at `regs` fails by `l`, spanning `lo` to `hi`, under the
// keyword `keyword_of` names, or `keyword`. Returns `.Stop` for a read with no sink.
@(cold)
@(private)
check_report :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, l: ^rules.Leaf, of: core.Kind, fails: rules.Failures, lo, hi: u64, keyword := "") -> core.Action {
	context = h.ctx
	for kind in fails {
		note(h, regs, {kind = kind, at = lo}, hi, keyword if keyword != "" else keyword_of(l, kind, of))
		if h.sink == nil {
			return .Stop
		}
	}
	return .Next
}

// The keyword of `l` that holds the rule a value of kind `of` fails as `kind`, none for a value its use takes nowhere,
// whose keyword path ends at the use.
@(private)
keyword_of :: proc "contextless" (l: ^rules.Leaf, kind: core.Typed_Error_Kind, of: core.Kind) -> string {
	#partial switch kind {
	case .Not_A_Member:
		return "const" if l.constant else "enum"
	case .Below_Minimum:
		return "exclusiveMinimum" if l.minimum.exclusive else "minimum"
	case .Above_Maximum:
		return "exclusiveMaximum" if l.maximum.exclusive else "maximum"
	case .Too_Few:
		return "minProperties" if of == .Object else "minItems"
	case .Too_Many:
		return "maxProperties" if of == .Object else "maxItems"
	}
	return KEYWORDS[kind]
}

@(private)
@(rodata)
KEYWORDS := #partial [core.Typed_Error_Kind]string {
	.Wrong_Kind    = "type",
	.Not_Multiple  = "multipleOf",
	.Too_Short     = "minLength",
	.Too_Long      = "maxLength",
	.No_Match      = "pattern",
	.Bad_Format    = "format",
	.Missing_Field = "required",
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

// A key of an open object at a `Checked` record: judges it by the object's name rules, and moves the cursor to the
// member it names, to the record of the members no record names, or past the member.
@(private)
check_key :: proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	regs := regs
	f := &h.frames[h.sp - 1]
	owner := field_at(f.b)
	m, u := &h.plan.meta[owner.meta], &h.plan.uses[owner.meta]
	f.owner, f.target = (^Field)(uintptr(t.lo)), uintptr(t.n) | uintptr(t.spelling) << 32
	buf: [TEXT_ROOM]u8 = ---
	key, ok := decoded_text(h, t, buf[:])
	if !ok {
		return regs, .Stop
	}
	if u.keys != 0 {
		l := &h.plan.leaves[u.keys - 1]
		fails := judge_string(h, t, l, key) if .String in l.kinds else {.Wrong_Kind}
		if fails != {} {
			lo, hi := core.scalar_ends(t)
			h.sp -= 1
			action := check_report(h, {f.a, f.b, f.c}, l, .String, fails, lo, hi, "propertyNames")
			h.sp += 1
			if action == .Stop {
				return regs, .Stop
			}
		}
	}
	if m.members > 0 {
		at := ([^]Field)(owner.first)
		// The cursor leaves where it stood, so the members it passed are marked first.
		mark_run(h, f, owner, (^Field)(uintptr(regs.b)))
		f.seen |= SEEN_ON
		if len(key) == 0 || m.names & name_bit(key) != 0 {
			for i in 0 ..< int(m.members) {
				if h.plan.meta[at[i].meta].name == key {
					seen_set(h, f, owner, i)
					next := &at[i + 1]
					if u.keys != 0 {
						next = &h.plan.solo[2 * (int(uintptr(&at[i]) - uintptr(raw_data(h.plan.fields))) / size_of(Field)) + 1]
					}
					regs.b, f.run = u64(uintptr(next)), &at[i + 1]
					return regs, .Next
				}
			}
		}
	}
	if u.additional != 0 {
		regs.b = u64(uintptr(&h.plan.fields[u.additional]))
		return regs, .Next
	}
	regs.c += 1
	return regs, .Skip
}

// The close of a container at a `Checked` record: judges an object's required members and its count, or an array's,
// then gives back the registers past the container.
@(cold)
@(private)
check_close :: #force_no_inline proc "contextless" (h: ^Check, f: ^Frame, owner: ^Field, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	m := &h.plan.meta[owner.meta]
	at := core.Hook_Regs{f.a, f.b, f.c}
	back := core.Hook_Regs{f.a, f.b + (size_of(Field) if h.plan.uses[owner.meta].step else 0), f.c + 1}
	lo, hi := u64(uintptr(f.data)), t.lo + u64(t.n)
	if f.kind == .Object && m.required_end > 0 {
		context = h.ctx
		for i := missing_member(h, f, owner, regs, 0); i >= 0; i = missing_member(h, f, owner, regs, i + 1) {
			// The object's frame is reopened for the path, whose last step the name replaces.
			h.sp += 1
			note(h, at, {kind = .Missing_Field, at = lo, steps = {0 = core.Name(h.plan.meta[m.block + i].name)}, n_steps = 1}, hi, "required")
			h.sp -= 1
			if h.sink == nil {
				return back, .Stop
			}
		}
	}
	if m.rule_set == 0 {
		return back, .Next
	}
	l := &h.plan.leaves[m.rule_set - 1]
	fails := container_fails(l, f.kind)
	fails += rules.judge_count(regs.c, l.min_members, l.max_members) if f.kind == .Object else rules.judge_count(regs.c, l.min_items, l.max_items)
	if fails != {} && check_report(h, at, l, f.kind, fails, lo, hi) == .Stop {
		return back, .Stop
	}
	return back, .Next
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

// Judges a scalar a type's plan stored by its record's rules, which the record's `Meta.rule_set` names. A string
// record's stored text is its decoded text.
@(cold)
@(private)
check_rules :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, fld: ^Field, dest: uintptr) -> core.Action {
	l := &h.plan.leaves[h.plan.meta[fld.meta].rule_set - 1]
	fails: rules.Failures
	#partial switch t.kind {
	case .String:
		stored: Maybe(string)
		if fld.kind == .String {
			stored = (^string)(dest)^
		}
		fails = judge_string(h, t, l, stored)
	case .Number:
		kind_ok := true
		fails = judge_number(h, t, l, &kind_ok)
	}
	if fails == {} {
		return .Next
	}
	context = h.ctx
	lo, hi := core.scalar_ends(t)
	for kind in fails {
		note(h, regs, {kind = kind, at = lo}, hi)
		if h.sink == nil {
			return .Stop
		}
	}
	return .Next
}

// The step of the value at `at` inside the container `f` of the `Checked` record `owner`: its index, the name of the
// member whose record reads it, or the text of the object's last key.
@(private)
checked_step :: proc(h: ^Reader, f: ^Frame, owner: ^Field, at: core.Hook_Regs) -> (core.Step, bool) {
	if f.kind == .Array {
		return core.Index(at.c), true
	}
	m := &h.plan.meta[owner.meta]
	if rec := i32(field_at(at.b).meta); rec >= m.block && rec < m.block + m.members {
		return core.Name(h.plan.meta[rec].name), true
	}
	key := core.Token{lo = u64(uintptr(f.owner)), n = u32(f.target), kind = .String, role = .Key, spelling = u16(f.target >> 32)}
	// The text is the input's or the temp allocator's, never the reader's.
	text, ok := core.token_text(h.plan.readers, &h.view, key, context.temp_allocator)
	return core.Name(text), ok
}
