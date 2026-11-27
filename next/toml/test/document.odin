// The document built from a TOML text: every valid toml-test case against its tagged JSON, the node readers, and a read
// that stops early against the whole read.
package toml_tests

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

// Whether node `i` of `doc` is the toml-test value `want`. `why` receives what differs.
@(private)
matches :: proc(doc: ^tape.Document, i: tape.Node_Index, want: json.Value, why: ^strings.Builder) -> bool {
	r := tape.Reader{doc = doc}
	switch doc.nodes[i].kind {
	case .Object:
		obj, is_obj := want.(json.Object)
		c, p, _ := tape.children(r, i, context.temp_allocator)
		defer tape.destroy(&c)
		buf: [4096]u8
		named := 0
		for {
			_, _, q := tape.next_child(r, &c)
			if q != .Found {
				break
			}
			named += 1
		}
		if !is_obj || len(obj) != named {
			fmt.sbprintf(why, "table of %d named members against %v", named, want)
			return false
		}
		c2, _, _ := tape.children(r, i, context.temp_allocator)
		defer tape.destroy(&c2)
		for {
			key, val, q := tape.next_child(r, &c2)
			if q != .Found {
				break
			}
			name, _ := tape.node_text(doc, key, buf[:])
			expected, found := obj[name]
			if !found {
				fmt.sbprintf(why, "member %q is not expected", name)
				return false
			}
			if !matches(doc, val, expected, why) {
				return false
			}
		}
		return p == .Found
	case .Array:
		list, is_list := want.(json.Array)
		n, _, _ := tape.length(r, i, context.temp_allocator)
		if !is_list || len(list) != n {
			fmt.sbprintf(why, "array of %d against %v", n, want)
			return false
		}
		c, _, _ := tape.children(r, i, context.temp_allocator)
		defer tape.destroy(&c)
		for k in 0 ..< n {
			_, val, _ := tape.next_child(r, &c)
			if !matches(doc, val, list[k], why) {
				return false
			}
		}
		return true
	case .True, .False, .Null, .String, .Number, .Bytes, .Plain, .End:
		return scalar_matches(doc, i, want, why)
	}
	return false
}

@(private)
scalar_matches :: proc(doc: ^tape.Document, i: tape.Node_Index, want: json.Value, why: ^strings.Builder) -> bool {
	obj, is_obj := want.(json.Object)
	if !is_obj {
		fmt.sbprintf(why, "scalar against %v", want)
		return false
	}
	type, _ := obj["type"].(json.String)
	value, _ := obj["value"].(json.String)
	buf: [1 << 16]u8
	node := doc.nodes[i]
	switch node.kind {
	case .True:
		return type == "bool" && value == "true"
	case .False:
		return type == "bool" && value == "false"
	case .String:
		text, _ := tape.node_text(doc, i, buf[:])
		if tag, is_date := toml.fact_name(doc, i, .Tag); is_date {
			ok := type == tag && datetime_form(text) == datetime_form(value)
			if !ok {
				fmt.sbprintf(why, "datetime %q against %v", text, want)
			}
			return ok
		}
		if type != "string" || text != value {
			fmt.sbprintf(why, "string %q against %v", text, want)
			return false
		}
		return true
	case .Number:
		return number_matches(doc, i, type, value, why)
	case .Null, .Bytes, .Plain, .End, .Array, .Object:
	}
	return false
}

@(private)
number_matches :: proc(doc: ^tape.Document, i: tape.Node_Index, type, value: string, why: ^strings.Builder) -> bool {
	n, _ := tape.node_number(doc, i)
	buf: [64]u8
	text, _ := tape.node_text(doc, i, buf[:])
	switch {
	case n.kind != .Float && !strings.contains(text, "nan") && !strings.contains(text, "inf"):
		got := fmt.tprint(i64(n.bits))
		if type != "integer" || got != value {
			fmt.sbprintf(why, "integer %v against %v", got, value)
			return false
		}
		return true
	case strings.contains(text, "inf"):
		return type == "float" && strings.trim_left(value, "+") == ("-inf" if n.bits >> 63 != 0 else "inf")
	case strings.contains(text, "nan"):
		return type == "float" && strings.contains(value, "nan")
	}
	want, ok := strconv.parse_f64(value)
	got := transmute(f64)n.bits
	if type != "float" || !ok || got != want {
		fmt.sbprintf(why, "float %v against %v", got, value)
		return false
	}
	return true
}

// A datetime text in one form: a `T` between the date and the time, an upper-case `Z`, seconds in the time, and no
// trailing zero in the fraction.
@(private)
datetime_form :: proc(text: string) -> string {
	s := strings.clone(text, context.temp_allocator)
	b := transmute([]u8)s
	at := 0
	if len(b) > 10 && b[4] == '-' {
		if b[10] == ' ' || b[10] == 't' {
			b[10] = 'T'
		}
		at = 11
	}
	for &c in b {
		if c == 'z' {
			c = 'Z'
		}
	}
	// A time of hour and minute only is the same time at second 0.
	if at + 5 <= len(b) && (at + 5 == len(b) || b[at + 5] == 'Z' || b[at + 5] == '+' || b[at + 5] == '-') {
		s = strings.concatenate({s[:at + 5], ":00", s[at + 5:]}, context.temp_allocator)
	}
	dot := strings.index_byte(s, '.')
	if dot < 0 {
		return s
	}
	end := dot + 1
	for end < len(s) && s[end] >= '0' && s[end] <= '9' {
		end += 1
	}
	digits := strings.trim_right(s[dot + 1:end], "0")
	return strings.concatenate({s[:dot], "." if digits != "" else "", digits, s[end:]}, context.temp_allocator)
}

@(private)
check_documents :: proc(t: ^testing.T, list: string, $spec: toml.Spec) -> (cases: int) {
	rest := list
	for name in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(name, "valid/") || !strings.has_suffix(name, ".toml") {
			continue
		}
		data, found := case_data(name)
		expected, has_json := case_data(strings.concatenate({name[:len(name) - 5], ".json"}, context.temp_allocator))
		if !testing.expectf(t, found && has_json, "%s is not vendored", name) {
			continue
		}
		want, perr := json.parse(expected, .JSON, true, context.temp_allocator)
		if !testing.expectf(t, perr == .None, "%s: the expected JSON does not parse", name) {
			continue
		}
		doc, err := toml.build(data, spec)
		if !testing.expectf(t, err == nil, "%s: %v", name, err) {
			continue
		}
		why: strings.Builder
		strings.builder_init(&why, context.temp_allocator)
		testing.expectf(t, matches(&doc, toml.ROOT, want, &why), "%s: %s", name, strings.to_string(why))
		toml.destroy(&doc)
		cases += 1
		free_all(context.temp_allocator)
	}
	return
}

@(test)
document_toml_1_0 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, check_documents(t, LIST_1_0, .Toml_1_0), 208)
}

@(test)
document_toml_1_1 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, check_documents(t, LIST_1_1, .Toml_1_1), 218)
}

// Every invalid case is a fault of the text, of a kind and a place, and no case builds a document.
@(test)
invalid_cases_do_not_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for list, k in ([?]string{LIST_1_0, LIST_1_1}) {
		spec := toml.Spec(k)
		rest := list
		for name in strings.split_lines_iterator(&rest) {
			if !strings.has_prefix(name, "invalid/") || !strings.has_suffix(name, ".toml") {
				continue
			}
			data, _ := case_data(name)
			doc, err := toml.build(data, spec)
			fault, is_fault := err.(tape.Fault)
			if !testing.expectf(t, is_fault && fault.at <= u64(len(data)), "%s: built or failed otherwise: %v", name, err) {
				toml.destroy(&doc)
			}
		}
	}
}

@(private)
SAMPLE :: `# top
title = "t"
when = 1979-05-27T07:32:00Z
day = 1979-05-27
clock = 07:32:00
local = 1979-05-27T07:32:00
a = 0xdead_beef
o = 0o17
b = 0b1010
f = 1_000.5e1
big = +1_0
nf = -inf
nn = nan
lit = 'x'
ml = """
y"""
mll = '''
z'''
dot.x = 1
inl = {y = 2}
[tbl]
k = [1, 2]
[up.down]
[[aot]]
`

@(private)
node_at :: proc(t: ^testing.T, doc: ^tape.Document, name: string) -> tape.Node_Index {
	i, p := tape.member({doc = doc}, toml.ROOT, name)
	testing.expectf(t, p == .Found, "member %s", name)
	return i
}

// A date-time reads as a string whose tag names its type, a value's style names how it is written, and a number reads
// as its value.
@(test)
facts_name_datetimes_and_styles :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := toml.build(transmute([]u8)string(SAMPLE), .Toml_1_1)
	expect_nil(t, err)
	defer toml.destroy(&doc)
	tags := [?][2]string{{"when", "datetime"}, {"local", "datetime-local"}, {"day", "date-local"}, {"clock", "time-local"}}
	for c in tags {
		tag, held := toml.fact_name(&doc, node_at(t, &doc, c[0]), .Tag)
		testing.expectf(t, held && tag == c[1], "%s: %q", c[0], tag)
	}
	for name in ([]string{"title", "ml", "a", "tbl"}) {
		_, tagged := toml.fact_name(&doc, node_at(t, &doc, name), .Tag)
		testing.expectf(t, !tagged, "%s has a tag", name)
	}
	styles := [?][2]string {
		{"title", "basic"}, {"lit", "literal"}, {"ml", "multiline"}, {"mll", "multiline_literal"},
		{"a", "hex"}, {"o", "octal"}, {"b", "binary"}, {"f", "float"}, {"big", "integer"}, {"nf", "inf"}, {"nn", "nan"},
		{"tbl", "header"}, {"dot", "dotted"}, {"up", "implicit"}, {"inl", "inline"}, {"aot", "header"},
	}
	for c in styles {
		style, held := toml.fact_name(&doc, node_at(t, &doc, c[0]), .Style)
		testing.expectf(t, held && style == c[1], "%s: %q", c[0], style)
	}
	k, _ := toml.member({&doc, nil}, node_at(t, &doc, "tbl"), "k")
	array, _ := toml.fact_name(&doc, k, .Style)
	key, _ := toml.fact_name(&doc, k - 1, .Style)
	testing.expectf(t, array == "inline" && key == "bare", "%q %q", array, key)
	_, root_styled := toml.fact_name(&doc, toml.ROOT, .Style)
	testing.expect(t, !root_styled)
	ints := [?]struct {
		name:  string,
		value: i64,
	}{{"a", 0xdead_beef}, {"o", 0o17}, {"b", 0b1010}, {"big", 10}}
	for c in ints {
		n, ok := toml.node_number(&doc, node_at(t, &doc, c.name))
		testing.expectf(t, ok && i64(n.bits) == c.value, "%s: %v", c.name, n)
	}
	n, _ := toml.node_number(&doc, node_at(t, &doc, "f"))
	testing.expect_value(t, transmute(f64)n.bits, 10005.0)
	n, _ = toml.node_number(&doc, node_at(t, &doc, "nf"))
	testing.expect_value(t, transmute(f64)n.bits, math.inf_f64(-1))
	n, _ = toml.node_number(&doc, node_at(t, &doc, "nn"))
	testing.expect(t, math.is_nan(transmute(f64)n.bits))
}

// A document lists a style or a tag among the facts it holds when one of its nodes spells one.
@(test)
the_facts_a_document_holds_are_those_its_nodes_spell :: proc(t: ^testing.T) {
	testkit.deadline(t)
	texts := [?]string{SAMPLE, "a = true\nb = 1979-05-27\n", "a = true\n[t]\n", "a = 'x'\n", ""}
	for text in texts {
		doc, err := toml.build(transmute([]u8)text, .Toml_1_1)
		expect_nil(t, err)
		spelled: toml.Facts
		for i in 0 ..< len(doc.nodes) {
			for kind in ([]toml.Fact_Kind{.Style, .Tag}) {
				if _, ok := toml.fact_name(&doc, toml.Node_Index(i), kind); ok {
					spelled += {kind}
				}
			}
		}
		testing.expectf(t, doc.present & {.Style, .Tag} == spelled, "%q: %v, spelled %v", text, doc.present, spelled)
		toml.destroy(&doc)
	}
	// A scan holds only the nodes its paths reach: here not the date-time its index path passes.
	d, _ := toml.demand_of({{toml.Name("a"), toml.Index(1)}})
	defer toml.destroy(&d)
	scan, err := toml.scan(transmute([]u8)string("a = [1979-05-27, 1]\n"), &d)
	expect_nil(t, err)
	defer toml.destroy(&scan)
	testing.expectf(t, .Tag not_in scan.present && .Style in scan.present, "%v", scan.present)
}

// A read that stops early gives the answer of a whole read, though a table's members may be written apart, and judges
// the statements before its answer but not those past the container that holds it.
@(test)
a_read_that_stops_early_answers_as_a_whole_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	texts := [?]string {
		"[[logs]]\nid = 1\n[logs.sub]\nk = 2\n[[logs]]\nid = 3\n",
		"[a]\nx = 1\n[b]\ny = 2\n[a.c]\nz = 3\n[[a.d]]\nw = 4\n[b.e]\n",
		"[a.b]\nk = 1\n[a]\nj = 2\nd.e.f = 3\ninline = {p = [1, [2]], q = {}}\n",
		"[[arr]]\nx = 1\n[other]\ny = 2\n[[arr]]\nx = 3\n[arr.sub]\nw = true\n# foot\n",
		"# head\n\nx = 1 # one\n[t] # table\ny = [ # open\n  1, # elem\n]\n",
	}
	paths := [?][]tape.Step {
		{tape.Name("logs"), tape.Index(0), tape.Name("id")},
		{tape.Name("logs"), tape.Index(0)},
		{tape.Name("logs"), tape.Index(1), tape.Name("id")},
		{tape.Name("a")},
		{tape.Name("a"), tape.Name("c"), tape.Name("z")},
		{tape.Name("a"), tape.Name("d"), tape.Index(0), tape.Name("w")},
		{tape.Name("b")},
		{tape.Name("a"), tape.Name("b")},
		{tape.Name("arr"), tape.Index(0)},
		{tape.Name("arr"), tape.Index(1), tape.Name("sub")},
		{tape.Name("other"), tape.Name("y")},
		{tape.Name("t"), tape.Name("y"), tape.Index(0)},
		{tape.Name("x")},
		{tape.Name("nope")},
	}
	for text in texts {
		src := transmute([]u8)text
		for path in paths {
			want, werr := toml.find(src, path, .Toml_1_1, {}, {dups = .First})
			got, gerr := toml.find(src, path, .Toml_1_1, {stop_early = true}, {dups = .First})
			expect_nil(t, werr)
			expect_nil(t, gerr)
			testing.expectf(t, got.outcome == want.outcome, "%q %v: %v, want %v", text, path, got.outcome, want.outcome)
			if want.outcome == .Found && got.outcome == .Found {
				testing.expectf(t, string(src[got.lo:got.hi]) == string(src[want.lo:want.hi]), "%q %v: %q, want %q", text, path, src[got.lo:got.hi], src[want.lo:want.hi])
			}
		}
	}
	// A read that stops at its answer judges the bytes it reads, so it answers before a fault past the container.
	path := []tape.Step{tape.Name("logs"), tape.Index(0), tape.Name("id")}
	open := transmute([]u8)string("[[logs]]\nid = 1\n[[logs]]\nid = [unclosed\n")
	got, err := toml.find(open, path, .Toml_1_1, {stop_early = true}, {dups = .First})
	expect_nil(t, err)
	testing.expect_value(t, string(open[got.lo:got.hi]), "1")
	_, werr := toml.find(open, path, .Toml_1_1)
	testing.expect_value(t, testkit.code_of(werr), "expected_value")
	// A table of a key the path does not take is passed unread, so a fault in a statement that later adds to it, past
	// the answer, is not judged, while a read to the end refuses the text.
	extend := transmute([]u8)string("[a]\nx = 1\n[b]\ny = 2\n[a.c]\nz = ]\n")
	got, err = toml.find(extend, {tape.Name("b"), tape.Name("y")}, .Toml_1_1, {stop_early = true}, {dups = .First})
	expect_nil(t, err)
	testing.expect_value(t, string(extend[got.lo:got.hi]), "2")
	_, werr = toml.find(extend, {tape.Name("b"), tape.Name("y")}, .Toml_1_1)
	testing.expect_value(t, testkit.code_of(werr), "expected_value")
	bad := transmute([]u8)string("x = \"\\q\"\n[[logs]]\nid = 1\n")
	_, berr := toml.find(bad, path, .Toml_1_1, {stop_early = true}, {dups = .First})
	testing.expect_value(t, testkit.code_of(berr), "bad_escape")
}
