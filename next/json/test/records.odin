package json_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import records "../../core/records"
import json ".."

// The record reader against a model: a plain framer per framing, then `validate` of each record's text alone.

@(private = "file")
Model_Record :: struct {
	at:    u64,
	text:  string,
	fault: Maybe(core.Fault),
	key:   string,
}

@(private = "file")
is_blank :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

@(private = "file")
has_bom :: proc(s: string) -> bool {
	return strings.has_prefix(s, "\xef\xbb\xbf")
}

// The model's verdict on a record: `validate` of its text alone, at its place in the input. A BOM is the input's, so
// one that starts a later record is `Bad_Char`, except in JSON5, where it is whitespace.
@(private = "file")
model_fault :: proc(text: string, at: u64, spec: json.Spec) -> Maybe(core.Fault) {
	if at > 0 && has_bom(text) && spec != .Json5 {
		return core.Fault{at = at, rules = &json.RULES, kind = .Bad_Char}
	}
	f: Maybe(core.Fault)
	switch spec {
	case .Json:  f = json.validate(transmute([]u8)text, .Json)
	case .Jsonc: f = json.validate(transmute([]u8)text, .Jsonc)
	case .Json5: f = json.validate(transmute([]u8)text, .Json5)
	}
	if x, bad := f.?; bad {
		x.at += at
		return x
	}
	return nil
}

// Returns the first offset at or past `i` that is no whitespace, in a spec with comments no comment, in JSON5 no BOM,
// and with `rs` no 0x1E.
@(private = "file")
model_gap :: proc(src: string, i: int, spec: json.Spec, rs: bool) -> int {
	i := i
	for i < len(src) {
		if is_blank(src[i]) || rs && src[i] == 0x1e {
			i += 1
		} else if spec == .Json5 && has_bom(src[i:]) {
			i += 3
		} else if spec != .Json && (strings.has_prefix(src[i:], "//") || strings.has_prefix(src[i:], "/*")) {
			// A `//` comment ends at a CR or an LF.
			e := strings.index_any(src[i:], "\r\n") if src[i + 1] == '/' else strings.index(src[i + 2:], "*/") + 4
			e = len(src) - i if e < 0 && src[i + 1] == '/' else e
			// A comment that does not end, or holds a control byte but a tab or a line end, is no gap.
			if e < 4 && src[i + 1] == '*' || strings.index_proc(src[i:][:e], proc(r: rune) -> bool {return r < 0x20 && r != '\t' && r != '\r' && r != '\n'}) >= 0 {
				return i
			}
			i += e
		} else {
			break
		}
	}
	return i
}

// Returns one past the value that starts at `i`: a string to its closing quote, a container to the bracket that
// closes it, anything else to the next byte that may follow a value.
@(private = "file")
model_value_end :: proc(src: string, i: int, spec: json.Spec) -> int {
	depth := 0
	j := i
	for j < len(src) {
		c := src[j]
		switch {
		case c == '"' || c == '\'' && spec == .Json5:
			j += 1
			for j < len(src) && src[j] != c {
				j += 2 if src[j] == '\\' else 1
			}
			j = min(j + 1, len(src))
		case c == '[' || c == '{':
			depth += 1
			j += 1
			continue
		case c == ']' || c == '}':
			depth -= 1
			j += 1
		case depth > 0:
			j = max(model_gap(src, j, spec, false), j + 1)
			continue
		case:
			k := j
			for k < len(src) && !strings.contains_rune(",:[]{}\"'/ \t\r\n\x1e", rune(src[k])) {
				k += 1
			}
			return max(k, j + 1)
		}
		if depth <= 0 {
			return j
		}
	}
	return j
}

@(private = "file")
is_ident :: proc(c: u8, first: bool) -> bool {
	return c == '_' || c == '$' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || !first && c >= '0' && c <= '9'
}

// Frames `src` byte by byte. Returns the records and the framing's own fault.
@(private = "file")
model_frame :: proc(src: string, framing: core.Framing, spec: json.Spec) -> (out: [dynamic]Model_Record, fault: Maybe(core.Fault)) {
	out = make([dynamic]Model_Record, context.temp_allocator)
	start := 3 if has_bom(src) else 0
	if framing == .Concatenated {
		for i := model_gap(src, start, spec, true); i < len(src); i = model_gap(src, i, spec, true) {
			j := model_value_end(src, i, spec)
			// A broken value's fault may lie past where this framer ends it, as in an unclosed comment before it.
			if model_fault(src[i:j], u64(i), spec) != nil {
				return out, model_fault(src[i:], u64(i), spec)
			}
			append(&out, Model_Record{at = u64(i), text = src[i:j]})
			i = j
		}
		return
	}
	if framing == .Entries {
		// The entries' fault is the whole text's, whichever entry or byte of the root breaks it.
		fault = model_fault(src, 0, spec)
		i := model_gap(src, start, spec, false)
		if i == len(src) || src[i] != '[' && src[i] != '{' {
			return
		}
		close := src[i] + 2
		i = model_gap(src, i + 1, spec, false)
		for n := 0;; n += 1 {
			if i < len(src) && src[i] == close && n == 0 {
				return
			}
			if n > 0 {
				if i == len(src) || src[i] != ',' {
					return
				}
				i = model_gap(src, i + 1, spec, false)
				if i < len(src) && src[i] == close && spec != .Json {
					return
				}
			}
			key := ""
			if close == '}' {
				k := i
				if i < len(src) && (src[i] == '"' || spec == .Json5 && src[i] == '\'') {
					i = model_value_end(src, i, spec)
					if model_fault(src[k:i], u64(k), spec) != nil {
						return
					}
				} else if spec == .Json5 {
					for i < len(src) && is_ident(src[i], i == k) {
						i += 1
					}
				}
				if i == k {
					return
				}
				key = src[k:i]
				i = model_gap(src, i, spec, false)
				if i == len(src) || src[i] != ':' {
					return
				}
				i = model_gap(src, i + 1, spec, false)
			}
			if i == len(src) {
				return
			}
			j := model_value_end(src, i, spec)
			if model_fault(src[i:j], u64(i), spec) != nil {
				return
			}
			append(&out, Model_Record{at = u64(i), text = src[i:j], key = key})
			i = model_gap(src, j, spec, false)
		}
	}
	stop: u8 = '\n' if framing == .Lines else 0x1e
	i := 3 if has_bom(src) else 0
	first := true
	for i < len(src) {
		j := i
		for j < len(src) && src[j] != stop {
			j += 1
		}
		hi := j
		if framing == .Lines && hi > i && src[hi - 1] == '\r' {
			hi -= 1
		}
		k := i
		for k < hi && is_blank(src[k]) {
			k += 1
		}
		if framing == .Seq && first {
			if k < hi {
				return out, core.Fault{at = u64(k), rules = &json.RULES, kind = .Bad_Char}
			}
		} else if k < hi {
			append(&out, Model_Record{at = u64(k), text = src[k:hi], fault = model_fault(src[k:hi], u64(k), spec)})
		}
		first = false
		i = j + 1
	}
	return
}

// Checks `records.next` and `records.check` on `src` against the model.
@(private = "file")
expect_model :: proc(t: ^testing.T, src: string, framing: core.Framing, spec: json.Spec) -> bool {
	want, framed := model_frame(src, framing, spec)
	it := records.open(transmute([]u8)src, json.as(spec), framing)
	defer records.close(&it)
	n := 0
	for rec in records.next(&it) {
		if n >= len(want) || rec.at != want[n].at || string(rec.text) != want[n].text || string(rec.key) != want[n].key {
			testing.expectf(t, false, "%v %v %q: record %d at %d %q key %q, want %v", framing, spec, src, n, rec.at, rec.text, rec.key, want[n] if n < len(want) else Model_Record{})
			return false
		}
		n += 1
	}
	if !testing.expectf(t, n == len(want) && it.fault == framed, "%v %v %q: %d records, fault %v, want %d, %v", framing, spec, src, n, it.fault, len(want), framed) {
		return false
	}
	faults, err := records.check(transmute([]u8)src, json.as(spec), framing, context.temp_allocator)
	testing.expect_value(t, err, nil)
	k := 0
	for r in want {
		if f, bad := r.fault.?; bad {
			if k >= len(faults) || faults[k] != f {
				testing.expectf(t, false, "%v %v %q: record at %d faults %v, check gave %v", framing, spec, src, r.at, f, faults[k:])
				return false
			}
			k += 1
		}
	}
	if f, bad := framed.?; bad {
		if k >= len(faults) || faults[k] != f {
			testing.expectf(t, false, "%v %v %q: framing fault %v, check gave %v", framing, spec, src, f, faults[k:])
			return false
		}
		k += 1
	}
	return testing.expectf(t, k == len(faults), "%v %v %q: check gave more faults %v", framing, spec, src, faults[k:])
}

// Records of every kind, with the separators of each framing between them: blank lines, CRLF, a BOM, a 0x1E in a
// line, values spread over lines and comments.
@(private = "file", rodata)
PIECES := []string {
	`{"a":1,"b":[true,false,null]}`,
	`[1,2.5e3,"x\né"]`,
	`"s"`,
	`-12`,
	`true`,
	`{"k":{"x":[{}]}}`,
	"{\"a\":\n1}",
	"[1,\n2]",
	"\x1e{\"a\":2}",
	"\xef\xbb\xbf[]",
	`{"a":1} // c`,
	`/* c */ [3]`,
	`{"a":1}  x`,
	`12 13`,
	`{a:'x',}`,
	"\"\\ud83d\\ude00\xf0\x9f\x98\x80\"",
}

@(private = "file", rodata)
SEPARATORS := []string{"\n", "\r\n", "\n\n", "\n  \t\n", " \n", "\r\n\r\n"}

// Object members' keys under `.Entries`, JSON5's among them.
@(private = "file", rodata)
KEYS := []string{`"a":`, `"b\"c" : `, "\"k\"\n:", `a:`, `'q' :`, `/* c */ "x"/* c */:`}

@(private = "file")
seeded_text :: proc(gen: rand.Generator, framing: core.Framing) -> string {
	b := strings.builder_make(context.temp_allocator)
	if rand.int_max(4, gen) == 0 {
		strings.write_string(&b, "\xef\xbb\xbf")
	}
	n := 1 + rand.int_max(6, gen)
	if framing == .Entries {
		// A root array or object of the pieces, with a trailing comma at times.
		object := rand.int_max(2, gen) == 0
		strings.write_byte(&b, '{' if object else '[')
		for i in 0 ..< n {
			if object {
				strings.write_string(&b, rand.choice(KEYS, gen))
			}
			strings.write_string(&b, rand.choice(PIECES, gen))
			strings.write_string(&b, rand.choice(SEPARATORS, gen))
			if i < n - 1 || rand.int_max(4, gen) == 0 {
				strings.write_byte(&b, ',')
			}
		}
		strings.write_string(&b, "}\n" if object else "]\n")
	}
	for _ in 0 ..< n * int(framing != .Entries) {
		if framing == .Seq {
			strings.write_byte(&b, 0x1e)
		}
		strings.write_string(&b, rand.choice(PIECES, gen))
		strings.write_string(&b, rand.choice(SEPARATORS, gen))
	}
	if rand.int_max(2, gen) == 0 {
		// No line end after the last record.
		strings.pop_byte(&b)
	}
	return strings.to_string(b)
}

@(test)
records_follow_the_model :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(1)
	gen := rand.default_random_generator(&state)
	// Each byte of a text in turn becomes a byte that breaks or ends a value.
	breakers := "x\"}],:\n\r \x1e\x00\\"
	for round in 0 ..< 200 {
		framing := core.Framing(round % 4)
		src := seeded_text(gen, framing)
		for spec in json.Spec {
			if !expect_model(t, src, framing, spec) {
				return
			}
		}
		buf := make([]u8, len(src), context.temp_allocator)
		for i in 0 ..< len(src) {
			copy(buf, src)
			for c in transmute([]u8)breakers {
				buf[i] = c
				for spec in json.Spec {
					if !expect_model(t, string(buf), framing, spec) {
						return
					}
				}
			}
		}
	}
}

@(test)
records_frame_and_place :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "\xef\xbb\xbf{\"a\":1}\r\n\n  [2]\n\t\n"
	it := records.open(transmute([]u8)src, json.as(.Json))
	defer records.close(&it)
	rec, ok := records.next(&it)
	testing.expect(t, ok && rec.at == 3 && string(rec.text) == `{"a":1}`)
	rec, ok = records.next(&it)
	testing.expect(t, ok && rec.at == 15 && string(rec.text) == "[2]")
	_, ok = records.next(&it)
	testing.expect(t, !ok && it.fault == nil)

	// A refused record is the caller's to see. The next one is read past it.
	faults, _ := records.check(transmute([]u8)string("{\"a\":\n1}\n2"), json.as(.Json), .Lines, context.temp_allocator)
	testing.expect_value(t, len(faults), 2)
	testing.expect_value(t, faults[0], core.Fault{at = 5, rules = &json.RULES, kind = .Truncated})
	testing.expect_value(t, faults[1], core.Fault{at = 7, rules = &json.RULES, kind = .Trailing})

	// The members of a root object, keys as written, and a root at the deepest level, whose entries may be no container.
	obj := transmute([]u8)string(`{"a": 1, "b\"c" :[2] , "a":{}}`)
	it3 := records.open(obj, json.as(.Json), .Entries)
	keys := []string{`"a"`, `"b\"c"`, `"a"`}
	values := []string{"1", "[2]", "{}"}
	n := 0
	for r in records.next(&it3) {
		testing.expect(t, string(r.key) == keys[n] && string(r.text) == values[n] && string(obj[r.at:][:len(r.text)]) == values[n])
		n += 1
	}
	testing.expect(t, n == 3 && it3.fault == nil)
	flat := json.as(.Json)
	flat.read.max_depth = 1
	faults, _ = records.check(transmute([]u8)string("[1, 2]"), flat, .Entries, context.temp_allocator)
	testing.expect_value(t, len(faults), 0)
	faults, _ = records.check(transmute([]u8)string("[1, [2]]"), flat, .Entries, context.temp_allocator)
	testing.expect(t, len(faults) == 1 && faults[0].kind == .Too_Deep && faults[0].at == 4)
	// Concatenated documents: a number runs on into a letter as one bad token.
	faults, _ = records.check(transmute([]u8)string("1 [2]{}\"s\"3x"), json.as(.Json), .Concatenated, context.temp_allocator)
	testing.expect(t, len(faults) == 1 && faults[0].kind == .Trailing && faults[0].at == 11)

	// RFC 7464: text before the first 0x1E ends the records.
	it2 := records.open(transmute([]u8)string(" 1\x1e2\n"), json.as(.Json), .Seq)
	_, ok = records.next(&it2)
	testing.expect(t, !ok && it2.fault == core.Fault{at = 1, rules = &json.RULES, kind = .Bad_Char})
}

@(private = "file")
Typed_Piece :: struct {
	a: Maybe(int),
	b: []Maybe(bool),
	k: struct {
		x: []string,
	},
}

// A typed error with its offsets moved by `at`, and its steps as text, which name keys by their bytes.
@(private = "file")
error_text :: proc(e: core.Typed_Error, at: u64) -> string {
	e := e
	if e.kind != .None {
		e.at += at
		if e.kind == .Walk {
			e.inner.at += at
		}
	}
	return fmt.tprint(e.kind, e.truncated, e.at, e.inner, e.steps[:e.n_steps])
}

// `records.read` against `json.unmarshal` of each record's text the model frames, with the model's BOM rule.
@(private = "file")
expect_read :: proc(t: ^testing.T, src: string, framing: core.Framing, spec: json.Spec, read: typed.Read_Options, plan: ^typed.Plan) -> bool {
	want, framed := model_frame(src, framing, spec)
	it := records.open(transmute([]u8)src, json.as(spec), framing)
	defer records.close(&it)
	got_sink, want_sink: typed.Collected
	got_sink.errors = make([dynamic]core.Typed_Error, context.temp_allocator)
	want_sink.errors = make([dynamic]core.Typed_Error, context.temp_allocator)
	got_read, want_read := read, read
	if read.collect != nil {
		got_read.collect = &got_sink
		want_read.collect = &want_sink
	}
	n := 0
	for {
		v: Typed_Piece
		more, err := records.read(&it, &v, plan, got_read, context.temp_allocator)
		if !more {
			break
		}
		if n >= len(want) {
			return testing.expectf(t, false, "%v %v %q: record %d past the model's", framing, spec, src, n)
		}
		r := want[n]
		w: Typed_Piece
		want_err: string
		if r.at > 0 && has_bom(r.text) && spec != .Json5 {
			bom := core.Typed_Error{kind = .Walk, at = r.at, inner = {at = r.at, rules = &json.RULES, kind = .Bad_Char}}
			want_err = error_text(bom, 0)
			if want_read.collect != nil {
				append(&want_sink.errors, bom)
			}
		} else {
			mark := len(want_sink.errors)
			e: core.Typed_Error
			switch spec {
			case .Json:  e = json.unmarshal(transmute([]u8)r.text, .Json, &w, plan, want_read, {}, context.temp_allocator)
			case .Jsonc: e = json.unmarshal(transmute([]u8)r.text, .Jsonc, &w, plan, want_read, {}, context.temp_allocator)
			case .Json5: e = json.unmarshal(transmute([]u8)r.text, .Json5, &w, plan, want_read, {}, context.temp_allocator)
			}
			want_err = error_text(e, r.at)
			for &x in want_sink.errors[mark:] {
				x.at += r.at
				if x.kind == .Walk {
					x.inner.at += r.at
				}
			}
		}
		got_err := error_text(err, 0)
		if !testing.expectf(t, got_err == want_err, "%v %v %v %q: record %d at %d: %s, want %s", framing, spec, read, src, n, r.at, got_err, want_err) {
			return false
		}
		if err.kind == .None && !testing.expectf(t, fmt.tprint(v) == fmt.tprint(w), "%v %v %q: record %d read %v, want %v", framing, spec, src, n, v, w) {
			return false
		}
		n += 1
	}
	if !testing.expectf(t, n == len(want) && it.fault == framed, "%v %v %q: %d records, fault %v, want %d, %v", framing, spec, src, n, it.fault, len(want), framed) {
		return false
	}
	return testing.expectf(t, fmt.tprint(got_sink.errors[:]) == fmt.tprint(want_sink.errors[:]), "%v %v %q: collected %v, want %v", framing, spec, src, got_sink.errors[:], want_sink.errors[:])
}

@(test)
records_read_as_unmarshal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, err := json.plan_make(Typed_Piece)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	defer typed.plan_destroy(&plan)
	state := rand.create(2)
	gen := rand.default_random_generator(&state)
	breakers := "x\"}],:\n\r \x1e\\1"
	sink: typed.Collected
	reads := []typed.Read_Options{{}, {collect = &sink}, {refuse_duplicates = true}, {unknown = .Refuse}}
	for round in 0 ..< 16 {
		framing := core.Framing(round % 4)
		src := seeded_text(gen, framing)
		buf := make([]u8, len(src), context.temp_allocator)
		for i in -1 ..< len(src) {
			for c in transmute([]u8)breakers {
				copy(buf, src)
				if i >= 0 {
					buf[i] = c
				}
				for spec in json.Spec {
					for read in reads {
						if !expect_read(t, string(buf), framing, spec, read, &plan) {
							return
						}
					}
				}
				if i < 0 {
					break
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
records_build_places_faults :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "{\"a\":[1,2]}\n[1,}\n\xef\xbb\xbf2\n"
	it := records.open(transmute([]u8)src, json.as(.Json))
	defer records.close(&it)
	rec, _ := records.next(&it)
	doc, err := records.build(&it, rec, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	path, _ := core.parse_path(".a[1]", context.temp_allocator)
	answers, _ := core.query(&doc, path, allocator = context.temp_allocator)
	testing.expect_value(t, len(answers), 1)
	rec, _ = records.next(&it)
	_, err = records.build(&it, rec, context.temp_allocator)
	testing.expect_value(t, err, core.Document_Error{kind = .Walk, at = 15, inner = {at = 15, rules = &json.RULES, kind = .Bad_Char}})
	rec, _ = records.next(&it)
	_, err = records.build(&it, rec, context.temp_allocator)
	testing.expect_value(t, err, core.Document_Error{kind = .Walk, at = 17, inner = {at = 17, rules = &json.RULES, kind = .Bad_Char}})
}
