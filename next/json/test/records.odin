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

// Frames `src` byte by byte. Returns the records and the framing's own fault.
@(private = "file")
model_frame :: proc(src: string, framing: core.Framing, spec: json.Spec) -> (out: [dynamic]Model_Record, fault: Maybe(core.Fault)) {
	out = make([dynamic]Model_Record, context.temp_allocator)
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
			append(&out, Model_Record{u64(k), src[k:hi], model_fault(src[k:hi], u64(k), spec)})
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
		if n >= len(want) || rec.at != want[n].at || string(rec.text) != want[n].text {
			testing.expectf(t, false, "%v %v %q: record %d at %d %q", framing, spec, src, n, rec.at, rec.text)
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

@(private = "file")
seeded_text :: proc(gen: rand.Generator, framing: core.Framing) -> string {
	b := strings.builder_make(context.temp_allocator)
	if rand.int_max(4, gen) == 0 {
		strings.write_string(&b, "\xef\xbb\xbf")
	}
	n := 1 + rand.int_max(6, gen)
	for _ in 0 ..< n {
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
		framing := core.Framing.Lines if round % 2 == 0 else core.Framing.Seq
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
		framing := core.Framing.Lines if round % 2 == 0 else core.Framing.Seq
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
