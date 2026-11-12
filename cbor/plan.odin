package cbor

// The typed plans of CBOR: a member's key is its text string head and its name, which a plan stores whole.

import "base:runtime"
import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import write "../core/write"

// How a typed write writes a struct: `.Map` as a map of its members by name, `.Array` as an array of its members in
// their order, with no keys. An array is for data the same program reads back, since a member added in the middle moves
// the ones after it. A member a model's write leaves out is null in an array, and `omitempty` leaves no member out of
// one.
Struct_Form :: enum u8 {
	Map,
	Array,
}

// Returns the typed reads of spec `S`, which `plan_make` takes to read a plan made from a type. Every spec shares them,
// since a plan's handle holds its spec.
reads :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	return &READS
}

// Returns the checks of spec `S` read and written with `opts`, which `model.compile` and `schema.bind` take: the reads
// of a plan made from a model or a description, and the handle its plans read by.
checks :: proc "contextless" ($S: Spec, opts := Options{}) -> typed.Format_Checks {
	return {&CHECKS, bound_as(S, opts)}
}

// Builds the plan of `T` for CBOR of `spec` read and written with `opts`, as `typed.plan_make` does. The plan reads only
// with `reads`, and with none it reads through `unmarshal`.
plan_make :: proc(T: typeid, spec := Spec.Cbor, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, refusal := plan_bound(T, spec, opts, plan, reads, allocator)
	// A plan that is built holds no refusal to copy.
	if refusal.kind == .None {
		return made, nil
	}
	return made, core.error_of(refusal)
}

// Builds the plan that reads values of description `d` as `spec`, as `typed.plan_of` does. The reads are the plan's with
// `reads`, as for `plan_make`.
plan_of :: proc(d: ^rules.Description, spec := Spec.Cbor, opts := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := typed.plan_of(d, plan_handle(spec, {}), reads, opts, allocator)
	if err == nil {
		plan_bind(&made, reads)
	}
	return made, err
}

@(private)
plan_bound :: proc(T: typeid, spec: Spec, opts: Options, plan: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	made, refusal := typed.plan_build(T, plan_handle(spec, opts), plan, allocator)
	plan_bind(&made, reads)
	return made, refusal
}

// The handle a plan holds: the plan's readers, which carry no `close_end` and no services, its spec and the option bytes.
@(private)
plan_handle :: proc "contextless" (spec: Spec, opts: Options) -> core.As {
	return as_of(&PLAN_READERS, spec, opts)
}

// Gives a plan CBOR's writer, the check of a `Raw` member's bytes and the token writer, and the reads `reads` holds.
@(private)
plan_bind :: proc(p: ^typed.Plan, reads: ^typed.Format_Reads) {
	p.marshal, p.raw, p.tokens = marshal_text, raw_check, &TOKENS
	p.value_text = write.value_text
	typed.plan_reads(p, reads)
}

// The handle's `plans`.
@(private)
plan_as :: proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as, opts, allocator)
	p.marshal, p.raw, p.value_text = marshal_text, raw_check, write.value_text
	return p, err
}

// A plan's check of a `Raw` member's bytes: exactly one item of the plan's spec, nested no deeper than the view says.
@(private)
raw_check :: proc(v: ^core.Token_View, src: []u8, _: runtime.Allocator) -> core.Document_Error {
	if f, bad := validate_text(src, handle_rules(v.as)).?; bad {
		return {kind = .Bad_Value, inner = f}
	}
	return {}
}

// The readers' `key_bytes`: the text string head of `name` and its bytes.
@(private)
key_bytes :: proc(name: string, buf: []u8) -> []u8 {
	n := write.put_head(raw_data(buf), u64(len(name)), TREE, .Text)
	return buf[:n + copy(buf[n:], name)]
}
