// A typed check of a CBOR item by a plan, a plan made from a model's description, and the checks a model and a schema run.
package cbor_tests

import "core:testing"
import core "../../core"
import rules "../../core/rules"
import typed "../../core/typed"
import schema "../../core/schema"
import walktest "../../walktest"
import cbor ".."
import stury_json "../../json"
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
	spec :: cbor.Spec.Preferred
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

// A model loads a CBOR item, judging its rules, and refuses one that breaks them.
@(test)
models_load_items :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Pet :: struct {
		name: string `model:"len>=2"`,
		age:  int `model:"optional,<=30"`,
		tags: []string `model:"optional"`,
	}
	reg: model.Registry
	defer model.destroy(&reg)
	m, err := model.compile(&reg, Pet, cbor.checks(.Cbor))
	if !walktest.expect_nil(t, err) {
		return
	}
	pet: Pet
	walktest.expect_nil(t, model.load(&m, hex("a3 646e616d65 63726578 63616765 03 6474616773 82 6161 6162"), &pet))
	testing.expect(t, pet.name == "rex" && pet.age == 3 && len(pet.tags) == 2 && pet.tags[1] == "b")
	// An array reads the members by position.
	placed: Pet
	walktest.expect_nil(t, model.load(&m, hex("83 63726578 04 80"), &placed))
	testing.expect(t, placed.name == "rex" && placed.age == 4 && len(placed.tags) == 0)
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	bad: Pet
	testing.expect(t, model.load(&m, hex("a2 646e616d65 6172 63616765 1863"), &bad, &sink) != nil)
	testing.expect_value(t, len(sink.entries), 2)
	missing: Pet
	testing.expect(t, model.load(&m, hex("a1 63616765 03"), &missing) != nil)
}

// A schema bound to CBOR judges an item. The numbers of a binary text are equal by value, not by the bytes that encode
// them: 1 as a one-byte integer, a two-byte integer and a half float, and a bignum as a bignum or as the integer it
// equals.
@(test)
schemas_check_items :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	bound :: proc(t: ^testing.T, text: string) -> (b: cbor.Bound_Schema, ok: bool) {
		s, err := stury_json.load_schema(transmute([]u8)text, .Json)
		if !walktest.expect_nil(t, err) {
			return
		}
		berr: core.Error
		b, berr = cbor.bind_schema(s, .Cbor)
		return b, walktest.expect_nil(t, berr)
	}
	unique, made := bound(t, `{"uniqueItems": true}`)
	if !made {
		return
	}
	same := [?]string {
		"82 01 1801",
		"82 01 f93c00",
		"82 01 fa3f800000",
		"82 00 f98000",
		"83 05 06 c2 41 05",
		"82 c2 49 010000000000000000 c2 4a 00010000000000000000",
	}
	for text in same {
		testing.expectf(t, schema.check(&unique, hex(text)) != nil, "%s is unique", text)
	}
	different := [?]string {
		"82 01 02",
		"82 01 f94000",
		"82 c2 49 010000000000000000 c2 49 010000000000000001",
		"82 6161 4161",
	}
	for text in different {
		testing.expectf(t, schema.check(&unique, hex(text)) == nil, "%s is not unique", text)
	}
	shaped, shaped_made := bound(t, `{"type": "object", "required": ["id"], "properties": {"id": {"type": "integer", "minimum": 1}, "name": {"type": "string", "maxLength": 3}}, "additionalProperties": false}`)
	if !shaped_made {
		return
	}
	walktest.expect_nil(t, schema.check(&shaped, hex("a2 626964 07 646e616d65 63616263")))
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	testing.expect(t, schema.check(&shaped, hex("a3 626964 00 646e616d65 6461626364 6178 f5"), &sink) != nil)
	testing.expect_value(t, len(sink.entries), 3)
	testing.expect(t, schema.check(&shaped, hex("a1 646e616d65 f6")) != nil)
	// An item that is not well-formed is the walk's fault.
	testing.expect(t, walktest.fault_of(schema.check(&shaped, hex("a2 626964 07"))) != nil)
}
