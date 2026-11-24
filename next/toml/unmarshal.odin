package toml

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed reads: a text read into an Odin value during the walk, with no document between them. A struct's members are
// named by their tags under `toml`, or else under `stury`. A date-time reads as its text into a string, and as its
// instant into a `time.Time` when it has an offset.

Plan :: typed.Plan
Plan_Options :: typed.Plan_Options
Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Refusal :: typed.Refusal
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "toml"

// The plan of `T` for TOML reads, which `unmarshal` takes in `Unmarshal_Options.plan`, in `allocator`, which
// `plan_destroy` frees. A type a read cannot take is `Bad_Option` naming the member, or the type.
@(require_results)
plan_make :: proc($T: typeid, opts := Plan_Options{}, allocator := context.allocator) -> (Plan, tape.Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Reads `src`, a text of `spec`, into `target`. A member the text does not hold keeps the target's value, and a value
// the type does not take is a `Fault` of kind `.Refused`, whose detail is a `Refusal`, at the value's first byte, unless
// the text fails as `validate` fails it, which is then the error. Strings and lists are allocated with `allocator`, and
// a string with nothing to decode is a span of `src` under `read.borrow_strings`. A key is never repeated, as a repeat
// is a fault.
@(require_results)
unmarshal :: proc(src: []u8, target: ^$T, spec := Spec.Toml_1_0, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_type(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_type :: proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	// A text in pieces is refused by the read, so only a step budget needs the lax walk.
	lax := opts.budget.steps != 0
	switch spec {
	case .Toml_1_0:
		if lax {
			return unmarshal_as(src, target, T, .Toml_1_0, true, read, opts, allocator)
		}
		return unmarshal_as(src, target, T, .Toml_1_0, false, read, opts, allocator)
	case .Toml_1_1:
		if lax {
			return unmarshal_as(src, target, T, .Toml_1_1, true, read, opts, allocator)
		}
		return unmarshal_as(src, target, T, .Toml_1_1, false, read, opts, allocator)
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
	// A repeated key is a fault, so `.Refuse` has no case to judge.
	o := opts
	if o.dups == .Refuse {
		o.dups = .Last
	}
	return typed.read(src, target, T, &FORMATS[S], TAG, o, read, allocator, typed.Text_Reader, walk)
}
