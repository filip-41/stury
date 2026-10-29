package dsv_tests

import "base:sanitizer"
import "core:math/rand"
import "core:testing"
import core "../../core"
import dsv ".."
import gen "gen"

Case :: struct {
	text:   string,
	kind:   core.Fault_Kind, // 0 for a valid text
	offset: u64,
}

// Every fault the CSV pass raises, at the byte the fault's rule names.
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
	{"a,b\n1\n", .Bad_Structure, 4},
	{"a,b\n1,2,3", .Bad_Structure, 4},
	{"a\n\nb,c\n", .Bad_Structure, 3},
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

// Every fault the TSV pass raises, at the byte the fault's rule names.
@(rodata)
TSV_CASES := []Case {
	{"a\tb\n1\t2\n", nil, 0},
	{"a\\tb\\\\\\n\\r\\0\n", nil, 0},
	{"\"a\tb\n1\t2\n", nil, 0},
	{"a,b\r\n", nil, 0},
	{"a\\xb\n", .Bad_Escape, 1},
	{"a\\", .Bad_Escape, 1},
	{"a\\\n", .Bad_Escape, 1},
	{"a\tb\n1\n", .Bad_Structure, 4},
	{"a\rb", .Bad_Char, 1},
	{"a\r", .Bad_Char, 1},
	{"\\\xff", .Bad_Escape, 0},
	{"a\xf5\n", .Bad_Char, 1},
	{"a\xf0\x9f\x98", .Truncated, 4},
}

@(test)
faults_at_their_byte :: proc(t: ^testing.T) {
	for c in CSV_CASES {
		expect_fault(t, c, dsv.validate(transmute([]u8)c.text, .Csv))
	}
	for c in TSV_CASES {
		expect_fault(t, c, dsv.validate(transmute([]u8)c.text, .Tsv))
	}
}

expect_fault :: proc(t: ^testing.T, c: Case, got: Maybe(core.Fault), shift := 0, loc := #caller_location) -> bool {
	if c.kind == nil {
		return testing.expectf(t, got == nil, "%q shifted %d: %v, want none", c.text, shift, got, loc = loc)
	}
	detail := u8(dsv.Detail.Field_Count) if c.kind == .Bad_Structure else 0
	want := core.Fault{c.offset + u64(shift), &dsv.RULES, c.kind, detail}
	return testing.expectf(t, got == want, "%q shifted %d: %v, want %v", c.text, shift, got, want, loc = loc)
}

// Each case after 0 to 129 empty lines, which are no records: every quote, CR, escape and UTF-8 sequence of a case
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
				if !expect_fault(t, c, validate(buf[:], tsv), k) {
					return
				}
				// The walk's verdict is `validate`'s, and it ends at the fault or at the text's end.
				hi, fault := walk(buf[:], tsv, false, &struct {}{}, &core.Hook_Regs{}, regs_hook)
				end := c.offset + u64(k) if c.kind != nil else u64(len(buf))
				if !expect_fault(t, c, fault, k) || !testing.expectf(t, hi == end, "%q shifted %d: hi %d, want %d", c.text, k, hi, end) {
					return
				}
			}
		}
	}
}

validate :: proc(src: []u8, tsv: bool) -> Maybe(core.Fault) {
	return dsv.validate(src, .Tsv) if tsv else dsv.validate(src, .Csv)
}

// `validate` and `walk` of `src` with the bytes after it poisoned: the pass's loads of the last, partial block stay in
// the text. The two verdicts agree, or the walk's is the one returned.
validate_fenced :: proc(src: []u8, tsv: bool) -> Maybe(core.Fault) {
	FENCE :: 64
	buf := make([]u8, len(src) + FENCE)
	defer delete(buf)
	copy(buf, src)
	sanitizer.address_poison(buf[len(src):])
	defer sanitizer.address_unpoison(buf[len(src):])
	verdict := validate(buf[:len(src)], tsv)
	if _, fault := walk(buf[:len(src)], tsv, false, &struct {}{}, &core.Hook_Regs{}, regs_hook); fault != verdict {
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

// Texts a tolerance takes, and faults no tolerance in the set takes, which stand as they do without it.
@(rodata)
TOLERATED := []Tolerated {
	{{"a,b,c\n1,2\n3\n", nil, 0}, false, false, {.Ragged}},
	{{"a,b\n1", nil, 0}, false, false, {.Ragged}},
	{{"1,2\n3\n4,5,6\n7,8,9,10", nil, 0}, false, true, {.Ragged}},
	{{"a,b\n1,2,3\n", .Bad_Structure, 4}, false, false, {.Ragged}},
	{{"a,b\n1,2,3", .Bad_Structure, 4}, false, false, {.Ragged}},
	{{"a,b\n1\n", .Bad_Structure, 4}, false, false, {.Invalid_Utf8, .Bare_Quote}},
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

// Each tolerance, through `validate` and `walk`, after 0 to 129 empty lines so that what it takes falls on every byte
// of a block: what it takes was a fault without it, and what it does not take faults alike.
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
				hi, fault = dsv.walk(buf[:], 0, .Tsv, opts, &struct {}{}, &core.Hook_Regs{}, regs_hook)
			} else {
				strict = dsv.validate(buf[:], .Csv, {no_header = c.no_header})
				got = dsv.validate(buf[:], .Csv, opts)
				hi, fault = dsv.walk(buf[:], 0, .Csv, opts, &struct {}{}, &core.Hook_Regs{}, regs_hook)
			}
			if !expect_fault(t, c, got, k) || !expect_fault(t, c, fault, k) || !testing.expectf(t, c.kind != nil || strict != nil, "%q: strict takes it", c.text) {
				return
			}
			end := c.offset + u64(k) if c.kind != nil else u64(len(buf))
			if !testing.expectf(t, hi == end, "%q shifted %d: hi %d, want %d", c.text, k, hi, end) {
				return
			}
		}
	}
}

// A ragged record's missing columns make no tokens, and a bare quote is a byte of its cell, which is no quoted cell.
@(test)
tolerated_tokens :: proc(t: ^testing.T) {
	log := new(Log)
	defer free(log)
	Tokens :: struct {
		text:   string,
		tol:    bit_set[dsv.Tolerance; u8],
		tokens: []core.Token,
	}
	for c in ([]Tokens {
		{"a,b,c\n1,2\n", {.Ragged}, {{0, 0, .Array, .Value, 0}, {6, 0, .Map, .Value, 0}, {0, 1, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}, {2, 1, .Plain, .Key, 0}, {8, 1, .Plain, .Value, 0}, {9, 1, .End, .Value, 0}, {10, 0, .End, .Value, 0}}},
		{"a\"b,c\n1,\"2\"", {.Bare_Quote}, {{0, 0, .Array, .Value, 0}, {6, 0, .Map, .Value, 0}, {0, 3, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}, {4, 1, .Plain, .Key, 0}, {8, 3, .Plain, .Value, 1}, {11, 0, .End, .Value, 0}, {11, 0, .End, .Value, 0}}},
	}) {
		log^ = {}
		hi, fault := dsv.walk(transmute([]u8)c.text, 0, .Csv, {tolerate = c.tol}, log, &core.Hook_Regs{}, log_hook)
		testing.expectf(t, fault == nil && hi == u64(len(c.text)), "%q: %d %v", c.text, hi, fault)
		testing.expectf(t, slice_eq(log.tokens[:log.n], c.tokens), "%q: %v", c.text, log.tokens[:log.n])
	}
}
