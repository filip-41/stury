package dsv_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:testkit"

Case :: struct {
	text:   string,
	kind:   tape.Fault_Kind, // `.None` for a valid text
	offset: u64,
}

// The kinds a case names for `Bad_Width` with too many and too few cells, a record wider or narrower than the first.
TOO_MANY :: tape.Fault_Kind(0xff)
TOO_FEW :: tape.Fault_Kind(0xfe)

// The rules of `dsv`, which name the details below by their index.
DETAIL_TOO_MANY :: 1
DETAIL_TOO_FEW :: 2
DETAIL_BARE_QUOTE :: 3
DETAIL_INVALID_UTF8 :: 4
DETAIL_LONE_CR :: 5
DETAIL_AFTER_QUOTE :: 6
DETAIL_OPEN_QUOTE :: 7
DETAIL_CUT_UTF8 :: 8

// CSV texts and the fault each raises, at the byte the fault's rule names.
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

// TSV texts and the fault each raises, at the byte the fault's rule names.
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

// The fault `c` names, shifted by `shift` bytes, with the detail its byte names.
want_fault :: proc(c: Case, shift: int, tsv: bool) -> tape.Error {
	if c.kind == nil {
		return nil
	}
	kind, detail := c.kind, u8(0)
	if kind == TOO_MANY || kind == TOO_FEW {
		kind, detail = .Bad_Width, DETAIL_TOO_MANY if c.kind == TOO_MANY else DETAIL_TOO_FEW
	} else if kind != .Bad_Escape {
		// The rule within the kind follows the byte the fault names.
		at := c.text[c.offset] if c.offset < u64(len(c.text)) else 0
		switch {
		case kind == .Truncated:
			detail = DETAIL_OPEN_QUOTE if at == '"' else DETAIL_CUT_UTF8
		case at == '"' && !tsv:
			detail = DETAIL_BARE_QUOTE
		case at == '\r':
			detail = DETAIL_LONE_CR
		case at >= 0x80:
			detail = DETAIL_INVALID_UTF8
		case !tsv:
			detail = DETAIL_AFTER_QUOTE
		}
	}
	return tape.Fault{c.offset + u64(shift), fault_rules(), kind, detail}
}

// The rules a dsv fault points to, read from one.
fault_rules :: proc() -> ^tape.Rules {
	err := dsv.validate(transmute([]u8)string("\"a"), .Csv)
	return err.(tape.Fault).rules
}

spec_of :: proc(tsv: bool) -> dsv.Spec {
	return .Tsv if tsv else .Csv
}

// Every read that checks the whole text gives the case's fault, after `shift` empty lines.
expect_reads :: proc(t: ^testing.T, c: Case, src: []u8, shift: int, tsv: bool, opts := dsv.Options{}, loc := #caller_location) -> bool {
	want := want_fault(c, shift, tsv)
	spec := spec_of(tsv)
	got := dsv.validate(src, spec, opts)
	ok := testing.expectf(t, got == want, "validate %q shifted %d: %v, want %v", c.text, shift, got, want, loc = loc)
	doc, berr := dsv.build(src, spec, opts)
	tape.destroy(&doc)
	ok &&= testing.expectf(t, berr == want, "build %q shifted %d: %v, want %v", c.text, shift, berr, want, loc = loc)
	_, ferr := dsv.find(src, []tape.Step{tape.Index(-1)}, spec, {}, opts)
	ok &&= testing.expectf(t, ferr == want, "find %q shifted %d: %v, want %v", c.text, shift, ferr, want, loc = loc)
	return ok
}

@(test)
faults_at_their_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in CSV_CASES {
		expect_reads(t, c, transmute([]u8)c.text, 0, false)
	}
	for c in TSV_CASES {
		expect_reads(t, c, transmute([]u8)c.text, 0, true)
	}
}

// Each case after 0 to 129 empty lines, which are no records. Every quote, CR, escape and UTF-8 sequence of a case
// falls on every byte of a 64-byte block and across the boundary between two, and its fault moves by the same count.
@(test)
faults_at_every_offset :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
				if !expect_reads(t, c, buf[:], k, tsv) {
					return
				}
			}
		}
	}
}

// A backslash at every byte of a block: each of the five escapes is valid there, and a byte no escape spells faults at
// the backslash. A comment line's backslash opens no escape.
@(test)
escapes_at_every_block_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
			err := dsv.validate(b[:], .Tsv)
			if valid < 5 {
				testing.expectf(t, err == nil, "backslash at %d escapes %#x: %v", 2 + k, escape, err)
			} else {
				f, bad := err.(tape.Fault)
				testing.expectf(t, bad && f.kind == .Bad_Escape && f.at == u64(2 + k), "backslash at %d escapes %#x: %v", 2 + k, escape, err)
			}
		}
	}
	comment := "h\n#a\\xb\n1\n"
	err := dsv.validate(transmute([]u8)comment, .Tsv, {format = dsv.Dsv_Options{comment = '#'}})
	testing.expectf(t, err == nil, "backslash in a comment line: %v", err)
}

Tolerated :: struct {
	using c:   Case,
	tsv:       bool,
	no_header: bool,
	tol:       tape.Tolerances,
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
	// A tolerated bare quote opens no quoted cell, so the line after it still starts a comment.
	{{"y\"\n#,\"\n", nil, 0}, false, false, {.Bare_Quote}},
	{{"a,b\n1,x\"\n#\"\n2,3\n", nil, 0}, false, false, {.Bare_Quote}},
}

// Each tolerance after 0 to 129 empty lines, so what it accepts falls on every byte of a block. A text the set accepts
// is clean with it, faulty without it, and its build is flagged `.Tolerated`. A text it does not accept keeps the kind
// and offset it has without the set.
@(test)
tolerances :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
				strict := dsv.Options{format = dsv.Dsv_Options{no_header = c.no_header, comment = comment}}
				opts := strict
				opts.tolerate = c.tol
				if !expect_reads(t, c, buf[:], k, c.tsv, opts) {
					return
				}
				if c.kind == nil {
					testing.expectf(t, dsv.validate(buf[:], spec_of(c.tsv), strict) != nil, "%q: a strict read takes it", c.text)
					doc, _ := dsv.build(buf[:], spec_of(c.tsv), opts)
					testing.expectf(t, .Tolerated in doc.flags, "%q: the build is not flagged tolerated", c.text)
					tape.destroy(&doc)
				}
			}
		}
	}
}

// A hook that records the tokens of a walk.
Log :: struct {
	tokens:   [dynamic]tape.Token,
	protocol: hook.Protocol({}, hook.Unused, hook.Unused, hook.Unused),
}

log_hook :: proc "contextless" (h: ^Log, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	context = runtime.default_context()
	append(&h.tokens, t)
	return s, .Next
}

// The tokens of a walk: a ragged record's missing columns make no tokens and its extra ones are named by position, a
// bare quote is a byte of its cell, a quoted cell's span leaves out its quotes, and an empty unquoted cell is null.
@(test)
walk_tokens :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Tokens :: struct {
		text:   string,
		tol:    tape.Tolerances,
		tokens: []tape.Token,
	}
	COLUMN :: tape.SPELLING_DECODE | 1 << 11
	QUOTED :: tape.SPELLING_QUOTED
	for c in ([]Tokens {
		{"a,b,c\n1,2\n", {.Ragged}, {{0, 0, .Array, .Value, 0}, {6, 0, .Object, .Value, 0}, {0, 1, .String, .Key, 0}, {6, 1, .String, .Value, 0}, {2, 1, .String, .Key, 0}, {8, 1, .String, .Value, 0}, {9, 1, .End, .Value, 0}, {10, 0, .End, .Value, 0}}},
		{"a,b\n1,2,3\n", {.Ragged}, {{0, 0, .Array, .Value, 0}, {4, 0, .Object, .Value, 0}, {0, 1, .String, .Key, 0}, {4, 1, .String, .Value, 0}, {2, 1, .String, .Key, 0}, {6, 1, .String, .Value, 0}, {0, 3, .String, .Key, COLUMN}, {8, 1, .String, .Value, 0}, {9, 1, .End, .Value, 0}, {10, 0, .End, .Value, 0}}},
		{"a\"b,c\n1,\"2\"", {.Bare_Quote}, {{0, 0, .Array, .Value, 0}, {6, 0, .Object, .Value, 0}, {0, 3, .String, .Key, 0}, {6, 1, .String, .Value, 0}, {4, 1, .String, .Key, 0}, {9, 1, .String, .Value, QUOTED}, {11, 0, .End, .Value, 0}, {11, 0, .End, .Value, 0}}},
		{"a,b\n,\"\"\r\n", {}, {{0, 0, .Array, .Value, 0}, {4, 0, .Object, .Value, 0}, {0, 1, .String, .Key, 0}, {4, 0, .Null, .Value, 0}, {2, 1, .String, .Key, 0}, {6, 0, .String, .Value, QUOTED}, {7, 2, .End, .Value, 0}, {9, 0, .End, .Value, 0}}},
	}) {
		log: Log
		defer delete(log.tokens)
		regs: hook.Regs
		at, err, _ := dsv.walk(transmute([]u8)c.text, .Csv, {tolerate = c.tol}, &log, &regs, log_hook)
		testing.expectf(t, err == nil && at == u64(len(c.text)), "%q: %d %v", c.text, at, err)
		testing.expectf(t, len(log.tokens) == len(c.tokens), "%q: %v", c.text, log.tokens[:])
		for tok, i in log.tokens {
			if i < len(c.tokens) && tok != c.tokens[i] {
				testing.expectf(t, false, "%q: token %d is %v, want %v", c.text, i, tok, c.tokens[i])
				break
			}
		}
	}
}

@(private = "file")
walk_of :: proc($S: dsv.Spec, $NO_HEADER: bool) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		o := opts
		o.format = dsv.Dsv_Options{no_header = NO_HEADER, comment = '#'}
		at, err, _ := dsv.walk(src, S, o, h, regs, testkit.probe_hook)
		return at, err
	}
}

// Every action at every token, a room that starts full or grows at every node, a refused stack and a step budget at
// every count of containers.
@(test)
walks_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	texts := []string{"a,b\n1,2\n#c\n\"x\"\"y\",\n", "a,b\r\n1,2", ""}
	testkit.hook_protocol(t, walk_of(.Csv, false), texts)
	testkit.hook_protocol(t, walk_of(.Csv, true), texts)
	testkit.hook_protocol(t, walk_of(.Tsv, false), {"a\tb\n1\t\\t\n"})
	testkit.hook_protocol(t, walk_of(.Plain, false), {"a,b\n1,2\n3,4"})
}

// A builder that stores the keys the walk gives, as `builder_hook` does, gets room for each of them: only the table
// hook, which drops them, goes without. The room starts at one node and the first record is sparse, so its growth is
// no larger than the nodes it must hold.
@(test)
walks_make_room_for_the_keys_a_hook_stores :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for columns in 1 ..= 24 {
		head := strings.builder_make(context.temp_allocator)
		dense := strings.builder_make(context.temp_allocator)
		for c in 0 ..< columns {
			sep := "," if c > 0 else ""
			fmt.sbprintf(&head, "%sh%d", sep, c)
			fmt.sbprintf(&dense, "%s1", sep)
		}
		sparse := strings.repeat("x", 300, context.temp_allocator)
		text := fmt.tprintf("%s\n%s\n%s\n%s\n", strings.to_string(head), sparse, strings.to_string(dense), strings.to_string(dense))
		src := transmute([]u8)text
		frames: [4]u64
		b: build.Builder
		build.builder_start(&b, src, dsv.as(.Csv), 1, 10_000, frames[:], context.allocator)
		regs := build.builder_regs(&b)
		at, werr, _ := dsv.walk(src, .Csv, {tolerate = {.Ragged}}, &b, &regs, build.builder_hook)
		stored := (regs.a - u64(uintptr(raw_data(b.doc.nodes)))) / size_of(tape.Node)
		testing.expectf(t, stored <= u64(len(b.doc.nodes)), "%d columns: %d nodes stored in a room of %d", columns, stored, len(b.doc.nodes))
		doc, err := build.builder_end(&b, regs, at, werr)
		dsv.destroy(&doc)
		testing.expect_value(t, err, nil)
	}
}
