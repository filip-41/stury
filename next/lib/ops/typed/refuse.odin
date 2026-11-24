package typed

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A value the read's type does not take ends the read with `tape.Fault{kind = .Refused}`, whose detail is a `Refusal`.
// The walk still judges the rest of the text, with no more tokens kept, so a text that is not one of its format fails as
// its validate does, and its fault is the read's error.

// Why a typed read refused a value, the detail of its fault.
Refusal :: enum u8 {
	None,
	Expected_Integer,
	Expected_Number,
	Expected_String,
	Expected_Bool,
	Expected_Object,
	Expected_Array,
	Expected_Name, // an enum's member by its name
	Expected_Date_Time,
	Above_Maximum, // a number past the largest value its type holds
	Below_Minimum,
	Not_A_Member, // a name or value no member of the enum has
	Too_Few, // a fixed array's elements
	Too_Many,
	Missing_Field, // a `required` member absent from its object, named by the path's last step
	Unknown_Field, // a key the type does not name, under `refuse_unknown`
	No_Arm, // a value no arm of the union takes
	Bad_Date_Time, // a string that is no RFC 3339 date-time with an offset
	Out_Of_Range, // a date-time `time.Time` does not hold
}

@(rodata)
RULES := tape.Rules{"typed", {
	{},
	{"expected_integer", "Expected an integer"},
	{"expected_number", "Expected a number"},
	{"expected_string", "Expected a string"},
	{"expected_bool", "Expected a boolean"},
	{"expected_object", "Expected an object"},
	{"expected_array", "Expected an array"},
	{"expected_name", "Expected an enum member's name"},
	{"expected_date_time", "Expected a date-time"},
	{"above_maximum", "Number above the type's maximum"},
	{"below_minimum", "Number below the type's minimum"},
	{"not_a_member", "Not a member of the enum"},
	{"too_few", "Fewer elements than the array holds"},
	{"too_many", "More elements than the array holds"},
	{"missing_field", "Required field missing"},
	{"unknown_field", "Field not in the type"},
	{"no_arm", "No union arm takes the value"},
	{"bad_date_time", "Invalid RFC 3339 date-time"},
	{"out_of_range", "Date-time out of range"},
}}

#assert(len(Refusal) == 19)

// The action a refused read answers token `t` with: a key's member and a container are passed, as the walk judges
// them with no token.
@(private)
dead_action :: #force_inline proc "contextless" (t: tape.Token) -> hook.Action {
	if t.role == .Key {
		return .Skip
	}
	return .Rest if t.kind == .Object || t.kind == .Array else .Next
}

// Refuses value token `t` at the registers `s` that read it.
@(private)
refuse_value :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, detail: Refusal) -> (hook.Regs, hook.Action) {
	head: u8
	if t.kind < .Array {
		head, _ = h.format.bounds(h.base[:h.len], t)
	}
	s := s
	return refuse_at(h, s, t, detail, t.lo - u64(head), h.sp, &s)
}

// Ends the read for memory refused at token `t`.
@(private)
refuse_memory :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if !h.dead {
		h.err = runtime.Allocator_Error.Out_Of_Memory
		settle_open(h, h.outer^ if h.outer != nil else s, h.sp)
		h.dead = true
	}
	h.sp = 1
	return dead_regs(), dead_action(t)
}

// Ends the read with refusal `detail` at byte `at`, the first refusal it meets. `n` frames are open, and the path to the
// value refused steps into each one's child, the last one's by the registers `leaf` when not nil, and then to member
// `name` when it is not empty.
@(private)
refuse_at :: proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, detail: Refusal, at: u64, n: int, leaf: ^hook.Regs, name := "") -> (hook.Regs, hook.Action) {
	if !h.dead {
		h.err = tape.Fault{at = at, rules = &RULES, kind = .Refused, detail = u8(detail)}
		s, leaf := s, leaf
		if h.outer != nil && n == h.sp {
			s = h.outer^
			if leaf != nil {
				leaf = h.outer
			}
		}
		if h.path != nil {
			fill_path(h, n, leaf, name)
		}
		settle_open(h, s, n)
		h.dead = true
	}
	h.sp = 1
	return dead_regs(), dead_action(t)
}

// Fills `Unmarshal_Options.path` with the steps from the target's root through the `n` frames open, as `refuse_at`
// takes them. A step the path's memory refuses is left out.
@(private)
fill_path :: proc "contextless" (h: ^Reader, n: int, leaf: ^hook.Regs, name: string) {
	context = h.ctx
	context.allocator = h.path.allocator if h.path.allocator.procedure != nil else h.caller
	clear(h.path)
	for k in 1 ..< n {
		child: hook.Regs
		if k + 1 < n {
			f := &h.frames[k + 1]
			child = {f.a, f.b, f.c}
		} else if leaf != nil {
			child = leaf^
		} else {
			break
		}
		f := &h.frames[k]
		owner := frame_owner(f)
		#partial switch owner.kind {
		case .Struct, .Required:
			r := (^Record)(uintptr(child.b) - size_of(Record))
			append(h.path, tape.Name(member_name(h, &h.plan.meta[r.meta])))
		case .Slice, .Dynamic, .Array:
			append(h.path, tape.Index((child.c - u64(uintptr(f.data))) / u64(h.plan.meta[owner.meta].size)))
		case .Map:
			append(h.path, tape.Name(key_span(h, f.key)))
		}
	}
	if name != "" {
		append(h.path, tape.Name(name))
	}
}

// The name a path gives member `m`: its key, or its Odin name when the key is one the plan spelled and the read made
// the plan, which it frees on return.
@(private)
member_name :: proc "contextless" (h: ^Reader, m: ^Meta) -> string {
	lo, n := uintptr(raw_data(h.plan.strings)), uintptr(len(h.plan.strings))
	if h.made && uintptr(raw_data(m.name)) - lo < n {
		return m.field
	}
	return m.name
}
