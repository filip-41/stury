package cbor_tests

import "core:math/rand"
import "core:testing"
import "stury:cbor"
import "stury:testkit"

// The read laws of `testkit` over random items of every kind and their mutations: the readers answer a scan's partial
// document as the build, every read refuses a text the build refuses, and a build on threads is the build on one.

// The readers law and the refusal law over random items, as each spec reads them, and their mutations.
@(test)
reads_agree_on_generated_items :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xcb0)
	for _ in 0 ..< testkit.rounds(40) {
		src := random_item()
		defer delete(src)
		for spec in cbor.Spec {
			testkit.readers_agree(t, cbor.reads(spec), cbor.as(spec), src, {}, "generated", &a)
		}
		for _ in 0 ..< 4 {
			bad := mutated(src)
			defer delete(bad)
			testkit.readers_agree(t, cbor.reads(.Cbor), cbor.as(.Cbor), bad, {}, "mutated", &a)
		}
	}
	testkit.expect_agreement(t, &a, {texts = 60, refused = 60, scans = 20_000, on_path = 20_000, shapes = 30})
}

// The readers law over the tables of Appendix A, each row's item alone.
@(test)
reads_agree_on_the_appendix :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	rows := [?]string {
		"a201020304", "a26161016162820203", "826161a161626163", "a56161614161626142616361436164614461656145",
		"5f42010243030405ff", "7f657374726561646d696e67ff", "9fff", "9f018202039f0405ffff", "9f01820203820405ff",
		"83018202039f0405ff", "83019f0203ff820405", "bf61610161629f0203ffff", "826161bf61626163ff", "bf6346756ef563416d7421ff",
	}
	for r in rows {
		src := hex(r)
		held := make([]u8, len(src))
		defer delete(held)
		copy(held, src)
		testkit.readers_agree(t, cbor.reads(.Cbor), cbor.as(.Cbor), held, {}, r, &a)
	}
	testing.expect_value(t, a.texts, len(rows))
}

// Records at a path over random items of every spec and their mutations are the children of the container the path
// reaches in the build, each read as the build reads it, and end with the verdict `validate` gives for the text.
@(test)
records_at_a_path_agree_with_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xcb1)
	read := 0
	for _ in 0 ..< testkit.rounds(40) {
		src := random_item()
		defer delete(src)
		for spec in cbor.Spec {
			read += testkit.records_at_agree(t, cbor.reads(spec), cbor.as(spec), src, {}, "generated")
		}
		for _ in 0 ..< 4 {
			bad := mutated(src)
			defer delete(bad)
			read += testkit.records_at_agree(t, cbor.reads(.Cbor), cbor.as(.Cbor), bad, {}, "mutated")
		}
	}
	testing.expectf(t, read > 100, "%d containers read", read)
}
