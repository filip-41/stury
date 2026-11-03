package json_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
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
