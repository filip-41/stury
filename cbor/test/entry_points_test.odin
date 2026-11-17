// The entry points that bind CBOR's passes to the handle.
package cbor_tests

import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import testkit "../../testkit"
import cbor ".."

// The entry points that bind their passes answer as the handle's do: a document `build` read is written and queried
// with no services.
@(test)
bound_entry_points_answer_as_the_handle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src := hex("a2 6161 9f 01 02 ff 6162 c1 03")
	doc, err := cbor.build(src, .Cbor)
	testkit.expect_nil(t, err)
	testing.expect(t, core.services_of(doc.as) == nil)
	text, dropped, werr := cbor.write(&doc, .Preferred)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, dropped, 0)
	testing.expect_value(t, hex_of(text), "a26161820102" + "6162c103")
	by_handle, _, herr := core.write(&doc, {}, cbor.as(.Preferred))
	testkit.expect_nil(t, herr)
	testing.expect_value(t, hex_of(by_handle), hex_of(text))
	_, _, key_err := cbor.write(&doc, .Cbor, node = 1)
	testing.expect(t, key_err != nil)
	answers, qerr := cbor.query(&doc, core.Path{steps = {core.Name("a"), core.Index(1)}})
	testkit.expect_nil(t, qerr)
	testing.expect_value(t, len(answers), 1)
	n, _ := core.number(&doc, answers[0].node)
	testing.expect_value(t, n.bits, 2)
	chosen, cerr := core.build(src, cbor.as(.Cbor))
	testkit.expect_nil(t, cerr)
	testing.expect(t, core.equal(core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&chosen, core.ROOT}))
	// A plan the handle makes reads and writes through the plan's own reads.
	Pair :: struct {
		a: int,
		b: string,
	}
	plan, perr := typed.plan_make(Pair, cbor.as(.Cbor, {structs = .Array}))
	testkit.expect_nil(t, perr)
	placed, merr := write.marshal(Pair{1, "x"}, &plan)
	testkit.expect_nil(t, merr)
	testing.expect_value(t, hex_of(placed), "82016178")
	pair: Pair
	testkit.expect_nil(t, typed.unmarshal_text(placed, &pair, Pair, &plan, {}))
	testing.expect_value(t, pair, Pair{1, "x"})
	w: write.Tokens
	testing.expect_value(t, cbor.tokens_init(&w, .Cbor), core.Typed_Error_Kind.None)
	write.open_array(&w)
	write.value_int(&w, -1)
	write.close(&w)
	tokens, terr := write.tokens_finish(&w)
	testing.expect_value(t, terr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, hex_of(tokens), "8120")
}
