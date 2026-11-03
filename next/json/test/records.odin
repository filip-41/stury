package json_tests

import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
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

// Returns the length of the whitespace character at the start of `s`: JSON's four bytes and, in JSON5, VT, FF, NBSP,
// BOM and U+2028 and U+2029 besides.
@(private = "file")
ws_len :: proc(s: string, spec: json.Spec) -> int {
	if len(s) > 0 && is_blank(s[0]) {
		return 1
	}
	if spec != .Json5 {
		return 0
	}
	for w in ([]string{"\x0b", "\x0c", "\xc2\xa0", "\xef\xbb\xbf", "\u2028", "\u2029"}) {
		if strings.has_prefix(s, w) {
			return len(w)
		}
	}
	return 0
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

// Returns the first offset at or past `i` that is no whitespace, in a spec with comments no comment, and with `rs` no
// 0x1E.
@(private = "file")
model_gap :: proc(src: string, i: int, spec: json.Spec, rs: bool) -> int {
	i := i
	for i < len(src) {
		if n := ws_len(src[i:], spec); n > 0 {
			i += n
		} else if rs && src[i] == 0x1e {
			i += 1
		} else if spec != .Json && (strings.has_prefix(src[i:], "//") || strings.has_prefix(src[i:], "/*")) {
			// A `//` comment ends at a CR or an LF, in JSON5 at U+2028 and U+2029 too.
			e := strings.index_any(src[i:], "\r\n\u2028\u2029" if spec == .Json5 else "\r\n") if src[i + 1] == '/' else strings.index(src[i + 2:], "*/") + 4
			e = len(src) - i if e < 0 && src[i + 1] == '/' else e
			// A comment that does not end, is not UTF-8, or holds a control byte but a tab or a line end, is no gap.
			if e < 4 && src[i + 1] == '*' || !utf8.valid_string(src[i:][:e]) || strings.index_proc(src[i:][:e], proc(r: rune) -> bool {return r < 0x20 && r != '\t' && r != '\r' && r != '\n'}) >= 0 {
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
			for k < len(src) && !strings.contains_rune(",:[]{}\"'/ \t\r\n\x1e", rune(src[k])) && ws_len(src[k:], spec) == 0 {
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
		for k < hi && ws_len(src[k:hi], spec) > 0 {
			k += ws_len(src[k:hi], spec)
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
	`{"aaaaaaaaaaaaaaaaaaaaaaaa":"𐀀xxxxxxxxxxxxxxxxxxxxxxxxxx","b":[1,2,3,4,5,6,7,8,9,10,11,12,13,14]}`,
	"[\"\\ud800\\udc00\xf0\x9f\x98\x80yyyyyyyyyyyyyyyyyyyyyyyyy\", 123456789012345678901234567890, -0.5e-300, \"\xc3\xa9zzzzzzzzzzzzzzzzzzzzz\"]",
	"/* a long comment that runs and runs and runs */ {\"k\":{\"x\":[\"pppppppppppppppppppppppp\"]}}   ",
	"{a:'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\\nyyyyy', bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: 0x1234567890abcdef, c: Infinity}",
	"[1, /* comment spread\n over lines */ 2, 33333333333333333333333333333333333333]",
	"{\"a\":\"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\\\"qqqqqqqqqqqqqqqqqqqqqq\",\"b\":[[[[[[[[[[1]]]]]]]]]]}  // tail comment here",
	"[1\x0b,2\xc2\xa0]",
	"12\xef\xbb\xbf13",
}

@(private = "file", rodata)
SEPARATORS := []string{"\n", "\r\n", "\n\n", "\n  \t\n", " \n", "\r\n\r\n", "\x0b\n", "\n\xc2\xa0\n", "\xef\xbb\xbf\n", "\x0c", "\xc2\xa0", "\xe2\x80\xa8\n"}

// Object members' keys under `.Entries`, JSON5's among them.
@(private = "file", rodata)
KEYS := []string{`"a":`, `"b\"c" : `, "\"k\"\n:", `a:`, `'q' :`, `/* c */ "x"/* c */:`}

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
	// Each byte of a text in turn becomes a byte or character that breaks or ends a value.
	breakers := []string{"x", "\"", "}", "]", ",", ":", "\n", "\r", " ", "\x1e", "\x00", "\\", "\x0b", "\x0c", "\xc2\xa0", "\xef\xbb\xbf"}
	buf := make([dynamic]u8, context.temp_allocator)
	for seed in u64(1) ..= SEEDS {
		state := rand.create(seed)
		gen := rand.default_random_generator(&state)
		for round in 0 ..< 200 / SEEDS {
			framing := core.Framing(round % 4)
			src := seeded_text(gen, framing)
			for spec in json.Spec {
				if !expect_model(t, src, framing, spec) {
					return
				}
			}
			for i in 0 ..< len(src) {
				for c in breakers {
					clear(&buf)
					append(&buf, src[:i])
					append(&buf, c)
					append(&buf, src[i + 1:])
					for spec in json.Spec {
						if !expect_model(t, string(buf[:]), framing, spec) {
							return
						}
					}
				}
			}
		}
	}
}

// The seeds each property test draws its texts from.
@(private = "file")
SEEDS :: 4

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
	testing.expect_value(t, faults[1], core.Fault{at = 7, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Trailing)})

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
	kp, _ := json.plan_make(string)
	defer typed.plan_destroy(&kp)
	name: string
	kerr := json.unmarshal(transmute([]u8)keys[1], .Json, &name, &kp, {}, {}, context.temp_allocator)
	testing.expect(t, kerr.kind == .None && name == `b"c`)
	flat := json.as(.Json)
	flat.max_depth = 1
	faults, _ = records.check(transmute([]u8)string("[1, 2]"), flat, .Entries, context.temp_allocator)
	testing.expect_value(t, len(faults), 0)
	faults, _ = records.check(transmute([]u8)string("[1, [2]]"), flat, .Entries, context.temp_allocator)
	testing.expect(t, len(faults) == 1 && faults[0].kind == .Too_Deep && faults[0].at == 4)
	// Concatenated documents: a number runs on into a letter as one bad token.
	faults, _ = records.check(transmute([]u8)string("1 [2]{}\"s\"3x"), json.as(.Json), .Concatenated, context.temp_allocator)
	testing.expect(t, len(faults) == 1 && faults[0].detail == u8(json.Detail.Trailing) && faults[0].at == 11)

	// A line of JSON5 whitespace is no record, in JSON it is a refused one.
	ws := transmute([]u8)string("1\n\x0b\n\xc2\xa0\n2")
	for spec in ([]json.Spec{.Json5, .Json}) {
		it4 := records.open(ws, json.as(spec))
		defer records.close(&it4)
		n = 0
		for _ in records.next(&it4) {
			n += 1
		}
		testing.expect_value(t, n, 2 if spec == .Json5 else 4)
	}

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
expect_read :: proc(t: ^testing.T, src: string, framing: core.Framing, spec: json.Spec, read: typed.Read_Options, plan: ^typed.Plan, $T: typeid) -> bool {
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
		v: T
		more, err := records.read(&it, &v, plan, got_read, context.temp_allocator)
		if !more {
			break
		}
		if n >= len(want) {
			return testing.expectf(t, false, "%v %v %q: record %d past the model's", framing, spec, src, n)
		}
		r := want[n]
		w: T
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
		if (err.kind == .None || r.fault == nil) && !testing.expectf(t, fmt.tprint(v) == fmt.tprint(w), "%v %v %q: record %d read %v, want %v", framing, spec, src, n, v, w) {
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
	breakers := []string{"x", "\"", "]", ",", "\n", "\x1e", "1", "\x0b", "\xc2\xa0", "\xef\xbb\xbf"}
	sink: typed.Collected
	reads := []typed.Read_Options{{}, {collect = &sink}, {refuse_duplicates = true}, {unknown = .Refuse}}
	buf: [dynamic]u8
	defer delete(buf)
	for seed in u64(1) ..= SEEDS {
		state := rand.create(seed + 1)
		gen := rand.default_random_generator(&state)
		framing := core.Framing(seed % 4)
		src := seeded_text(gen, framing)
		for i in -1 ..< len(src) {
			for c in breakers {
				clear(&buf)
				if i < 0 {
					append(&buf, src)
				} else {
					append(&buf, src[:i])
					append(&buf, c)
					append(&buf, src[i + 1:])
				}
				for spec in json.Spec {
					for read in reads {
						if !expect_read(t, string(buf[:]), framing, spec, read, &plan, Typed_Piece) {
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

// A union target reads the arm its record's class picks, and refuses the other classes, as `unmarshal` does.
@(test)
records_read_a_union :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Arms :: union {
		int,
		string,
		[]int,
	}
	plan, err := json.plan_make(Arms)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	defer typed.plan_destroy(&plan)
	texts := []string{"1\n\"s\"\n[1,2]\ntrue\n{}\n[\"x\"]\n", "[1, \"s\", [3], null, false, {\"a\":1}]", "1 \"s\" [2] 3x"}
	for text in texts {
		for framing in core.Framing {
			for spec in json.Spec {
				if !expect_read(t, text, framing, spec, {}, &plan, Arms) {
					return
				}
			}
		}
	}
}

// A plan of another type is refused the same way under every framing, before any record is read.
@(test)
records_read_checks_the_plan_once :: proc(t: ^testing.T) {
	plan, _ := json.plan_make(Typed_Piece)
	defer typed.plan_destroy(&plan)
	for framing in core.Framing {
		it := records.open(transmute([]u8)string("{\"a\":1}\n{\"a\":2}\n"), json.as(.Json), framing)
		defer records.close(&it)
		v: struct{ a: int }
		more, err := records.read(&it, &v, &plan)
		testing.expectf(t, !more && err.kind == .Plan_Mismatch && it.pos == core.text_start(it.src, 0), "%v: %v %v", framing, more, err.kind)
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

// An input that gives at most `sizes[i % len(sizes)]` bytes on its `i`-th read, a random count up to 16 when `sizes`
// is empty, and fails with `.Unknown` once `fail_at` bytes are read.
@(private = "file")
Chunked :: struct {
	src:     []u8,
	sizes:   []int,
	gen:     rand.Generator,
	reads:   int,
	at:      int,
	fail_at: int,
}

@(private = "file")
chunked :: proc(c: ^Chunked) -> io.Reader {
	return {data = c, procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		c := (^Chunked)(data)
		if mode != .Read {
			return 0, .Unsupported
		}
		if c.at == c.fail_at {
			return 0, .Unknown
		}
		if c.at == len(c.src) {
			return 0, .EOF
		}
		k := c.sizes[c.reads % len(c.sizes)] if len(c.sizes) > 0 else 1 + rand.int_max(16, c.gen)
		c.reads += 1
		k = min(k, c.fail_at - c.at) if c.fail_at >= 0 else k
		n := copy(p[:min(len(p), k)], c.src[c.at:])
		c.at += n
		return i64(n), nil
	}}
}

@(private = "file")
Got :: struct {
	recs:  [dynamic]records.Record,
	errs:  [dynamic]string,
	fault: Maybe(core.Fault),
	held:  string,
	at:    u64,
}

// Every record of `it` with its built document's error, copied, since a stream's record text is gone at the next call.
@(private = "file")
drain :: proc(it: ^records.Reader) -> (g: Got) {
	g.recs = make([dynamic]records.Record, context.temp_allocator)
	g.errs = make([dynamic]string, context.temp_allocator)
	for rec in records.next(it) {
		_, err := records.build(it, rec, context.temp_allocator)
		text := strings.clone(string(rec.text), context.temp_allocator)
		key := strings.clone(string(rec.key), context.temp_allocator)
		append(&g.recs, records.Record{text = transmute([]u8)text, key = transmute([]u8)key, at = rec.at})
		append(&g.errs, fmt.tprint(err))
	}
	g.fault, g.held, g.at = it.fault, strings.clone(string(it.held), context.temp_allocator), it.held_at
	return
}

// A stream of `src` read in chunks gives the records and faults `src` in memory gives, but for a last record the input
// ends inside, which it holds.
@(private = "file")
expect_window_law :: proc(t: ^testing.T, src: string, framing: core.Framing, spec: json.Spec, sizes: []int, gen: rand.Generator) -> bool {
	mem := records.open(transmute([]u8)src, json.as(spec), framing)
	defer records.close(&mem)
	want := drain(&mem)
	c := Chunked{src = transmute([]u8)src, sizes = sizes, gen = gen, fail_at = -1}
	st := records.open_stream(chunked(&c), json.as(spec), framing)
	defer records.close(&st)
	got := drain(&st)
	n := len(got.recs)
	same := n <= len(want.recs)
	for i in 0 ..< min(n, len(want.recs)) {
		r, w := got.recs[i], want.recs[i]
		same &&= r.at == w.at && string(r.text) == string(w.text) && string(r.key) == string(w.key) && got.errs[i] == want.errs[i]
	}
	end := u64(len(src))
	if len(got.held) == 0 {
		same &&= n == len(want.recs) && got.fault == want.fault
	} else {
		// The held bytes run to the input's end, and in memory they are a record refused as cut off, or that fault.
		cut := core.Fault{at = end, rules = &json.RULES, kind = .Truncated}
		extra := len(want.recs) - n
		same &&= got.fault == nil && got.at + u64(len(got.held)) == end && src[got.at:] == got.held
		same &&= extra == 0 && want.fault == cut || extra == 1 && want.fault == nil && strings.contains(want.errs[n], "Truncated")
	}
	return testing.expectf(t, same && st.cause == nil, "%v %v %v %q: stream %v %v held %q at %d, memory %v %v %v", framing, spec, sizes, src, got.recs[:], got.fault, got.held, got.at, want.recs[:], want.errs[:], want.fault)
}

@(test)
records_stream_as_in_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(3)
	gen := rand.default_random_generator(&state)
	sizes := [][]int{{1}, {2}, {3}, {7}, {64}, {}}
	// Tokens and gaps longer than a window that cuts them.
	long := []string{"1 /* a comment longer than a window */ 2", "1 // a line comment longer than a window\n2", "[\"a string longer than the window\"]"}
	for src in long {
		for spec in json.Spec {
			for s in sizes {
				if !expect_window_law(t, src, .Concatenated, spec, s, gen) {
					return
				}
			}
		}
	}
	breakers := "x\"}],:\n\r \x1e\x00\\"
	for round in 0 ..< 800 {
		framing := core.Framing(round % 4)
		src := seeded_text(gen, framing)
		if round % 8 >= 4 {
			// A byte that breaks or ends a value, at a random place.
			buf := transmute([]u8)strings.clone(src, context.temp_allocator)
			buf[rand.int_max(len(buf), gen)] = breakers[rand.int_max(len(breakers), gen)]
			src = string(buf)
		}
		for spec in json.Spec {
			for s in sizes {
				if !expect_window_law(t, src, framing, spec, s, gen) {
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

// `records.read` on a stream gives what it gives in memory, with offsets from the input's first byte.
@(test)
records_stream_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, perr := json.plan_make(Typed_Piece)
	testing.expect_value(t, perr.kind, core.Typed_Error_Kind.None)
	defer typed.plan_destroy(&plan)
	state := rand.create(4)
	gen := rand.default_random_generator(&state)
	for round in 0 ..< 200 {
		framing := core.Framing(round % 4)
		src := seeded_text(gen, framing)
		for spec in json.Spec {
			mem := records.open(transmute([]u8)src, json.as(spec), framing)
			c := Chunked{src = transmute([]u8)src, sizes = {1 + round % 5}, fail_at = -1}
			st := records.open_stream(chunked(&c), json.as(spec), framing)
			ms, ss: typed.Collected
			ms.errors = make([dynamic]core.Typed_Error, context.temp_allocator)
			ss.errors = make([dynamic]core.Typed_Error, context.temp_allocator)
			for {
				v, w: Typed_Piece
				more, err := records.read(&st, &v, &plan, {collect = &ss}, context.temp_allocator)
				wmore, werr := records.read(&mem, &w, &plan, {collect = &ms}, context.temp_allocator)
				if !more {
					// A record the stream holds is the last one memory reads.
					if len(st.held) > 0 && wmore {
						resize(&ms.errors, len(ss.errors))
						wmore, _ = records.read(&mem, &w, &plan, {collect = &ms}, context.temp_allocator)
					}
					testing.expectf(t, !wmore && (st.fault == mem.fault || len(st.held) > 0), "%v %v %q: stream ends %v, memory %v %v", framing, spec, src, st.fault, wmore, mem.fault)
					break
				}
				if !testing.expectf(t, wmore && error_text(err, 0) == error_text(werr, 0) && (err.kind != .None || fmt.tprint(v) == fmt.tprint(w)), "%v %v %q: read %v %s, memory %v %s", framing, spec, src, v, error_text(err, 0), w, error_text(werr, 0)) {
					return
				}
			}
			if len(st.held) == 0 {
				testing.expectf(t, fmt.tprint(ss.errors[:]) == fmt.tprint(ms.errors[:]), "%v %v %q: collected %v, memory %v", framing, spec, src, ss.errors[:], ms.errors[:])
			}
			records.close(&mem)
			records.close(&st)
		}
		free_all(context.temp_allocator)
	}
}

// An input that ends at any byte inside its last record holds that record's bytes and ends with no fault.
@(test)
records_stream_holds_a_cut_record :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	last := `{"k":["xé",-1.5e3,true,null]}`
	heads := [3]string{"1\n[2]\n", "\x1e1\n\x1e[2]\n\x1e", "1 [2] "}
	for head, i in heads {
		framing := core.Framing(i)
		src := strings.concatenate({head, last}, context.temp_allocator)
		for k in len(head) + 1 ..< len(src) {
			c := Chunked{src = transmute([]u8)src[:k], sizes = {3}, fail_at = -1}
			it := records.open_stream(chunked(&c), json.as(.Json), framing)
			n := 0
			for _ in records.next(&it) {
				n += 1
			}
			// The held bytes start past the last whole record, which under `.Concatenated` is before the gap.
			from := len(head) - int(framing == .Concatenated)
			testing.expectf(t, n == 2 && it.fault == nil && it.held_at == u64(from) && string(it.held) == src[from:k], "%v cut at %d: %d records, %v, held %q at %d", framing, k, n, it.fault, it.held, it.held_at)
			records.close(&it)
		}
		// A whole last record with no end byte is a record.
		c := Chunked{src = transmute([]u8)src, sizes = {3}, fail_at = -1}
		it := records.open_stream(chunked(&c), json.as(.Json), framing)
		n := 0
		for _ in records.next(&it) {
			n += 1
		}
		testing.expectf(t, n == 3 && it.fault == nil && len(it.held) == 0, "%v whole: %d records, %v", framing, n, it.fault)
		records.close(&it)
	}
}

@(test)
records_stream_limits_and_failures :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := strings.concatenate({"1\n22\n\"", strings.repeat("a", 100, context.temp_allocator), "\"\n4\n"}, context.temp_allocator)
	for limit in ([]int{32, 200}) {
		c := Chunked{src = transmute([]u8)src, sizes = {7}, fail_at = -1}
		it := records.open_stream(chunked(&c), json.as(.Json), .Lines, {max_bytes = limit})
		n := 0
		for _ in records.next(&it) {
			n += 1
		}
		if limit == 32 {
			testing.expectf(t, n == 2 && it.fault == core.Fault{at = 5, rules = &records.RULES, kind = .Too_Wide, detail = 1}, "%d records, %v", n, it.fault)
		} else {
			testing.expectf(t, n == 4 && it.fault == nil, "%d records, %v", n, it.fault)
		}
		records.close(&it)
	}

	// A failing input ends the records it gave whole and holds the bytes past them. Under `.Concatenated` a record
	// within 12 bytes of the window's end is not known to be whole.
	for framing in ([]core.Framing{.Lines, .Concatenated, .Entries}) {
		text := "[1,22,333,4444,55555,666666]" if framing == .Entries else "1\n22\n333\n4444\n55555\n666666\n"
		c := Chunked{src = transmute([]u8)text, sizes = {2}, fail_at = 24}
		it := records.open_stream(chunked(&c), json.as(.Json), framing)
		got := make([dynamic]string, context.temp_allocator)
		for rec in records.next(&it) {
			append(&got, strings.clone(string(rec.text), context.temp_allocator))
		}
		want: []string
		held := text[:24]
		#partial switch framing {
		case .Lines:
			want, held = {"1", "22", "333", "4444", "55555"}, text[20:24]
		case .Concatenated:
			want, held = {"1", "22", "333"}, text[8:24]
		}
		testing.expectf(t, fmt.tprint(got[:]) == fmt.tprint(want) && it.fault == nil && it.cause == .Unknown && string(it.held) == held, "%v: %v, %v %v, held %q", framing, got[:], it.fault, it.cause, it.held)
		records.close(&it)
	}
}

// A reader opened at a byte of the input, on the text in memory or on a stream of the text past that byte, gives the
// records from that byte with offsets from the input's first byte.
@(test)
records_open_at_an_offset :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		src:     string,
		framing: core.Framing,
		at:      u64,
	}
	cases := []Case{{"1\n[2]\n\xef\xbb\xbf3\n4", .Lines, 2}, {"x\x1e1\x1e2", .Seq, 1}, {"1 [2] 3x", .Concatenated, 1}, {"xx [1, {}]", .Entries, 2}, {"xx [1, }", .Entries, 2}}
	for c in cases {
		// The text past `at` read alone, with its offsets moved by `at`. None of these starts with a BOM.
		past := records.open(transmute([]u8)c.src[c.at:], json.as(.Json), c.framing)
		want := drain(&past)
		records.close(&past)
		for &r in want.recs {
			r.at += c.at
		}
		fault := want.fault
		if f, bad := fault.?; bad {
			f.at += c.at
			fault = f
		}
		mem := records.open(transmute([]u8)c.src, json.as(.Json), c.framing, c.at)
		from := drain(&mem)
		records.close(&mem)
		ch := Chunked{src = transmute([]u8)c.src[c.at:], sizes = {2}, fail_at = -1}
		st := records.open_stream(chunked(&ch), json.as(.Json), c.framing, at = c.at)
		streamed := drain(&st)
		records.close(&st)
		testing.expectf(t, fmt.tprint(from.recs[:]) == fmt.tprint(want.recs[:]) && from.fault == fault, "%q at %d: %v %v, want %v %v", c.src, c.at, from.recs[:], from.fault, want.recs[:], fault)
		testing.expectf(t, fmt.tprint(streamed.recs[:]) == fmt.tprint(want.recs[:]) && streamed.fault == fault, "%q stream at %d: %v %v, want %v %v", c.src, c.at, streamed.recs[:], streamed.fault, want.recs[:], fault)
	}
}

// `next_window` gives windows of whole records that hold every record `next` gives.
@(test)
records_next_window :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(5)
	gen := rand.default_random_generator(&state)
	for round in 0 ..< 300 {
		framing := core.Framing(round % 3)
		src := seeded_text(gen, framing)
		mem := records.open(transmute([]u8)src, json.as(.Json), framing)
		want := drain(&mem)
		records.close(&mem)
		c := Chunked{src = transmute([]u8)src, sizes = {1 + round % 9}, fail_at = -1}
		st := records.open_stream(chunked(&c), json.as(.Json), framing)
		n := 0
		end := u64(0)
		for window, base in records.next_window(&st) {
			if !testing.expectf(t, base >= end && src[base:][:len(window)] == string(window), "%v %q: window %q at %d", framing, src, window, base) {
				return
			}
			end = base + u64(len(window))
			for r in want.recs {
				n += int(r.at >= base && r.at + u64(len(r.text)) <= end)
			}
		}
		held := u64(len(st.held))
		testing.expectf(t, n == len(want.recs) - int(held > 0 && want.fault == nil) && end + held <= u64(len(src)), "%v %q: windows hold %d records of %d", framing, src, n, len(want.recs))
		records.close(&st)
		free_all(context.temp_allocator)
	}
}
