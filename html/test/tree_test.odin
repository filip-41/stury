// Runs the html5lib tree-construction cases, as the web-platform-tests keep them, on the tree: each case must print as
// the tree it lists, a document or a fragment in its context element, with scripting enabled for `#script-on`,
// disabled for `#script-off`, and both ways for a case that names neither.
package html_tests

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import html ".."

@(private)
TREE_CASES := #load_directory("conformance/wpt/tree-construction")

// The cases whose tree differs from the one the case lists, by file and case number from 1, and why. A case listed
// here that passes fails the run, so the list stays current.
@(private)
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

@(private)
SCRIPTED :: "the tree the case lists is the one its script leaves, and the parser runs no script"

@(private)
Tree_Case :: struct {
	number:                           int,
	data, document, fragment_context: string,
	fragment, script_on, script_off:  bool,
	has_errors:                       bool,
}

// The cases of a `.dat` file. A case starts at `#data`, or at a `#description` before it, and each `#` heading the
// format names starts a section.
@(private)
tree_cases :: proc(text: string) -> []Tree_Case {
	cases: [dynamic]Tree_Case
	section := ""
	lines: [dynamic]string
	close :: proc(c: ^Tree_Case, section: string, lines: ^[dynamic]string) {
		for len(lines) > 0 && lines[len(lines) - 1] == "" && section != "#data" {
			pop(lines)
		}
		joined := strings.join(lines[:], "\n")
		switch section {
		case "#data":
			c.data = joined
		case "#document":
			c.document = joined
		case "#document-fragment":
			c.fragment_context = joined
		case "#errors", "#new-errors":
			c.has_errors ||= len(lines) > 0
		}
		clear(lines)
	}
	current: Tree_Case
	started := false
	for line in strings.split_lines(text) {
		switch line {
		case "#data", "#description", "#errors", "#new-errors", "#document", "#document-fragment", "#script-off", "#script-on":
			close(&current, section, &lines)
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
	close(&current, section, &lines)
	if started {
		append(&cases, current)
	}
	return cases[:]
}

@(private)
indent :: proc(b: ^strings.Builder, depth: int) {
	strings.write_string(b, "| ")
	for _ in 0 ..< depth {
		strings.write_string(b, "  ")
	}
}

// Prints the children of node `n` at `depth` as the format does. A template's contents follow a `content` line.
@(private)
print_tree :: proc(b: ^strings.Builder, t: ^html.Internal_Tree, n: u32, depth: int) {
	for c := t.nodes[n].first; c != 0; c = t.nodes[c].next {
		node := &t.nodes[c]
		indent(b, depth)
		switch node.kind {
		case .Document:
		case .Doctype:
			name := strings.clone(html.internal_decoded(t, node.name))
			public, system := "", ""
			if .Missing not_in t.public_id.flags {
				public = strings.clone(html.internal_decoded(t, t.public_id))
			}
			if .Missing not_in t.system_id.flags {
				system = strings.clone(html.internal_decoded(t, t.system_id))
			}
			if public != "" || system != "" {
				fmt.sbprintf(b, "<!DOCTYPE %s \"%s\" \"%s\">\n", name, public, system)
			} else {
				fmt.sbprintf(b, "<!DOCTYPE %s>\n", name)
			}
		case .Element:
			prefix := [html.Namespace]string{.Html = "", .Svg = "svg ", .Math = "math "}
			fmt.sbprintf(b, "<%s%s>\n", prefix[node.ns], html.internal_element_name(t, node))
			attrs := make([]string, node.b)
			for &a, i in t.attrs[node.a:][:node.b] {
				ns, name := html.internal_attribute_name(t, node, &a)
				spaced := [html.Internal_Attribute_Namespace]string{.None = "", .Xlink = "xlink ", .Xml = "xml ", .Xmlns = "xmlns "}
				name = fmt.aprintf("%s%s", spaced[ns], name)
				attrs[i] = fmt.aprintf("%s=\"%s\"", name, html.internal_decoded(t, a.value))
			}
			slice.sort(attrs)
			for a in attrs {
				indent(b, depth + 1)
				fmt.sbprintf(b, "%s\n", a)
			}
			if node.ns == .Html && html.internal_element_name(t, node) == "template" {
				indent(b, depth + 1)
				strings.write_string(b, "content\n")
				print_tree(b, t, c, depth + 2)
			} else {
				print_tree(b, t, c, depth + 1)
			}
		case .Text:
			strings.write_byte(b, '"')
			for p := node.a;; p = t.pieces[p].next {
				strings.write_string(b, html.internal_decoded(t, t.pieces[p].span))
				if p == node.b {
					break
				}
			}
			strings.write_string(b, "\"\n")
		case .Comment:
			fmt.sbprintf(b, "<!-- %s -->\n", html.internal_decoded(t, node.name))
		case .Instruction:
			target := strings.clone(html.internal_decoded(t, node.name))
			fmt.sbprintf(b, "<?%s %s?>\n", target, html.internal_decoded(t, t.pieces[node.a].span))
		}
	}
}

// The cases, the builds compared, which are one per scripting mode a case reads in, the ledger's cases, and the cases
// of each kind.
@(private)
Tree_Tally :: struct {
	cases, runs, ledger, fragments, script_on, script_off, templates, foreign_content: int,
}

@(private)
in_ledger :: proc(file: string, number: int) -> bool {
	for l in TREE_LEDGER {
		if l.file == file && l.number == number {
			return true
		}
	}
	return false
}

// Whether `data` holds `tag` as a start or end tag, ASCII case folded.
@(private)
holds_tag :: proc(data, tag: string) -> bool {
	lower := strings.to_lower(data)
	return strings.contains(lower, fmt.tprintf("<%s", tag)) || strings.contains(lower, fmt.tprintf("</%s", tag))
}

// The options of a fragment case's context, `svg path` or `td` as the format writes it.
@(private)
context_options :: proc(c: Tree_Case, scripting: bool) -> html.Options {
	opts := html.Options{scripting = scripting, context_name = c.fragment_context}
	if ns, space, name := strings.partition(c.fragment_context, " "); space != "" {
		opts.context_name = name
		opts.context_namespace = .Svg if ns == "svg" else .Math
	}
	return opts
}

@(private)
run_tree_file :: proc(t: ^testing.T, file: string, data: []u8, tally: ^Tree_Tally) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for c in tree_cases(string(data)) {
		tally.cases += 1
		tally.fragments += int(c.fragment)
		tally.script_on += int(c.script_on)
		tally.script_off += int(c.script_off)
		tally.templates += int(holds_tag(c.data, "template") || c.fragment_context == "template")
		tally.foreign_content += int(holds_tag(c.data, "svg") || holds_tag(c.data, "math") || strings.contains(c.fragment_context, " "))
		listed := in_ledger(file, c.number)
		passed := false
		for scripting in ([2]bool{false, true}) {
			if scripting && c.script_off || !scripting && c.script_on {
				continue
			}
			tree, fault := html.internal_build(transmute([]u8)c.data, .Fragment if c.fragment else .Document, context_options(c, scripting))
			if !testing.expectf(t, fault == nil, "%s #%d %q: %v", file, c.number, c.data, fault) {
				continue
			}
			defer html.internal_tree_destroy(&tree)
			b := strings.builder_make()
			// A fragment's nodes are the children of its root, the document's one element.
			print_tree(&b, &tree, tree.nodes[1].first if c.fragment else 1, 0)
			got := strings.trim_right(strings.to_string(b), "\n")
			passed ||= got == c.document
			if listed {
				continue
			}
			tally.runs += 1
			testing.expectf(t, got == c.document, "%s #%d %q, scripting %v:\n got\n%s\nwant\n%s", file, c.number, c.data, scripting, got, c.document)
			// The errors are counted, not compared: the standard does not name the tree construction's. A case that lists
			// none and opens with a DOCTYPE reports none.
			if c.has_errors {
				testing.expectf(t, len(tree.errors) > 0, "%s #%d %q: no parse error", file, c.number, c.data)
			} else if strings.has_prefix(strings.to_lower(c.data), "<!doctype") && len(tree.errors) > 0 {
				testing.expectf(t, false, "%s #%d %q: parse error %v", file, c.number, c.data, tree.errors[0])
			}
			read_document(t, file, c, scripting, &tree)
		}
		if listed {
			tally.ledger += 1
			testing.expectf(t, !passed, "%s #%d is in the ledger and passes", file, c.number)
		}
	}
}

// Builds the case's text into a document through the format, and reads every node, attribute and fact of it: each
// text decodes, each container closes at or past its start, `validate` names a parse error when the tree has one, and
// the document's elements are the tree's in preorder, each under the name the tree prints and with the values of its
// attributes.
@(private)
read_document :: proc(t: ^testing.T, file: string, c: Tree_Case, scripting: bool, tree: ^html.Internal_Tree) {
	src := transmute([]u8)c.data
	spec := html.Spec.Fragment if c.fragment else .Document
	doc, err := html.build(src, spec, context_options(c, scripting))
	if !testing.expectf(t, err == nil, "%s #%d %q: %v", file, c.number, c.data, err) {
		return
	}
	defer core.destroy(&doc)
	testing.expectf(t, (html.validate(src, spec, context_options(c, scripting)) == nil) == (len(tree.errors) == 0), "%s #%d %q: validate disagrees with the tree", file, c.number, c.data)
	elements := tree_elements(tree, tree.nodes[1].first if c.fragment else 1)
	next := 0
	for n, i in doc.nodes {
		node := core.Node_Index(i)
		if n.kind <= .Plain {
			buf := make([]u8, core.text_room(&doc, node))
			s, ok := core.text(&doc, node, buf)
			testing.expectf(t, ok, "%s #%d %q: node %d does not read", file, c.number, c.data, i)
			if n.role == .Key && s != html.TEXT_KEY && testing.expectf(t, next < len(elements), "%s #%d %q: key %q past the tree's elements", file, c.number, c.data, s) {
				e := &tree.nodes[elements[next]]
				next += 1
				testing.expectf(t, s == html.internal_element_name(tree, e), "%s #%d %q: key %q, element %q", file, c.number, c.data, s, html.internal_element_name(tree, e))
				testing.expectf(t, core.key_equals(&doc, node, s), "%s #%d %q: key %q does not equal its text", file, c.number, c.data, s)
				attributes := core.attributes_of(&doc, node + 1)
				k := u32(0)
				for name, value in core.attribute_next(&attributes) {
					if k == e.b {
						k += 1
						break
					}
					a := &tree.attrs[e.a + k]
					k += 1
					ns, want_name := html.internal_attribute_name(tree, e, a)
					got_name, nok := core.token_text(doc.readers, &doc.view, name, context.allocator)
					got_value, vok := core.token_text(doc.readers, &doc.view, value, context.allocator)
					testing.expectf(t, nok && vok, "%s #%d %q: an attribute of node %d does not read", file, c.number, c.data, i)
					testing.expectf(t, ns != .None || got_name == want_name, "%s #%d %q: attribute %q, want %q", file, c.number, c.data, got_name, want_name)
					testing.expectf(t, got_value == html.internal_decoded(tree, a.value), "%s #%d %q: attribute %q is %q", file, c.number, c.data, got_name, got_value)
				}
				testing.expectf(t, k == e.b, "%s #%d %q: %q has %d attributes, the tree %d", file, c.number, c.data, s, k, e.b)
				if v := doc.nodes[node + 1]; v.kind == .Plain {
					want := element_text(tree, e)
					got := make([]u8, core.text_room(&doc, node + 1))
					text, _ := core.text(&doc, node + 1, got)
					testing.expectf(t, text == want, "%s #%d %q: %q reads %q, its text is %q", file, c.number, c.data, s, text, want)
				}
			}
		} else {
			testing.expectf(t, len(core.span(&doc, node)) >= 0, "%s #%d", file, c.number)
		}
		if n.role == .Value {
			_, _ = core.fact_value(&doc, node, .Content)
		}
	}
	testing.expectf(t, next == len(elements), "%s #%d %q: %d keys, %d elements", file, c.number, c.data, next, len(elements))
}

// The text of element `e`, which has no child element: its text children's, decoded and joined.
@(private)
element_text :: proc(tree: ^html.Internal_Tree, e: ^html.Internal_Node) -> string {
	b := strings.builder_make()
	for c := e.first; c != 0; c = tree.nodes[c].next {
		n := &tree.nodes[c]
		if n.kind != .Text {
			continue
		}
		for p := n.a;; p = tree.pieces[p].next {
			strings.write_string(&b, html.internal_decoded(tree, tree.pieces[p].span))
			if p == n.b {
				break
			}
		}
	}
	return strings.to_string(b)
}

// The elements below node `top` of the tree, in preorder.
@(private)
tree_elements :: proc(tree: ^html.Internal_Tree, top: u32) -> []u32 {
	out := make([dynamic]u32)
	stack := make([dynamic]u32)
	if first := tree.nodes[top].first; first != 0 {
		append(&stack, first)
	}
	for len(stack) > 0 {
		n := pop(&stack)
		if next := tree.nodes[n].next; next != 0 {
			append(&stack, next)
		}
		if tree.nodes[n].kind != .Element {
			continue
		}
		append(&out, n)
		if first := tree.nodes[n].first; first != 0 {
			append(&stack, first)
		}
	}
	return out[:]
}

@(test)
tree_construction :: proc(t: ^testing.T) {
	tally: Tree_Tally
	for f in TREE_CASES {
		if strings.has_suffix(f.name, ".dat") {
			run_tree_file(t, f.name, f.data, &tally)
		}
	}
	testing.expect_value(t, tally, Tree_Tally{cases = 1973, runs = 3898, ledger = len(TREE_LEDGER), fragments = 206, script_on = 14, script_off = 28, templates = 130, foreign_content = 312})
}

// The tree keeps every parse error, the tokenizer's and its own, in the order the text holds them.
@(test)
tree_errors :: proc(t: ^testing.T) {
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

// A fragment's context element sets the state its text is read in, `noscript` by whether scripting is enabled.
@(test)
tree_fragment_states :: proc(t: ^testing.T) {
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
	context.allocator = context.temp_allocator
	for c in cases {
		src := "<b>&amp;"
		tree, fault := html.internal_build(transmute([]u8)src, .Fragment, {context_name = c.context_name, scripting = c.scripting})
		if !testing.expect(t, fault == nil) {
			continue
		}
		b := strings.builder_make()
		print_tree(&b, &tree, tree.nodes[1].first, 0)
		got := strings.trim_right(strings.to_string(b), "\n")
		testing.expectf(t, got == c.want, "%s, scripting %v: got\n%s\nwant\n%s", c.context_name, c.scripting, got, c.want)
		html.internal_tree_destroy(&tree)
	}
}

// A tree past `max_depth` faults `.Too_Deep` at the tag that would pass it, and one the allocator refuses `.No_Memory`.
@(test)
tree_faults :: proc(t: ^testing.T) {
	src := strings.repeat("<div>", 20, context.temp_allocator)
	tree, fault := html.internal_build(transmute([]u8)src, opts = {max_depth = 8})
	f, faulted := fault.?
	testing.expect(t, faulted && f.kind == .Too_Deep && f.at == 5 * 6, "a tree past max_depth")
	testing.expect(t, len(tree.nodes) == 0)
	tree, fault = html.internal_build(transmute([]u8)src, opts = {max_depth = 64})
	testing.expect(t, fault == nil)
	html.internal_tree_destroy(&tree)
	refuse :: proc(_: rawptr, mode: runtime.Allocator_Mode, _, _: int, _: rawptr, _: int, _: runtime.Source_Code_Location) -> ([]byte, runtime.Allocator_Error) {
		return nil, .Out_Of_Memory if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed else nil
	}
	_, fault = html.internal_build(transmute([]u8)src, allocator = runtime.Allocator{procedure = refuse})
	f, faulted = fault.?
	testing.expect(t, faulted && f.kind == .No_Memory, "a refused allocation")
}
