package yaml_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"
import "stury:yaml"

@(private = "file")
PRETTY :: yaml.Write_Options{indent = 2}

@(private = "file")
FLOW :: yaml.Write_Options{}

@(test)
suite_documents_round_trip_and_match_out_yaml :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	list := load_suite_cases(context.allocator)
	defer free_suite_cases(list, context.allocator)

	compared, checked_out, failures := 0, 0, 0
	for c in list {
		src, has_in := read_suite_file(c.dir, "in.yaml", context.temp_allocator)
		if !has_in {
			continue
		}
		if _, is_error := read_suite_file(c.dir, "error", context.temp_allocator); is_error {
			continue
		}
		r := yaml.records_open(src, .Concatenated)
		defer yaml.destroy(&r)
		recs: [8]yaml.Record
		ans: [8]yaml.Span_Answer
		for {
			n := yaml.records_find(&r, nil, recs[:], ans[:])
			for rec in recs[:n] {
				if rec.err != nil {
					continue
				}
				doc, derr := yaml.build(src[rec.lo:rec.hi], .Yaml_1_2, {}, context.temp_allocator)
				if derr != nil {
					continue
				}
				text, _, werr := yaml.write(&doc, .Yaml_1_2, PRETTY, context.temp_allocator)
				if werr != nil {
					failures += 1
					continue
				}
				again, aerr := yaml.build(text, .Yaml_1_2, {}, context.temp_allocator)
				if aerr != nil {
					failures += 1
					continue
				}
				if !testkit.values_agree(t, &doc, yaml.ROOT, &again, yaml.ROOT, {number_values = true}, c.name) {
					failures += 1
					continue
				}
				second, _, _ := yaml.write(&again, .Yaml_1_2, PRETTY, context.temp_allocator)
				if string(second) != string(text) {
					third_doc, terr := yaml.build(second, .Yaml_1_2, {}, context.temp_allocator)
					if terr != nil {
						failures += 1
						continue
					}
					third, _, _ := yaml.write(&third_doc, .Yaml_1_2, PRETTY, context.temp_allocator)
					if string(third) != string(second) {
						failures += 1
						continue
					}
				}
				compared += 1
			}
			if n < len(recs) {
				break
			}
		}

		if out_src, has_out := read_suite_file(c.dir, "out.yaml", context.temp_allocator); has_out {
			want, werr := yaml.build(out_src, .Yaml_1_2, {}, context.temp_allocator)
			doc, derr := yaml.build(src, .Yaml_1_2, {}, context.temp_allocator)
			if werr == nil && derr == nil {
				text, _, wrerr := yaml.write(&doc, .Yaml_1_2, PRETTY, context.temp_allocator)
				got, gerr := yaml.build(text, .Yaml_1_2, {}, context.temp_allocator)
				checked_out += 1
				if wrerr != nil || gerr != nil || !testkit.values_agree(t, &want, yaml.ROOT, &got, yaml.ROOT, {number_values = true}, c.name) {
					failures += 1
				}
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, compared > 250)
	testing.expect(t, checked_out > 50)
	testing.expect_value(t, failures, 0)
}

@(test)
quoting_folding_layout_and_binary_round_trip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Words YAML 1.1 or Core Schema retype must be quoted on write.
	words := [?]string{"yes", "no", "on", "off", "y", "n", "~", "null", "true", "0123", "0o17", "0x1F", "1_000", "1e3", ".inf", ".NaN", "+1", "12:30:45", "2001-12-14", "=", "<<", "", " lead", "trail ", "a: b", "a #b", "- a", "? a", "&a", "*a", "a\tb", "a\nb", "\x01"}
	for w in words {
		src := fmt.tprintf("[%s]", json_escape(w))
		jdoc, jerr := json.build(transmute([]u8)src, .Json)
		defer json.destroy(&jdoc)
		testing.expect_value(t, jerr, nil)
		for style in ([?]yaml.Write_Options{PRETTY, FLOW}) {
			out, _, werr := yaml.write(&jdoc, .Yaml_1_2, style)
			defer delete(out)
			testing.expect_value(t, werr, nil)
			again, aerr := yaml.build(out)
			defer yaml.destroy(&again)
			expect_nil(t, aerr)
			item, _ := yaml.element({&again, nil}, yaml.ROOT, 0)
			got := testkit.scalar_text(&again, item)
			testing.expectf(t, again.nodes[item].kind == .String && got == w, "%q -> %q (%v)", w, got, again.nodes[item].kind)
		}
	}

	// Layout options (`indent`, `tab` forces block with space indent, compact flow, `ascii`).
	jdoc, _ := json.build(transmute([]u8)string(`{"a":1,"b":[1,{"c":2,"d":[]},[3,4]],"e":{},"f":"x y"}`))
	defer json.destroy(&jdoc)
	b2, _, _ := yaml.write(&jdoc, .Yaml_1_2, PRETTY)
	defer delete(b2)
	testing.expect_value(t, string(b2), "a: 1\nb:\n  - 1\n  - c: 2\n    d: []\n  - - 3\n    - 4\ne: {}\nf: x y\n")

	tab_out, _, _ := yaml.write(&jdoc, .Yaml_1_2, {tab = true})
	defer delete(tab_out)
	testing.expect(t, !strings.contains(string(tab_out), "\t") && strings.contains(string(tab_out), "  - 1\n"))

	flow_out, _, _ := yaml.write(&jdoc, .Yaml_1_2, FLOW)
	defer delete(flow_out)
	testing.expect_value(t, string(flow_out), `{a: 1, b: [1, {c: 2, d: []}, [3, 4]], e: {}, f: x y}`)

	// Folded blocks preserved & `!!binary` never duplicates tag!
	src_bin := transmute([]u8)string("v: >\n  a\n  b\nbin: !!binary YWJjAP8=\n")
	ydoc, yerr := yaml.build(src_bin)
	defer yaml.destroy(&ydoc)
	expect_nil(t, yerr)
	yout, dropped, ywerr := yaml.write(&ydoc, .Yaml_1_2, PRETTY)
	defer delete(yout)
	testing.expect(t, ywerr == nil && dropped == {})
	testing.expect(t, strings.contains(string(yout), "v: >\n"))
	testing.expect_value(t, strings.count(string(yout), "!!binary"), 1)
	testing.expect(t, strings.contains(string(yout), "bin: !!binary YWJjAP8="))

	// `.Bytes` (`!!binary`) keys + French UTF-8 plain scalars + colons/hashes + nested array round-trip!
	long_b64 := strings.repeat("QUJD", 280, context.temp_allocator)
	bin_key_src := fmt.tprintf("!!binary YWJj: [1, 2, 3]\n? !!binary %s\n: long_v\n'205705993': Arrière-scène central\ntime: 10:30:00\nhash: a#b\nnel: \"a\\u0085b\"\n", long_b64)
	bk_doc, bk_err := yaml.build(transmute([]u8)bin_key_src)
	defer yaml.destroy(&bk_doc)
	if expect_nil(t, bk_err) {
		for st in ([?]yaml.Write_Options{PRETTY, FLOW, {indent = 2, ascii = true}}) {
			wtxt, _, bwerr := yaml.write(&bk_doc, .Yaml_1_2, st)
			defer delete(wtxt)
			if testing.expect_value(t, bwerr, nil) {
				if st.indent == 2 && !st.ascii {
					testing.expect_value(t, strings.count(string(wtxt), "!!binary YWJj"), 1)
					testing.expect(t, strings.contains(string(wtxt), "Arrière-scène central"))
				}
				again, aerr := yaml.build(wtxt)
				defer yaml.destroy(&again)
				if expect_nil(t, aerr) {
					testing.expect(t, testkit.values_agree(t, &bk_doc, yaml.ROOT, &again, yaml.ROOT, {number_values = true}, "binary key + utf8 plain"))
				}
			}
		}
	}

	// `!!str`-tagged Core Schema-shaped keys must quote on write since keys drop tags (`put_key`), staying `.String` on round-trip!
	tagged_keys_src := transmute([]u8)string("!!str 123: 1\n!!str true: 2\n!!str null: 3\n!!str ~: 4\n!!str .inf: 5\n")
	tk_doc, tk_err := yaml.build(tagged_keys_src)
	defer yaml.destroy(&tk_doc)
	if expect_nil(t, tk_err) {
		for st in ([?]yaml.Write_Options{PRETTY, FLOW, {indent = 2, ascii = true}}) {
			wtxt, tk_dropped, werr := yaml.write(&tk_doc, .Yaml_1_2, st)
			defer delete(wtxt)
			testing.expect(t, werr == nil && .Tag in tk_dropped)
			again, aerr := yaml.build(wtxt)
			defer yaml.destroy(&again)
			if expect_nil(t, aerr) {
				for k in ([?]string{"123", "true", "null", "~", ".inf"}) {
					v_idx, pres := yaml.member({&again, nil}, yaml.ROOT, k)
					got_kind := again.nodes[v_idx - 1].kind if pres == .Found else yaml.Kind.Null
					testing.expectf(t, pres == .Found && got_kind == .String, "key %q got pres=%v kind=%v in %q", k, pres, got_kind, string(wtxt))
				}
				testing.expect(t, testkit.values_agree(t, &tk_doc, yaml.ROOT, &again, yaml.ROOT, {number_values = true}, "!!str key round-trip"))
			}
		}
	}
}

@(test)
foreign_comments_toml_dates_facts_dropped_and_sink :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// JSONC comments + directives + inline comments + empty collection foot comments.
	cdoc, _ := json.build(transmute([]u8)string("// head\n{\n// lead a\n\"a\": 1, // tail a\n\"e\": {\n  // in e\n}\n}\n"), .Jsonc)
	defer json.destroy(&cdoc)
	cout, cdropped, cwerr := yaml.write(&cdoc, .Yaml_1_2, PRETTY)
	defer delete(cout)
	testing.expect(t, cwerr == nil && cdropped == {})
	testing.expect_value(t, string(cout), "# head\n\n# lead a\na: 1 # tail a\ne: {\n  # in e\n  }\n")

	// TOML datetime -> YAML `!!timestamp`.
	tdoc, _ := toml.build(transmute([]u8)string("when = 1979-05-27T07:32:00Z\n# note\nn = 0xff\n"))
	defer toml.destroy(&tdoc)
	tout, tdropped, twerr := yaml.write(&tdoc, .Yaml_1_2, PRETTY)
	defer delete(tout)
	testing.expect(t, twerr == nil && tdropped == {})
	testing.expect(t, strings.contains(string(tout), "when: !!timestamp 1979-05-27T07:32:00Z"))
	testing.expect(t, yaml.validate(tout) == nil)

	// Invalid UTF-8 comment is dropped and reported in `dropped`.
	bad := transmute([]u8)strings.clone("// bad X comment\n{\"a\": 1}", context.temp_allocator)
	bdoc, _ := json.build(bad, .Jsonc)
	defer json.destroy(&bdoc)
	bad[7] = 0xff
	bout, bdropped, bwerr := yaml.write(&bdoc, .Yaml_1_2, PRETTY)
	defer delete(bout)
	testing.expect(t, bwerr == nil && .Comment in bdropped && yaml.validate(bout) == nil)

	// `write_to` via `chunked_sink`.
	sink: testkit.Chunked
	w := testkit.chunked_sink(&sink, 7)
	defer testkit.chunked_destroy(&sink)
	j_sample := jdoc_sample()
	defer json.destroy(&j_sample)
	sdropped, serr := yaml.write_to(w, &j_sample, .Yaml_1_2, PRETTY)
	testing.expect(t, serr == nil && sdropped == {} && string(sink.taken[:]) == "x: 1\n")

	// Random JSON values round-trip cleanly across all YAML write styles.
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x5A11)
	styles := [?]yaml.Write_Options{PRETTY, {indent = 4}, FLOW, {indent = 2, ascii = true}, {indent = 2, sort_keys = true}}
	for _ in 0 ..< testkit.rounds(80) {
		rb: strings.Builder
		strings.builder_init(&rb, context.temp_allocator)
		gen_json(&rb, 3)
		src := transmute([]u8)strings.to_string(rb)
		gdoc, gerr := json.build(src, .Json)
		if gerr != nil {
			continue
		}
		defer json.destroy(&gdoc)
		for st in styles {
			txt, _, werr := yaml.write(&gdoc, .Yaml_1_2, st)
			defer delete(txt)
			testing.expect_value(t, werr, nil)
			back, berr := yaml.build(txt)
			defer yaml.destroy(&back)
			testing.expect_value(t, berr, nil)
			if !st.sort_keys {
				testing.expect(t, testkit.values_agree(t, &gdoc, yaml.ROOT, &back, yaml.ROOT, {number_values = true}, string(src)))
			}
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
jdoc_sample :: proc() -> tape.Document {
	doc, _ := json.build(transmute([]u8)string(`{"x":1}`))
	return doc
}

@(test)
token_writer_and_marshal_round_trips :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Token writer.
	w: yaml.Writer
	testing.expect_value(t, yaml.writer_start(&w, .Yaml_1_2, PRETTY), nil)
	testing.expect_value(t, yaml.token(&w, .Object), nil)
	testing.expect_value(t, yaml.token(&w, .Key, "on"), nil)
	testing.expect_value(t, yaml.token(&w, .String, "yes"), nil)
	testing.expect_value(t, yaml.token(&w, .Key, "list"), nil)
	testing.expect_value(t, yaml.token(&w, .Array), nil)
	testing.expect_value(t, yaml.token(&w, .Number, "1"), nil)
	testing.expect_value(t, yaml.token(&w, .Number, "1.5"), nil)
	testing.expect_value(t, yaml.token(&w, .Null), nil)
	testing.expect_value(t, yaml.token(&w, .Close), nil)
	testing.expect_value(t, yaml.token(&w, .Close), nil)
	tout, terr := yaml.writer_end(&w)
	defer delete(tout)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, string(tout), "'on': 'yes'\nlist:\n  - 1\n  - 1.5\n  - null\n")

	// Marshal + unmarshal structs, `Maybe`, slices, maps, `[]u8` (`!!binary` & array), and struct tag `yaml:`.
	Inner :: struct {
		on:   bool,
		tags: []string,
	}
	Config :: struct {
		name:  string `yaml:"app_name"`,
		port:  int,
		ratio: f64,
		data:  []u8,
		inner: Inner,
		none:  Maybe(int),
		meta:  map[string]int,
	}
	val := Config {
		name  = "web",
		port  = 80,
		ratio = 0.5,
		data  = []u8{'a', 'b', 'c', 0, 0xff},
		inner = {on = true, tags = {"a", "b c"}},
		meta  = make(map[string]int, context.temp_allocator),
	}
	val.meta["k"] = 7
	mtxt, merr := yaml.marshal(&val, .Yaml_1_2, PRETTY)
	defer delete(mtxt)
	testing.expect_value(t, merr, nil)
	testing.expect(t, strings.contains(string(mtxt), "app_name: web\n"))

	back: Config
	uerr := yaml.unmarshal(mtxt, &back, .Yaml_1_2, {}, {}, context.temp_allocator)
	expect_nil(t, uerr)
	testing.expect_value(t, back.name, "web")
	testing.expect_value(t, back.port, 80)
	testing.expect_value(t, back.ratio, 0.5)
	testing.expect_value(t, string(back.data), "abc\x00\xff")
	testing.expect(t, back.inner.on && len(back.inner.tags) == 2 && back.inner.tags[1] == "b c" && back.none == nil && back.meta["k"] == 7)

	// Explicit `!!binary` YAML scalar also unmarshals directly into `[]u8`.
	bin_yaml := transmute([]u8)string("app_name: bin\ndata: !!binary YWJjAP8=\n")
	bin_cfg: Config
	buerr := yaml.unmarshal(bin_yaml, &bin_cfg, .Yaml_1_2, {}, {}, context.temp_allocator)
	expect_nil(t, buerr)
	testing.expect_value(t, bin_cfg.name, "bin")
	testing.expect_value(t, string(bin_cfg.data), "abc\x00\xff")

	// Refusal under `.Refuse` duplicate keys on unmarshal.
	bad_dup := transmute([]u8)string("app_name: a\napp_name: b\nport: 1\n")
	bad_cfg: Config
	derr := yaml.unmarshal(bad_dup, &bad_cfg, .Yaml_1_2, {}, {dups = .Refuse}, context.temp_allocator)
	f, is_f := derr.(yaml.Fault)
	testing.expect(t, is_f && f.kind == .Duplicate_Key)

	// Failing allocator sweep & zero `context.temp_allocator` usage on `marshal`.
	Sweep :: struct {
		title: string,
		port:  int,
		tags:  []string,
		inner: struct {
			label: string,
		},
	}
	Sweep_Data :: struct {
		v:    ^Sweep,
		opts: yaml.Write_Options,
	}
	sweep_marshal :: proc(data: rawptr, a: runtime.Allocator) {
		d := (^Sweep_Data)(data)
		buf, berr := yaml.marshal(d.v, .Yaml_1_2, d.opts, nil, a)
		if berr == nil {
			delete(buf, a)
		} else {
			_ = berr.(runtime.Allocator_Error)
		}
	}
	sw := Sweep{title = "t", port = 8, tags = {"x", "y: z"}, inner = {label = "n"}}
	for opts in ([]yaml.Write_Options{FLOW, PRETTY, {indent = 2, ascii = true}}) {
		sd := Sweep_Data{&sw, opts}
		s := testkit.sweep_failures(sweep_marshal, &sd)
		testing.expectf(t, s.bad == 0 && s.refused >= 1, "marshal sweep %v: %v", opts, s)
	}
	tf := testkit.Failing{backing = context.temp_allocator, fail_at = -1}
	saved_temp := context.temp_allocator
	context.temp_allocator = testkit.failing_allocator(&tf)
	defer context.temp_allocator = saved_temp
	heap_alloc := context.allocator
	for opts in ([]yaml.Write_Options{FLOW, PRETTY, {indent = 2, ascii = true}}) {
		out, oerr := yaml.marshal(&sw, .Yaml_1_2, opts, nil, heap_alloc)
		testing.expectf(t, oerr == nil, "no-temp marshal %v: %v", opts, oerr)
		delete(out, heap_alloc)
	}
	testing.expect_value(t, tf.count, 0)
}

@(private = "file")
json_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':  strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\t': strings.write_string(&b, "\\t")
		case 0 ..< 0x20: fmt.sbprintf(&b, "\\u%04x", c)
		case: strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

@(private = "file")
gen_json :: proc(b: ^strings.Builder, depth: int) {
	pick := rand.int_max(7 if depth > 0 else 5)
	switch pick {
	case 0:
		strings.write_string(b, "null")
	case 1:
		strings.write_string(b, "true" if rand.int_max(2) == 0 else "false")
	case 2:
		fmt.sbprintf(b, "%d", rand.int_max(200) - 100)
	case 3:
		fmt.sbprintf(b, "%v", f64(rand.int_max(10000)) / 64)
	case 4:
		pool := [?]string{"", "x", "yes", "no", "null", "0123", "a: b", "# c", "x\ny", "é", "\t", "1e3", ".inf"}
		strings.write_string(b, json_escape(rand.choice(pool[:])))
	case 5:
		strings.write_byte(b, '[')
		for i in 0 ..< rand.int_max(4) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			gen_json(b, depth - 1)
		}
		strings.write_byte(b, ']')
	case:
		strings.write_byte(b, '{')
		for i in 0 ..< rand.int_max(4) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, `"k%d":`, i)
			gen_json(b, depth - 1)
		}
		strings.write_byte(b, '}')
	}
}
