#+feature dynamic-literals
package json_tests

import json "../.."
import fmt "quiet"
import "core:testing"

// The library's common-path snippets, each verbatim,
// followed by checks of what it read or wrote, so a snippet that stops compiling or answering fails `make test`.
// Their `fmt` is `quiet`, which prints nothing.

@(private = "file")
SRC :: `{"name": "ada", "tags": ["math", "engines"]}`

@(test)
test_quickstart_validate :: proc(t: ^testing.T) {
	src := transmute([]byte)string(`{"name": "ada", "tags": ["math", "engines"]}`)

	if err, bad := json.validate(src).?; bad {
		fmt.eprintln(json.render_error(src, err, context.temp_allocator)) // such as `1:10: Bad_Literal`
	}

	testing.expect(t, json.validate(src) == nil)
	bad_src := transmute([]byte)string(`{"a": tru}`)
	err := json.validate(bad_src).?
	testing.expect_value(t, err, json.Error{kind = .Bad_Literal, offset = 9})
	line, col := json.error_position(bad_src, err)
	testing.expect_value(t, [2]int{line, col}, [2]int{1, 10})
	testing.expect_value(t, json.render_error(bad_src, err, context.temp_allocator), "1:10: Bad_Literal")
	free_all(context.temp_allocator)
}

@(test)
test_quickstart_build :: proc(t: ^testing.T) {
	src := transmute([]byte)string(SRC)
	// The snippet returns when its call fails, which must fail the test too.
	reached := false
	defer testing.expect(t, reached, "the snippet returned early")

	doc, err := json.build(src)
	if err != nil {
		return
	}
	defer json.destroy(&doc)
	name, _ := json.get_string(&doc, json.child(&doc, json.ROOT, "name")) // "ada"
	tags := json.child(&doc, json.ROOT, "tags")
	it := json.children(&doc, tags)
	for tag_node in json.children(&it) {
		tag, _ := json.get_string(&doc, tag_node)
		fmt.println(name, tag) // ada math, then ada engines
	}

	reached = true
	testing.expect_value(t, name, "ada")
	testing.expect_value(t, json.child_count(&doc, tags), 2)
	second, _ := json.get_string(&doc, json.child(&doc, tags, 1))
	testing.expect_value(t, second, "engines")
}

// The snippet declares it inside the proc. A test package keeps it at file scope.
@(private = "file")
Person :: struct {
	name: string,
	tags: []string,
}

@(test)
test_quickstart_unmarshal_marshal :: proc(t: ^testing.T) {
	src := transmute([]byte)string(SRC)

	// unmarshal frees nothing it allocates, so read into memory freed whole.
	p: Person
	if uerr, bad := json.unmarshal(src, &p, allocator = context.temp_allocator).?; bad {
		fmt.eprintf("%v at byte %d\n", uerr.kind, uerr.offset)
	}
	defer free_all(context.temp_allocator)

	out, merr := json.marshal(p)
	defer delete(out)
	// out is `{"name":"ada","tags":["math","engines"]}`

	testing.expect_value(t, p.name, "ada")
	testing.expect_value(t, merr, json.Marshal_Error.None)
	testing.expect_value(t, string(out), `{"name":"ada","tags":["math","engines"]}`)
}

@(test)
test_quickstart_marshal_values :: proc(t: ^testing.T) {
	src := transmute([]byte)string(SRC)

	three := map[string]any{"three" = 3} // a map literal needs `#+feature dynamic-literals` in its file
	defer delete(three)
	mixed, err := json.marshal([]any{1, "two", three})
	defer delete(mixed)
	// mixed is `[1,"two",{"three":3}]`

	doc, _ := json.build(src)
	defer json.destroy(&doc)
	compact, _ := json.marshal(&doc)
	defer delete(compact)
	// compact is `{"name":"ada","tags":["math","engines"]}`: the document as authored, without whitespace

	testing.expect_value(t, err, json.Marshal_Error.None)
	testing.expect_value(t, string(mixed), `[1,"two",{"three":3}]`)
	testing.expect_value(t, string(compact), `{"name":"ada","tags":["math","engines"]}`)
	defer free_all(context.temp_allocator)
	nested, _ := json.marshal([]Person{{name = "g", tags = {"x"}}, {}}, allocator = context.temp_allocator)
	testing.expect_value(t, string(nested), `[{"name":"g","tags":["x"]},{"name":"","tags":[]}]`)
	cell := map[string][]int{"a" = {1, 2}}
	defer delete(cell)
	grid, _ := json.marshal([][]any{{cell, nil}, {}}, allocator = context.temp_allocator)
	testing.expect_value(t, string(grid), `[[{"a":[1,2]},null],[]]`)
	pretty, _ := json.marshal(&doc, {pretty = true, indent = 2}, context.temp_allocator)
	testing.expect_value(t, string(pretty), "{\n  \"name\": \"ada\",\n  \"tags\": [\n    \"math\",\n    \"engines\"\n  ]\n}")
}

@(test)
test_quickstart_query :: proc(t: ^testing.T) {
	src := transmute([]byte)string(SRC)
	// The snippet returns when its call fails, which must fail the test too.
	reached := false
	defer testing.expect(t, reached, "the snippet returned early")

	a, err := json.find(src, ".tags[1]")
	if err != nil {
		return
	}
	if a.outcome == .Found {
		fmt.println(string(src[a.lo:a.hi])) // "engines", quotes and all
	}

	reached = true
	testing.expect_value(t, a.outcome, json.Path_Outcome.Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), `"engines"`)
}

@(test)
test_quickstart_edit :: proc(t: ^testing.T) {
	src := transmute([]byte)string(SRC)

	out, err := json.set(src, ".name", "grace")
	defer delete(out)
	// out is `{"name": "grace", "tags": ["math", "engines"]}`: every byte outside the edit kept

	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), `{"name": "grace", "tags": ["math", "engines"]}`)
}
