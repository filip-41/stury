package json_tests

import "core:testing"
import "stury:json"
import "stury:testkit"

// A program that reads JSON imports `json` alone: build and read a document, find a value with no document, scan the
// values paths reach, and tell a fault from an answer.
@(test)
json_alone_serves_a_program :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"name": "stury", "tags": ["a", "b"], "size": 12}`)
	doc, err := json.build(src)
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := json.Reader{&doc, nil}
	at, p := json.member(r, json.ROOT, "name")
	buf: [16]u8
	name, ok := json.node_text(&doc, at, buf[:])
	testing.expect(t, p == .Found && ok && name == "stury")
	tags, _ := json.member(r, json.ROOT, "tags")
	n, _, _ := json.length(r, tags, context.allocator)
	testing.expect_value(t, n, 2)
	path := []json.Step{json.Name("size")}
	a, ferr := json.find(src, path)
	size, is_number := json.node_number(json.as(.Json), src, json.answer_node(a))
	testing.expect(t, ferr == nil && a.outcome == .Found && is_number && size == json.Number{12, .Int})
	d, derr := json.demand_of({{json.Name("tags"), json.Index(-1)}})
	defer json.destroy(&d)
	s, serr := json.scan(src, &d)
	defer json.destroy(&s)
	last, lp, has := json.answer({&s, nil}, 0, 0)
	text, _ := json.node_text(&s, last, buf[:])
	testing.expect(t, derr == nil && serr == nil && has && lp == .Found && text == "b")
	_, bad := json.build(transmute([]u8)string(`[1,]`))
	fault, faulted := bad.(json.Fault)
	testing.expect(t, faulted && fault.kind == .Bad_Char && fault.at == 3)
}
