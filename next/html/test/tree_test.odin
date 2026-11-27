// Runs the full html5lib / WPT tree-construction suite (1,973 cases, 3,898 runs) and verifies built v2 Document parity on every tree.
package html_tests

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/tape"
import "stury:testkit"

@(private = "file")
TREE_CASES := #load_directory("conformance/wpt/tree-construction")

@(private = "file")
TREE_LEDGER := [?]struct {
	file:   string,
	number: int,
	reason: string,
} {
	{"scripted_adoption01.dat", 1, SCRIPTED},
	{"scripted_ark.dat", 1, SCRIPTED},
	{"scripted_foster01.dat", 1, SCRIPTED},
	{"scripted_foster01.dat", 2, SCRIPTED},
	{"scripted_webkit01.dat", 1, SCRIPTED},
	{"scripted_webkit01.dat", 2, SCRIPTED},
}

@(private = "file")
SCRIPTED :: "the tree the case lists is the one its script leaves, and the parser runs no script"

@(private = "file")
Tree_Case :: struct {
	number:                           int,
	data, document, fragment_context: string,
	fragment, script_on, script_off:  bool,
	has_errors:                       bool,
}

@(private = "file")
close_tree_section :: proc(tc: ^Tree_Case, section: string, lines: ^[dynamic]string) {
	for len(lines) > 0 && lines[len(lines) - 1] == "" && section != "#data" {
		pop(lines)
	}
	joined := strings.join(lines[:], "\n")
	switch section {
	case "#data":
		tc.data = joined
	case "#document":
		tc.document = joined
	case "#document-fragment":
		tc.fragment_context = joined
	case "#errors", "#new-errors":
		tc.has_errors ||= len(lines) > 0
	}
	clear(lines)
}

@(private = "file")
tree_cases :: proc(text: string) -> []Tree_Case {
	cases: [dynamic]Tree_Case
	section := ""
	lines: [dynamic]string
	current: Tree_Case
	started := false
	for line in strings.split_lines(text) {
		switch line {
		case "#data", "#description", "#errors", "#new-errors", "#document", "#document-fragment", "#script-off", "#script-on":
			close_tree_section(&current, section, &lines)
			if line == "#description" || line == "#data" && section != "#description" {
				if started {
					append(&cases, current)
				}
				current = {number = len(cases) + 1}
				started = true
			}
			section = line
			current.fragment ||= line == "#document-fragment"
			current.script_on ||= line == "#script-on"
			current.script_off ||= line == "#script-off"
			continue
		}
		append(&lines, line)
	}
	close_tree_section(&current, section, &lines)
	if started {
		append(&cases, current)
	}
	return cases[:]
}

@(private = "file")
tree_indent :: proc(b: ^strings.Builder, depth: int) {
	strings.write_string(b, "| ")
	for _ in 0 ..< depth {
		strings.write_string(b, "  ")
	}
}

@(private = "file")
print_tree :: proc(b: ^strings.Builder, tree: ^html.Internal_Tree, n: u32, depth: int) {
	for c := html.internal_node(tree, n).first; c != 0; c = html.internal_node(tree, c).next {
		node := html.internal_node(tree, c)
		tree_indent(b, depth)
		switch node.kind {
		case .Document:
		case .Doctype:
			name := strings.clone(html.internal_decoded(tree, node.name))
			public, system := "", ""
			if .Missing not_in tree.public_id.flags {
				public = strings.clone(html.internal_decoded(tree, tree.public_id))
			}
			if .Missing not_in tree.system_id.flags {
				system = strings.clone(html.internal_decoded(tree, tree.system_id))
			}
			if public != "" || system != "" {
				fmt.sbprintf(b, "<!DOCTYPE %s \"%s\" \"%s\">\n", name, public, system)
			} else {
				fmt.sbprintf(b, "<!DOCTYPE %s>\n", name)
			}
		case .Element:
			prefix := [html.Namespace]string{.Html = "", .Svg = "svg ", .Math = "math "}
			fmt.sbprintf(b, "<%s%s>\n", prefix[node.ns], html.internal_element_name(tree, node))
			attrs := make([]string, node.b)
			for &a, idx in tree.attrs[node.a:][:node.b] {
				ns, name := html.internal_attribute_name(tree, node, &a)
				spaced := [html.Internal_Attribute_Namespace]string{.None = "", .Xlink = "xlink ", .Xml = "xml ", .Xmlns = "xmlns "}
				name = fmt.aprintf("%s%s", spaced[ns], name)
				attrs[idx] = fmt.aprintf("%s=\"%s\"", name, html.internal_decoded(tree, a.value))
			}
			slice.sort(attrs)
			for a in attrs {
				tree_indent(b, depth + 1)
				fmt.sbprintf(b, "%s\n", a)
			}
			if node.ns == .Html && html.internal_element_name(tree, node) == "template" {
				tree_indent(b, depth + 1)
				strings.write_string(b, "content\n")
				print_tree(b, tree, c, depth + 2)
			} else {
				print_tree(b, tree, c, depth + 1)
			}
		case .Text:
			strings.write_byte(b, '"')
			for p := node.a; ; p = tree.pieces[p].next {
				strings.write_string(b, html.internal_decoded(tree, tree.pieces[p].span))
				if p == node.b {
					break
				}
			}
			strings.write_string(b, "\"\n")
		case .Comment:
			fmt.sbprintf(b, "<!-- %s -->\n", html.internal_decoded(tree, node.name))
		case .Instruction:
			target := strings.clone(html.internal_decoded(tree, node.name))
			fmt.sbprintf(b, "<?%s %s?>\n", target, html.internal_decoded(tree, tree.pieces[node.a].span))
		}
	}
}

@(private = "file")
Tree_Tally :: struct {
	cases, runs, ledger: int,
}

@(private = "file")
in_ledger :: proc(file: string, number: int) -> bool {
	for l in TREE_LEDGER {
		if l.file == file && l.number == number {
			return true
		}
	}
	return false
}

@(private = "file")
context_fopts :: proc(tc: Tree_Case, scripting: bool) -> html.Fragment_Options {
	fopts := html.Fragment_Options{scripting = scripting, context_name = tc.fragment_context}
	if ns, space, name := strings.partition(tc.fragment_context, " "); space != "" {
		fopts.context_name = name
		fopts.context_namespace = .Svg if ns == "svg" else .Math
	}
	return fopts
}

@(private = "file")
run_tree_file :: proc(t: ^testing.T, file: string, data: []u8, tally: ^Tree_Tally) {
	arena: runtime.Arena
	if !testing.expect(t, runtime.arena_init(&arena, 0, context.allocator) == nil) {
		return
	}
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.arena_allocator(&arena)
	for tc in tree_cases(string(data)) {
		tally.cases += 1
		listed := in_ledger(file, tc.number)
		passed := false
		for scripting in ([2]bool{false, true}) {
			if scripting && tc.script_off || !scripting && tc.script_on {
				continue
			}
			spec := html.Spec.Fragment if tc.fragment else .Html
			fopts := context_fopts(tc, scripting)
			tree, fault := html.internal_build(transmute([]u8)tc.data, spec, fopts)
			if !testing.expectf(t, fault == nil, "%s #%d %q: %v", file, tc.number, tc.data, fault) {
				continue
			}
			defer html.internal_tree_destroy(&tree)
			b := strings.builder_make()
			print_tree(&b, &tree, html.internal_node(&tree, 1).first if tc.fragment else 1, 0)
			got := strings.trim_right(strings.to_string(b), "\n")
			passed ||= got == tc.document
			if listed {
				continue
			}
			tally.runs += 1
			testing.expectf(t, got == tc.document, "%s #%d %q, scripting %v:\n got\n%s\nwant\n%s", file, tc.number, tc.data, scripting, got, tc.document)
			if tc.has_errors {
				testing.expectf(t, len(tree.errors) > 0, "%s #%d %q: no parse error", file, tc.number, tc.data)
			} else if strings.has_prefix(strings.to_lower(tc.data), "<!doctype") && len(tree.errors) > 0 {
				testing.expectf(t, false, "%s #%d %q: parse error %v", file, tc.number, tc.data, tree.errors[0])
			}
			read_document(t, file, tc, scripting, &tree)
		}
		if listed {
			tally.ledger += 1
			testing.expectf(t, !passed, "%s #%d is in the ledger and passes", file, tc.number)
		}
	}
}

@(private = "file")
read_document :: proc(t: ^testing.T, file: string, tc: Tree_Case, scripting: bool, tree: ^html.Internal_Tree) {
	if scripting && !tc.fragment {
		return
	}
	src := transmute([]u8)tc.data
	fopts := context_fopts(tc, scripting)
	doc: tape.Document
	err: tape.Error
	val_err: tape.Error
	if tc.fragment {
		doc, err = html.build_fragment(src, fopts)
		val_err = html.validate_fragment(src, fopts)
	} else {
		doc, err = html.build(src, .Html)
		val_err = html.validate(src, .Html)
	}
	if !testing.expectf(t, err == nil, "%s #%d %q: %v", file, tc.number, tc.data, err) {
		return
	}
	defer html.destroy(&doc)
	testing.expectf(t, (val_err == nil) == (len(tree.errors) == 0), "%s #%d %q: validate disagrees with tree errors (val=%v, errs=%d)", file, tc.number, tc.data, val_err, len(tree.errors))
	elements := tree_elements(tree, html.internal_node(tree, 1).first if tc.fragment else 1)
	next_elem := 0
	for n, idx in doc.nodes {
		node := html.Node_Index(idx)
		if n.role == .Key || (n.kind >= .Number && n.kind <= .Plain) {
			buf := make([]u8, max(html.text_room(&doc, node), int(n.n), 1))
			s, ok := html.node_text(&doc, node, buf)
			testing.expectf(t, ok, "%s #%d %q: node %d does not read", file, tc.number, tc.data, idx)
			if n.role == .Key && s != html.TEXT_KEY && testing.expectf(t, next_elem < len(elements), "%s #%d %q: key %q past the tree's elements", file, tc.number, tc.data, s) {
				el := html.internal_node(tree, elements[next_elem])
				next_elem += 1
				testing.expectf(t, s == html.internal_element_name(tree, el), "%s #%d %q: key %q, element %q", file, tc.number, tc.data, s, html.internal_element_name(tree, el))
				k := u32(0)
				for f in html.facts_of(&doc, node + 1) {
					if f.kind != .Attribute {
						continue
					}
					if k == el.b {
						k += 1
						break
					}
					a := &tree.attrs[el.a + k]
					k += 1
					ns, want_name := html.internal_attribute_name(tree, el, a)
					name_tok, val_tok := doc.format.attribute(&doc, f)
					nbuf := make([]u8, max(tape.text_room(&doc, name_tok), int(name_tok.n), 1))
					vbuf := make([]u8, max(tape.text_room(&doc, val_tok), int(val_tok.n), 1))
					got_name, nok := tape.node_text(&doc, name_tok, nbuf)
					got_value, vok := tape.node_text(&doc, val_tok, vbuf)
					testing.expectf(t, nok && vok, "%s #%d %q: attr of node %d does not read", file, tc.number, tc.data, idx)
					testing.expectf(t, ns != .None || got_name == want_name, "%s #%d %q: attr %q, want %q", file, tc.number, tc.data, got_name, want_name)
					testing.expectf(t, got_value == html.internal_decoded(tree, a.value), "%s #%d %q: attr %q is %q, want %q", file, tc.number, tc.data, got_name, got_value, html.internal_decoded(tree, a.value))
				}
				testing.expectf(t, k == el.b, "%s #%d %q: %q has %d attrs, tree %d", file, tc.number, tc.data, s, k, el.b)
				if v := doc.nodes[node + 1]; v.kind == .Plain {
					want := element_text(tree, el)
					got_buf := make([]u8, max(html.text_room(&doc, node + 1), int(v.n), 1))
					got_txt, _ := html.node_text(&doc, node + 1, got_buf)
					testing.expectf(t, got_txt == want, "%s #%d %q: %q reads %q, want %q", file, tc.number, tc.data, s, got_txt, want)
				}
			}
		} else {
			_, has_close := doc.format.close_end(&doc, node)
			_ = has_close
		}
		if n.role == .Value {
			_, _ = html.content(&doc, node, context.allocator)
		}
	}
	testing.expectf(t, next_elem == len(elements), "%s #%d %q: %d keys, %d elements", file, tc.number, tc.data, next_elem, len(elements))
}

@(private = "file")
element_text :: proc(tree: ^html.Internal_Tree, el: ^html.Internal_Node) -> string {
	b := strings.builder_make()
	for c := el.first; c != 0; c = html.internal_node(tree, c).next {
		n := html.internal_node(tree, c)
		if n.kind != .Text {
			continue
		}
		for p := n.a; ; p = tree.pieces[p].next {
			strings.write_string(&b, html.internal_decoded(tree, tree.pieces[p].span))
			if p == n.b {
				break
			}
		}
	}
	return strings.to_string(b)
}

@(private = "file")
tree_elements :: proc(tree: ^html.Internal_Tree, top: u32) -> []u32 {
	out := make([dynamic]u32)
	stack := make([dynamic]u32)
	if first := html.internal_node(tree, top).first; first != 0 {
		append(&stack, first)
	}
	for len(stack) > 0 {
		n := pop(&stack)
		if next := html.internal_node(tree, n).next; next != 0 {
			append(&stack, next)
		}
		if html.internal_node(tree, n).kind != .Element {
			continue
		}
		append(&out, n)
		if first := html.internal_node(tree, n).first; first != 0 {
			append(&stack, first)
		}
	}
	return out[:]
}

@(test)
tree_construction :: proc(t: ^testing.T) {
	testkit.deadline(t)
	tally: Tree_Tally
	for f in TREE_CASES {
		if strings.has_suffix(f.name, ".dat") {
			run_tree_file(t, f.name, f.data, &tally)
		}
	}
	testing.expect_value(t, tally, Tree_Tally{cases = 1973, runs = 3898, ledger = len(TREE_LEDGER)})
}

@(test)
tree_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "<!DOCTYPE html><p></b>&#0;</i><svg><![CDATA[\x00]]></svg>"
	tree, fault := html.internal_build(transmute([]u8)src)
	defer html.internal_tree_destroy(&tree)
	testing.expect(t, fault == nil)
	want := [?]html.Internal_Parse_Error {
		{18, .Unexpected_End_Tag},
		{26, .Null_Character_Reference},
		{26, .Unexpected_End_Tag},
		{44, .Unexpected_Null_Character},
	}
	testing.expectf(t, slice.equal(tree.errors[:], want[:]), "%v", tree.errors)
}

@(test)
tree_fragment_states :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Case :: struct {
		context_name: string,
		scripting:    bool,
		want:         string,
	}
	cases := [?]Case {
		{"title", false, "| \"<b>&\""},
		{"textarea", false, "| \"<b>&\""},
		{"style", false, "| \"<b>&amp;\""},
		{"noscript", true, "| \"<b>&amp;\""},
		{"noscript", false, "| <b>\n|   \"&\""},
		{"plaintext", false, "| \"<b>&amp;\""},
		{"div", false, "| <b>\n|   \"&\""},
	}
	for c in cases {
		src := "<b>&amp;"
		tree, fault := html.internal_build(transmute([]u8)src, .Fragment, {context_name = c.context_name, scripting = c.scripting}, allocator = context.temp_allocator)
		if !testing.expect(t, fault == nil) {
			continue
		}
		b := strings.builder_make(context.temp_allocator)
		print_tree(&b, &tree, html.internal_node(&tree, 1).first, 0)
		got := strings.trim_right(strings.to_string(b), "\n")
		testing.expectf(t, got == c.want, "%s, scripting %v: got\n%s\nwant\n%s", c.context_name, c.scripting, got, c.want)
	}
}

@(test)
tree_faults :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := strings.repeat("<div>", 20, context.temp_allocator)
	_, err := html.internal_build(transmute([]u8)src, opts = {budget = {depth = 8}})
	f, faulted := err.(tape.Exceeded)
	testing.expect(t, faulted && f.kind == .Depth && f.at == 5 * 6, "a tree past max_depth")

	tree, ok_err := html.internal_build(transmute([]u8)src, opts = {budget = {depth = 64}})
	testing.expect(t, ok_err == nil)
	html.internal_tree_destroy(&tree)

	refuse :: proc(_: rawptr, mode: runtime.Allocator_Mode, _, _: int, _: rawptr, _: int, _: runtime.Source_Code_Location) -> ([]byte, runtime.Allocator_Error) {
		return nil, .Out_Of_Memory if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed else nil
	}
	_, oom_err := html.internal_build(transmute([]u8)src, allocator = runtime.Allocator{procedure = refuse})
	testing.expect_value(t, oom_err, html.Error(runtime.Allocator_Error.Out_Of_Memory))

	// Depth = 1 after `<meta>` / `<head>` must report `Exceeded{.Depth}` cleanly without stack underflow or UB.
	for tiny in ([?]string{"<html><meta><meta>", "<html><head></head><meta>", "<svg><g><circle/></g></svg>"}) {
		spec := html.Spec.Fragment if strings.has_prefix(tiny, "<svg") else html.Spec.Html
		_, derr := html.build(transmute([]u8)tiny, spec, {budget = {depth = 1}})
		dex, is_dex := derr.(tape.Exceeded)
		testing.expect(t, is_dex && dex.kind == .Depth)
	}

	// OOM during `adoption_agency` and foreign content cleans up cleanly without panicking or leaking.
	alloc := runtime.heap_allocator()
	for k in 0 ..< 80 {
		fail := testkit.Failing{backing = alloc, fail_at = k}
		d, err_a := html.build(transmute([]u8)string("<b>1<p>2</b>3</p><svg><g><rect/></g></svg>"), .Fragment, {}, testkit.failing_allocator(&fail))
		if !fail.failed {
			testing.expect_value(t, err_a, nil)
			html.destroy(&d)
			break
		}
		testing.expect_value(t, err_a, html.Error(runtime.Allocator_Error.Out_Of_Memory))
	}
}
