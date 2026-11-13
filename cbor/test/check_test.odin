// A typed check of a CBOR item by a plan, and a plan made from a model's description.
package cbor_tests

import "core:testing"
import core "../../core"
import rules "../../core/rules"
import typed "../../core/typed"
import walktest "../../walktest"
import cbor ".."
import model "../../core/model"

@(private = "file")
Pair :: struct {
	a: int,
	b: []int,
}

// `check` gives every refusal of an item read by a plan, for a spec bound or chosen at run time, and a plan made with
// the reads `reads` gives reads an item through `core/typed`.
@(test)
a_plan_checks_an_item :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	plan, perr := cbor.plan_make(Pair, .Cbor)
	walktest.expect_nil(t, perr)
	src := hex("a2 61 61 61 78 61 62 82 01 61 79")
	v: Pair
	sink: typed.Sink
	testing.expect(t, cbor.check(src, .Cbor, &v, &plan, {sink = &sink}) != nil)
	testing.expect_value(t, len(sink.entries), 2)
	spec := cbor.Spec.Preferred
	again: Pair
	other: typed.Sink
	testing.expect(t, cbor.check(src, spec, &again, &plan, {sink = &other}) != nil)
	testing.expect_value(t, len(other.entries), 2)
	good: Pair
	walktest.expect_nil(t, cbor.unmarshal(hex("a2 61 61 01 61 62 81 02"), spec, &good))
	testing.expect(t, good.a == 1 && len(good.b) == 1)
	read, rerr := cbor.plan_make(Pair, .Cbor, reads = cbor.reads(.Cbor))
	walktest.expect_nil(t, rerr)
	walktest.expect_nil(t, typed.unmarshal_text(hex("a1 61 61 03"), &good, Pair, &read, {}))
	testing.expect_value(t, good.a, 3)
}

// A plan of a description reads CBOR, and an empty description is refused.
@(test)
a_plan_of_a_description_reads_cbor :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	m, compiled := model.compile(&reg, Pair, cbor.checks(.Cbor))
	walktest.expect_nil(t, compiled)
	d, derr := model.schema(&m, .Load, context.temp_allocator)
	walktest.expect_nil(t, derr)
	plan, built := cbor.plan_of(&d, .Cbor, reads = cbor.reads(.Cbor))
	walktest.expect_nil(t, built)
	testing.expect(t, plan.read != nil && plan.marshal != nil)
	_, empty := cbor.plan_of(&rules.Description{})
	walktest.expect_kind(t, empty, core.Typed_Error_Kind.Bad_Option)
}
