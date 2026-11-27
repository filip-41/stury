package gates_tests

import "core:c"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:capi"
import "stury:cbor"
import "stury:engine"
import "stury:html"
import "stury:json"
import "stury:jsonpath"
import "stury:lib/core/tape"
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import "stury:lib/query"
import "stury:msgpack"
import "stury:stury"
import "stury:testkit"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

@(private = "file")
ONE_MIB :: uint(1 << 20)

@(private = "file")
DEEP :: 100_000

@(private = "file")
DEEP_LIMIT :: DEEP + 16

@(private = "file")
DEEP_BUDGET :: tape.Budget{depth = DEEP_LIMIT}

@(private = "file")
make_nested_json_array :: proc(depth: int, leaf: string, allocator := context.allocator) -> []u8 {
	b := strings.builder_make_len_cap(0, depth * 2 + len(leaf), allocator)
	for _ in 0 ..< depth {
		strings.write_byte(&b, '[')
	}
	strings.write_string(&b, leaf)
	for _ in 0 ..< depth {
		strings.write_byte(&b, ']')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_nested_json_object :: proc(depth: int, leaf: string, allocator := context.allocator) -> []u8 {
	b := strings.builder_make_len_cap(0, depth * 6 + len(leaf), allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, `{"a":`)
	}
	strings.write_string(&b, leaf)
	for _ in 0 ..< depth {
		strings.write_byte(&b, '}')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_nested_cbor_array :: proc(depth: int, allocator := context.allocator) -> []u8 {
	buf := make([]u8, depth + 1, allocator)
	for i in 0 ..< depth {
		buf[i] = 0x81 // 1-element definite array
	}
	buf[depth] = 0x01 // uint 1
	return buf
}

@(private = "file")
make_nested_toml_arrays :: proc(depth: int, allocator := context.allocator) -> []u8 {
	b := strings.builder_make_len_cap(0, depth * 2 + 8, allocator)
	strings.write_string(&b, "a = ")
	for _ in 0 ..< depth {
		strings.write_byte(&b, '[')
	}
	strings.write_byte(&b, '1')
	for _ in 0 ..< depth {
		strings.write_byte(&b, ']')
	}
	strings.write_byte(&b, '\n')
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_nested_toml_dotted :: proc(depth: int, allocator := context.allocator) -> []u8 {
	b := strings.builder_make_len_cap(0, depth * 2 + 8, allocator)
	strings.write_byte(&b, 'a')
	for _ in 1 ..< depth {
		strings.write_string(&b, ".a")
	}
	strings.write_string(&b, " = 1\n")
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_nested_xml :: proc(depth: int, allocator := context.allocator) -> []u8 {
	b := strings.builder_make_len_cap(0, depth * 7 + 1, allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, "<a>")
	}
	strings.write_byte(&b, '1')
	for _ in 0 ..< depth {
		strings.write_string(&b, "</a>")
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_nested_yaml_flow :: proc(depth: int, leaf: string, allocator := context.allocator) -> []u8 {
	b := strings.builder_make_len_cap(0, depth * 2 + len(leaf) + 4, allocator)
	strings.write_string(&b, "a: ")
	for _ in 0 ..< depth {
		strings.write_byte(&b, '[')
	}
	strings.write_string(&b, leaf)
	for _ in 0 ..< depth {
		strings.write_byte(&b, ']')
	}
	strings.write_byte(&b, '\n')
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_nested_html :: proc(depth: int, allocator := context.allocator) -> []u8 {
	b := strings.builder_make_len_cap(0, depth * 11 + 1, allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, "<div>")
	}
	strings.write_byte(&b, '1')
	for _ in 0 ..< depth {
		strings.write_string(&b, "</div>")
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
make_nested_msgpack_array :: proc(depth: int, allocator := context.allocator) -> []u8 {
	buf := make([]u8, depth + 1, allocator)
	for i in 0 ..< depth {
		buf[i] = 0x91 // 1-element fixarray
	}
	buf[depth] = 0x01 // positive fixint 1
	return buf
}

@(private = "file")
is_depth_exceeded :: proc(err: tape.Error) -> bool {
	exc, ok := err.(tape.Exceeded)
	return ok && exc.kind == .Depth
}

// Exercises cross-cutting JSON public entry points at 100k depth on a 1 MiB stack
// (validate/build/find/scan are covered by `json/test/stack_posix.odin`):
// 0: default depth rejection (validate, build, find, scan)
// 1: build -> write round-trip (100k)
// 2: build -> diff (identical & leaf-modified 100k docs)
// 3: build -> edit (init + set_path + commit + commit_document)
@(private = "file")
run_json_100k :: proc(op: int, text: []u8) -> bool {
	is_obj := len(text) > 0 && text[0] == '{'
	step0 := tape.Step(tape.Name("a")) if is_obj else tape.Step(tape.Index(0))
	path1 := [1]tape.Step{step0}
	opts := json.Options{budget = DEEP_BUDGET}

	switch op {
	case 0:
		// Default depth (10,000) must reject cleanly without stack overflow.
		if !is_depth_exceeded(json.validate(text)) {
			return false
		}
		doc, berr := json.build(text)
		tape.destroy(&doc)
		if !is_depth_exceeded(berr) {
			return false
		}
		_, ferr := json.find(text, path1[:])
		if !is_depth_exceeded(ferr) {
			return false
		}
		dem, derr := tape.demand_of({path1[:]})
		defer tape.destroy(&dem)
		if derr != nil {
			return false
		}
		sdoc, serr := json.scan(text, &dem)
		tape.destroy(&sdoc)
		return is_depth_exceeded(serr)

	case 1:
		doc, err := json.build(text, .Json, opts)
		defer tape.destroy(&doc)
		if err != nil {
			return false
		}
		// 1. Compact dense writer at 100,000 depth.
		out, _, werr := json.write(&doc, .Json)
		defer delete(out)
		if werr != nil || len(out) != len(text) || string(out) != string(text) {
			return false
		}
		// 2. Non-dense `write_tree` writer (`sort_keys = true`) at 100,000 depth.
		out_tree, _, werr_tree := json.write(&doc, .Json, {sort_keys = true})
		defer delete(out_tree)
		if werr_tree != nil || len(out_tree) != len(text) || string(out_tree) != string(text) {
			return false
		}
		// 3. Pretty `write_tree` writer (`indent = 2`) at 2,000 depth (~8 MiB indented output;
		//    100k indented would emit ~20 GiB of O(D^2) indentation spaces).
		pretty_src := make_nested_json_object(2_000, "1") if is_obj else make_nested_json_array(2_000, "1")
		defer delete(pretty_src)
		pretty_doc, pberr := json.build(pretty_src, .Json, {budget = {depth = 2_016}})
		defer tape.destroy(&pretty_doc)
		if pberr != nil {
			return false
		}
		out_pretty, _, werr_pretty := json.write(&pretty_doc, .Json, {indent = 2})
		defer delete(out_pretty)
		return werr_pretty == nil && len(out_pretty) > len(pretty_src) && json.validate(out_pretty, .Json, {budget = {depth = 2_016}}) == nil

	case 2:
		doc_a, err_a := json.build(text, .Json, opts)
		defer tape.destroy(&doc_a)
		if err_a != nil {
			return false
		}
		// Identical 100k docs -> 0 changes.
		res_eq, derr_eq := diff.diff_documents(&doc_a, &doc_a, {max_depth = DEEP_LIMIT})
		defer diff.destroy_result(&res_eq)
		if derr_eq != nil || res_eq.too_deep || len(res_eq.changes) != 0 {
			return false
		}
		// Leaf-modified 100k doc -> 1 change at depth DEEP.
		alt := make_nested_json_object(DEEP, "2") if is_obj else make_nested_json_array(DEEP, "2")
		defer delete(alt)
		doc_b, err_b := json.build(alt, .Json, opts)
		defer tape.destroy(&doc_b)
		if err_b != nil {
			return false
		}
		res_neq, derr_neq := diff.diff_documents(&doc_a, &doc_b, {max_depth = DEEP_LIMIT})
		defer diff.destroy_result(&res_neq)
		return derr_neq == nil && !res_neq.too_deep && len(res_neq.changes) == 1 && len(res_neq.changes[0].path) == DEEP

	case 3:
		// Wrap the 100k-deep payload alongside a sibling scalar (`[0, <100k>]` or `{"k":0,"a":<100k>}`)
		// so we exercise BOTH `json.commit` (on the 100k-deep document) AND `json.commit_document`
		// incremental `walk_fragment` splicing at 100k depth with `DEEP_BUDGET`.
		wrapped_b := strings.builder_make_len_cap(0, len(text) + 16)
		defer strings.builder_destroy(&wrapped_b)
		if is_obj {
			strings.write_string(&wrapped_b, `{"k":0,"a":`)
			strings.write_bytes(&wrapped_b, text)
			strings.write_byte(&wrapped_b, '}')
		} else {
			strings.write_string(&wrapped_b, `[0,`)
			strings.write_bytes(&wrapped_b, text)
			strings.write_byte(&wrapped_b, ']')
		}
		wrapped := transmute([]u8)strings.to_string(wrapped_b)

		doc, err := json.build(wrapped, .Json, opts)
		defer tape.destroy(&doc)
		if err != nil {
			return false
		}
		ov: json.Overlay
		if json.edit_init(&ov, &doc) != nil {
			return false
		}
		defer json.edit_destroy(&ov)
		mut_step := tape.Step(tape.Name("k")) if is_obj else tape.Step(tape.Index(0))
		mut_path := [1]tape.Step{mut_step}
		if _, eerr := edit.set_path(&ov, mut_path[:], edit.val_int(99)); eerr != nil {
			return false
		}
		cres, cerr := json.commit(&ov, .Json, {budget = DEEP_BUDGET})
		defer edit.destroy_commit_result(&cres)
		if cerr != nil {
			return false
		}
		if json.validate(cres.bytes, .Json, opts) != nil {
			return false
		}
		spliced, sres, serr := json.commit_document(&ov, .Json, {budget = DEEP_BUDGET})
		defer tape.destroy(&spliced)
		defer edit.destroy_commit_result(&sres)
		return serr == nil && len(spliced.nodes) > DEEP
	}
	return false
}

@(test)
gate_100k_json_all_entries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arr := make_nested_json_array(DEEP, "1")
	defer delete(arr)
	testkit.expect_reads_on_thread(t, ONE_MIB, 4, arr, "json_array_100k", run_json_100k)

	obj := make_nested_json_object(DEEP, "1")
	defer delete(obj)
	testkit.expect_reads_on_thread(t, ONE_MIB, 4, obj, "json_object_100k", run_json_100k)
}

// Exercises cross-cutting CBOR entry points at 100k depth on a 1 MiB stack:
// 0: default depth rejection
// 1: write (.Cbor verbatim + .Preferred full tree walk)
@(private = "file")
run_cbor_100k :: proc(op: int, text: []u8) -> bool {
	opts := cbor.Options{budget = DEEP_BUDGET}

	switch op {
	case 0:
		if !is_depth_exceeded(cbor.validate(text)) {
			return false
		}
		doc, berr := cbor.build(text)
		tape.destroy(&doc)
		return is_depth_exceeded(berr)

	case 1:
		doc, err := cbor.build(text, .Cbor, opts)
		defer tape.destroy(&doc)
		if err != nil {
			return false
		}
		out_cbor, _, werr1 := cbor.write(&doc, .Cbor)
		defer delete(out_cbor)
		if werr1 != nil || len(out_cbor) != len(text) {
			return false
		}
		// `.Preferred` disables verbatim copy and traverses `write.Tree` through all 100,000 levels.
		out_pref, _, werr2 := cbor.write(&doc, .Preferred)
		defer delete(out_pref)
		return werr2 == nil && len(out_pref) == len(text)
	}
	return false
}

@(test)
gate_100k_cbor_all_entries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	data := make_nested_cbor_array(DEEP)
	defer delete(data)
	testkit.expect_reads_on_thread(t, ONE_MIB, 2, data, "cbor_array_100k", run_cbor_100k)
}

// Exercises cross-cutting TOML entry points (100k nested arrays and 100k dotted keys) on a 1 MiB stack:
// 0: default depth rejection
// 1: write
@(private = "file")
run_toml_100k :: proc(op: int, text: []u8) -> bool {
	opts := toml.Options{budget = DEEP_BUDGET}

	switch op {
	case 0:
		if !is_depth_exceeded(toml.validate(text)) {
			return false
		}
		doc, berr := toml.build(text)
		tape.destroy(&doc)
		return is_depth_exceeded(berr)

	case 1:
		doc, err := toml.build(text, .Toml_1_0, opts)
		defer tape.destroy(&doc)
		if err != nil {
			return false
		}
		out, _, werr := toml.write(&doc, .Toml_1_0)
		defer delete(out)
		return werr == nil && len(out) > 0 && toml.validate(out, .Toml_1_0, opts) == nil
	}
	return false
}

// Exercises cross-cutting XML entry points (100k nested elements) on a 1 MiB stack:
// 0: default depth rejection
// 1: write
@(private = "file")
run_xml_100k :: proc(op: int, text: []u8) -> bool {
	opts := xml.Options{budget = DEEP_BUDGET}

	switch op {
	case 0:
		if !is_depth_exceeded(xml.validate(text)) {
			return false
		}
		doc, berr := xml.build(text)
		tape.destroy(&doc)
		return is_depth_exceeded(berr)

	case 1:
		doc, err := xml.build(text, .Xml, opts)
		defer tape.destroy(&doc)
		if err != nil {
			return false
		}
		out, _, werr := xml.write(&doc, .Xml)
		defer delete(out)
		return werr == nil && len(out) == len(text) && string(out) == string(text)
	}
	return false
}

@(test)
gate_100k_toml_and_xml_all_entries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	toml_arr := make_nested_toml_arrays(DEEP)
	defer delete(toml_arr)
	testkit.expect_reads_on_thread(t, ONE_MIB, 2, toml_arr, "toml_arrays_100k", run_toml_100k)

	toml_dot := make_nested_toml_dotted(DEEP)
	defer delete(toml_dot)
	testkit.expect_reads_on_thread(t, ONE_MIB, 2, toml_dot, "toml_dotted_100k", run_toml_100k)

	xml_doc := make_nested_xml(DEEP)
	defer delete(xml_doc)
	testkit.expect_reads_on_thread(t, ONE_MIB, 2, xml_doc, "xml_elements_100k", run_xml_100k)
}

// Exercises cross-cutting YAML entry points (100k nested flow arrays) on a 1 MiB stack:
// 0: default depth rejection
// 1: build -> write -> validate
@(private = "file")
run_yaml_100k :: proc(op: int, text: []u8) -> bool {
	opts := yaml.Options{budget = DEEP_BUDGET}

	switch op {
	case 0:
		if !is_depth_exceeded(yaml.validate(text)) {
			return false
		}
		doc, berr := yaml.build(text)
		tape.destroy(&doc)
		return is_depth_exceeded(berr)

	case 1:
		doc, err := yaml.build(text, .Yaml_1_2, opts)
		defer tape.destroy(&doc)
		if err != nil {
			return false
		}
		out, _, werr := yaml.write(&doc, .Yaml_1_2)
		defer delete(out)
		return werr == nil && len(out) > 0 && yaml.validate(out, .Yaml_1_2, opts) == nil
	}
	return false
}

// Exercises cross-cutting HTML entry points (100k nested `<div>` elements) on a 1 MiB stack:
// 0: default depth rejection
// 1: build -> write round-trip
@(private = "file")
run_html_100k :: proc(op: int, text: []u8) -> bool {
	opts := html.Options{budget = DEEP_BUDGET}

	switch op {
	case 0:
		if !is_depth_exceeded(html.validate(text, .Fragment)) {
			return false
		}
		doc, berr := html.build(text, .Fragment)
		tape.destroy(&doc)
		return is_depth_exceeded(berr)

	case 1:
		doc, err := html.build(text, .Fragment, opts)
		defer tape.destroy(&doc)
		if err != nil {
			return false
		}
		out, _, werr := html.write(&doc, .Fragment)
		defer delete(out)
		return werr == nil && len(out) == len(text) && string(out) == string(text)
	}
	return false
}

// Exercises cross-cutting MessagePack entry points (100k nested fixarrays) on a 1 MiB stack:
// 0: default depth rejection
// 1: build -> write (.Msgpack verbatim + .Compact full tree walk)
@(private = "file")
run_msgpack_100k :: proc(op: int, text: []u8) -> bool {
	opts := msgpack.Options{budget = DEEP_BUDGET}

	switch op {
	case 0:
		if !is_depth_exceeded(msgpack.validate(text)) {
			return false
		}
		doc, berr := msgpack.build(text)
		tape.destroy(&doc)
		return is_depth_exceeded(berr)

	case 1:
		doc, err := msgpack.build(text, .Msgpack, opts)
		defer tape.destroy(&doc)
		if err != nil {
			return false
		}
		out_mp, _, werr1 := msgpack.write(&doc, .Msgpack)
		defer delete(out_mp)
		if werr1 != nil || len(out_mp) != len(text) {
			return false
		}
		out_compact, _, werr2 := msgpack.write(&doc, .Compact)
		defer delete(out_compact)
		return werr2 == nil && len(out_compact) == len(text)
	}
	return false
}

@(test)
gate_100k_yaml_html_msgpack_all_entries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	yaml_flow := make_nested_yaml_flow(DEEP, "1")
	defer delete(yaml_flow)
	testkit.expect_reads_on_thread(t, ONE_MIB, 2, yaml_flow, "yaml_flow_100k", run_yaml_100k)

	html_doc := make_nested_html(DEEP)
	defer delete(html_doc)
	testkit.expect_reads_on_thread(t, ONE_MIB, 2, html_doc, "html_elements_100k", run_html_100k)

	mp_arr := make_nested_msgpack_array(DEEP)
	defer delete(mp_arr)
	testkit.expect_reads_on_thread(t, ONE_MIB, 2, mp_arr, "msgpack_array_100k", run_msgpack_100k)
}

@(private = "file")
Deep_Jp_Count :: struct {
	h:     ^query.Heap,
	count: int,
	last:  i64,
}

@(private = "file")
deep_jp_count_cb :: proc(data: rawptr, v: query.Value, _: string) -> bool {
	c := (^Deep_Jp_Count)(data)
	if i, ok := query.as_i64(v); ok {
		c.last = i
	}
	c.count += 1
	query.release(c.h, v)
	return true
}

// Exercises RFC 9535 JSONPath compilation and evaluation at 100k depth on a 1 MiB stack:
// 0: compile 100,000 chained `.a` segments
// 1: compile 100,000 nested `((((...))))` parens in filter (default rejects with .Depth; lifted succeeds)
// 2: eval `$..v` on a 100,000-deep nested object (default rejects with .Exceeded; lifted succeeds)
// 3: eval `$..[0]` on a 100,000-deep nested array
@(private = "file")
run_jsonpath_100k :: proc(op: int, _: []u8) -> bool {
	switch op {
	case 0:
		b := strings.builder_make_len_cap(0, DEEP * 2 + 1)
		defer strings.builder_destroy(&b)
		strings.write_byte(&b, '$')
		for _ in 0 ..< DEEP {
			strings.write_string(&b, ".a")
		}
		prog, err := jsonpath.compile(strings.to_string(b), {max_depth = DEEP * 4})
		defer jsonpath.destroy_program(prog)
		return err.kind == .None

	case 1:
		b := strings.builder_make_len_cap(0, DEEP * 2 + 16)
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "$[?")
		for _ in 0 ..< DEEP {
			strings.write_byte(&b, '(')
		}
		strings.write_string(&b, "@.a == 1")
		for _ in 0 ..< DEEP {
			strings.write_byte(&b, ')')
		}
		strings.write_byte(&b, ']')
		src := strings.to_string(b)
		p_def, err_def := jsonpath.compile(src)
		jsonpath.destroy_program(p_def)
		if err_def.kind != .Depth {
			return false
		}
		prog, err := jsonpath.compile(src, {max_depth = DEEP * 8})
		defer jsonpath.destroy_program(prog)
		return err.kind == .None

	case 2:
		obj := make_nested_json_object(DEEP, `{"v":42}`)
		defer delete(obj)
		doc, derr := json.build(obj, .Json, {budget = DEEP_BUDGET})
		if derr != nil {
			return false
		}
		prog, cerr := jsonpath.compile(`$..v`)
		if cerr.kind != .None {
			tape.destroy(&doc)
			return false
		}
		defer jsonpath.destroy_program(prog)

		h_def: query.Heap
		query.heap_init(&h_def, context.allocator)
		defer query.heap_destroy(&h_def)
		root_def, st_def := query.document_value(&h_def, doc, false)
		if st_def != .Ok {
			tape.destroy(&doc)
			return false
		}
		cnt_def := Deep_Jp_Count{h = &h_def}
		end_def := jsonpath.eval(prog, &h_def, root_def, deep_jp_count_cb, &cnt_def)
		query.release(&h_def, root_def)
		if end_def != .Exceeded {
			tape.destroy(&doc)
			return false
		}

		h: query.Heap
		query.heap_init(&h, context.allocator, depth = DEEP_LIMIT)
		defer query.heap_destroy(&h)
		root, st := query.document_value(&h, doc, true)
		if st != .Ok {
			return false
		}
		defer query.release(&h, root)
		cnt := Deep_Jp_Count{h = &h}
		end := jsonpath.eval(prog, &h, root, deep_jp_count_cb, &cnt, {budget = {depth = DEEP_LIMIT}})
		return end == .Done && cnt.count == 1 && cnt.last == 42

	case 3:
		arr := make_nested_json_array(DEEP, "99")
		defer delete(arr)
		doc, derr := json.build(arr, .Json, {budget = DEEP_BUDGET})
		if derr != nil {
			return false
		}
		prog, cerr := jsonpath.compile(`$..[0]`)
		if cerr.kind != .None {
			tape.destroy(&doc)
			return false
		}
		defer jsonpath.destroy_program(prog)
		h: query.Heap
		query.heap_init(&h, context.allocator, depth = DEEP_LIMIT)
		defer query.heap_destroy(&h)
		root, st := query.document_value(&h, doc, true)
		if st != .Ok {
			return false
		}
		defer query.release(&h, root)
		cnt := Deep_Jp_Count{h = &h}
		end := jsonpath.eval(prog, &h, root, deep_jp_count_cb, &cnt, {budget = {depth = DEEP_LIMIT}})
		return end == .Done && cnt.count == DEEP && cnt.last == 99
	}
	return false
}

@(test)
gate_100k_jsonpath_parse_and_eval :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.expect_reads_on_thread(t, ONE_MIB, 4, nil, "jsonpath_100k", run_jsonpath_100k)
}

// Exercises recursive `$ref` schema checking (both streaming `check_schema` and `check_document`) at 100k depth:
// 0: default depth rejects 100k deep JSON cleanly (.Exceeded)
// 1: streaming `stury.check_schema` accepts valid 100k nested array against recursive `$ref` schema
// 2: streaming `stury.check_schema` rejects invalid leaf in 100k nested array against recursive `$ref` schema
// 3: document `stury.check_document` accepts valid 100k nested array against recursive `$ref` schema
@(private = "file")
run_schema_100k :: proc(op: int, text: []u8) -> bool {
	schema_src := `{"anyOf":[{"type":"integer"},{"type":"array","items":{"$ref":"#"}}]}`
	compiled, scerr := stury.schema_compile(transmute([]u8)schema_src)
	if scerr.kind != .None {
		stury.schema_error_destroy(&scerr)
		return false
	}
	defer stury.schema_destroy(compiled)

	switch op {
	case 0:
		r := stury.check_schema(text, json.Spec.Json, compiled)
		defer stury.destroy_check_result(&r)
		return !r.valid && (r.err.kind == .Exceeded || is_depth_exceeded(r.walk_err) || is_depth_exceeded(r.err.walk_err))

	case 1:
		r := stury.check_schema(text, json.Spec.Json, compiled, {budget = DEEP_BUDGET})
		defer stury.destroy_check_result(&r)
		return r.valid

	case 2:
		bad := make_nested_json_array(DEEP, `"not_int"`)
		defer delete(bad)
		r := stury.check_schema(bad, json.Spec.Json, compiled, {budget = DEEP_BUDGET})
		defer stury.destroy_check_result(&r)
		return !r.valid && r.walk_err == nil && r.err.kind != .Exceeded

	case 3:
		doc, berr := json.build(text, .Json, {budget = DEEP_BUDGET})
		defer tape.destroy(&doc)
		if berr != nil {
			return false
		}
		r := stury.check_document(&doc, compiled, {budget = DEEP_BUDGET})
		defer stury.destroy_check_result(&r)
		return r.valid
	}
	return false
}

@(test)
gate_100k_schema_recursive_ref :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arr := make_nested_json_array(DEEP, "1")
	defer delete(arr)
	testkit.expect_reads_on_thread(t, ONE_MIB, 4, arr, "schema_recursive_100k", run_schema_100k)
}

// Exercises `stury` universal facade and `capi` (`stury_validate` / `stury_build`) at 100k depth on 1 MiB stack:
// 0: `stury.validate` + `stury.build` on 100k JSON (default reject + lifted accept)
// 1: `stury.validate` + `stury.build` on 100k CBOR (default reject + lifted accept)
// 2: `capi.stury_validate` + `capi.stury_build` on 100k JSON (default reject + lifted accept)
// 3: `capi.stury_validate` + `capi.stury_build` on 100k CBOR (default reject + lifted accept)
@(private = "file")
run_facade_and_capi_100k :: proc(op: int, _: []u8) -> bool {
	switch op {
	case 0:
		arr := make_nested_json_array(DEEP, "1")
		defer delete(arr)
		if !is_depth_exceeded(stury.validate(arr, json.Spec.Json)) {
			return false
		}
		if stury.validate(arr, json.Spec.Json, {budget = DEEP_BUDGET}) != nil {
			return false
		}
		doc, err := stury.build(arr, json.Spec.Json, {budget = DEEP_BUDGET})
		defer stury.destroy(&doc)
		return err == nil && len(doc.nodes) == DEEP + 1

	case 1:
		data := make_nested_cbor_array(DEEP)
		defer delete(data)
		if !is_depth_exceeded(stury.validate(data, cbor.Spec.Cbor)) {
			return false
		}
		if stury.validate(data, cbor.Spec.Cbor, {budget = DEEP_BUDGET}) != nil {
			return false
		}
		doc, err := stury.build(data, cbor.Spec.Cbor, {budget = DEEP_BUDGET})
		defer stury.destroy(&doc)
		return err == nil && len(doc.nodes) == DEEP + 1

	case 2:
		arr := make_nested_json_array(DEEP, "1")
		defer delete(arr)
		a := capi.stury_arena_new()
		if a == nil {
			return false
		}
		defer capi.stury_arena_free(a)
		verr_def := capi.stury_validate(a, raw_data(arr), c.size_t(len(arr)), u32(engine.Format_Id.Json), nil)
		if verr_def.code != .Budget {
			return false
		}
		b := capi.Budget{depth = DEEP_LIMIT}
		verr_ok := capi.stury_validate(a, raw_data(arr), c.size_t(len(arr)), u32(engine.Format_Id.Json), &b)
		if verr_ok.code != .Ok {
			return false
		}
		doc: ^tape.Document
		berr := capi.stury_build(a, raw_data(arr), c.size_t(len(arr)), u32(engine.Format_Id.Json), &b, &doc)
		if berr.code != .Ok || doc == nil {
			return false
		}
		nodes := capi.stury_doc_node_count(doc)
		capi.stury_doc_free(doc)
		return nodes == c.size_t(DEEP + 1)

	case 3:
		data := make_nested_cbor_array(DEEP)
		defer delete(data)
		a := capi.stury_arena_new()
		if a == nil {
			return false
		}
		defer capi.stury_arena_free(a)
		verr_def := capi.stury_validate(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Cbor), nil)
		if verr_def.code != .Budget {
			return false
		}
		b := capi.Budget{depth = DEEP_LIMIT}
		verr_ok := capi.stury_validate(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Cbor), &b)
		if verr_ok.code != .Ok {
			return false
		}
		doc: ^tape.Document
		berr := capi.stury_build(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Cbor), &b, &doc)
		if berr.code != .Ok || doc == nil {
			return false
		}
		nodes := capi.stury_doc_node_count(doc)
		capi.stury_doc_free(doc)
		return nodes == c.size_t(DEEP + 1)

	case 4:
		data := make_nested_yaml_flow(DEEP, "1")
		defer delete(data)
		if !is_depth_exceeded(stury.validate(data, yaml.Spec.Yaml_1_2)) {
			return false
		}
		if stury.validate(data, yaml.Spec.Yaml_1_2, {budget = DEEP_BUDGET}) != nil {
			return false
		}
		a := capi.stury_arena_new()
		if a == nil {
			return false
		}
		defer capi.stury_arena_free(a)
		if capi.stury_validate(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Yaml), nil).code != .Budget {
			return false
		}
		b := capi.Budget{depth = DEEP_LIMIT}
		doc: ^tape.Document
		if capi.stury_build(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Yaml), &b, &doc).code != .Ok || doc == nil {
			return false
		}
		nodes := capi.stury_doc_node_count(doc)
		capi.stury_doc_free(doc)
		return nodes > c.size_t(DEEP)

	case 5:
		data := make_nested_html(DEEP)
		defer delete(data)
		if !is_depth_exceeded(stury.validate(data, html.Spec.Fragment)) {
			return false
		}
		if stury.validate(data, html.Spec.Fragment, {budget = DEEP_BUDGET}) != nil {
			return false
		}
		a := capi.stury_arena_new()
		if a == nil {
			return false
		}
		defer capi.stury_arena_free(a)
		if capi.stury_validate(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Html_Fragment), nil).code != .Budget {
			return false
		}
		b := capi.Budget{depth = DEEP_LIMIT}
		doc: ^tape.Document
		if capi.stury_build(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Html_Fragment), &b, &doc).code != .Ok || doc == nil {
			return false
		}
		nodes := capi.stury_doc_node_count(doc)
		capi.stury_doc_free(doc)
		return nodes > c.size_t(DEEP)

	case 6:
		data := make_nested_msgpack_array(DEEP)
		defer delete(data)
		if !is_depth_exceeded(stury.validate(data, msgpack.Spec.Msgpack)) {
			return false
		}
		if stury.validate(data, msgpack.Spec.Msgpack, {budget = DEEP_BUDGET}) != nil {
			return false
		}
		a := capi.stury_arena_new()
		if a == nil {
			return false
		}
		defer capi.stury_arena_free(a)
		if capi.stury_validate(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Msgpack), nil).code != .Budget {
			return false
		}
		b := capi.Budget{depth = DEEP_LIMIT}
		doc: ^tape.Document
		if capi.stury_build(a, raw_data(data), c.size_t(len(data)), u32(engine.Format_Id.Msgpack), &b, &doc).code != .Ok || doc == nil {
			return false
		}
		nodes := capi.stury_doc_node_count(doc)
		capi.stury_doc_free(doc)
		return nodes == c.size_t(DEEP + 1)
	}
	return false
}

@(test)
gate_100k_stury_facade_and_capi :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.expect_reads_on_thread(t, ONE_MIB, 7, nil, fmt.tprintf("facade_capi_%d", DEEP), run_facade_and_capi_100k)
}
