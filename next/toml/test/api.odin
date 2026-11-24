package toml_tests

import "core:testing"
import "stury:testkit"
import "stury:toml"

// A program that reads TOML imports `toml` alone: build and read a document, find a value with no document, scan the
// values paths reach, and tell a fault from an answer.
@(test)
toml_alone_serves_a_program :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("name = \"stury\"\ntags = [\"a\", \"b\"]\n[tbl]\nsize = 12\n")
	doc, err := toml.build(src)
	defer toml.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := toml.Reader{&doc, nil}
	at, p := toml.member(r, toml.ROOT, "name")
	buf: [16]u8
	name, ok := toml.node_text(&doc, at, buf[:])
	testing.expect(t, p == .Found && ok && name == "stury")
	tags, _ := toml.member(r, toml.ROOT, "tags")
	n, _, _ := toml.length(r, tags, context.allocator)
	testing.expect_value(t, n, 2)
	path := []toml.Step{toml.Name("tbl"), toml.Name("size")}
	a, ferr := toml.find(src, path)
	size, is_number := toml.node_number(toml.as(.Toml_1_0), src, toml.answer_node(a))
	testing.expect(t, ferr == nil && a.outcome == .Found && is_number && size == toml.Number{12, .Int})
	d, derr := toml.demand_of({{toml.Name("tags"), toml.Index(-1)}})
	defer toml.destroy(&d)
	s, serr := toml.scan(src, &d)
	defer toml.destroy(&s)
	last, lp, has := toml.answer({&s, nil}, 0, 0)
	text, _ := toml.node_text(&s, last, buf[:])
	testing.expect(t, derr == nil && serr == nil && has && lp == .Found && text == "b")
	bad := transmute([]u8)string("a = 1\na = 2\n")
	_, berr := toml.build(bad)
	fault, faulted := berr.(toml.Fault)
	testing.expect(t, faulted && fault.at == 6)
	msg: [64]u8
	testing.expect_value(t, toml.error_message(msg[:], berr, bad), "2:1: Key defined twice")
	_, refused := toml.find(src, path, .Toml_1_0, {}, {dups = .All})
	option, is_option := refused.(toml.Bad_Option)
	testing.expect(t, is_option && option.option == "dups")
}
