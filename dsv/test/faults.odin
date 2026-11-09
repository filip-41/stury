package dsv_tests

import "core:math/rand"
import "core:slice"
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

// The kinds a case names for `Bad_Width` with `Detail.Too_Many` and `Detail.Too_Few`, a record wider or narrower than the first.
TOO_MANY :: core.Fault_Kind(0xff)
TOO_FEW :: core.Fault_Kind(0xfe)

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
	{"a,b\n1\n", TOO_FEW, 5},
	{"a,b\n1,2,3", TOO_MANY, 7},
	{"a\n\nb,c\n", TOO_MANY, 4},
	{"a\"b\n", .Bad_Char, 1},
	{"\"a\"b\n", .Bad_Char, 3},
	{"\"a\" ,b\n", .Bad_Char, 3},
	{"\"abc", .Truncated, 0},
	{"a,\"b\nc", .Truncated, 2},
	{"a,\"b\xc3", .Truncated, 2},
	{"a,\"b\xff", .Bad_Char, 4},
	{"a,b\n\"\"\"x\n\"\"\",\"y", .Truncated, 13},
	{"a\rb\n", .Bad_Char, 1},
	{"a\r", .Bad_Char, 1},
	{"\"a\"\r", .Bad_Char, 3},
	{"a\xff\n", .Bad_Char, 1},
	{"a\xed\xa0\x80\n", .Bad_Char, 1},
	{"\"\xc3\"\n", .Bad_Char, 1},
	{"a\xc3", .Truncated, 2},
	{"\"a\xc3", .Truncated, 0},
	{"x,\"\xe2\x82", .Truncated, 2},
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
	{"a\tb\n1\n", TOO_FEW, 5},
	{"a\rb", .Bad_Char, 1},
	{"a\r", .Bad_Char, 1},
	{"\\\xff", .Bad_Escape, 0},
	{"a\xf5\n", .Bad_Char, 1},
	{"a\xf0\x9f\x98", .Truncated, 4},
}

@(test)
faults_at_their_byte :: proc(t: ^testing.T) {
	for c in CSV_CASES {
		expect_fault(t, c, walktest.fault_of(dsv.validate(transmute([]u8)c.text, .Csv)), tsv = false)
	}
	for c in TSV_CASES {
		expect_fault(t, c, walktest.fault_of(dsv.validate(transmute([]u8)c.text, .Tsv)), tsv = true)
	}
}

// A backslash at every byte of a block: each of the five escapes is valid there, and a byte no escape spells faults at
// the backslash. The last case holds the pair split across the block's end, and a comment line's backslash opens no
// escape.
@(test)
escapes_at_every_block_byte :: proc(t: ^testing.T) {
	b: [dynamic]u8
	defer delete(b)
	for k in 0 ..< 128 {
		for escape, valid in ([]u8{'t', 'n', 'r', '0', '\\', 'x', 'T', '\\' ~ 0x20, 0x80}) {
			clear(&b)
			append(&b, "h\n")
			for _ in 0 ..< k {
				append(&b, 'a')
			}
			append(&b, '\\', escape, '\n')
			got := walktest.fault_of(dsv.validate(b[:], .Tsv))
			fault, bad := got.?
			if valid < 5 {
				testing.expectf(t, !bad, "backslash at %d escapes %#x: %v", 2 + k, escape, fault)
			} else if !bad || fault.kind != .Bad_Escape || fault.at != u64(2 + k) {
				testing.expectf(t, false, "backslash at %d escapes %#x: %v, want .Bad_Escape at %d", 2 + k, escape, got, 2 + k)
			}
		}
	}
	// A `\\` pair split across the block's end: the backslash is at byte 63 and its letter at 64.
	clear(&b)
	append(&b, "h\n")
	for _ in 0 ..< 61 {
		append(&b, 'a')
	}
	append(&b, '\\', 't', '\n')
	if fault, bad := walktest.fault_of(dsv.validate(b[:], .Tsv)).?; bad {
		testing.expectf(t, false, "escape split across a block: %v", fault)
	}
	// A backslash in a comment line is text.
	comment := "h\n#a\\xb\n1\n"
	if fault, bad := walktest.fault_of(dsv.validate(transmute([]u8)comment, .Tsv, {comment = '#'})).?; bad {
		testing.expectf(t, false, "backslash in a comment line: %v", fault)
	}
}

expect_fault :: proc(t: ^testing.T, c: Case, got: Maybe(core.Fault), shift := 0, tsv := false, loc := #caller_location) -> bool {
	if c.kind == nil {
		return testing.expectf(t, got == nil, "%q shifted %d: %v, want none", c.text, shift, got, loc = loc)
	}
	kind, detail := c.kind, u8(0)
	if kind == TOO_MANY || kind == TOO_FEW {
		kind, detail = .Bad_Width, u8(dsv.Detail.Too_Many if c.kind == TOO_MANY else dsv.Detail.Too_Few)
	}
	// The rule within the kind follows the byte the fault names. A quote byte is a fault only inside an unquoted CSV cell,
	// and a text cut short ends in a quote's cell or a UTF-8 sequence.
	if c.kind != TOO_MANY && c.kind != TOO_FEW && c.kind != .Bad_Escape && c.kind != nil {
		at := c.text[c.offset] if c.offset < u64(len(c.text)) else 0
		switch {
		case c.kind == .Truncated:
			detail = u8(dsv.Detail.Open_Quote if at == '"' else dsv.Detail.Cut_Utf8)
		case at == '"' && !tsv:
			detail = u8(dsv.Detail.Bare_Quote)
		case at == '\r':
			detail = u8(dsv.Detail.Lone_Cr)
		case at >= 0x80:
			detail = u8(dsv.Detail.Invalid_Utf8)
		case !tsv:
			detail = u8(dsv.Detail.After_Quote)
		}
	}
	want := core.Fault{c.offset + u64(shift), &dsv.RULES, kind, detail}
	return testing.expectf(t, got == want, "%q shifted %d: %v, want %v", c.text, shift, got, want, loc = loc)
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
	return walktest.fault_of(dsv.validate(src, .Tsv)) if tsv else walktest.fault_of(dsv.validate(src, .Csv))
}

// Runs `validate` and `walk` on `src` from a copy at the end of `fence`'s readable page, with the page after it
// unreadable, so a load past the text faults in every build. Returns the walk's fault when the two differ, else
// `validate`'s.
validate_fenced :: proc(fence: ^walktest.Fence, src: []u8, tsv: bool) -> Maybe(core.Fault) {
	fenced := walktest.fence_copy(fence, src)
	verdict := validate(fenced, tsv)
	if _, fault := walk(fenced, tsv, false, &struct {}{}, &core.Hook_Regs{}, walktest.regs_hook); fault != verdict {
		return fault
	}
	return verdict
}

// Every prefix of seeded texts, read from a copy that ends at a guard page.
@(test)
prefixes_fenced :: proc(t: ^testing.T) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	fence := walktest.fence_init()
	defer walktest.unfence(&fence)
	for round in 0 ..< 400 {
		tsv := round % 2 == 1
		gen.text(&text, tsv)
		for n in 0 ..= len(text) {
			if !testing.expectf(t, validate_fenced(&fence, text[:n], tsv) == validate(text[:n], tsv), "%q", text[:n]) {
				return
			}
		}
	}
}

Tolerated :: struct {
	using c:   Case,
	tsv:       bool,
	no_header: bool,
	tol:       bit_set[core.Tolerance; u8],
}

// Texts each tolerance set accepts, and faults no tolerance in the set accepts, which stay the same without it.
@(rodata)
TOLERATED := []Tolerated {
	{{"a,b,c\n1,2\n3\n", nil, 0}, false, false, {.Ragged}},
	{{"a,b\n1", nil, 0}, false, false, {.Ragged}},
	{{"1,2\n3\n4,5,6\n7,8,9,10", nil, 0}, false, true, {.Ragged}},
	{{"a,b\n1,2,3\n", nil, 0}, false, false, {.Ragged}},
	{{"a,b\n1,2,3,4", nil, 0}, false, false, {.Ragged}},
	{{"a,b\n1,2,3\n", TOO_MANY, 7}, false, false, {.Invalid_Utf8, .Bare_Quote}},
	{{"a,b\n1\n", TOO_FEW, 5}, false, false, {.Invalid_Utf8, .Bare_Quote}},
	{{"a\tb\tc\n1\n", nil, 0}, true, false, {.Ragged}},
	{{"a,5\" pipe,b\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"x\"y\"z\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"a\"\"b\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"a\"b,\"c,\"\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"ab\"", nil, 0}, false, false, {.Bare_Quote}},
	{{"a\"b,\"c\n", .Truncated, 4}, false, false, {.Bare_Quote}},
	{{"\"a\"b\n", .Bad_Char, 3}, false, false, {.Bare_Quote}},
	{{"a\"\rb\n", .Bad_Char, 2}, false, false, {.Bare_Quote}},
	{{"a\"b\n", .Bad_Char, 1}, false, false, {.Ragged, .Invalid_Utf8}},
	{{"a\xff\n", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"a\xed\xa0\x80,\xc0\xaf\n", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"\"\xc3\",\"x\"\n", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"a\xc3", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"\"a\xc3", .Truncated, 0}, false, false, {.Invalid_Utf8}},
	{{"a\xf5\n", nil, 0}, true, false, {.Invalid_Utf8}},
	{{"a\xf0\x9f\x98", nil, 0}, true, false, {.Invalid_Utf8}},
	{{"a\\xb\n", .Bad_Escape, 1}, true, false, {.Invalid_Utf8, .Ragged, .Bare_Quote}},
	{{"a\xff\n", .Bad_Char, 1}, false, false, {.Ragged, .Bare_Quote}},
	{{"a,b\n\xff,x\"y\n1\n", nil, 0}, false, false, {.Invalid_Utf8, .Lone_Surrogate, .Ragged, .Bare_Quote}},
	{{"a\xff\n", .Bad_Char, 1}, false, false, {.Lone_Surrogate}},
	{{"a\t\"b\n1\n", TOO_FEW, 6}, true, false, {.Bare_Quote}},
}

// Texts with `#` comment lines. `.Invalid_Utf8` is for cells, so an ill-formed sequence in a comment line is still a
// fault.
@(rodata)
COMMENTED := []Tolerated {
	{{"a,b\n# ok\n1,\xff\n", nil, 0}, false, false, {.Invalid_Utf8}},
	{{"a,b\n# x\xffy\n1,2\n", .Bad_Char, 7}, false, false, {.Invalid_Utf8}},
	{{"a,\xff\n# \xff\n", .Bad_Char, 6}, false, false, {.Invalid_Utf8}},
	{{"a\n#\xf0\x9f\x98\n", .Bad_Char, 3}, false, false, {.Invalid_Utf8}},
	{{"a,b\n1,2\n# x\xe2\x82", .Truncated, 13}, false, false, {.Invalid_Utf8}},
	{{"a\tb\n# \xc3(\n", .Bad_Char, 6}, true, false, {.Invalid_Utf8}},
	{{"a\"b,c\n#x\n1,2\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"a,b\nx\"y,1\n#c\n2,3\n", nil, 0}, false, false, {.Bare_Quote}},
	// A tolerated bare quote opens no quoted field, so the line after it still starts a comment.
	{{"y\"\n#,\"\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"a,b\n1,x\"\n#\"\n2,3\n", nil, 0}, false, false, {.Bare_Quote}},
}

// Each tolerance, through `validate` and `walk`, after 0 to 129 empty lines so what it accepts falls on every byte of
// a block. A text the set accepts is clean with it and faulty without it, a text it does not accept keeps the kind and
// offset it has without the set, and both return the same fault.
@(test)
tolerances :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	for k in 0 ..< 130 {
		for commented in ([]bool{false, true}) {
			comment := u8('#') if commented else 0
			for c in (COMMENTED if commented else TOLERATED) {
				clear(&buf)
				for _ in 0 ..< k {
					append(&buf, '\n')
				}
				append(&buf, c.text)
				opts := dsv.Options{no_header = c.no_header, comment = comment, tolerate = c.tol}
				strict, got, fault: Maybe(core.Fault)
				hi: u64
				if c.tsv {
					strict = walktest.fault_of(dsv.validate(buf[:], .Tsv, {no_header = c.no_header, comment = comment}))
					got = walktest.fault_of(dsv.validate(buf[:], .Tsv, opts))
					hi, fault = dsv.walk(buf[:], 0, .Tsv, opts, &struct {}{}, &core.Hook_Regs{}, walktest.regs_hook)
				} else {
					strict = walktest.fault_of(dsv.validate(buf[:], .Csv, {no_header = c.no_header, comment = comment}))
					got = walktest.fault_of(dsv.validate(buf[:], .Csv, opts))
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
}

// A ragged record's missing columns make no tokens, and a bare quote is a byte of its cell, so the cell is not quoted.
@(test)
tolerated_tokens :: proc(t: ^testing.T) {
	log := new(walktest.Log)
	defer free(log)
	Tokens :: struct {
		text:   string,
		tol:    bit_set[core.Tolerance; u8],
		tokens: []core.Token,
	}
	for c in ([]Tokens {
		{"a,b,c\n1,2\n", {.Ragged}, {{0, 0, .Array, .Value, 0}, {6, 0, .Object, .Value, 0}, {0, 1, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}, {2, 1, .Plain, .Key, 0}, {8, 1, .Plain, .Value, 0}, {9, 1, .End, .Value, 0}, {10, 0, .End, .Value, 0}}},
		{"a,b\n1,2,3\n", {.Ragged}, {{0, 0, .Array, .Value, 0}, {4, 0, .Object, .Value, 0}, {0, 1, .Plain, .Key, 0}, {4, 1, .Plain, .Value, 0}, {2, 1, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}, {0, 3, .Plain, .Key, core.SPELLING_DECODE | 16}, {8, 1, .Plain, .Value, 0}, {9, 1, .End, .Value, 0}, {10, 0, .End, .Value, 0}}},
		{"a\"b,c\n1,\"2\"", {.Bare_Quote}, {{0, 0, .Array, .Value, 0}, {6, 0, .Object, .Value, 0}, {0, 3, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}, {4, 1, .Plain, .Key, 0}, {8, 3, .Plain, .Value, core.SPELLING_DECODE | core.SPELLING_QUOTED}, {11, 0, .End, .Value, 0}, {11, 0, .End, .Value, 0}}},
	}) {
		log^ = {}
		hi, fault := dsv.walk(transmute([]u8)c.text, 0, .Csv, {tolerate = c.tol}, log, &core.Hook_Regs{}, walktest.log_hook)
		testing.expectf(t, fault == nil && hi == u64(len(c.text)), "%q: %d %v", c.text, hi, fault)
		testing.expectf(t, slice.equal(log.tokens[:log.n], c.tokens), "%q: %v", c.text, log.tokens[:log.n])
	}
}
