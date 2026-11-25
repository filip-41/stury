package diff_test

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/diff"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(private = "file")
build_json :: proc(t: ^testing.T, text: string, spec := json.Spec.Json, max_depth := u32(0)) -> (doc: tape.Document, ok: bool) {
	opts := tape.Options{budget = {depth = max_depth}}
	err: tape.Error
	doc, err = json.build(transmute([]u8)text, spec, opts, runtime.heap_allocator())
	return doc, testing.expectf(t, err == nil, "%s: %v", text, err)
}

@(private = "file")
node_json :: proc(doc: ^tape.Document, at: tape.Node_Index, alloc: runtime.Allocator) -> string {
	out, _, err := json.write(doc, .Json, {node = at}, alloc)
	if err != nil {
		return ""
	}
	return string(out)
}

@(private = "file")
format_steps :: proc(sb: ^strings.Builder, steps: []tape.Step) {
	for s in steps {
		#partial switch step in s {
		case tape.Name:
			strings.write_byte(sb, '.')
			strings.write_string(sb, string(step))
		case tape.Index:
			fmt.sbprintf(sb, "[%d]", int(step))
		}
	}
}

@(private = "file")
render :: proc(r: diff.Result, a, b: ^tape.Document) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c, i in r.changes {
		if i > 0 {
			strings.write_byte(&sb, ';')
		}
		switch c.op {
		case .Added:
			strings.write_byte(&sb, '+')
		case .Removed:
			strings.write_byte(&sb, '-')
		case .Changed:
			strings.write_byte(&sb, '~')
		case .Fact:
			strings.write_byte(&sb, '#')
		}
		format_steps(&sb, c.path)
		if c.op == .Fact {
			strings.write_string(&sb, " ")
			strings.write_string(&sb, c.old_text)
			strings.write_string(&sb, " > ")
			strings.write_string(&sb, c.new_text)
			continue
		}
		if c.op != .Added {
			strings.write_string(&sb, " ")
			strings.write_string(&sb, node_json(a, c.old_node, context.temp_allocator))
		}
		if c.op != .Removed {
			strings.write_string(&sb, " > ")
			strings.write_string(&sb, node_json(b, c.new_node, context.temp_allocator))
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
expect_diff :: proc(t: ^testing.T, old, new, want: string, opts := diff.Options{}, spec := json.Spec.Json) -> bool {
	a, a_ok := build_json(t, old, spec)
	defer tape.destroy_document(&a)
	b, b_ok := build_json(t, new, spec)
	defer tape.destroy_document(&b)
	if !a_ok || !b_ok {
		return false
	}
	r, err := diff.diff_documents(&a, &b, opts, runtime.heap_allocator())
	testing.expect(t, err == nil)
	defer diff.destroy_result(&r)
	defer free_all(context.temp_allocator)
	got := render(r, &a, &b)
	return testing.expectf(t, got == want, "%s against %s: got %q, want %q", old, new, got, want)
}

@(test)
diff_objects :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_diff(t, `{"a":1,"b":2,"c":3}`, `{"b":2,"a":5,"d":4}`, `~.a 1 > 5;-.c 3;+.d > 4`)
	expect_diff(t, `{"a":{"x":[1]}}`, `{"a":{"x":[1]}}`, ``)
	expect_diff(t, `{"a":{"x":[1,2]}}`, `{"a":{"x":[1,3]}}`, `~.a.x[1] 2 > 3`)
	// Decoded escaped strings and keys compare by decoded text.
	expect_diff(t, `{"a\nb":"hi\u0021"}`, `{"a\u000ab":"hi!"}`, ``)
}

@(test)
diff_kinds_and_numbers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_diff(t, `1`, `"1"`, `~ 1 > "1"`)
	expect_diff(t, `[1.0,1e2,-0.0]`, `[1,100,0]`, ``)
	expect_diff(t, `{"a":null}`, `{"a":[]}`, `~.a null > []`)
	a, a_ok := build_json(t, `{"a":null}`)
	defer tape.destroy_document(&a)
	b, b_ok := build_json(t, `{"a":false}`)
	defer tape.destroy_document(&b)
	if !a_ok || !b_ok {
		return
	}
	r, _ := diff.diff_documents(&a, &b, {}, runtime.heap_allocator())
	defer diff.destroy_result(&r)
	testing.expect(t, len(r.changes) == 1 && r.changes[0].kind_changed)
}

@(test)
diff_array_modes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_diff(t, `[1,2,3,4]`, `[1,3,4,5]`, `-[1] 2;+[3] > 5`)
	expect_diff(t, `[1,2,3]`, `[1,9,3]`, `~[1] 2 > 9`)
	expect_diff(t, `[3,1,2]`, `[1,2,3]`, `-[0] 3;+[2] > 3`)
	expect_diff(t, `[3,1,2]`, `[1,2,3]`, ``, {arrays = .Set})
	expect_diff(t, `[3,1,2]`, `[1,2,3]`, ``, {ignore_order = true})
	expect_diff(t, `[1,1,2]`, `[1,2,2]`, `+[2] > 2;-[1] 1`, {arrays = .Set})
	expect_diff(t, `[1,2,3]`, `[2,3]`, `~[0] 1 > 2;~[1] 2 > 3;-[2] 3`, {arrays = .Position})
}

@(test)
diff_keyed_arrays :: proc(t: ^testing.T) {
	testkit.deadline(t)
	old := `[{"id":1,"v":"a"},{"id":2,"v":"b"},{"id":3,"v":"c"}]`
	new := `[{"id":3,"v":"c"},{"id":2,"v":"B"},{"id":4,"v":"d"}]`
	keys := []diff.Key_Rule{{member = "id"}}
	expect_diff(t, old, new, `~[1].v "b" > "B";+[2] > {"id":4,"v":"d"};-[0] {"id":1,"v":"a"}`, {keys = keys})
	nested := []diff.Key_Rule{{at = {tape.Name("rows")}, member = "id"}}
	expect_diff(t, `{"rows":[{"id":1,"v":1},{"id":2,"v":2}]}`, `{"rows":[{"id":2,"v":3},{"id":1,"v":1}]}`, `~.rows[0].v 2 > 3`, {keys = nested})
}

@(test)
diff_facts_jsonc_xml_and_toml :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	expect_diff(t, `{"a":1 /*x*/}`, `{"a":1 /*y*/}`, `#.a x > y`, {facts = true}, .Jsonc)
	expect_diff(t, `{"a":1 /*x*/}`, `{"a":1 /*x*/}`, ``, {facts = true}, .Jsonc)
	expect_diff(t, `{"a":1 /*x*/}`, `{"a":1 /*y*/}`, ``, {}, .Jsonc)

	// Strict JSON vs JSONC: comments are ignored when one format does not carry them.
	jsonc, _ := build_json(t, `{"a":1 /*x*/}`, .Jsonc)
	defer tape.destroy_document(&jsonc)
	strict, _ := build_json(t, `{"a":1}`)
	defer tape.destroy_document(&strict)
	r, _ := diff.diff_documents(&jsonc, &strict, {facts = true}, alloc)
	defer diff.destroy_result(&r)
	testing.expect_value(t, len(r.changes), 0)

	// XML attribute facts.
	xa, e1 := xml.build(transmute([]u8)string(`<r a="1" b="2">hi</r>`), .Xml, {}, alloc)
	xb, e2 := xml.build(transmute([]u8)string(`<r b="2" a="9">hi</r>`), .Xml, {}, alloc)
	defer tape.destroy_document(&xa)
	defer tape.destroy_document(&xb)
	testing.expect(t, e1 == nil && e2 == nil)
	xr, _ := diff.diff_documents(&xa, &xb, {facts = true}, alloc)
	defer diff.destroy_result(&xr)
	testing.expect_value(t, len(xr.changes), 1)
	testing.expect_value(t, xr.changes[0].op, diff.Op.Fact)
	testing.expect_value(t, xr.changes[0].fact_kind, tape.Fact_Kind.Attribute)
	testing.expect_value(t, xr.changes[0].old_text, "a=1\nb=2")
	testing.expect_value(t, xr.changes[0].new_text, "a=9\nb=2")

	// TOML comments & tags.
	ta, te1 := toml.build(transmute([]u8)string("# c1\nd = 2024-01-02\n"), .Toml_1_0, {}, alloc)
	tb, te2 := toml.build(transmute([]u8)string("# c2\nd = 2024-01-02\n"), .Toml_1_0, {}, alloc)
	defer tape.destroy_document(&ta)
	defer tape.destroy_document(&tb)
	testing.expect(t, te1 == nil && te2 == nil)
	tr, _ := diff.diff_documents(&ta, &tb, {facts = true}, alloc)
	defer diff.destroy_result(&tr)
	testing.expect(t, len(tr.changes) == 1 && tr.changes[0].op == .Fact && tr.changes[0].old_text == "c1" && tr.changes[0].new_text == "c2")
}

@(private = "file")
lcs_length :: proc(xs, ys: []int) -> int {
	row := make([]int, len(ys) + 1, context.temp_allocator)
	for x in xs {
		diag := 0
		for y, j in ys {
			above := row[j + 1]
			row[j + 1] = diag + 1 if x == y else max(row[j + 1], row[j])
			diag = above
		}
	}
	return row[len(ys)]
}

@(private = "file")
array_text :: proc(xs: []int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '[')
	for x, i in xs {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, "%d", x)
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}

@(test)
diff_sequence_is_minimal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	r := rand.create(0x5d1ff)
	rng := rand.default_random_generator(&r)
	for _ in 0 ..< 400 {
		xs := make([]int, rand.int_max(24, rng), context.temp_allocator)
		ys := make([]int, rand.int_max(24, rng), context.temp_allocator)
		alphabet := 2 + rand.int_max(5, rng)
		for &x in xs {
			x = rand.int_max(alphabet, rng)
		}
		for &y in ys {
			y = rand.int_max(alphabet, rng)
		}
		a, a_ok := build_json(t, array_text(xs))
		b, b_ok := build_json(t, array_text(ys))
		if !a_ok || !b_ok {
			tape.destroy_document(&a)
			tape.destroy_document(&b)
			return
		}
		res, _ := diff.diff_documents(&a, &b, {}, runtime.heap_allocator())
		removed, added := 0, 0
		for c in res.changes {
			switch c.op {
			case .Removed:
				removed += 1
			case .Added:
				added += 1
			case .Changed:
				removed, added = removed + 1, added + 1
			case .Fact:
			}
		}
		keep := lcs_length(xs, ys)
		ok := testing.expectf(t, removed == len(xs) - keep && added == len(ys) - keep, "%s against %s: rem %d add %d, want %d %d", array_text(xs), array_text(ys), removed, added, len(xs) - keep, len(ys) - keep)
		diff.destroy_result(&res)
		tape.destroy_document(&a)
		tape.destroy_document(&b)
		free_all(context.temp_allocator)
		if !ok {
			return
		}
	}
}

@(test)
diff_bounds_long_arrays_and_edit_cap :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	defer free_all(context.temp_allocator)

	// Edit cap triggers truncation.
	{
		a, _ := build_json(t, `[1,2,3,4,5,6]`)
		defer tape.destroy_document(&a)
		b, _ := build_json(t, `[7,8,9,10,11,12]`)
		defer tape.destroy_document(&b)
		r, _ := diff.diff_documents(&a, &b, {max_edits = 4}, alloc)
		defer diff.destroy_result(&r)
		testing.expect(t, r.truncated && len(r.changes) == 1 && r.changes[0].op == .Changed)
	}

	// max_changes stops early.
	{
		a, _ := build_json(t, `{"a":1,"b":2,"c":3,"d":4}`)
		defer tape.destroy_document(&a)
		b, _ := build_json(t, `{"a":9,"b":9,"c":9,"d":9}`)
		defer tape.destroy_document(&b)
		r, _ := diff.diff_documents(&a, &b, {max_changes = 2}, alloc)
		defer diff.destroy_result(&r)
		testing.expect(t, r.truncated && len(r.changes) == 2)
	}

	// Long 20,000-element array with scattered edits.
	{
		n := 20_000
		xs := make([]int, n, context.temp_allocator)
		ys := make([]int, n, context.temp_allocator)
		for i in 0 ..< n {
			xs[i], ys[i] = i, i
		}
		for i := 7; i < n; i += 1009 {
			ys[i] = -1 - i
		}
		a, a_ok := build_json(t, array_text(xs))
		defer tape.destroy_document(&a)
		b, b_ok := build_json(t, array_text(ys))
		defer tape.destroy_document(&b)
		if !a_ok || !b_ok {
			return
		}
		r, _ := diff.diff_documents(&a, &b, {}, alloc)
		defer diff.destroy_result(&r)
		testing.expectf(t, !r.truncated && len(r.changes) == (n - 7 + 1008) / 1009, "got %d changes", len(r.changes))
	}
}

@(private = "file")
deep_array :: proc(levels: int, leaf: string, alloc: runtime.Allocator) -> string {
	b := make([]u8, 2 * levels + len(leaf), alloc)
	for i in 0 ..< levels {
		b[i] = '['
		b[levels + len(leaf) + i] = ']'
	}
	copy(b[levels:], leaf)
	return string(b)
}

// Explicit heap stack proof: 10,000-level deep nesting works cleanly with zero native recursion,
// and respects `max_depth` when exceeded.
@(test)
diff_deep_nesting_10000_levels :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	LEVELS :: 10_000
	sa := deep_array(LEVELS, "0", alloc)
	defer delete(sa, alloc)
	sb := deep_array(LEVELS, "1", alloc)
	defer delete(sb, alloc)

	a, a_ok := build_json(t, sa, .Json, max_depth = 12_000)
	defer tape.destroy_document(&a)
	b, b_ok := build_json(t, sb, .Json, max_depth = 12_000)
	defer tape.destroy_document(&b)
	if !a_ok || !b_ok {
		return
	}

	r, err := diff.diff_documents(&a, &b, {max_depth = 12_000}, alloc)
	testing.expect(t, err == nil)
	testing.expectf(t, !r.too_deep && len(r.changes) == 1 && len(r.changes[0].path) == LEVELS, "too_deep=%v changes=%d", r.too_deep, len(r.changes))
	diff.destroy_result(&r)

	p, perr := diff.diff_to_patch(&a, &b, {max_depth = 12_000}, alloc)
	testing.expect(t, perr == nil)
	testing.expect(t, !p.too_deep && len(p.ops) == 1 && p.ops[0].op == .Replace)
	diff.destroy_patch(&p)

	// Exceeding `max_depth` reports `too_deep`.
	r2, _ := diff.diff_documents(&a, &b, {max_depth = 512}, alloc)
	testing.expect(t, r2.too_deep)
	diff.destroy_result(&r2)
}

@(test)
pointer_rfc6901_encoding_and_decoding :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// Root.
	root_s, e0 := diff.encode_pointer(nil, alloc)
	testing.expect(t, e0 == nil && root_s == "")
	root_toks, de0 := diff.decode_pointer("", alloc)
	testing.expect(t, de0 == .None && len(root_toks) == 0)

	// Escaping `~` -> `~0`, `/` -> `~1`, and empty key.
	steps := []tape.Step{tape.Name("a/b"), tape.Name("m~n"), tape.Index(0), tape.Name("~1/0"), tape.Name("")}
	enc, e1 := diff.encode_pointer(steps, alloc)
	defer delete(enc, alloc)
	testing.expect(t, e1 == nil)
	testing.expect_value(t, enc, "/a~1b/m~0n/0/~01~10/")

	toks, de1 := diff.decode_pointer(enc, alloc)
	defer diff.destroy_pointer_tokens(toks, alloc)
	testing.expect(t, de1 == .None && len(toks) == 5)
	testing.expect_value(t, toks[0], "a/b")
	testing.expect_value(t, toks[1], "m~n")
	testing.expect_value(t, toks[2], "0")
	testing.expect_value(t, toks[3], "~1/0")
	testing.expect_value(t, toks[4], "")

	// Error cases.
	_, err_slash := diff.decode_pointer("no-leading-slash", alloc)
	testing.expect_value(t, err_slash, diff.Pointer_Error.Missing_Slash)
	_, err_bad := diff.decode_pointer("/a~2b", alloc)
	testing.expect_value(t, err_bad, diff.Pointer_Error.Bad_Escape)
	_, err_trail := diff.decode_pointer("/a~", alloc)
	testing.expect_value(t, err_trail, diff.Pointer_Error.Bad_Escape)

	// Strict RFC 6901 array index parsing.
	idx, dash, ok := diff.parse_array_index("-")
	testing.expect(t, ok && dash && idx == 0)
	idx, dash, ok = diff.parse_array_index("0")
	testing.expect(t, ok && !dash && idx == 0)
	idx, dash, ok = diff.parse_array_index("42")
	testing.expect(t, ok && !dash && idx == 42)
	_, _, ok = diff.parse_array_index("01")
	testing.expect(t, !ok)
	_, _, ok = diff.parse_array_index("00")
	testing.expect(t, !ok)
	_, _, ok = diff.parse_array_index("-1")
	testing.expect(t, !ok)
	_, _, ok = diff.parse_array_index("")
	testing.expect(t, !ok)
}

@(test)
diff_to_patch_basic :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	a, _ := build_json(t, `{"a/b":1,"rm":true,"arr":[1,2,3,4]}`)
	defer tape.destroy_document(&a)
	b, _ := build_json(t, `{"a/b":2,"add":"ok","arr":[1,3,4,5]}`)
	defer tape.destroy_document(&b)

	p, err := diff.diff_to_patch(&a, &b, {}, alloc)
	testing.expect(t, err == nil)
	defer diff.destroy_patch(&p)
	testing.expect_value(t, len(p.ops), 5)
	testing.expect(t, p.ops[0].op == .Replace && p.ops[0].path == "/a~1b")
	testing.expect(t, p.ops[1].op == .Remove && p.ops[1].path == "/rm")
	testing.expect(t, p.ops[2].op == .Remove && p.ops[2].path == "/arr/1")
	testing.expect(t, p.ops[3].op == .Add && p.ops[3].path == "/arr/3")
	testing.expect(t, p.ops[4].op == .Add && p.ops[4].path == "/add")
}

// C1: XML `.Group` repeated elements compare as ordered grouped arrays in diff, hash, equality, and diff_to_patch.
@(test)
diff_xml_group_repeated_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. Repeated sibling key with changed 2nd element MUST detect the diff (not 0 changes!).
	{
		xa, ea := xml.build(transmute([]u8)string(`<r><a>1</a><a>1</a></r>`), .Xml, {}, alloc)
		xb, eb := xml.build(transmute([]u8)string(`<r><a>1</a><a>2</a></r>`), .Xml, {}, alloc)
		defer tape.destroy_document(&xa)
		defer tape.destroy_document(&xb)
		testing.expect(t, ea == nil && eb == nil)

		r, err := diff.diff_documents(&xa, &xb, {}, alloc)
		testing.expect(t, err == nil)
		defer diff.destroy_result(&r)
		testing.expect_value(t, len(r.changes), 1)
		testing.expect_value(t, r.changes[0].op, diff.Op.Changed)
		testing.expect(t, tape.steps_equal(r.changes[0].path, {tape.Name("r"), tape.Name("a"), tape.Index(1)}))

		p, perr := diff.diff_to_patch(&xa, &xb, {}, alloc)
		testing.expect(t, perr == nil)
		defer diff.destroy_patch(&p)
		testing.expect_value(t, len(p.ops), 1)
		testing.expect(t, p.ops[0].op == .Replace && p.ops[0].path == "/r/a/1")
	}

	// 2. Single element vs repeated group detects kind change and emits grouped Patch_Op.
	{
		xa, ea := xml.build(transmute([]u8)string(`<r><a>1</a></r>`), .Xml, {}, alloc)
		xb, eb := xml.build(transmute([]u8)string(`<r><a>1</a><a>2</a></r>`), .Xml, {}, alloc)
		defer tape.destroy_document(&xa)
		defer tape.destroy_document(&xb)
		testing.expect(t, ea == nil && eb == nil)

		r, _ := diff.diff_documents(&xa, &xb, {}, alloc)
		defer diff.destroy_result(&r)
		testing.expect(t, len(r.changes) == 1 && r.changes[0].op == .Changed && r.changes[0].kind_changed)

		p, _ := diff.diff_to_patch(&xa, &xb, {}, alloc)
		defer diff.destroy_patch(&p)
		testing.expect(t, len(p.ops) == 1 && p.ops[0].op == .Replace && p.ops[0].path == "/r/a" && len(p.ops[0].nodes) == 2)
	}

	// 3. Interleaved XML repeated keys equal contiguous order & cross-format JSON array.
	{
		xa, ea := xml.build(transmute([]u8)string(`<r><a>1</a><b>2</b><a>3</a></r>`), .Xml, {}, alloc)
		xb, eb := xml.build(transmute([]u8)string(`<r><a>1</a><a>3</a><b>2</b></r>`), .Xml, {}, alloc)
		jdoc, ej := json.build(transmute([]u8)string(`{"r":{"a":["1","3"],"b":"2"}}`), .Json, {}, alloc)
		defer tape.destroy_document(&xa)
		defer tape.destroy_document(&xb)
		defer tape.destroy_document(&jdoc)
		testing.expect(t, ea == nil && eb == nil && ej == nil)

		r1, _ := diff.diff_documents(&xa, &xb, {}, alloc)
		defer diff.destroy_result(&r1)
		testing.expect_value(t, len(r1.changes), 0)

		r2, _ := diff.diff_documents(&xa, &jdoc, {}, alloc)
		defer diff.destroy_result(&r2)
		testing.expect_value(t, len(r2.changes), 0)
	}
}

// C2: CBOR `.Wide` bignums, exact decimals, negative -2^64, and unspellable >8192-byte bignum raw-bytes fallback.
@(test)
diff_cbor_wide_numbers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	make_cbor_bignum :: proc(byte_len: int, low_byte: u8, alloc: runtime.Allocator) -> []u8 {
		// Tag 2 (0xC2) + byte string header (2-byte len 0x59 for >= 256, 1-byte 0x58 for 24..255) + 0x01 + zeros + low_byte.
		out := make([dynamic]u8, 0, byte_len + 4, alloc)
		append(&out, 0xC2)
		if byte_len < 256 {
			append(&out, 0x58, u8(byte_len))
		} else {
			append(&out, 0x59, u8(byte_len >> 8), u8(byte_len & 0xFF))
		}
		append(&out, 0x01)
		for _ in 1 ..< byte_len - 1 {
			append(&out, 0x00)
		}
		append(&out, low_byte)
		return out[:]
	}

	// 1. 2^2000 vs 2^2000 + 1 (251-byte bignums): MUST compare unequal, identical MUST compare equal!
	{
		b1 := make_cbor_bignum(251, 0x00, alloc)
		b2 := make_cbor_bignum(251, 0x01, alloc)
		defer delete(b1, alloc)
		defer delete(b2, alloc)
		d1, e1 := cbor.build(b1, .Cbor, {}, alloc)
		d2, e2 := cbor.build(b2, .Cbor, {}, alloc)
		defer tape.destroy_document(&d1)
		defer tape.destroy_document(&d2)
		testing.expect(t, e1 == nil && e2 == nil)

		r_eq, _ := diff.diff_documents(&d1, &d1, {}, alloc)
		defer diff.destroy_result(&r_eq)
		testing.expect_value(t, len(r_eq.changes), 0)

		r_ne, _ := diff.diff_documents(&d1, &d2, {}, alloc)
		defer diff.destroy_result(&r_ne)
		testing.expect_value(t, len(r_ne.changes), 1)
	}

	// 2. CBOR 10^20 + 1 vs JSON 100000000000000000001: cross-format exact equality!
	{
		// 10^20 + 1 = 0x05_6BC7_5E2D_6310_0001 (9 bytes).
		cbytes := []u8{0xC2, 0x49, 0x05, 0x6B, 0xC7, 0x5E, 0x2D, 0x63, 0x10, 0x00, 0x01}
		cdoc, ce := cbor.build(cbytes, .Cbor, {}, alloc)
		jdoc, je := json.build(transmute([]u8)string(`100000000000000000001`), .Json, {}, alloc)
		jdoc2, je2 := json.build(transmute([]u8)string(`100000000000000000002`), .Json, {}, alloc)
		defer tape.destroy_document(&cdoc)
		defer tape.destroy_document(&jdoc)
		defer tape.destroy_document(&jdoc2)
		testing.expect(t, ce == nil && je == nil && je2 == nil)

		r_eq, _ := diff.diff_documents(&cdoc, &jdoc, {}, alloc)
		defer diff.destroy_result(&r_eq)
		testing.expect_value(t, len(r_eq.changes), 0)

		r_ne, _ := diff.diff_documents(&cdoc, &jdoc2, {}, alloc)
		defer diff.destroy_result(&r_ne)
		testing.expect_value(t, len(r_ne.changes), 1)
	}

	// 3. CBOR Decimal(-30, 1) (tag 4, [-30, 1]) vs JSON 1e-30 (equal) and 2e-30 (unequal).
	{
		// Tag 4 (0xC4), array(2) (0x82), negative int -30 = -1 - 29 (0x38, 0x1D), uint 1 (0x01).
		dbytes := []u8{0xC4, 0x82, 0x38, 0x1D, 0x01}
		cdoc, ce := cbor.build(dbytes, .Cbor, {}, alloc)
		j1, je1 := json.build(transmute([]u8)string(`1e-30`), .Json, {}, alloc)
		j2, je2 := json.build(transmute([]u8)string(`2e-30`), .Json, {}, alloc)
		defer tape.destroy_document(&cdoc)
		defer tape.destroy_document(&j1)
		defer tape.destroy_document(&j2)
		testing.expect(t, ce == nil && je1 == nil && je2 == nil)

		r_eq, _ := diff.diff_documents(&cdoc, &j1, {}, alloc)
		defer diff.destroy_result(&r_eq)
		testing.expect_value(t, len(r_eq.changes), 0)

		r_ne, _ := diff.diff_documents(&cdoc, &j2, {}, alloc)
		defer diff.destroy_result(&r_ne)
		testing.expect_value(t, len(r_ne.changes), 1)
	}

	// 4. CBOR -2^64 (major 1, arg = max(u64), `.Float` with `form.kind == 0`) vs JSON -18446744073709551616.
	{
		cneg := []u8{0x3B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
		cdoc, ce := cbor.build(cneg, .Cbor, {}, alloc)
		jdoc, je := json.build(transmute([]u8)string(`-18446744073709551616`), .Json, {}, alloc)
		defer tape.destroy_document(&cdoc)
		defer tape.destroy_document(&jdoc)
		testing.expect(t, ce == nil && je == nil)

		r, _ := diff.diff_documents(&cdoc, &jdoc, {}, alloc)
		defer diff.destroy_result(&r)
		testing.expect_value(t, len(r.changes), 0)
	}

	// 5. Huge CBOR bignums past `BIGNUM_BYTES_MAX` (8200 bytes): raw-bytes fallback keeps distinct bignums unequal.
	{
		h1 := make_cbor_bignum(8200, 0x00, alloc)
		h2 := make_cbor_bignum(8200, 0x01, alloc)
		defer delete(h1, alloc)
		defer delete(h2, alloc)
		d1, e1 := cbor.build(h1, .Cbor, {}, alloc)
		d2, e2 := cbor.build(h2, .Cbor, {}, alloc)
		defer tape.destroy_document(&d1)
		defer tape.destroy_document(&d2)
		testing.expect(t, e1 == nil && e2 == nil)

		r_eq, _ := diff.diff_documents(&d1, &d1, {}, alloc)
		defer diff.destroy_result(&r_eq)
		testing.expect_value(t, len(r_eq.changes), 0)

		r_ne, _ := diff.diff_documents(&d1, &d2, {}, alloc)
		defer diff.destroy_result(&r_ne)
		testing.expect_value(t, len(r_ne.changes), 1)
	}
}

// H1 + M2: `diff_to_patch` loop break on `max_changes`/`too_deep`, and empty `{}`/`[]` at `depth == max_depth`.
@(test)
diff_patch_limits_and_empty_containers_at_max_depth :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// M2: Empty `{}` and `[]` at exact `max_depth` compare equal with `!too_deep`.
	for txt in ([?]string{`[[{}]]`, `[[[]]]`}) {
		a, _ := build_json(t, txt)
		b, _ := build_json(t, txt)
		defer tape.destroy_document(&a)
		defer tape.destroy_document(&b)
		r, err := diff.diff_documents(&a, &b, {max_depth = 2}, alloc)
		testing.expect(t, err == nil && !r.too_deep && len(r.changes) == 0)
		diff.destroy_result(&r)
	}

	// Non-empty container at `depth == max_depth` still marks `too_deep`.
	{
		a, _ := build_json(t, `[[[1]]]`)
		b, _ := build_json(t, `[[[1]]]`)
		defer tape.destroy_document(&a)
		defer tape.destroy_document(&b)
		r, _ := diff.diff_documents(&a, &b, {max_depth = 2}, alloc)
		testing.expect(t, r.too_deep)
		diff.destroy_result(&r)
	}

	// H1: `diff_to_patch` stops immediately at `max_changes` (labeled `break patch_loop`).
	{
		a, _ := build_json(t, `{"a":1,"b":2,"c":3,"d":4}`)
		b, _ := build_json(t, `{"a":9,"b":9,"c":9,"d":9}`)
		defer tape.destroy_document(&a)
		defer tape.destroy_document(&b)
		p, err := diff.diff_to_patch(&a, &b, {max_changes = 2}, alloc)
		testing.expect(t, err == nil && p.truncated && len(p.ops) == 2)
		diff.destroy_patch(&p)
	}

	// H1: `diff_to_patch` stops immediately on `too_deep` without emitting sibling ops after it.
	{
		a, _ := build_json(t, `{"a":{"x":1},"b":2}`)
		b, _ := build_json(t, `{"a":{"x":9},"b":99}`)
		defer tape.destroy_document(&a)
		defer tape.destroy_document(&b)
		p, err := diff.diff_to_patch(&a, &b, {max_depth = 1}, alloc)
		testing.expect(t, err == nil && p.too_deep && len(p.ops) == 0)
		diff.destroy_patch(&p)
	}
}
