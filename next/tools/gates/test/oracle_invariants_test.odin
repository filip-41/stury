package gates_tests

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:html"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import "stury:msgpack"
import "stury:stury"
import "stury:testkit"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

@(private = "file")
ORACLE_KEYS := [?]string{"alpha", "beta", "gamma", "delta", "id", "name", "flag", "score"}

@(private = "file")
ORACLE_STRS := [?]string{"hello", "world", "ada", "stury-v2", "a b c", "123", "x_y"}

// Writes a seeded random JSON value (depth-bounded, unique keys per object).
@(private = "file")
gen_json_value :: proc(b: ^strings.Builder, depth: int, allow_null: bool, json5: bool) {
	if depth <= 0 {
		kind := rand.int_max(4 if allow_null else 3)
		switch kind {
		case 0:
			fmt.sbprintf(b, "%d", rand.int_max(2001) - 1000)
		case 1:
			strings.write_string(b, "true" if rand.int_max(2) == 1 else "false")
		case 2:
			s := ORACLE_STRS[rand.int_max(len(ORACLE_STRS))]
			if json5 && rand.int_max(2) == 0 {
				strings.write_byte(b, '\'')
				strings.write_string(b, s)
				strings.write_byte(b, '\'')
			} else {
				strings.write_byte(b, '"')
				strings.write_string(b, s)
				strings.write_byte(b, '"')
			}
		case:
			strings.write_string(b, "null")
		}
		return
	}
	shape := rand.int_max(5)
	if shape == 0 {
		strings.write_byte(b, '[')
		n := rand.int_max(4)
		for i in 0 ..< n {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			gen_json_value(b, depth - 1, allow_null, json5)
		}
		if json5 && n > 0 && rand.int_max(2) == 0 {
			strings.write_byte(b, ',')
		}
		strings.write_byte(b, ']')
		return
	}
	if shape == 1 {
		strings.write_byte(b, '{')
		n := 1 + rand.int_max(4)
		start := rand.int_max(len(ORACLE_KEYS))
		for i in 0 ..< n {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			k := ORACLE_KEYS[(start + i) % len(ORACLE_KEYS)]
			if json5 && rand.int_max(2) == 0 {
				strings.write_string(b, k)
			} else {
				strings.write_byte(b, '"')
				strings.write_string(b, k)
				strings.write_byte(b, '"')
			}
			strings.write_byte(b, ':')
			gen_json_value(b, depth - 1, allow_null, json5)
		}
		if json5 && rand.int_max(2) == 0 {
			strings.write_byte(b, ',')
		}
		strings.write_byte(b, '}')
		return
	}
	gen_json_value(b, 0, allow_null, json5)
}

@(private = "file")
gen_json_object :: proc(depth: int, allow_null: bool, jsonc: bool, json5: bool) -> []u8 {
	b := strings.builder_make()
	if jsonc || json5 {
		strings.write_string(&b, "// generated comment\n")
	}
	strings.write_byte(&b, '{')
	n := 2 + rand.int_max(4)
	for i in 0 ..< n {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		k := ORACLE_KEYS[i]
		if json5 && i % 2 == 1 {
			strings.write_string(&b, k)
		} else {
			strings.write_byte(&b, '"')
			strings.write_string(&b, k)
			strings.write_byte(&b, '"')
		}
		strings.write_byte(&b, ':')
		gen_json_value(&b, depth, allow_null, json5)
	}
	if jsonc || json5 {
		strings.write_byte(&b, ',')
	}
	strings.write_byte(&b, '}')
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
gen_toml_doc :: proc() -> []u8 {
	b := strings.builder_make()
	fmt.sbprintf(&b, "# seed header\nid = %d\nname = \"%s\"\nok = %v\n",
		rand.int_max(1000),
		ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
		rand.int_max(2) == 1,
	)
	strings.write_string(&b, "nums = [")
	n := 1 + rand.int_max(4)
	for i in 0 ..< n {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "%d", rand.int_max(500) - 250)
	}
	strings.write_string(&b, "]\n\n[nested]\n")
	fmt.sbprintf(&b, "score = %d\nlabel = \"%s\"\n",
		rand.int_max(100),
		ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
	)
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
gen_xml_doc :: proc() -> []u8 {
	b := strings.builder_make()
	fmt.sbprintf(&b, `<root id="r%d"><alpha>%s</alpha><beta>%d</beta><nested><gamma>%s</gamma></nested></root>`,
		rand.int_max(100),
		ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
		rand.int_max(1000),
		ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
	)
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
gen_dsv_doc :: proc(tsv: bool) -> []u8 {
	sep := "\t" if tsv else ","
	b := strings.builder_make()
	fmt.sbprintf(&b, "id%sname%sscore\n", sep, sep)
	rows := 1 + rand.int_max(5)
	for r in 0 ..< rows {
		fmt.sbprintf(&b, "%d%s%s%s%d\n",
			r + 1,
			sep,
			ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
			sep,
			rand.int_max(500),
		)
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
gen_yaml_doc :: proc() -> []u8 {
	b := strings.builder_make()
	fmt.sbprintf(&b, "# seed header\nid: %d\nname: \"%s\"\nok: %v\n",
		rand.int_max(1000),
		ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
		rand.int_max(2) == 1,
	)
	strings.write_string(&b, "nums:\n")
	n := 1 + rand.int_max(4)
	for _ in 0 ..< n {
		fmt.sbprintf(&b, "  - %d\n", rand.int_max(500) - 250)
	}
	fmt.sbprintf(&b, "nested:\n  score: %d\n  label: \"%s\"\n",
		rand.int_max(100),
		ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
	)
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
gen_html_doc :: proc() -> []u8 {
	b := strings.builder_make()
	fmt.sbprintf(&b, `<!DOCTYPE html><html><head><title>t%d</title></head><body><div id="r%d"><p>%s</p><span>%d</span></div></body></html>`,
		rand.int_max(100),
		rand.int_max(100),
		ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
		rand.int_max(1000),
	)
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
gen_html_fragment :: proc() -> []u8 {
	b := strings.builder_make()
	fmt.sbprintf(&b, `<div id="r%d"><p>%s</p><span>%d</span></div>`,
		rand.int_max(100),
		ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
		rand.int_max(1000),
	)
	return transmute([]u8)strings.to_string(b)
}

// Decodes a scalar node's text representation from `doc` into `buf` (or returns empty/false for containers).
@(private = "file")
decode_scalar_text :: proc(doc: ^tape.Document, idx: tape.Node_Index, buf: []u8) -> (string, bool) {
	n := doc.nodes[idx]
	#partial switch n.kind {
	case .String, .Number, .Null, .False, .True:
		return tape.node_text(doc, idx, buf)
	}
	return "", false
}

// Checks `validate == nil && build == nil`, `find == scan == build.query` (including decoded scalar text/numbers),
// and `build -> write -> build` round-trip equivalence on valid generated inputs.
@(private = "file")
verify_format_invariants :: proc(t: ^testing.T, src: []u8, spec: stury.Spec, path: []tape.Step, label: string) {
	verr := stury.validate(src, spec)
	doc, berr := stury.build(src, spec)
	defer stury.destroy(&doc)

	testing.expectf(t, verr == nil, "%s: validate failed on valid generated input: %v", label, verr)
	testing.expectf(t, berr == nil, "%s: build failed on valid generated input: %v", label, berr)
	if verr != nil || berr != nil {
		return
	}

	// `find` agrees with `build.query` on `path`.
	ans, ferr := stury.find(src, path, spec)
	testing.expectf(t, ferr == nil, "%s: find failed: %v", label, ferr)

	dem, derr := tape.demand_of({path})
	testing.expect_value(t, derr, nil)
	defer tape.destroy(&dem)

	qdoc, qerr := build.query({&doc, nil}, &dem)
	testing.expectf(t, qerr == nil, "%s: build.query failed: %v", label, qerr)
	defer tape.destroy(&qdoc)

	sdoc, serr := stury.scan(src, &dem, spec)
	testing.expectf(t, serr == nil, "%s: scan failed: %v", label, serr)
	defer stury.destroy(&sdoc)

	qnode, qpres, qhas := tape.answer({&qdoc, nil}, 0, 0)
	snode, spres, shas := tape.answer({&sdoc, nil}, 0, 0)
	testing.expectf(t, qhas == shas && qpres == spres, "%s: scan/query presence mismatch", label)
	testing.expectf(t, (ans.outcome == .Found) == (qhas && qpres == .Found), "%s: find/query presence mismatch", label)
	if qhas && qpres == .Found && shas && spres == .Found {
		testing.expect_value(t, sdoc.nodes[snode].kind, qdoc.nodes[qnode].kind)
		testing.expect_value(t, ans.kind, qdoc.nodes[qnode].kind)

		// Compare decoded scalar values/text across `build.query`, `scan`, and `find`.
		qbuf, sbuf, fbuf: [512]u8
		if qtxt, qok := decode_scalar_text(&qdoc, qnode, qbuf[:]); qok {
			stxt, sok := decode_scalar_text(&sdoc, snode, sbuf[:])
			testing.expectf(t, sok && stxt == qtxt, "%s: scan scalar %q != query scalar %q", label, stxt, qtxt)

			anode := [1]tape.Node{tape.answer_node(ans)}
			fdoc := tape.Document{src = src, nodes = anode[:], format = doc.format}
			ftxt, fok := decode_scalar_text(&fdoc, 0, fbuf[:])
			testing.expectf(t, fok && ftxt == qtxt, "%s: find scalar %q != query scalar %q", label, ftxt, qtxt)

			if qdoc.nodes[qnode].kind == .Number {
				qnum, qnok := tape.node_number(&qdoc, qnode)
				snum, snok := tape.node_number(&sdoc, snode)
				fnum, fnok := tape.node_number(&fdoc, 0)
				testing.expectf(t, qnok && snok && fnok && qnum == snum && qnum == fnum, "%s: decoded numbers diverged", label)
			}
		} else {
			// For container answers, verify `scan` and `query` serialize identically as JSON.
			qjson, _, qwerr := stury.write(&qdoc, json.Spec.Json, {node = qnode})
			sjson, _, swerr := stury.write(&sdoc, json.Spec.Json, {node = snode})
			testing.expectf(t, qwerr == nil && swerr == nil, "%s: container answer write failed", label)
			if qwerr == nil && swerr == nil {
				testing.expectf(t, bytes.equal(qjson, sjson), "%s: scan container %q != query container %q", label, string(sjson), string(qjson))
			}
			delete(qjson)
			delete(sjson)
		}
	}

	// `build -> write -> build` round-trip structural equivalence (0 diff changes).
	written, _, werr := stury.write(&doc, spec)
	testing.expectf(t, werr == nil, "%s: write failed: %v", label, werr)
	if werr != nil {
		return
	}
	defer delete(written)

	doc2, berr2 := stury.build(written, spec)
	testing.expectf(t, berr2 == nil, "%s: round-trip build failed: %v", label, berr2)
	if berr2 != nil {
		return
	}
	defer stury.destroy(&doc2)

	dres, diff_err := diff.diff_documents(&doc, &doc2)
	testing.expect_value(t, diff_err, nil)
	defer diff.destroy_result(&dres)
	testing.expectf(t, len(dres.changes) == 0, "%s: round-trip diff had %d changes", label, len(dres.changes))
}

// YAML `validate` accepts valid 0-document (comment-only), multi-document, and complex-key streams,
// whereas single-document `build`/`find`/`scan` refuse them with `no_document`, `extra_document`, or `complex_key`.
@(private = "file")
is_yaml_single_doc_refusal :: proc(err: tape.Error) -> bool {
	f, ok := err.(tape.Fault)
	if !ok || f.rules == nil || f.rules.format != "yaml" || int(f.detail) >= len(f.rules.details) {
		return false
	}
	code := f.rules.details[f.detail].code
	return code == "no_document" || code == "extra_document" || code == "complex_key"
}

// Verifies `validate == build` agreement on intentionally corrupted bytes across formats.
@(private = "file")
verify_corrupted_agreement :: proc(t: ^testing.T, base: []u8, spec: stury.Spec, label: string) {
	if len(base) < 2 {
		return
	}
	// Truncate at a random point and flip a random byte.
	cut := 1 + rand.int_max(len(base) - 1)
	trunc := base[:cut]
	v1 := stury.validate(trunc, spec)
	d1, b1 := stury.build(trunc, spec)
	stury.destroy(&d1)
	if v1 == nil && is_yaml_single_doc_refusal(b1) {
		_, f1 := stury.find(trunc, nil, spec)
		testing.expectf(t, is_yaml_single_doc_refusal(f1), "%s trunc: find=%v disagreed with yaml single-doc refusal build=%v", label, f1, b1)
	} else {
		testing.expectf(t, (v1 == nil) == (b1 == nil), "%s trunc: validate=%v build=%v", label, v1, b1)
	}

	mut := make([]u8, len(base))
	defer delete(mut)
	copy(mut, base)
	pos := rand.int_max(len(mut))
	mut[pos] ~= 0x5A
	v2 := stury.validate(mut, spec)
	d2, b2 := stury.build(mut, spec)
	stury.destroy(&d2)
	if v2 == nil && is_yaml_single_doc_refusal(b2) {
		_, f2 := stury.find(mut, nil, spec)
		testing.expectf(t, is_yaml_single_doc_refusal(f2), "%s flip: find=%v disagreed with yaml single-doc refusal build=%v", label, f2, b2)
	} else {
		testing.expectf(t, (v2 == nil) == (b2 == nil), "%s flip: validate=%v build=%v", label, v2, b2)
	}
}

// HTML5 `build` recovers syntax mutations by specification while `validate` reports HTML5 parse errors;
// verify that valid inputs always build cleanly, recovered builds agree with `scan`, and hard depth budgets agree.
@(private = "file")
verify_html_corrupted_agreement :: proc(t: ^testing.T, base: []u8, spec: stury.Spec, path: []tape.Step, label: string) {
	if len(base) < 2 {
		return
	}
	cut := 1 + rand.int_max(len(base) - 1)
	trunc := base[:cut]
	vt := stury.validate(trunc, spec)
	dt, bt := stury.build(trunc, spec)
	defer stury.destroy(&dt)
	if vt == nil {
		testing.expectf(t, bt == nil, "%s trunc: validate ok but build failed: %v", label, bt)
	}
	if bt == nil {
		dem, derr := tape.demand_of({path})
		testing.expect_value(t, derr, nil)
		defer tape.destroy(&dem)
		qd, qe := build.query({&dt, nil}, &dem)
		defer tape.destroy(&qd)
		sd, se := stury.scan(trunc, &dem, spec)
		defer stury.destroy(&sd)
		testing.expectf(t, qe == nil && se == nil, "%s trunc: query=%v scan=%v", label, qe, se)
		if qe == nil && se == nil {
			_, qp, qh := tape.answer({&qd, nil}, 0, 0)
			_, sp, sh := tape.answer({&sd, nil}, 0, 0)
			testing.expectf(t, qh == sh && qp == sp, "%s trunc: scan/query presence mismatch", label)
		}
	}

	mut := make([]u8, len(base))
	defer delete(mut)
	copy(mut, base)
	pos := rand.int_max(len(mut))
	mut[pos] ~= 0x5A
	vm := stury.validate(mut, spec)
	dm, bm := stury.build(mut, spec)
	stury.destroy(&dm)
	if vm == nil {
		testing.expectf(t, bm == nil, "%s flip: validate ok but build failed: %v", label, bm)
	}

	tight := tape.Options{budget = {depth = 1}}
	vb := stury.validate(base, spec, tight)
	db, bb := stury.build(base, spec, tight)
	stury.destroy(&db)
	testing.expectf(t, (vb == nil) == (bb == nil), "%s budget: validate=%v build=%v", label, vb, bb)
}

@(test)
oracle_validate_build_scan_find_and_roundtrip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	rng: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &rng, 401)

	rounds := testkit.rounds(12)
	p_alpha := [1]tape.Step{tape.Name("alpha")}
	p_id := [1]tape.Step{tape.Name("id")}
	p_xml := [2]tape.Step{tape.Name("root"), tape.Name("alpha")}
	p_dsv := [2]tape.Step{tape.Index(0), tape.Name("name")}
	p_html_doc := [4]tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("div"), tape.Name("p")}
	p_html_frag := [2]tape.Step{tape.Name("div"), tape.Name("p")}

	for _ in 0 ..< rounds {
		// JSON
		j := gen_json_object(2, true, false, false)
		verify_format_invariants(t, j, json.Spec.Json, p_alpha[:], "json")
		verify_corrupted_agreement(t, j, json.Spec.Json, "json")

		// CBOR & MessagePack (encoded from valid JSON)
		jdoc, jerr := stury.build(j, json.Spec.Json)
		testing.expect_value(t, jerr, stury.Error(nil))
		if jerr == nil {
			cb, _, cerr := stury.write(&jdoc, cbor.Spec.Cbor)
			testing.expect_value(t, cerr, stury.Write_Error(nil))
			if cerr == nil {
				verify_format_invariants(t, cb, cbor.Spec.Cbor, p_alpha[:], "cbor")
				verify_corrupted_agreement(t, cb, cbor.Spec.Cbor, "cbor")
				// Cross-format CBOR -> JSON -> diff == 0
				back_j, _, bjerr := stury.format(cb, cbor.Spec.Cbor, json.Spec.Json)
				testing.expect_value(t, bjerr, stury.Format_Error(nil))
				if bjerr == nil {
					dres, derr := stury.diff(j, json.Spec.Json, back_j, json.Spec.Json)
					testing.expect_value(t, derr, stury.Diff_Error(nil))
					testing.expect_value(t, len(dres.changes), 0)
					stury.destroy_diff(&dres)
					delete(back_j)
				}
				delete(cb)
			}

			mp, _, mperr := stury.write(&jdoc, msgpack.Spec.Compact)
			testing.expect_value(t, mperr, stury.Write_Error(nil))
			if mperr == nil {
				verify_format_invariants(t, mp, msgpack.Spec.Msgpack, p_alpha[:], "msgpack")
				verify_format_invariants(t, mp, msgpack.Spec.Compact, p_alpha[:], "msgpack:compact")
				verify_corrupted_agreement(t, mp, msgpack.Spec.Msgpack, "msgpack")
				// Cross-format MessagePack -> JSON -> diff == 0
				back_mj, _, bmjerr := stury.format(mp, msgpack.Spec.Msgpack, json.Spec.Json)
				testing.expect_value(t, bmjerr, stury.Format_Error(nil))
				if bmjerr == nil {
					dres, derr := stury.diff(j, json.Spec.Json, back_mj, json.Spec.Json)
					testing.expect_value(t, derr, stury.Diff_Error(nil))
					testing.expect_value(t, len(dres.changes), 0)
					stury.destroy_diff(&dres)
					delete(back_mj)
				}
				delete(mp)
			}
			stury.destroy(&jdoc)
		}
		delete(j)

		// JSONC
		jc := gen_json_object(2, true, true, false)
		verify_format_invariants(t, jc, json.Spec.Jsonc, p_alpha[:], "jsonc")
		verify_corrupted_agreement(t, jc, json.Spec.Jsonc, "jsonc")
		delete(jc)

		// JSON5
		j5 := gen_json_object(2, true, false, true)
		verify_format_invariants(t, j5, json.Spec.Json5, p_alpha[:], "json5")
		verify_corrupted_agreement(t, j5, json.Spec.Json5, "json5")
		delete(j5)

		// TOML
		tm := gen_toml_doc()
		verify_format_invariants(t, tm, toml.Spec.Toml_1_0, p_id[:], "toml")
		verify_corrupted_agreement(t, tm, toml.Spec.Toml_1_0, "toml")
		delete(tm)

		// XML
		xm := gen_xml_doc()
		verify_format_invariants(t, xm, xml.Spec.Xml, p_xml[:], "xml")
		verify_corrupted_agreement(t, xm, xml.Spec.Xml, "xml")
		delete(xm)

		// CSV & TSV
		csv_src := gen_dsv_doc(false)
		verify_format_invariants(t, csv_src, dsv.Spec.Csv, p_dsv[:], "csv")
		verify_corrupted_agreement(t, csv_src, dsv.Spec.Csv, "csv")
		delete(csv_src)

		tsv_src := gen_dsv_doc(true)
		verify_format_invariants(t, tsv_src, dsv.Spec.Tsv, p_dsv[:], "tsv")
		verify_corrupted_agreement(t, tsv_src, dsv.Spec.Tsv, "tsv")
		delete(tsv_src)

		// YAML
		ym := gen_yaml_doc()
		verify_format_invariants(t, ym, yaml.Spec.Yaml_1_2, p_id[:], "yaml")
		verify_corrupted_agreement(t, ym, yaml.Spec.Yaml_1_2, "yaml")
		delete(ym)

		// HTML (document & fragment)
		hm := gen_html_doc()
		verify_format_invariants(t, hm, html.Spec.Html, p_html_doc[:], "html")
		verify_html_corrupted_agreement(t, hm, html.Spec.Html, p_html_doc[:], "html")
		delete(hm)

		hf := gen_html_fragment()
		verify_format_invariants(t, hf, html.Spec.Fragment, p_html_frag[:], "html:fragment")
		verify_html_corrupted_agreement(t, hf, html.Spec.Fragment, p_html_frag[:], "html:fragment")
		delete(hf)
	}
}

@(private = "file")
verify_edit_noop_and_mutate :: proc(t: ^testing.T, src: []u8, spec: stury.Spec, path: []tape.Step, new_val: edit.Edit_Value, label: string) {
	doc, berr := stury.build(src, spec)
	testing.expectf(t, berr == nil, "%s build failed: %v", label, berr)
	if berr != nil {
		return
	}
	defer stury.destroy(&doc)

	// 1. No-op identity: committing an untouched overlay must yield byte-for-byte identical output.
	ov_noop: stury.Overlay
	testing.expect_value(t, stury.edit_init(&ov_noop, &doc), stury.Edit_Error(nil))
	defer stury.edit_destroy(&ov_noop)
	cres_noop, cerr_noop := stury.commit(&ov_noop, spec)
	testing.expectf(t, cerr_noop == nil, "%s noop commit failed: %v", label, cerr_noop)
	if cerr_noop == nil {
		testing.expectf(t, bytes.equal(cres_noop.bytes, src), "%s noop commit altered bytes", label)
		stury.destroy_commit_result(&cres_noop)
	}

	// 2. Mutation validity: mutate `path`, verify `commit_document` yields valid bytes & exact tape parity with fresh build.
	ov: stury.Overlay
	testing.expect_value(t, stury.edit_init(&ov, &doc), stury.Edit_Error(nil))
	defer stury.edit_destroy(&ov)
	_, serr := stury.set_path(&ov, path, new_val)
	testing.expectf(t, serr == nil, "%s set_path failed: %v", label, serr)
	if serr != nil {
		return
	}
	spliced, cres, cerr := stury.commit_document(&ov, spec)
	testing.expectf(t, cerr == nil, "%s commit_document failed: %v", label, cerr)
	if cerr != nil {
		return
	}
	defer stury.destroy(&spliced)
	defer stury.destroy_commit_result(&cres)

	testing.expectf(t, stury.validate(cres.bytes, spec) == nil, "%s committed bytes failed validate", label)
	fresh, ferr := stury.build(cres.bytes, spec)
	testing.expectf(t, ferr == nil, "%s fresh build failed: %v", label, ferr)
	if ferr == nil {
		defer stury.destroy(&fresh)
		dres, derr := diff.diff_documents(&spliced, &fresh)
		testing.expect_value(t, derr, nil)
		defer diff.destroy_result(&dres)
		testing.expectf(t, len(dres.changes) == 0, "%s spliced doc diverged from fresh build (%d changes)", label, len(dres.changes))
	}
}

@(test)
oracle_edit_noop_and_random_mutations :: proc(t: ^testing.T) {
	testkit.deadline(t)
	rng: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &rng, 402)

	rounds := testkit.rounds(10)
	p_alpha := [1]tape.Step{tape.Name("alpha")}
	p_id := [1]tape.Step{tape.Name("id")}
	p_xml := [2]tape.Step{tape.Name("root"), tape.Name("beta")}
	p_dsv := [2]tape.Step{tape.Index(0), tape.Name("score")}
	p_html_doc := [4]tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("div"), tape.Name("span")}
	p_html_frag := [2]tape.Step{tape.Name("div"), tape.Name("span")}

	for _ in 0 ..< rounds {
		v_int := stury.val_int(i64(rand.int_max(10_000)))
		v_str := stury.val_string(ORACLE_STRS[rand.int_max(len(ORACLE_STRS))])

		// JSON
		j := gen_json_object(1, true, false, false)
		verify_edit_noop_and_mutate(t, j, json.Spec.Json, p_alpha[:], v_int, "json")

		// CBOR (encoded from JSON)
		cb, _, cerr := stury.format(j, json.Spec.Json, cbor.Spec.Cbor)
		testing.expect_value(t, cerr, stury.Format_Error(nil))
		if cerr == nil {
			verify_edit_noop_and_mutate(t, cb, cbor.Spec.Cbor, p_alpha[:], v_int, "cbor")
			delete(cb)
		}

		// MessagePack (encoded from JSON)
		mp, _, mperr := stury.format(j, json.Spec.Json, msgpack.Spec.Compact)
		testing.expect_value(t, mperr, stury.Format_Error(nil))
		if mperr == nil {
			verify_edit_noop_and_mutate(t, mp, msgpack.Spec.Msgpack, p_alpha[:], v_int, "msgpack")
			verify_edit_noop_and_mutate(t, mp, msgpack.Spec.Compact, p_alpha[:], v_int, "msgpack:compact")
			delete(mp)
		}
		delete(j)

		// JSONC
		jc := gen_json_object(1, true, true, false)
		verify_edit_noop_and_mutate(t, jc, json.Spec.Jsonc, p_alpha[:], v_str, "jsonc")
		delete(jc)

		// JSON5
		j5 := gen_json_object(1, true, false, true)
		verify_edit_noop_and_mutate(t, j5, json.Spec.Json5, p_alpha[:], v_str, "json5")
		delete(j5)

		// TOML
		tm := gen_toml_doc()
		verify_edit_noop_and_mutate(t, tm, toml.Spec.Toml_1_0, p_id[:], v_int, "toml")
		delete(tm)

		// XML
		xm := gen_xml_doc()
		verify_edit_noop_and_mutate(t, xm, xml.Spec.Xml, p_xml[:], v_str, "xml")
		delete(xm)

		// CSV
		csv_src := gen_dsv_doc(false)
		verify_edit_noop_and_mutate(t, csv_src, dsv.Spec.Csv, p_dsv[:], v_str, "csv")
		delete(csv_src)

		// YAML
		ym := gen_yaml_doc()
		verify_edit_noop_and_mutate(t, ym, yaml.Spec.Yaml_1_2, p_id[:], v_int, "yaml")
		delete(ym)

		// HTML (document & fragment)
		hm := gen_html_doc()
		verify_edit_noop_and_mutate(t, hm, html.Spec.Html, p_html_doc[:], v_str, "html")
		delete(hm)

		hf := gen_html_fragment()
		verify_edit_noop_and_mutate(t, hf, html.Spec.Fragment, p_html_frag[:], v_str, "html:fragment")
		delete(hf)
	}
}

@(private = "file")
Oracle_Query_Out :: struct {
	items: [dynamic]string,
}

@(private = "file")
oracle_jq_emit :: proc(ctx: rawptr, b: []u8) -> bool {
	o := (^Oracle_Query_Out)(ctx)
	append(&o.items, strings.clone(string(b)))
	return true
}

@(private = "file")
oracle_jp_emit :: proc(ctx: rawptr, b: []u8, _: string) -> bool {
	o := (^Oracle_Query_Out)(ctx)
	append(&o.items, strings.clone(string(b)))
	return true
}

@(private = "file")
destroy_oracle_out :: proc(o: ^Oracle_Query_Out) {
	for s in o.items {
		delete(s)
	}
	delete(o.items)
}

@(test)
oracle_jq_vs_jsonpath_shared_queries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	rng: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &rng, 403)

	Query_Pair :: struct {
		jq_src: string,
		jp_src: string,
	}
	pairs := [?]Query_Pair{
		{`.user.name`, `$.user.name`},
		{`.user.score`, `$.user.score`},
		{`.items[0].id`, `$.items[0].id`},
		{`.items[1].tag`, `$.items[1].tag`},
		{`.items[].id`, `$.items[*].id`},
		{`.items[-1].tag`, `$.items[-1].tag`},
		{`.items[0:2][] | .id`, `$.items[0:2].id`},
		{`.. | objects | select(has("leaf")) | .leaf`, `$..leaf`},
	}

	rounds := testkit.rounds(12)
	for _ in 0 ..< rounds {
		b := strings.builder_make()
		fmt.sbprintf(
			&b,
			`{{"user":{{"name":"%s","score":%d}},"items":[{{"id":%d,"tag":"%s"}},{{"id":%d,"tag":"%s"}},{{"id":%d,"tag":"%s"}}],"deep":{{"a":{{"leaf":%d}}}}}}`,
			ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
			rand.int_max(1000),
			rand.int_max(500),
			ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
			rand.int_max(500),
			ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
			rand.int_max(500),
			ORACLE_STRS[rand.int_max(len(ORACLE_STRS))],
			rand.int_max(9999),
		)
		json_bytes := transmute([]u8)strings.to_string(b)
		defer delete(json_bytes)

		cbor_bytes, _, cerr := stury.format(json_bytes, json.Spec.Json, cbor.Spec.Cbor)
		testing.expect_value(t, cerr, stury.Format_Error(nil))
		defer delete(cbor_bytes)

		yaml_bytes, _, yerr := stury.format(json_bytes, json.Spec.Json, yaml.Spec.Yaml_1_2)
		testing.expect_value(t, yerr, stury.Format_Error(nil))
		defer delete(yaml_bytes)

		mp_bytes, _, mperr := stury.format(json_bytes, json.Spec.Json, msgpack.Spec.Compact)
		testing.expect_value(t, mperr, stury.Format_Error(nil))
		defer delete(mp_bytes)

		specs := [4]stury.Spec{json.Spec.Json, cbor.Spec.Cbor, yaml.Spec.Yaml_1_2, msgpack.Spec.Compact}
		inputs := [4][]u8{json_bytes, cbor_bytes, yaml_bytes, mp_bytes}

		for pair in pairs {
			jq_prog, jq_errs := stury.jq_compile(pair.jq_src)
			testing.expect_value(t, len(jq_errs), 0)
			defer stury.jq_destroy(jq_prog)

			jp_prog, jp_err := stury.jsonpath_compile(pair.jp_src)
			testing.expect_value(t, jp_err.kind, .None)
			defer stury.jsonpath_destroy(jp_prog)

			for s, idx in specs {
				jq_out: Oracle_Query_Out
				defer destroy_oracle_out(&jq_out)
				jq_res := stury.jq_run(jq_prog, inputs[idx], s, oracle_jq_emit, &jq_out)
				defer stury.jq_run_result_destroy(&jq_res)
				testing.expect_value(t, jq_res.err, stury.Query_Error.None)

				jp_out: Oracle_Query_Out
				defer destroy_oracle_out(&jp_out)
				jp_res := stury.jsonpath_eval(jp_prog, inputs[idx], s, oracle_jp_emit, &jp_out)
				testing.expect_value(t, jp_res.err, stury.Query_Error.None)

				testing.expectf(
					t,
					len(jq_out.items) == len(jp_out.items),
					"query %s vs %s count mismatch: jq=%d jp=%d",
					pair.jq_src,
					pair.jp_src,
					len(jq_out.items),
					len(jp_out.items),
				)
				for k in 0 ..< min(len(jq_out.items), len(jp_out.items)) {
					testing.expectf(
						t,
						jq_out.items[k] == jp_out.items[k],
						"query %s vs %s item %d: jq=%q jp=%q",
						pair.jq_src,
						pair.jp_src,
						k,
						jq_out.items[k],
						jp_out.items[k],
					)
				}
			}
		}
	}
}
