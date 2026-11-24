package cbor

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed reads: an item read into an Odin value during the walk, with no document between them. A struct's members are
// named by their tags under `cbor`, or else under `stury`. A `time.Time` takes tag 0's date-time and tag 1's seconds,
// and every other tag is passed to its content.

Plan :: typed.Plan
Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Typed_Refusal :: typed.Typed_Refusal
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "cbor"

// The plan of `T` for CBOR reads, as `typed.plan_make` makes it, which `unmarshal` takes in `Unmarshal_Options.plan`.
@(require_results)
plan_make :: proc($T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (Plan, tape.Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Reads `src`, an item of `spec`, into `target`, as `typed.read` reads, where a string with nothing to decode is a
// definite text string. Needs `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
unmarshal :: #force_inline proc(src: []u8, target: ^$T, spec := Spec.Cbor, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_type(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_type :: #force_inline proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Cbor:
		return unmarshal_spec(src, target, T, .Cbor, read, opts, allocator)
	case .Preferred:
		return unmarshal_spec(src, target, T, .Preferred, read, opts, allocator)
	case .Deterministic:
		return unmarshal_spec(src, target, T, .Deterministic, read, opts, allocator)
	case .Length_First:
		return unmarshal_spec(src, target, T, .Length_First, read, opts, allocator)
	}
	return tape.Bad_Option{"spec"}
}

// A text in pieces is refused by the read, so only a step budget needs the lax walk.
@(private)
unmarshal_spec :: #force_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	lax := opts.budget.steps != 0
	if opts.dups == .Refuse {
		return unmarshal_as(src, target, T, S, true, true, read, opts, allocator) if lax else unmarshal_as(src, target, T, S, false, true, read, opts, allocator)
	}
	return unmarshal_as(src, target, T, S, true, false, read, opts, allocator) if lax else unmarshal_as(src, target, T, S, false, false, read, opts, allocator)
}

@(private)
unmarshal_as :: #force_no_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $LAX, $REFUSE: bool, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	when REFUSE {
		refusing :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Refusing_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			on :: #force_inline proc "contextless" (h: ^typed.Refusing_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
				if t.role == .Tag {
					note_epoch(&h.epoch, h.base, t)
				}
				return typed.refusing_hook(h, s, t, number_in_place)
			}
			end, err, tolerated := walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
			return end, typed.refusing_end(h, err, &RULES), tolerated
		}
		return typed.read(src, target, T, &FORMATS[S], TAG, opts, read, allocator, typed.Refusing_Reader, refusing)
	} else {
		walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Text_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			on :: #force_inline proc "contextless" (h: ^typed.Text_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
				if t.role == .Tag {
					note_epoch(&h.epoch, h.base, t)
				}
				return typed.text_hook(h, s, t, number_in_place)
			}
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
		}
		return typed.read(src, target, T, &FORMATS[S], TAG, opts, read, allocator, typed.Text_Reader, walk)
	}
}

// Sets `epoch` to where tag fact `t` of the item at `base` ends when it is tag 1, whose number of seconds since the Unix
// epoch a `time.Time` takes.
@(private)
note_epoch :: #force_no_inline proc "contextless" (epoch: ^u64, base: [^]u8, t: tape.Token) {
	if t.kind == .Number {
		if n := number_value(base[:t.lo + u64(t.n)], t); n.kind == .Int && n.bits == 1 {
			epoch^ = t.lo + u64(t.n)
		}
	}
}
