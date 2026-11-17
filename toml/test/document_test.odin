// The document built from a TOML text: every valid toml-test case against its tagged JSON, the facts and number
// services, the path reads, and the JSON written from a built document.
package toml_tests

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import core "../../core"
import json_pkg "../../json"
import toml ".."
import testkit "../../testkit"

// Whether node `i` of `doc` is the toml-test value `want`. `why` receives what differs.
@(private)
matches :: proc(doc: ^core.Document, i: core.Node_Index, want: json.Value, why: ^strings.Builder) -> bool {
	switch kind := core.kind(doc, i); kind {
	case .Object:
		obj, is_obj := want.(json.Object)
		it := core.pairs(doc, i)
		buf: [4096]u8
		// Odin's JSON parser drops a member with an empty name, so the count and the value of one are not compared.
		named := 0
		for key in core.pair_next(&it) {
			if name, _ := core.text(doc, key, buf[:]); name != "" {
				named += 1
			}
		}
		if !is_obj || len(obj) != named {
			fmt.sbprintf(why, "table of %d named members against %v", named, want)
			return false
		}
		it = core.pairs(doc, i)
		for key, val in core.pair_next(&it) {
			name, _ := core.text(doc, key, buf[:])
			if name == "" {
				continue
			}
			expected, found := obj[name]
			if !found {
				fmt.sbprintf(why, "member %q is not expected", name)
				return false
			}
			if !matches(doc, val, expected, why) {
				return false
			}
		}
		return true
	case .Array:
		list, is_list := want.(json.Array)
		if !is_list || len(list) != core.length(doc, i) {
			fmt.sbprintf(why, "array of %d against %v", core.length(doc, i), want)
			return false
		}
		it := core.children(doc, i)
		for k := 0; true; k += 1 {
			val := core.child_next(&it) or_break
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
scalar_matches :: proc(doc: ^core.Document, i: core.Node_Index, want: json.Value, why: ^strings.Builder) -> bool {
	obj, is_obj := want.(json.Object)
	if !is_obj {
		fmt.sbprintf(why, "scalar against %v", want)
		return false
	}
	type, _ := obj["type"].(json.String)
	value, _ := obj["value"].(json.String)
	buf: [1 << 16]u8
	switch core.kind(doc, i) {
	case .True:
		return type == "bool" && value == "true"
	case .False:
		return type == "bool" && value == "false"
	case .String:
		text, _ := core.text(doc, i, buf[:])
		tag, tagged := core.fact_value(doc, i, .Tag)
		if tagged {
			ok := type == tag.text && datetime_form(text) == datetime_form(value)
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
number_matches :: proc(doc: ^core.Document, i: core.Node_Index, type, value: string, why: ^strings.Builder) -> bool {
	n, _ := core.number(doc, i)
	style, _ := core.fact_value(doc, i, .Style)
	switch style.text {
	case "integer", "hex", "octal", "binary":
		got := fmt.tprint(i64(n.bits))
		if type != "integer" || got != value {
			fmt.sbprintf(why, "integer %v against %v", got, value)
			return false
		}
		return true
	case "inf":
		return type == "float" && strings.trim_left(value, "+") == ("-inf" if n.bits >> 63 != 0 else "inf")
	case "nan":
		return type == "float" && strings.contains(value, "nan")
	case "float":
		want, ok := strconv.parse_f64(value)
		got := transmute(f64)n.bits
		if n.kind != .Float {
			got = f64(i64(n.bits))
		}
		if type != "float" || !ok || got != want {
			fmt.sbprintf(why, "float %v against %v", got, value)
			return false
		}
		return true
	}
	return false
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
		testing.expectf(t, matches(&doc, core.ROOT, want, &why), "%s: %s", name, strings.to_string(why))
		core.destroy(&doc)
		cases += 1
		free_all(context.temp_allocator)
	}
	return
}

@(test)
document_toml_1_0 :: proc(t: ^testing.T) {
	testing.expect_value(t, check_documents(t, LIST_1_0, .Toml_1_0), 208)
}

@(test)
document_toml_1_1 :: proc(t: ^testing.T) {
	testing.expect_value(t, check_documents(t, LIST_1_1, .Toml_1_1), 218)
}

@(test)
invalid_cases_do_not_build :: proc(t: ^testing.T) {
	for list, k in ([?]string{LIST_1_0, LIST_1_1}) {
		spec := toml.Spec(k)
		rest := list
		for name in strings.split_lines_iterator(&rest) {
			if !strings.has_prefix(name, "invalid/") || !strings.has_suffix(name, ".toml") {
				continue
			}
			data, _ := case_data(name)
			doc, err := core.build(data, toml.as(spec))
			fault, walked := err.(core.Fault)
			if !testing.expectf(t, walked && fault.kind != .No_Memory, "%s: built or failed otherwise: %v", name, err) {
				core.destroy(&doc)
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
[tbl]
k = [1, 2]
`

@(private)
node_at :: proc(t: ^testing.T, doc: ^core.Document, name: string) -> core.Node_Index {
	i, ok := core.member(doc, core.ROOT, name)
	testing.expectf(t, ok, "member %s", name)
	return i
}

@(test)
facts_name_datetimes_and_styles :: proc(t: ^testing.T) {
	doc, err := toml.build(transmute([]u8)string(SAMPLE), .Toml_1_1)
	testkit.expect_nil(t, err)
	defer core.destroy(&doc)
	tags := [?][2]string{{"when", "datetime"}, {"local", "datetime-local"}, {"day", "date-local"}, {"clock", "time-local"}}
	for pair in tags {
		fv, held := core.fact_value(&doc, node_at(t, &doc, pair[0]), .Tag)
		testing.expectf(t, held && fv.text == pair[1], "%s: %v", pair[0], fv)
	}
	_, tagged := core.fact_value(&doc, node_at(t, &doc, "title"), .Tag)
	testing.expect(t, !tagged)
	styles := [?][2]string{
		{"title", "basic"}, {"lit", "literal"}, {"ml", "multiline"}, {"mll", "multiline_literal"},
		{"a", "hex"}, {"o", "octal"}, {"b", "binary"}, {"f", "float"}, {"big", "integer"}, {"nf", "inf"}, {"nn", "nan"},
	}
	for pair in styles {
		fv, held := core.fact_value(&doc, node_at(t, &doc, pair[0]), .Style)
		testing.expectf(t, held && fv.text == pair[1], "%s: %v", pair[0], fv)
	}
}

@(test)
numbers_read_by_value :: proc(t: ^testing.T) {
	doc, _ := toml.build(transmute([]u8)string(SAMPLE), .Toml_1_1)
	defer core.destroy(&doc)
	ints := [?]struct {
		name:  string,
		value: i64,
	}{{"a", 0xdead_beef}, {"o", 0o17}, {"b", 0b1010}, {"big", 10}}
	for c in ints {
		n, ok := core.number(&doc, node_at(t, &doc, c.name))
		testing.expectf(t, ok && i64(n.bits) == c.value, "%s: %v", c.name, n)
	}
	n, _ := core.number(&doc, node_at(t, &doc, "f"))
	testing.expect_value(t, transmute(f64)n.bits, 10005.0)
	n, _ = core.number(&doc, node_at(t, &doc, "nf"))
	testing.expect_value(t, transmute(f64)n.bits, math.inf_f64(-1))
	n, _ = core.number(&doc, node_at(t, &doc, "nn"))
	testing.expect(t, math.is_nan(transmute(f64)n.bits))
	view := core.Token_View{src = transmute([]u8)string("x = 0o7")}
	octal, ok := toml.token_number(&view, core.Token{lo = 4, n = 3, kind = .Number, role = .Value, spelling = u16(toml.Number_Spelling.Octal)})
	testing.expect(t, ok && i64(octal.bits) == 7)
}

// A read that stops early gives the answer of a whole read, though a table's members may be written apart, and judges
// the statements before its answer but not those past the container that holds it.
@(test)
a_read_that_stops_early_answers_as_a_whole_read :: proc(t: ^testing.T) {
	texts := [?]string {
		"[[logs]]\nid = 1\n[logs.sub]\nk = 2\n[[logs]]\nid = 3\n",
		"[a]\nx = 1\n[b]\ny = 2\n[a.c]\nz = 3\n[[a.d]]\nw = 4\n[b.e]\n",
		"[a.b]\nk = 1\n[a]\nj = 2\nd.e.f = 3\ninline = {p = [1, [2]], q = {}}\n",
		"[[arr]]\nx = 1\n[other]\ny = 2\n[[arr]]\nx = 3\n[arr.sub]\nw = true\n# foot\n",
		"# head\n\nx = 1 # one\n[t] # table\ny = [ # open\n  1, # elem\n]\n",
	}
	paths := [?]string{".logs[0].id", ".logs[0]", ".logs[1].id", ".a", ".a.c.z", ".a.d[0].w", ".b", ".a.b", ".a.d.e", ".arr[0]", ".arr[1].sub", ".other.y", ".t.y[0]", ".x", ".nope"}
	for text in texts {
		src := transmute([]u8)text
		for path_text in paths {
			path, _ := core.parse_path(path_text, context.temp_allocator)
			whole, want, werr := toml.find(src, .Toml_1_1, path, read = {dups = .First})
			early, got, gerr := toml.find(src, .Toml_1_1, path, read = {dups = .First, stop_early = true})
			testkit.expect_nil(t, werr)
			testkit.expect_nil(t, gerr)
			testing.expectf(t, got.outcome == want.outcome, "%q %s: %v, want %v", text, path_text, got.outcome, want.outcome)
			if want.outcome == .Found && got.outcome == .Found {
				w, _, _ := core.write(&whole, {}, json_pkg.as(.Json), want.node, context.temp_allocator)
				g, _, _ := core.write(&early, {}, json_pkg.as(.Json), got.node, context.temp_allocator)
				testing.expectf(t, string(g) == string(w), "%q %s: %s, want %s", text, path_text, g, w)
			}
			core.destroy(&whole)
			core.destroy(&early)
		}
	}
	path, _ := core.parse_path(".logs[0].id", context.temp_allocator)
	open := transmute([]u8)string("[[logs]]\nid = 1\n[[logs]]\nid = [unclosed\n")
	doc, answer, err := toml.find(open, .Toml_1_1, path, read = {dups = .First, stop_early = true})
	testkit.expect_nil(t, err)
	testing.expect_value(t, string(core.span(&doc, answer.node)), "1")
	core.destroy(&doc)
	_, _, werr := toml.find(open, .Toml_1_1, path, allocator = context.temp_allocator)
	testkit.expect_kind(t, werr, core.Path_Error_Kind.Walk)
	bad := transmute([]u8)string("x = \"\\q\"\n[[logs]]\nid = 1\n")
	_, _, berr := toml.find(bad, .Toml_1_1, path, read = {dups = .First, stop_early = true}, allocator = context.temp_allocator)
	testkit.expect_kind(t, berr, core.Path_Error_Kind.Walk)
}

@(test)
path_reads_through_the_build :: proc(t: ^testing.T) {
	src := transmute([]u8)string(SAMPLE)
	path := core.Path{steps = {core.Name("tbl"), core.Name("k"), core.Index(1)}}
	doc, answer, err := toml.find(src, .Toml_1_1, path)
	testkit.expect_nil(t, err)
	defer core.destroy(&doc)
	testing.expect_value(t, answer.outcome, core.Presence.Found)
	n, _ := core.number(&doc, answer.node)
	testing.expect_value(t, n.bits, 2)

	missing := core.Path{steps = {core.Name("tbl"), core.Name("nope")}}
	doc2, answer2, _ := toml.find(src, .Toml_1_1, missing)
	defer core.destroy(&doc2)
	testing.expect_value(t, answer2.outcome, core.Presence.Missing)

	seen: [dynamic]string
	defer delete(seen)
	collect :: proc(state: rawptr, a: core.Token_Answer) -> bool {
		append((^[dynamic]string)(state), fmt.aprint(a.outcome, a.lo, a.hi))
		return true
	}
	eerr := toml.each_answer(src, .Toml_1_1, core.Path{steps = {core.Name("title")}}, &seen, collect)
	testkit.expect_nil(t, eerr)
	testing.expect_value(t, len(seen), 1)
	for s in seen {
		testing.expect_value(t, s, fmt.tprint(core.Presence.Found, 14, 17))
		delete(s)
	}
}

@(test)
build_faults_name_the_rule :: proc(t: ^testing.T) {
	_, err := toml.build(transmute([]u8)string("a = 1\na = 2\n"), .Toml_1_0)
	testkit.expect_kind(t, err, core.Document_Error_Kind.Walk)
	inner, _ := err.(core.Fault)
	testing.expect_value(t, toml.Detail(inner.detail), toml.Detail.Duplicate_Key)
	_, fault := core.build(transmute([]u8)string("x = 1979-13-01"), toml.as(.Toml_1_1))
	testkit.expect_kind(t, fault, core.Document_Error_Kind.Walk)
}

@(test)
json_output_spells_numbers_in_decimal :: proc(t: ^testing.T) {
	doc, _ := toml.build(transmute([]u8)string("a = 0xdead_beef\no = 0o17\nb = 0b1010\nbig = +1_0\nf = 1_0.5\nz = -0\nnz = -0.0\nd = 1979-05-27\ns = \"x\"\n"), .Toml_1_1)
	defer core.destroy(&doc)
	out, _, err := core.write(&doc, {}, json_pkg.as(.Json))
	defer delete(out)
	testkit.expect_nil(t, err)
	testing.expect_value(t, string(out), `{"a":3735928559,"o":15,"b":10,"big":10,"f":10.5,"z":0,"nz":-0.0,"d":"1979-05-27","s":"x"}`)
}

@(test)
json_output_refuses_inf_and_nan :: proc(t: ^testing.T) {
	doc, _ := toml.build(transmute([]u8)string("x = inf\n"), .Toml_1_1)
	defer core.destroy(&doc)
	out, _, err := core.write(&doc, {}, json_pkg.as(.Json))
	defer delete(out)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Non_Finite)
}
