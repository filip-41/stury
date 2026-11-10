package model

import "base:runtime"
import regex "../regex"
import spell "../spell"
import core ".."
import rules "../rules"
import typed "../typed"
import write "../write"

// Judges `v` by its model's rules as a load of `marshal(v)` judges that text: each value's rules, and what a write
// refuses, a float that is not finite and an enum value no member has. A number is judged as its text, the shortest
// spelling that reads back as its value. Every refusal goes to `sink` as a `core.Error_Entry` with its path, up to the
// sink's limit, and with no sink the first ends the walk. A write-only member is not walked, as a write skips it. Returns
// the first. It allocates nothing for a value that passes but where it lists a map or a captured struct's members, or
// matches a pattern.
validate :: proc(m: ^Model($T), v: ^T, sink: ^typed.Sink = nil) -> core.Error {
	return validate_value(&m.plan, v, sink)
}

@(private)
validate_value :: proc(plan: ^typed.Plan, v: rawptr, sink: ^typed.Sink) -> core.Error {
	j := Judging{visitor = {call = write.Visit(judge)}, plan = plan, sink = sink}
	ended := write.visit(plan, v, &j.visitor)
	regex.scratch_destroy(&j.scratch)
	delete(j.steps)
	if j.first.kind == .None {
		j.first = ended
	}
	typed.own_names(&j.first)
	return core.error_of(j.first)
}

@(private)
Judging :: struct {
	using visitor: write.Visitor,
	plan:          ^typed.Plan,
	sink:          ^typed.Sink,
	first:         core.Typed_Error,
	steps:         [dynamic]core.Step,
	scratch:       regex.Scratch,
}

// The visitor of `validate`: judges the value `at` of record `f` by its rules, or reports the walk's refusal `kind`.
@(private)
judge :: proc(v: ^write.Visitor, f: ^typed.Field, at: uintptr, kind: core.Typed_Error_Kind) -> bool {
	j := (^Judging)(v)
	fails := rules.Failures{kind} if kind != .None else judged(j, f, at)
	for k in fails {
		if !report(j, k) {
			return false
		}
	}
	return true
}

// The rules of record `f`'s leaf that the value at `at` fails.
@(private)
judged :: proc(j: ^Judging, f: ^typed.Field, at: uintptr) -> rules.Failures {
	l := &j.plan.leaves[j.plan.meta[f.meta].rule_set - 1]
	buf: [max(spell.F64_ROOM, spell.INT_ROOM)]u8
	#partial switch f.kind {
	case .String, .Cstring:
		s := string((^cstring)(at)^) if f.kind == .Cstring else (^string)(at)^
		fails: rules.Failures
		if l.has_enum && !rules.enum_has(l, .String, s) {
			fails += {.Not_A_Member}
		}
		return fails + rules.judge_string(l, s, &j.scratch if l.pattern != nil else nil)
	case .I8 ..= .U64:
		signed := f.kind <= .I64
		bits := write.loaded(at, 1 << (uint(f.kind) - uint(typed.Read_Kind.I8 if signed else typed.Read_Kind.U8)), signed)
		small := Maybe(i64)(i64(bits)) if signed || bits <= u64(max(i64)) else nil
		return rules.judge_number(l, "" if l.fast && small != nil else string(buf[:write.int_text(&buf[0], f.kind, at)]), small)
	case .F32:
		x := (^f32)(at)^
		return {} if x - x != 0 else rules.judge_number(l, string(buf[:spell.f32_text(&buf[0], x)]), nil)
	case .F64:
		x := (^f64)(at)^
		return {} if x - x != 0 else rules.judge_number(l, string(buf[:spell.f64_text(&buf[0], x)]), nil)
	case .Slice, .Dynamic:
		return rules.judge_count(u64((^runtime.Raw_Slice)(at).len), l.min_items, l.max_items)
	case .Array:
		return rules.judge_count(u64(j.plan.meta[f.meta].count), l.min_items, l.max_items)
	case .Fixed_List:
		return rules.judge_count(u64((^int)(at + uintptr(j.plan.meta[f.meta].tag))^), l.min_items, l.max_items)
	case .Map:
		return rules.judge_count(u64((^runtime.Raw_Map)(at).len), l.min_members, l.max_members)
	}
	return {}
}

// Records a refusal of kind `k` at the record the visitor is called at, and says whether the walk goes on.
@(private)
report :: proc(j: ^Judging, k: core.Typed_Error_Kind) -> bool {
	clear(&j.steps)
	if !write.visit_path(&j.visitor, &j.steps) {
		j.first = {kind = .No_Memory}
		return false
	}
	if j.first.kind == .None {
		j.first.kind = k
		#reverse for s in j.steps {
			typed.path_add(&j.first, s)
		}
		typed.path_close(&j.first)
	}
	c := j.sink
	if c == nil || !typed.sink_room(c, context.allocator) {
		return false
	}
	if !typed.sink_entry(c, core.Error_Entry{kind = k, record = c.record}, j.steps[:], nil, false) {
		j.first = {kind = .No_Memory}
		return false
	}
	return true
}
