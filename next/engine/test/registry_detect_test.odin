package engine_tests

import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:engine"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(test)
registry_entries_and_handles_complete :: proc(t: ^testing.T) {
	testkit.deadline(t)

	for id in engine.Format_Id {
		e, ok := engine.entry_of(id)
		testing.expectf(t, ok, "entry_of(%v) failed", id)
		testing.expect_value(t, e.id, id)
		testing.expect(t, e.format != nil)
		testing.expect(t, e.reads != nil)
		testing.expect_value(t, e.format.id, e.tape_id)

		// Round-trip Spec <-> Format_Id <-> ^tape.Format <-> tape.Format_Id.
		spec_from_id := engine.spec_of_id(id)
		id_back, id_ok := engine.id_of_spec(spec_from_id)
		testing.expect(t, id_ok)
		testing.expect_value(t, id_back, id)

		e_spec, spec_ok := engine.entry_of(spec_from_id)
		testing.expect(t, spec_ok)
		testing.expect_value(t, e_spec.id, id)

		e_fmt, fmt_ok := engine.entry_of(e.format)
		testing.expect(t, fmt_ok)
		testing.expect_value(t, e_fmt.id, id)

		e_tid, tid_ok := engine.entry_of(e.tape_id)
		testing.expect(t, tid_ok)
		testing.expect_value(t, e_tid.id, id)

		testing.expect_value(t, engine.format_of(e.spec), e.format)
		testing.expect_value(t, engine.reads_of(e.spec), e.reads)

		rt_spec, rt_ok := engine.spec_of(e.format)
		testing.expect(t, rt_ok)
		rt_id, _ := engine.id_of_spec(rt_spec)
		testing.expect_value(t, rt_id, id)
	}

	// Scan support & format traits match v2 design (`analysis.md` §3).
	testing.expect(t, engine.supports_scan(json.Spec.Json))
	testing.expect(t, engine.supports_scan(json.Spec.Jsonc))
	testing.expect(t, engine.supports_scan(json.Spec.Json5))
	testing.expect(t, !engine.supports_scan(toml.Spec.Toml_1_0))
	testing.expect(t, !engine.supports_scan(toml.Spec.Toml_1_1))
	testing.expect(t, engine.supports_scan(xml.Spec.Xml))
	testing.expect(t, engine.supports_scan(dsv.Spec.Csv))
	testing.expect(t, engine.supports_scan(dsv.Spec.Tsv))
	testing.expect(t, engine.supports_scan(dsv.Spec.Plain))
	testing.expect(t, engine.supports_scan(cbor.Spec.Cbor))
	testing.expect(t, engine.supports_scan(cbor.Spec.Deterministic))

	// Zero / nil guards.
	_, nil_spec_ok := engine.entry_of(engine.Spec(nil))
	testing.expect(t, !nil_spec_ok)
	_, nil_fmt_ok := engine.entry_of((^tape.Format)(nil))
	testing.expect(t, !nil_fmt_ok)
	testing.expect(t, engine.format_of(nil) == nil)
	testing.expect(t, engine.reads_of(nil) == nil)
	testing.expect(t, !engine.supports_scan(nil))

	// `to_tape_framing` covers every engine Framing variant.
	tf_single, is_framed_single := engine.to_tape_framing(.Single)
	testing.expect(t, !is_framed_single)
	_ = tf_single
	tf_lines, is_framed_lines := engine.to_tape_framing(.Lines)
	testing.expect(t, is_framed_lines && tf_lines == .Lines)
	tf_seq, is_framed_seq := engine.to_tape_framing(.Seq)
	testing.expect(t, is_framed_seq && tf_seq == .Seq)
	tf_elems, is_framed_elems := engine.to_tape_framing(.Elements)
	testing.expect(t, is_framed_elems && tf_elems == .Elements)
	tf_mems, is_framed_mems := engine.to_tape_framing(.Members)
	testing.expect(t, is_framed_mems && tf_mems == .Members)
	tf_cat, is_framed_cat := engine.to_tape_framing(.Concatenated)
	testing.expect(t, is_framed_cat && tf_cat == .Concatenated)
}

@(test)
registry_names_aliases_and_case_folding :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Case :: struct {
		name:    string,
		id:      engine.Format_Id,
		framing: engine.Framing,
	}
	cases := [?]Case {
		{"json", .Json, .Single},
		{"JSON", .Json, .Single},
		{"ndjson", .Json, .Lines},
		{"JSONL", .Json, .Lines},
		{"ldjson", .Json, .Lines},
		{"jsonlines", .Json, .Lines},
		{"json-seq", .Json, .Seq},
		{"RFC7464", .Json, .Seq},
		{"jsonc", .Jsonc, .Single},
		{"JSON-C", .Jsonc, .Single},
		{"json5", .Json5, .Single},
		{"toml", .Toml_1_0, .Single},
		{"TOML1.0", .Toml_1_0, .Single},
		{"toml1.1", .Toml_1_1, .Single},
		{"toml:1.1", .Toml_1_1, .Single},
		{"xml", .Xml, .Single},
		{"xml1.0", .Xml, .Single},
		{"csv", .Csv, .Lines},
		{"TSV", .Tsv, .Lines},
		{"plain", .Plain, .Lines},
		{"dsv", .Plain, .Lines},
		{"cbor", .Cbor, .Concatenated},
		{"cbor:preferred", .Cbor_Preferred, .Concatenated},
		{"CBOR:DETERMINISTIC", .Cbor_Deterministic, .Concatenated},
		{"cbor:length-first", .Cbor_Length_First, .Concatenated},
	}
	for c in cases {
		e1, ok1 := engine.format_by_name(c.name)
		testing.expectf(t, ok1, "format_by_name(%q) failed", c.name)
		testing.expect_value(t, e1.id, c.id)

		e2, fr, ok2 := engine.format_and_framing_by_name(c.name)
		testing.expectf(t, ok2, "format_and_framing_by_name(%q) failed", c.name)
		testing.expect_value(t, e2.id, c.id)
		testing.expect_value(t, fr, c.framing)
	}

	_, bad1 := engine.format_by_name("")
	testing.expect(t, !bad1)
	_, bad2 := engine.format_by_name("yaml-nope")
	testing.expect(t, !bad2)
	_, _, bad3 := engine.format_and_framing_by_name("unknown")
	testing.expect(t, !bad3)
}

@(test)
detect_paths_and_compression :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Compression suffix stripping preserves inner path cleanly and ignores single-ext archives / dotfiles.
	s1, c1 := engine.strip_compression_suffix("/tmp/events.NDJSON.GZ")
	testing.expect_value(t, s1, "/tmp/events.NDJSON")
	testing.expect_value(t, c1, engine.Compression_Kind.Gzip)

	s2, c2 := engine.strip_compression_suffix("C:\\data\\dump.cbor.zst")
	testing.expect_value(t, s2, "C:\\data\\dump.cbor")
	testing.expect_value(t, c2, engine.Compression_Kind.Zstd)

	s3, c3 := engine.strip_compression_suffix("archive.gz")
	testing.expect_value(t, s3, "archive.gz")
	testing.expect_value(t, c3, engine.Compression_Kind.Gzip)

	s4, c4 := engine.strip_compression_suffix(".hidden.json")
	testing.expect_value(t, s4, ".hidden.json")
	testing.expect_value(t, c4, engine.Compression_Kind.None)

	Path_Case :: struct {
		path:    string,
		id:      engine.Format_Id,
		framing: engine.Framing,
		ok:      bool,
	}
	cases := [?]Path_Case {
		{"config.json", .Json, .Single, true},
		{"config.JSON.gz", .Json, .Single, true},
		{"logs/app.ndjson.zst", .Json, .Lines, true},
		{"stream.jsonl.bz2", .Json, .Lines, true},
		{"events.jsonlines", .Json, .Lines, true},
		{"events.jsonlines.gz", .Json, .Lines, true},
		{"seq.jsonseq.xz", .Json, .Seq, true},
		{"tsconfig.jsonc", .Jsonc, .Single, true},
		{"settings.json5", .Json5, .Single, true},
		{"Cargo.toml", .Toml_1_0, .Single, true},
		{"layout.svg.br", .Xml, .Single, true},
		{"feed.atom", .Xml, .Single, true},
		{"metrics.CSV.lz4", .Csv, .Lines, true},
		{"rows.tsv", .Tsv, .Lines, true},
		{"data.dsv", .Plain, .Lines, true},
		{"packet.cbor", .Cbor, .Concatenated, true},
		{".gitignore", .Json, .Single, false},
		{"Makefile", .Json, .Single, false},
		{"dir.json/noext", .Json, .Single, false},
	}
	for c in cases {
		e, fr, ok := engine.format_of_path(c.path)
		testing.expectf(t, ok == c.ok, "path %q ok=%v, want %v", c.path, ok, c.ok)
		if c.ok {
			testing.expect_value(t, e.id, c.id)
			testing.expect_value(t, fr, c.framing)
		}
	}
}

@(test)
detect_content_all_formats_and_framings :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Content_Case :: struct {
		name:    string,
		data:    []u8,
		id:      engine.Format_Id,
		framing: engine.Framing,
		ok:      bool,
	}
	json_bom := []u8{0xEF, 0xBB, 0xBF, '{', '"', 'a', '"', ':', '1', '}'}
	cbor_single := []u8{0xA1, 0x61, 'a', 0x01}
	cbor_seq := []u8{0xA1, 0x61, 'a', 0x01, 0xA1, 0x61, 'a', 0x02}
	json_seq := []u8{0x1E, '{', '"', 'a', '"', ':', '1', '}', '\n', 0x1E, '{', '"', 'a', '"', ':', '2', '}', '\n'}

	cases := [?]Content_Case {
		{"json object", transmute([]u8)string(`{"a":1}`), .Json, .Single, true},
		{"json array", transmute([]u8)string(`[1, 2, 3]`), .Json, .Single, true},
		{"json bom", json_bom, .Json, .Single, true},
		{"jsonc", transmute([]u8)string("// comment\n{\"a\": 1,}"), .Jsonc, .Single, true},
		{"json5", transmute([]u8)string(`{bare: 'ok', hex: 0x10}`), .Json5, .Single, true},
		{"ndjson", transmute([]u8)string("{\"id\":1}\n{\"id\":2}\n"), .Json, .Lines, true},
		{"json seq", json_seq, .Json, .Seq, true},
		{"json concat", transmute([]u8)string(`{"a":1}{"a":2}`), .Json, .Concatenated, true},
		{"toml section", transmute([]u8)string("[pkg]\nname = \"stury\"\n"), .Toml_1_0, .Single, true},
		{"toml kv", transmute([]u8)string("# header\ntitle = \"hello\"\ncount = 42\n"), .Toml_1_0, .Single, true},
		{"toml 1.1", transmute([]u8)string("a = {\n  x = 1,\n  y = 2,\n}\n"), .Toml_1_1, .Single, true},
		{"xml", transmute([]u8)string(`<?xml version="1.0"?><root id="1"><item>v</item></root>`), .Xml, .Single, true},
		{"csv", transmute([]u8)string("name,age\nalice,30\nbob,25\n"), .Csv, .Lines, true},
		{"tsv", transmute([]u8)string("name\tage\nalice\t30\n"), .Tsv, .Lines, true},
		{"cbor single", cbor_single, .Cbor, .Single, true},
		{"plain word not cbor", transmute([]u8)string("cabc"), .Json, .Single, false},
		{"empty", nil, .Json, .Single, false},
		{"whitespace", transmute([]u8)string("   \n\t "), .Json, .Single, false},
		{"unparsed", transmute([]u8)string(`{{{bad`), .Json, .Single, false},
	}

	for c in cases {
		e, fr, ok := engine.detect_format(c.data)
		testing.expectf(t, ok == c.ok, "detect(%s) ok=%v, want %v", c.name, ok, c.ok)
		if c.ok {
			testing.expectf(t, e.id == c.id, "detect(%s) id=%v, want %v", c.name, e.id, c.id)
			testing.expectf(t, fr == c.framing, "detect(%s) framing=%v, want %v", c.name, fr, c.framing)
		}
	}

	ec, frc, okc := engine.detect_format(cbor_seq)
	testing.expect(t, okc)
	testing.expect_value(t, ec.id, engine.Format_Id.Cbor)
	testing.expect_value(t, frc, engine.Framing.Concatenated)

	// Multi-line delimiter-free prose/YAML must NOT be misclassified as `.Csv`.
	yaml_like := transmute([]u8)string("name: stury\nversion: 2\nnote: multi-line without commas or tabs\n")
	_, _, yaml_ok := engine.detect_format(yaml_like)
	testing.expect(t, !yaml_ok)

	// >= 513 consecutive UTF-8 continuation bytes (`0x80` = empty CBOR array) must be flagged non-UTF8 and detected as CBOR sequence!
	long_cbor: [520]u8
	for i in 0 ..< len(long_cbor) {
		long_cbor[i] = 0x80
	}
	lc_e, lc_fr, lc_ok := engine.detect_format(long_cbor[:])
	testing.expect(t, lc_ok)
	testing.expect_value(t, lc_e.id, engine.Format_Id.Cbor)
	testing.expect_value(t, lc_fr, engine.Framing.Concatenated)
}
