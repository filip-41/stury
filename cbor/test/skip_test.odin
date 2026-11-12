// The law of a skipping walk: a path read judges every byte it passes as `validate` does, so it faults where `validate`
// faults, and with `stop_early` it leaves only the text past its last answer unjudged.
package cbor_tests

import "core:encoding/json"
import "core:math/rand"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import cbor ".."

@(private)
Skip_Tally :: struct {
	agreed:  int,
	faulted: int,
}

@(private)
skip_law :: proc(t: ^testing.T, tally: ^Skip_Tally, src: []u8) {
	context.allocator = context.temp_allocator
	verdict, invalid := walktest.fault_of(cbor.validate(src, .Cbor)).?
	step_zz := [?]core.Step{core.Name("zz")}
	step_0 := [?]core.Step{core.Index(0)}
	step_1 := [?]core.Step{core.Name("1")}
	step_a1 := [?]core.Step{core.Name("a"), core.Index(1)}
	paths := [?]core.Path{{steps = step_zz[:]}, {steps = step_0[:]}, {steps = step_1[:]}, {steps = step_a1[:]}}
	for path in paths {
		doc, err := cbor.scan(src, .Cbor, path)
		if invalid {
			if !testing.expectf(t, err != nil, "%x: validate faults at %d, the scan does not", src, verdict.at) {
				continue
			}
			testing.expectf(t, walktest.at_of(err) == verdict.at, "%x: validate faults at %d, the scan at %d", src, verdict.at, walktest.at_of(err))
			tally.faulted += 1
		} else {
			testing.expectf(t, err == nil, "%x: validate accepts, the scan faults: %v", src, err)
			core.destroy(&doc)
		}
		tally.agreed += 1

		early, early_err := cbor.scan(src, .Cbor, path, read = {stop_early = true})
		if early_err != nil {
			testing.expectf(t, invalid && walktest.at_of(early_err) == verdict.at, "%x: a stop_early scan faults where validate does not", src)
		} else {
			core.destroy(&early)
		}
		if !invalid {
			testing.expectf(t, early_err == nil, "%x: validate accepts, the stop_early scan faults", src)
		}
	}
}

// The malformed items of Appendix F and every Appendix A example.
@(test)
skipping_judges_the_tables :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tally: Skip_Tally
	for c in MALFORMED {
		skip_law(t, &tally, hex(c.hex))
	}
	table, _ := json.parse(transmute([]u8)APPENDIX_A)
	for row in table.(json.Array) {
		skip_law(t, &tally, hex(row.(json.Object)["hex"].(json.String)))
	}
	testing.expect(t, 0 < tally.faulted)
	testing.expect(t, 400 < tally.agreed)
}

// Mutations of generated items.
@(test)
skipping_judges_mutated_items :: proc(t: ^testing.T) {
	state := rand.create(0x5eed_cb04)
	g := Generator {
		rng = rand.default_random_generator(&state),
	}
	tally: Skip_Tally
	for _ in 0 ..< 3000 {
		g.out = make([dynamic]u8, context.temp_allocator)
		put_item(&g, 0, false)
		src := g.out[:]
		switch below(&g, 3) {
		case 0:
			src[below(&g, len(src))] = u8(below(&g, 256))
		case 1:
			src = src[:below(&g, len(src))]
		case:
			append(&g.out, u8(below(&g, 256)))
			src = g.out[:]
		}
		skip_law(t, &tally, src)
		free_all(context.temp_allocator)
	}
	testing.expect(t, 0 < tally.faulted)
}

// A path read answers from the item without building the rest: the answer is the value at the path, whatever precedes
// it, and a skipped value that is ill-formed still faults.
@(test)
skipping_reads_the_answer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src := hex("a3 61 62 82 01 02 61 61 a1 01 f5 61 63 7f 61 78 ff")
	doc, answer, err := cbor.find(src, .Cbor, core.Path{steps = {core.Name("a"), core.Name("1")}})
	walktest.expect_nil(t, err)
	testing.expect_value(t, answer.outcome, core.Presence.Found)
	testing.expect_value(t, core.kind(&doc, answer.node), core.Kind.True)
	testing.expect(t, len(doc.nodes) < 8, "the skipped values are not nodes")

	tail := hex("82 01 ff")
	_, tail_answer, tail_err := cbor.find(tail, .Cbor, core.Path{steps = {core.Index(0)}}, read = {stop_early = true})
	walktest.expect_nil(t, tail_err)
	testing.expect_value(t, tail_answer.outcome, core.Presence.Found)
	_, _, full_err := cbor.find(tail, .Cbor, core.Path{steps = {core.Index(0)}})
	testing.expect(t, full_err != nil, "without stop_early the bytes past the answer are judged")

	bad := hex("a2 61 62 61 c3 61 61 01")
	_, bad_answer, bad_err := cbor.find(bad, .Cbor, core.Path{steps = {core.Name("a")}})
	_ = bad_answer
	testing.expect(t, bad_err != nil)
	_, early_answer, early_err := cbor.find(bad[:3], .Cbor, core.Path{steps = {core.Name("b")}}, read = {stop_early = true})
	_ = early_answer
	testing.expect(t, early_err != nil)
}
