package dsv_tests

import "base:sanitizer"
import "core:math/rand"
import "core:testing"
import core "../../core"
import dsv ".."
import gen "gen"
import walktest "../../walktest"

Case :: struct {
	text:   string,
	kind:   core.Fault_Kind, // 0 for a valid text
	offset: u64,
}

// CSV texts and the fault each raises, at the byte the fault's rule names. `nil` for a valid text.
@(rodata)
CSV_CASES := []Case {
	{"", nil, 0},
	{"a,b\n1,2\n", nil, 0},
	{"a,b\r\n1,2", nil, 0},
	{"\xef\xbb\xbfa\n", nil, 0},
	{"a\n\n\r\nb\n", nil, 0},
	{"\"a\"\"b\",c\n", nil, 0},
	{"\"a\rb\nc,d\"\n", nil, 0},
	{"a,\"\"\r\n", nil, 0},
	{"a\\,b\n", nil, 0},
	{"a,b\n1\n", .Bad_Structure, 5},
	{"a,b\n1,2,3", .Bad_Structure, 7},
	{"a\n\nb,c\n", .Bad_Structure, 4},
	{"a\"b\n", .Bad_Char, 1},
	{"\"a\"b\n", .Bad_Char, 3},
	{"\"a\" ,b\n", .Bad_Char, 3},
	{"\"abc", .Truncated, 4},
	{"a,\"b\nc", .Truncated, 6},
	{"a\rb\n", .Bad_Char, 1},
	{"a\r", .Bad_Char, 1},
	{"\"a\"\r", .Bad_Char, 3},
	{"a\xff\n", .Bad_Char, 1},
	{"a\xed\xa0\x80\n", .Bad_Char, 1},
	{"\"\xc3\"\n", .Bad_Char, 1},
	{"a\xc3", .Truncated, 2},
	{"a,b\n1\r2,3\n", .Bad_Char, 5},
}

// TSV texts and the fault each raises, at the byte the fault's rule names. `nil` for a valid text.
@(rodata)
TSV_CASES := []Case {
	{"a\tb\n1\t2\n", nil, 0},
	{"a\\tb\\\\\\n\\r\\0\n", nil, 0},
	{"\"a\tb\n1\t2\n", nil, 0},
	{"a,b\r\n", nil, 0},
	{"a\\xb\n", .Bad_Escape, 1},
	{"a\\", .Bad_Escape, 1},
	{"a\\\n", .Bad_Escape, 1},
	{"a\tb\n1\n", .Bad_Structure, 5},
	{"a\rb", .Bad_Char, 1},
	{"a\r", .Bad_Char, 1},
	{"\\\xff", .Bad_Escape, 0},
	{"a\xf5\n", .Bad_Char, 1},
	{"a\xf0\x9f\x98", .Truncated, 4},
}

@(test)
faults_at_their_byte :: proc(t: ^testing.T) {
	for c in CSV_CASES {
		expect_fault(t, c, dsv.validate(transmute([]u8)c.text, .Csv), tsv = false)
	}
	for c in TSV_CASES {
		expect_fault(t, c, dsv.validate(transmute([]u8)c.text, .Tsv), tsv = true)
	}
}

expect_fault :: proc(t: ^testing.T, c: Case, got: Maybe(core.Fault), shift := 0, tsv := false, loc := #caller_location) -> bool {
	if c.kind == nil {
		return testing.expectf(t, got == nil, "%q shifted %d: %v, want none", c.text, shift, got, loc = loc)
	}
	detail := u8(dsv.Detail.Field_Count) if c.kind == .Bad_Structure else 0
	// A quote byte is a fault only inside an unquoted CSV cell.
	if c.kind == .Bad_Char && !tsv && c.offset < u64(len(c.text)) && c.text[c.offset] == '"' {
		detail = u8(dsv.Detail.Bare_Quote)
	}
	want := core.Fault{c.offset + u64(shift), &dsv.RULES, c.kind, detail}
	return testing.expectf(t, got == want, "%q shifted %d: %v, want %v", c.text, shift, got, want, loc = loc)
}

// A quote inside an unquoted CSV cell is a bare quote, and a quote after a closing quote is not.
@(rodata)
BARE_QUOTE_CASES := []Case {
	{"a\"b\n", .Bad_Char, 1},
	{"x\"y\"z\n", .Bad_Char, 1},
	{"a\"\"b\n", .Bad_Char, 1},
	{"ab\"", .Bad_Char, 2},
	{"a\"b,\"c,\"\n", .Bad_Char, 1},
}

@(test)
bare_quote_detail :: proc(t: ^testing.T) {
	for c in BARE_QUOTE_CASES {
		f, bad := dsv.validate(transmute([]u8)c.text, .Csv).?
		testing.expectf(t, bad && f.kind == c.kind && f.at == c.offset && f.detail == u8(dsv.Detail.Bare_Quote), "%q: %v", c.text, f)
		hi, fault := walk(transmute([]u8)c.text, false, false, &struct {}{}, &core.Hook_Regs{}, walktest.regs_hook)
		testing.expectf(t, fault == f && hi == c.offset, "%q: walk %d %v, validate %v", c.text, hi, fault, f)
	}
	f, bad := dsv.validate(transmute([]u8)string("\"a\"b\n"), .Csv).?
	testing.expectf(t, bad && f.kind == .Bad_Char && f.at == 3 && f.detail == u8(dsv.Detail.None), "%v", f)
}

// Each case after 0 to 129 empty lines, which are no records. Every quote, CR, escape and UTF-8 sequence of a case
// falls on every byte of a 64-byte block and across the boundary between two, and its fault moves by the same count.
@(test)
faults_at_every_offset :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	for k in 0 ..< 130 {
		for tsv in ([]bool{false, true}) {
			for c in (TSV_CASES if tsv else CSV_CASES) {
				clear(&buf)
				for _ in 0 ..< k {
					append(&buf, '\n')
				}
				append(&buf, c.text)
				if !expect_fault(t, c, validate(buf[:], tsv), k, tsv) {
					return
				}
				// The walk's verdict is `validate`'s, and it ends at the fault or at the text's end.
				hi, fault := walk(buf[:], tsv, false, &struct {}{}, &core.Hook_Regs{}, walktest.regs_hook)
				end := c.offset + u64(k) if c.kind != nil else u64(len(buf))
				if !expect_fault(t, c, fault, k, tsv) || !testing.expectf(t, hi == end, "%q shifted %d: hi %d, want %d", c.text, k, hi, end) {
					return
				}
			}
		}
	}
}

validate :: proc(src: []u8, tsv: bool) -> Maybe(core.Fault) {
	return dsv.validate(src, .Tsv) if tsv else dsv.validate(src, .Csv)
}

// Runs `validate` and `walk` on `src` with the bytes after it poisoned, so a load of the last partial block must stay
// inside the text. Returns the walk's fault when the two differ, else `validate`'s.
validate_fenced :: proc(src: []u8, tsv: bool) -> Maybe(core.Fault) {
	FENCE :: 64
	buf := make([]u8, len(src) + FENCE)
	defer delete(buf)
	copy(buf, src)
	sanitizer.address_poison(buf[len(src):])
	defer sanitizer.address_unpoison(buf[len(src):])
	verdict := validate(buf[:len(src)], tsv)
	if _, fault := walk(buf[:len(src)], tsv, false, &struct {}{}, &core.Hook_Regs{}, walktest.regs_hook); fault != verdict {
		return fault
	}
	return verdict
}

// Every prefix of seeded texts, read with its next bytes poisoned.
@(test)
prefixes_fenced :: proc(t: ^testing.T) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	for round in 0 ..< 400 {
		tsv := round % 2 == 1
		gen.text(&text, tsv)
		for n in 0 ..= len(text) {
			if !testing.expectf(t, validate_fenced(text[:n], tsv) == validate(text[:n], tsv), "%q", text[:n]) {
				return
			}
		}
	}
}

Tolerated :: struct {
	using c:   Case,
	tsv:       bool,
	no_header: bool,
	tol:       bit_set[dsv.Tolerance; u8],
}

// Texts each tolerance set accepts, and faults no tolerance in the set accepts, which stay the same without it.
@(rodata)
TOLERATED := []Tolerated {
	{{"a,b,c\n1,2\n3\n", nil, 0}, false, false, {.Ragged}},
	{{"a,b\n1", nil, 0}, false, false, {.Ragged}},
	{{"1,2\n3\n4,5,6\n7,8,9,10", nil, 0}, false, true, {.Ragged}},
	{{"a,b\n1,2,3\n", .Bad_Structure, 7}, false, false, {.Ragged}},
	{{"a,b\n1,2,3", .Bad_Structure, 7}, false, false, {.Ragged}},
	{{"a,b\n1\n", .Bad_Structure, 5}, false, false, {.Invalid_Utf8, .Bare_Quote}},
	{{"a\tb\tc\n1\n", nil, 0}, true, false, {.Ragged}},
	{{"a,5\" pipe,b\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"x\"y\"z\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"a\"\"b\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"a\"b,\"c,\"\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"ab\"", nil, 0}, false, false, {.Bare_Quote}},
	{{"a\"b,\"c\n", .Truncated, 7}, false, false, {.Bare_Quote}},
	{{"\"a\"b\n", .Bad_Char, 3}, false, false, {.Bare_Quote}},
	{{"a\"\rb\n", .Bad_Char, 2}, false, false, {.Bare_Quote}},
	{{"a\"b\n", .Bad_Char, 1}, false, false, {.Ragged, .Invalid_Utf8}},
	{{"a\xff\n", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"a\xed\xa0\x80,\xc0\xaf\n", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"\"\xc3\",\"x\"\n", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"a\xc3", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"\"a\xc3", .Truncated, 3}, false, false, {.Invalid_Utf8}},
	{{"a\xf5\n", nil, 0}, true, false, {.Invalid_Utf8}},
	{{"a\xf0\x9f\x98", nil, 0}, true, false, {.Invalid_Utf8}},
	{{"a\\xb\n", .Bad_Escape, 1}, true, false, {.Invalid_Utf8, .Ragged, .Bare_Quote}},
	{{"a\xff\n", .Bad_Char, 1}, false, false, {.Ragged, .Bare_Quote}},
}

// Each tolerance, through `validate` and `walk`, after 0 to 129 empty lines so what it accepts falls on every byte of
// a block. A text the set accepts is clean with it and faulty without it, a text it does not accept keeps the kind and
// offset it has without the set, and both return the same fault.
@(test)
tolerances :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	for k in 0 ..< 130 {
		for c in TOLERATED {
			clear(&buf)
			for _ in 0 ..< k {
				append(&buf, '\n')
			}
			append(&buf, c.text)
			opts := dsv.Options{no_header = c.no_header, tolerate = c.tol}
			strict, got, fault: Maybe(core.Fault)
			hi: u64
			if c.tsv {
				strict = dsv.validate(buf[:], .Tsv, {no_header = c.no_header})
				got = dsv.validate(buf[:], .Tsv, opts)
				hi, fault = dsv.walk(buf[:], 0, .Tsv, opts, &struct {}{}, &core.Hook_Regs{}, walktest.regs_hook)
			} else {
				strict = dsv.validate(buf[:], .Csv, {no_header = c.no_header})
				got = dsv.validate(buf[:], .Csv, opts)
				hi, fault = dsv.walk(buf[:], 0, .Csv, opts, &struct {}{}, &core.Hook_Regs{}, walktest.regs_hook)
			}
			if !expect_fault(t, c, got, k, c.tsv) || !expect_fault(t, c, fault, k, c.tsv) || !testing.expectf(t, c.kind != nil || strict != nil, "%q: strict takes it", c.text) {
				return
			}
			end := c.offset + u64(k) if c.kind != nil else u64(len(buf))
			if !testing.expectf(t, hi == end, "%q shifted %d: hi %d, want %d", c.text, k, hi, end) {
				return
			}
		}
	}
}

// A tolerance set changes `validate` and `walk` alike on generated texts. Both return the same fault, and a walk with
// no fault ends at the text's end and keeps every cell's bytes in its token's span.
@(test)
tolerances_agree :: proc(t: ^testing.T) {
	tolerances_agree_in(t, .Csv)
	tolerances_agree_in(t, .Tsv)
}

tolerances_agree_in :: proc(t: ^testing.T, $S: dsv.Spec) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	log := new(walktest.Log)
	defer free(log)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	tsv := S == .Tsv
	for round in 0 ..< 1200 {
		no_header := round % 8 >= 4
		gen.text(&text, tsv)
		src := text[:]
		if round % 2 == 1 {
			walktest.mutate(&broken, text[:], gen.SHARP)
			src = broken[:]
		} else {
			// Writes a byte no cell may hold into the first plain cell that holds no backslash, so `Invalid_Utf8` is
			// reached.
			log^ = {}
			dsv.walk(src, 0, S, {no_header = no_header}, log, &core.Hook_Regs{}, walktest.log_hook)
			for tok in log.tokens[:log.n] {
				if tok.kind != .Plain || tok.n == 0 {
					continue
				}
				escaped := false
				for i in tok.lo ..< tok.lo + u64(tok.n) {
					if src[i] == '\\' {
						escaped = true
						break
					}
				}
				if escaped {
					continue
				}
				for i in tok.lo ..< tok.lo + u64(tok.n) {
					if src[i] != '"' {
						src[i] = 0xff
						break
					}
				}
				break
			}
		}
		tol: bit_set[dsv.Tolerance; u8]
		if rand.int_max(2) == 0 {
			tol |= {.Invalid_Utf8}
		}
		if rand.int_max(2) == 0 {
			tol |= {.Ragged}
		}
		if rand.int_max(2) == 0 {
			tol |= {.Bare_Quote}
		}
		opts := dsv.Options{no_header = no_header, tolerate = tol}
		want := dsv.validate(src, S, opts)
		log^ = {}
		hi, got := dsv.walk(src, 0, S, opts, log, &core.Hook_Regs{}, walktest.log_hook)
		if !testing.expectf(t, got == want, "%q tsv %v no_header %v tol %v: walk %v, validate %v", src, tsv, no_header, tol, got, want) {
			return
		}
		if got == nil && !testing.expectf(t, hi == u64(len(src)), "%q: hi %d", src, hi) {
			return
		}
		for tok in log.tokens[:log.n] {
			if !testing.expectf(t, spans(src, tok, tsv, tol), "%q tol %v: %v", src, tol, tok) {
				return
			}
		}
	}
}

// A ragged record's missing columns make no tokens, and a bare quote is a byte of its cell, so the cell is not quoted.
@(test)
tolerated_tokens :: proc(t: ^testing.T) {
	log := new(walktest.Log)
	defer free(log)
	Tokens :: struct {
		text:   string,
		tol:    bit_set[dsv.Tolerance; u8],
		tokens: []core.Token,
	}
	for c in ([]Tokens {
		{"a,b,c\n1,2\n", {.Ragged}, {{0, 0, .Array, .Value, 0}, {6, 0, .Map, .Value, 0}, {0, 1, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}, {2, 1, .Plain, .Key, 0}, {8, 1, .Plain, .Value, 0}, {9, 1, .End, .Value, 0}, {10, 0, .End, .Value, 0}}},
		{"a\"b,c\n1,\"2\"", {.Bare_Quote}, {{0, 0, .Array, .Value, 0}, {6, 0, .Map, .Value, 0}, {0, 3, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}, {4, 1, .Plain, .Key, 0}, {8, 3, .Plain, .Value, core.SPELLING_DECODE | core.SPELLING_QUOTED}, {11, 0, .End, .Value, 0}, {11, 0, .End, .Value, 0}}},
	}) {
		log^ = {}
		hi, fault := dsv.walk(transmute([]u8)c.text, 0, .Csv, {tolerate = c.tol}, log, &core.Hook_Regs{}, walktest.log_hook)
		testing.expectf(t, fault == nil && hi == u64(len(c.text)), "%q: %d %v", c.text, hi, fault)
		testing.expectf(t, slice_eq(log.tokens[:log.n], c.tokens), "%q: %v", c.text, log.tokens[:log.n])
	}
}
