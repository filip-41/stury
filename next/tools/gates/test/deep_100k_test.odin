package gates_tests

import "core:c"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:capi"
import "stury:cbor"
import "stury:engine"
import "stury:jq"
import "stury:json"
import "stury:jsonpath"
import "stury:lib/core/tape"
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import "stury:lib/query"
import "stury:stury"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

Gate_Read :: #type proc(read: int, text: []u8) -> bool

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
is_depth_exceeded :: proc(err: tape.Error) -> bool {
	exc, ok := err.(tape.Exceeded)
	return ok && exc.kind == .Depth
}

// Exercises every major JSON public entry point at 100k depth on a 1 MiB stack:
// 0: default depth rejection (validate, build, find, scan)
// 1: validate (100k)
// 2: build (100k)
// 3: find (100k)
// 4: scan (100k)
// 5: build -> write round-trip (100k)
// 6: build -> diff (identical & leaf-modified 100k docs)
// 7: build -> edit (init + set_path + commit + commit_document)
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
		return json.validate(text, .Json, opts) == nil

	case 2:
		doc, err := json.build(text, .Json, opts)
		defer tape.destroy(&doc)
		return err == nil && len(doc.nodes) > DEEP

	case 3:
		ans, err := json.find(text, path1[:], .Json, {}, opts)
		return err == nil && ans.outcome == .Found

	case 4:
		dem, derr := tape.demand_of({path1[:]})
		defer tape.destroy(&dem)
		if derr != nil {
			return false
		}
		sdoc, serr := json.scan(text, &dem, .Json, {}, opts)
		defer tape.destroy(&sdoc)
		return serr == nil && sdoc.partial != nil && len(sdoc.partial.answers) == 1

	case 5:
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

	case 6:
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

	case 7:
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
	run_on_1mib_stack(t, 8, arr, "json_array_100k", run_json_100k)

	obj := make_nested_json_object(DEEP, "1")
	defer delete(obj)
	run_on_1mib_stack(t, 8, obj, "json_object_100k", run_json_100k)
}

// Exercises every major CBOR public entry point at 100k depth on a 1 MiB stack:
// 0: default depth rejection
// 1: validate
// 2: build
// 3: find
// 4: scan
// 5: write (.Cbor verbatim + .Preferred full tree walk)
@(private = "file")
run_cbor_100k :: proc(op: int, text: []u8) -> bool {
	path1 := [1]tape.Step{tape.Index(0)}
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
		return cbor.validate(text, .Cbor, opts) == nil

	case 2:
		doc, err := cbor.build(text, .Cbor, opts)
		defer tape.destroy(&doc)
		return err == nil && len(doc.nodes) == DEEP + 1

	case 3:
		ans, err := cbor.find(text, path1[:], .Cbor, {}, opts)
		return err == nil && ans.outcome == .Found

	case 4:
		dem, derr := tape.demand_of({path1[:]})
		defer tape.destroy(&dem)
		if derr != nil {
			return false
		}
		sdoc, serr := cbor.scan(text, &dem, .Cbor, {}, opts)
		defer tape.destroy(&sdoc)
		return serr == nil && sdoc.partial != nil && len(sdoc.partial.answers) == 1

	case 5:
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
	run_on_1mib_stack(t, 6, data, "cbor_array_100k", run_cbor_100k)
}

// Exercises TOML (100k nested arrays and 100k dotted keys) on a 1 MiB stack:
// 0: default depth rejection
// 1: validate
// 2: build
// 3: find
// 4: scan
// 5: write
@(private = "file")
run_toml_100k :: proc(op: int, text: []u8) -> bool {
	path1 := [1]tape.Step{tape.Name("a")}
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
		return toml.validate(text, .Toml_1_0, opts) == nil

	case 2:
		doc, err := toml.build(text, .Toml_1_0, opts)
		defer tape.destroy(&doc)
		return err == nil && len(doc.nodes) > DEEP

	case 3:
		ans, err := toml.find(text, path1[:], .Toml_1_0, {}, opts)
		return err == nil && ans.outcome == .Found

	case 4:
		dem, derr := tape.demand_of({path1[:]})
		defer tape.destroy(&dem)
		if derr != nil {
			return false
		}
		sdoc, serr := toml.scan(text, &dem, .Toml_1_0, {}, opts)
		defer tape.destroy(&sdoc)
		return serr == nil && sdoc.partial != nil && len(sdoc.partial.answers) == 1

	case 5:
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

// Exercises XML (100k nested elements) on a 1 MiB stack:
// 0: default depth rejection
// 1: validate
// 2: build
// 3: find
// 4: scan
// 5: write
@(private = "file")
run_xml_100k :: proc(op: int, text: []u8) -> bool {
	path2 := [2]tape.Step{tape.Name("a"), tape.Name("a")}
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
		return xml.validate(text, .Xml, opts) == nil

	case 2:
		doc, err := xml.build(text, .Xml, opts)
		defer tape.destroy(&doc)
		return err == nil && len(doc.nodes) > DEEP

	case 3:
		ans, err := xml.find(text, path2[:], .Xml, {}, opts)
		return err == nil && ans.outcome == .Found

	case 4:
		dem, derr := tape.demand_of({path2[:]})
		defer tape.destroy(&dem)
		if derr != nil {
			return false
		}
		sdoc, serr := xml.scan(text, &dem, .Xml, {}, opts)
		defer tape.destroy(&sdoc)
		return serr == nil && sdoc.partial != nil && len(sdoc.partial.answers) == 1

	case 5:
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
	run_on_1mib_stack(t, 6, toml_arr, "toml_arrays_100k", run_toml_100k)

	toml_dot := make_nested_toml_dotted(DEEP)
	defer delete(toml_dot)
	run_on_1mib_stack(t, 6, toml_dot, "toml_dotted_100k", run_toml_100k)

	xml_doc := make_nested_xml(DEEP)
	defer delete(xml_doc)
	run_on_1mib_stack(t, 6, xml_doc, "xml_elements_100k", run_xml_100k)
}

@(private = "file")
Deep_Query_State :: struct {
	h:     ^query.Heap,
	count: int,
	last:  i64,
}

@(private = "file")
jq_count_sink :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
	st := (^Deep_Query_State)(data)
	if n, ok := query.as_i64(v); ok {
		st.last = n
	}
	st.count += 1
	query.release(h, v)
	return true
}

@(private = "file")
jp_count_sink :: proc(data: rawptr, v: query.Value, _: string) -> bool {
	st := (^Deep_Query_State)(data)
	if n, ok := query.as_i64(v); ok {
		st.last = n
	}
	st.count += 1
	query.release(st.h, v)
	return true
}

// Exercises jq & jsonpath compilation and evaluation at 100k depth on a 1 MiB stack:
// 0: jq default compile rejects 100k deep program; lifted max_depth compiles cleanly
// 1: jq evaluates `[.. | numbers]` and recursive `leaf` over 100k-deep JSON array document
// 2: jsonpath default compile rejects 100k deep path; lifted max_depth compiles cleanly
// 3: jsonpath default eval rejects 100k deep doc (.Exceeded); lifted depth evaluates `$..v` over 100k object
// 4: jsonpath evaluates `$..[0]` over 100k array
@(private = "file")
run_query_100k :: proc(op: int, _: []u8) -> bool {
	switch op {
	case 0:
		b := strings.builder_make_len_cap(0, DEEP * 2 + 1)
		defer strings.builder_destroy(&b)
		for _ in 0 ..< DEEP {
			strings.write_byte(&b, '[')
		}
		strings.write_byte(&b, '.')
		for _ in 0 ..< DEEP {
			strings.write_byte(&b, ']')
		}
		src := strings.to_string(b)
		// Default compile depth rejects cleanly.
		p_def, errs_def := jq.compile(src)
		jq.destroy_program(p_def)
		if len(errs_def) == 0 {
			return false
		}
		// Lifted compile depth succeeds on 1 MiB stack.
		p_deep, errs_deep := jq.compile(src, {max_depth = 8 * DEEP})
		defer jq.destroy_program(p_deep)
		return len(errs_deep) == 0

	case 1:
		arr := make_nested_json_array(DEEP, "42")
		defer delete(arr)
		doc, berr := json.build(arr, .Json, {budget = DEEP_BUDGET})
		if berr != nil {
			return false
		}
		prog, cerrs := jq.compile(`.. | numbers`)
		if len(cerrs) != 0 {
			tape.destroy(&doc)
			return false
		}
		defer jq.destroy_program(prog)

		h: query.Heap
		query.heap_init(&h, context.allocator, depth = 4 * DEEP)
		defer query.heap_destroy(&h)
		root, st := query.document_value(&h, doc, owned = true)
		if st != .Ok {
			return false
		}
		run: jq.Run
		jq.run_init(&run, prog, &h, nil)
		qs := Deep_Query_State{h = &h}
		end := jq.run_value(&run, root, jq_count_sink, &qs)
		jq.run_destroy(&run)
		return end == .Done && qs.count == 1 && qs.last == 42 && query.heap_live(&h) == 0

	case 2:
		// 100k chained `.a` segments compile cleanly on 1 MiB stack.
		b_chain := strings.builder_make_len_cap(0, DEEP * 2 + 1)
		defer strings.builder_destroy(&b_chain)
		strings.write_byte(&b_chain, '$')
		for _ in 0 ..< DEEP {
			strings.write_string(&b_chain, ".a")
		}
		p_chain, err_chain := jsonpath.compile(strings.to_string(b_chain), {max_depth = 4 * DEEP})
		jsonpath.destroy_program(p_chain)
		if err_chain.kind != .None {
			return false
		}
		// 100k nested filter parens: default max_depth (10,000) rejects with .Depth; lifted max_depth compiles cleanly.
		b_paren := strings.builder_make_len_cap(0, DEEP * 2 + 16)
		defer strings.builder_destroy(&b_paren)
		strings.write_string(&b_paren, "$[?")
		for _ in 0 ..< DEEP {
			strings.write_byte(&b_paren, '(')
		}
		strings.write_string(&b_paren, "@.a == 1")
		for _ in 0 ..< DEEP {
			strings.write_byte(&b_paren, ')')
		}
		strings.write_byte(&b_paren, ']')
		src := strings.to_string(b_paren)
		p_def, err_def := jsonpath.compile(src)
		jsonpath.destroy_program(p_def)
		if err_def.kind != .Depth {
			return false
		}
		p_deep, err_deep := jsonpath.compile(src, {max_depth = 8 * DEEP})
		defer jsonpath.destroy_program(p_deep)
		return err_deep.kind == .None

	case 3:
		obj := make_nested_json_object(DEEP, `{"v":42}`)
		defer delete(obj)
		doc, berr := json.build(obj, .Json, {budget = DEEP_BUDGET})
		if berr != nil {
			return false
		}
		prog, cerr := jsonpath.compile(`$..v`)
		if cerr.kind != .None {
			tape.destroy(&doc)
			return false
		}
		defer jsonpath.destroy_program(prog)

		// Default depth rejects cleanly with .Exceeded.
		h_def: query.Heap
		query.heap_init(&h_def, context.allocator)
		defer query.heap_destroy(&h_def)
		root_def, st_def := query.document_value(&h_def, doc, owned = false)
		if st_def != .Ok {
			tape.destroy(&doc)
			return false
		}
		qs_def := Deep_Query_State{h = &h_def}
		end_def := jsonpath.eval(prog, &h_def, root_def, jp_count_sink, &qs_def)
		query.release(&h_def, root_def)
		if end_def != .Exceeded {
			tape.destroy(&doc)
			return false
		}

		// Lifted depth evaluates all 100k levels cleanly.
		h: query.Heap
		query.heap_init(&h, context.allocator, depth = DEEP_LIMIT)
		defer query.heap_destroy(&h)
		root, st := query.document_value(&h, doc, owned = true)
		if st != .Ok {
			return false
		}
		defer query.release(&h, root)
		qs := Deep_Query_State{h = &h}
		end := jsonpath.eval(prog, &h, root, jp_count_sink, &qs, {budget = DEEP_BUDGET})
		return end == .Done && qs.count == 1 && qs.last == 42

	case 4:
		arr := make_nested_json_array(DEEP, "99")
		defer delete(arr)
		doc, berr := json.build(arr, .Json, {budget = DEEP_BUDGET})
		if berr != nil {
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
		root, st := query.document_value(&h, doc, owned = true)
		if st != .Ok {
			return false
		}
		defer query.release(&h, root)
		qs := Deep_Query_State{h = &h}
		end := jsonpath.eval(prog, &h, root, jp_count_sink, &qs, {budget = DEEP_BUDGET})
		return end == .Done && qs.count == DEEP && qs.last == 99
	}
	return false
}

@(test)
gate_100k_jq_and_jsonpath_all_entries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	run_on_1mib_stack(t, 5, nil, "jq_and_jsonpath_100k", run_query_100k)
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
	run_on_1mib_stack(t, 4, arr, "schema_recursive_100k", run_schema_100k)
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
	}
	return false
}

@(test)
gate_100k_stury_facade_and_capi :: proc(t: ^testing.T) {
	testkit.deadline(t)
	run_on_1mib_stack(t, 4, nil, fmt.tprintf("facade_capi_%d", DEEP), run_facade_and_capi_100k)
}
