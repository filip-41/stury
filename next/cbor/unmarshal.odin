package cbor

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed reads: an item read into an Odin value during the walk, with no document between them. A struct's members are
// named by their tags under `cbor`, or else under `stury`. A `time.Time` takes tag 0's date-time and tag 1's seconds,
// and every other tag is passed to its content.

Plan :: typed.Plan
Plan_Options :: typed.Plan_Options
Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Refusal :: typed.Refusal
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "cbor"

// The plan of `T` for CBOR reads, which `unmarshal` takes in `Unmarshal_Options.plan`, in `allocator`, which
// `plan_destroy` frees. A type a read cannot take is `Bad_Option` naming the member, or the type.
@(require_results)
plan_make :: proc($T: typeid, opts := Plan_Options{}, allocator := context.allocator) -> (Plan, tape.Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Reads `src`, an item of `spec`, into `target`. A member the item does not hold keeps the target's value, and a value
// the type does not take is a `Fault` of kind `.Refused`, whose detail is a `Refusal`, at the value's first byte,
// unless the item fails as `validate` fails it, which is then the error. Strings and lists are allocated with
// `allocator`, and a definite text string is a span of `src` under `read.borrow_strings`. Under `.Refuse` the item is
// built first, to judge its keys. Needs `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
unmarshal :: proc(src: []u8, target: ^$T, spec := Spec.Cbor, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_type(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_type :: proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	if opts.dups == .Refuse {
		doc, err := build(src, spec, opts, allocator)
		if err != nil {
			return err
		}
		tape.destroy_document(&doc)
	}
	// A text in pieces is refused by the read, so only a step budget needs the lax walk.
	lax := opts.budget.steps != 0
	switch spec {
	case .Cbor:
		if lax {
			return unmarshal_as(src, target, T, .Cbor, true, read, opts, allocator)
		}
		return unmarshal_as(src, target, T, .Cbor, false, read, opts, allocator)
	case .Preferred:
		if lax {
			return unmarshal_as(src, target, T, .Preferred, true, read, opts, allocator)
		}
		return unmarshal_as(src, target, T, .Preferred, false, read, opts, allocator)
	case .Deterministic:
		if lax {
			return unmarshal_as(src, target, T, .Deterministic, true, read, opts, allocator)
		}
		return unmarshal_as(src, target, T, .Deterministic, false, read, opts, allocator)
	case .Length_First:
		if lax {
			return unmarshal_as(src, target, T, .Length_First, true, read, opts, allocator)
		}
		return unmarshal_as(src, target, T, .Length_First, false, read, opts, allocator)
	}
	return tape.Bad_Option{"spec"}
}

@(private)
unmarshal_as :: #force_no_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $LAX: bool, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Text_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		on :: #force_inline proc "contextless" (h: ^typed.Text_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
			return typed.text_hook(h, s, t, number_value)
		}
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
	}
	return typed.read(src, target, T, &FORMATS[S], TAG, opts, read, allocator, typed.Text_Reader, walk)
}
