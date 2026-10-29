package dsv_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import dsv ".."
import gen "gen"

// The most tokens a test text holds.
MAX_TOKENS :: 1 << 14

// A hook that keeps its state behind `h`, logs every token, and asks for Skip and Stop by `ask`.
Log :: struct {
	tokens: [MAX_TOKENS]core.Token,
	n:      int,
	hash:   u64,
	rule:   u64,
}

log_hook :: proc "contextless" (h: ^Log, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	a := ask(h.rule, u64(h.n), t)
	h.tokens[h.n] = t
	h.n += 1
	h.hash = mix(h.hash, t)
	return s, a
}

// `log_hook` with its state in the walk's registers: `a` the hash, `b` the count, `c` the rule.
regs_hook :: proc "contextless" (h: ^struct {}, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return {mix(s.a, t), s.b + 1, s.c}, ask(s.c, s.b, t)
}

// What the hooks ask on the `i`th token they see: Stop on the token the rule's low half names, Skip on a container or
// a key the rule's high half picks, else Next. Rule 0 asks for nothing.
ask :: proc "contextless" (rule, i: u64, t: core.Token) -> core.Action {
	if rule == 0 {
		return .Next
	}
	if i == rule & 0xffff_ffff {
		return .Stop
	}
	if (t.kind == .Array || t.kind == .Map || t.role == .Key) && ((i + rule >> 32) * 0x9e37_79b9_7f4a_7c15) >> 62 == 0 {
		return .Skip
	}
	return .Next
}

mix :: proc "contextless" (hash: u64, t: core.Token) -> u64 {
	x := hash ~ t.lo ~ u64(t.n) << 32 ~ u64(t.kind) << 48 ~ u64(t.role) << 56 ~ u64(t.spelling) << 60
	return x * 0x100_0000_01b3 + 1
}

// The tokens a walk under `rule` gives, from the tokens of the walk that asked for nothing, and where a Stop ends it.
expect :: proc(all: []core.Token, rule: u64, out: ^[dynamic]core.Token) -> (stop_hi: u64, stopped: bool) {
	clear(out)
	for j := 0; j < len(all); j += 1 {
		t := all[j]
		a := ask(rule, u64(len(out)), t)
		append(out, t)
		switch a {
		case .Stop:
			return t.lo + u64(t.n), true
		case .Skip:
			if t.role == .Key {
				// Past the cell the key names.
				j += 1
			} else if t.kind == .Array || t.kind == .Map {
				// Past the record, or the text, and its `End`.
				depth := 0
				for ; j < len(all); j += 1 {
					#partial switch all[j].kind {
					case .Array, .Map:
						depth += 1
					case .End:
						depth -= 1
					}
					if depth == 0 {
						break
					}
				}
			}
		case .Next:
		}
	}
	return
}

walk :: proc(src: []u8, tsv, no_header: bool, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), lo := u64(0)) -> (u64, Maybe(core.Fault)) {
	if tsv {
		return dsv.walk(src, lo, .Tsv, {no_header = no_header}, h, regs, on)
	}
	return dsv.walk(src, lo, .Csv, {no_header = no_header}, h, regs, on)
}

// On valid and broken texts, with and without a header, a hook that keeps its state behind `h` and one that keeps it
// in `Hook_Regs` see the same tokens, with Skip and Stop at random, and those are the tokens Skip and Stop leave of
// the full walk. The full walk's verdict is `validate`'s.
@(test)
hooks_agree :: proc(t: ^testing.T) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	log := new(Log)
	defer free(log)
	full := new(Log)
	defer free(full)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	want: [dynamic]core.Token
	defer delete(want)
	for round in 0 ..< 4000 {
		tsv := round % 4 >= 2
		no_header := round % 8 >= 4
		gen.text(&text, tsv)
		src := text[:]
		if round % 2 == 1 {
			gen.mutate(&broken, text[:])
			src = broken[:]
		}
		full^ = {}
		hi, fault := walk(src, tsv, no_header, full, &core.Hook_Regs{}, log_hook)
		ok := testing.expectf(t, fault == validate(src, tsv), "%q: walk %v, validate %v", src, fault, validate(src, tsv))
		ok &&= testing.expectf(t, fault != nil || hi == u64(len(src)), "%q: hi %d", src, hi)
		ok &&= round % 2 == 1 || testing.expectf(t, fault == nil, "%q: %v", src, fault)
		if !ok {
			return
		}
		for tok in full.tokens[:full.n] {
			if !testing.expectf(t, spans(src, tok, tsv), "%q: %v", src, tok) {
				return
			}
		}
		for _ in 0 ..< 4 {
			rule := rand.uint64() | 1 << 63
			if full.n > 0 {
				rule = rule &~ 0xffff_ffff | u64(rand.int_max(full.n + 4))
			}
			stop_hi, was_stopped := expect(full.tokens[:full.n], rule, &want)
			log^ = {rule = rule}
			hi1, fault1 := walk(src, tsv, no_header, log, &core.Hook_Regs{}, log_hook)
			regs := core.Hook_Regs{0, 0, rule}
			hi2, fault2 := walk(src, tsv, no_header, &struct {}{}, &regs, regs_hook)
			ok = testing.expectf(t, slice_eq(log.tokens[:log.n], want[:]), "%q rule %x: tokens", src, rule)
			if was_stopped {
				ok &&= testing.expectf(t, hi1 == stop_hi && fault1 == nil, "%q rule %x: stop at %d %v", src, rule, hi1, fault1)
			} else {
				ok &&= testing.expectf(t, hi1 == hi && fault1 == fault, "%q rule %x: %d %v, want %d %v", src, rule, hi1, fault1, hi, fault)
			}
			ok &&= testing.expectf(t, hi2 == hi1 && fault2 == fault1 && regs.a == log.hash && regs.b == u64(log.n), "%q rule %x: regs", src, rule)
			if !ok {
				return
			}
		}
	}
}

Walked :: struct {
	text:   string,
	lo:     u64,
	hi:     u64,
	fault:  Want, // kind 0 for none
	tokens: []core.Token,
}

// A fault as a rodata table writes it: a `core.Fault` holds a pointer, which rodata cannot.
Want :: struct {
	at:     u64,
	kind:   core.Fault_Kind,
	detail: dsv.Detail,
}

// Texts whose tokens are written out: walks from a byte past the first, texts with no record, and a record wider than
// the header, whose cells past the header's make no tokens.
@(rodata)
WALKED := []Walked {
	{"junk\na,b\n1,2\n", 5, 13, {}, {{5, 0, .Array, .Value, 0}, {9, 0, .Map, .Value, 0}, {5, 1, .Plain, .Key, 0}, {9, 1, .Plain, .Value, 0}, {7, 1, .Plain, .Key, 0}, {11, 1, .Plain, .Value, 0}, {12, 1, .End, .Value, 0}, {13, 0, .End, .Value, 0}}},
	{"\xc3\xa9", 1, 1, {1, .Bad_Char, .None}, {{1, 0, .Array, .Value, 0}}},
	{"\xf0\x9f,\x98\x80", 2, 3, {3, .Bad_Char, .None}, {{2, 0, .Array, .Value, 0}}},
	{"\xe6\x97", 1, 1, {1, .Bad_Char, .None}, {{1, 0, .Array, .Value, 0}}},
	{"a,b", 100, 3, {}, {{3, 0, .Array, .Value, 0}, {3, 0, .End, .Value, 0}}},
	{"", 0, 0, {}, {{0, 0, .Array, .Value, 0}, {0, 0, .End, .Value, 0}}},
	{"\r\n\n", 0, 3, {}, {{0, 0, .Array, .Value, 0}, {3, 0, .End, .Value, 0}}},
	{"\xef\xbb\xbf", 0, 3, {}, {{0, 0, .Array, .Value, 0}, {3, 0, .End, .Value, 0}}},
	{"a,b\n1,2,3\n", 0, 7, {7, .Bad_Structure, .Field_Count}, {{0, 0, .Array, .Value, 0}, {4, 0, .Map, .Value, 0}, {0, 1, .Plain, .Key, 0}, {4, 1, .Plain, .Value, 0}, {2, 1, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}}},
	{"a,b\n1,2,3", 0, 7, {7, .Bad_Structure, .Field_Count}, {{0, 0, .Array, .Value, 0}, {4, 0, .Map, .Value, 0}, {0, 1, .Plain, .Key, 0}, {4, 1, .Plain, .Value, 0}, {2, 1, .Plain, .Key, 0}, {6, 1, .Plain, .Value, 0}}},
}

// A cell's span in a generated text.
Span :: struct {
	lo: int,
	n:  int,
}

SPANS_MAX :: 8

// Appends one record's bytes, each cell quoted when `quoted`, and fills `spans`.
append_record :: proc(out: ^[dynamic]u8, cells: []string, sep: u8, quoted: bool, spans: ^[SPANS_MAX]Span) -> (lo: int) {
	lo = len(out)
	for c, i in cells {
		if i > 0 {
			append(out, sep)
		}
		clo := len(out)
		if quoted {
			append(out, '"')
		}
		append(out, c)
		if quoted {
			append(out, '"')
		}
		spans[i] = {clo, len(out) - clo}
	}
	return
}

// The tokens a record makes: its opening, its cells (each naming its column's header cell when `with_header`), and the
// `End` at `end` when `with_end`. A short record that faults makes all but its `End`.
append_record_tokens :: proc(out: ^[dynamic]core.Token, rec_lo: int, spans: [SPANS_MAX]Span, cells: int, header_spans: [SPANS_MAX]Span, with_header, tsv, quoted: bool, end: int, with_end: bool) {
	append(out, core.Token{u64(rec_lo), 0, .Map if with_header else .Array, .Value, 0})
	for i in 0 ..< cells {
		if with_header {
			h := header_spans[i]
			append(out, core.Token{u64(h.lo), u32(h.n), .Plain, .Key, u16(!tsv && quoted)})
		}
		s := spans[i]
		append(out, core.Token{u64(s.lo), u32(s.n), .Plain, .Value, u16(!tsv && quoted)})
	}
	if with_end {
		append(out, core.Token{u64(end), 1, .End, .Value, 0})
	}
}

// A wide record makes its `Map` and first `width` cells, then faults at the delimiter that opens the next cell. A short
// one makes its `Map` and all its cells, then faults at its line end. Neither makes its `End`. The paddings move the
// record over every byte of a block and across the boundary between two.
@(test)
wrong_width_records :: proc(t: ^testing.T) {
	log := new(Log)
	defer free(log)
	text: [dynamic]u8
	defer delete(text)
	want: [dynamic]core.Token
	defer delete(want)
	HEADER := []string{"h0", "h1", "h2"}
	FIRST := []string{"a0", "a1", "a2"}
	VALID := []string{"v0", "v1", "v2"}
	WIDE_ONE := []string{"w0", "w1", "w2", "w3"}
	WIDE_TWO := []string{"w0", "w1", "w2", "w3", "w4"}
	SHORT := []string{"s0", "s1"}
	for tsv in ([]bool{false, true}) {
		sep := u8('\t') if tsv else ','
		for header in ([]bool{false, true}) {
			for quoted in ([]bool{false, true}) {
				for bad in ([][]string{WIDE_ONE, WIDE_TWO, SHORT}) {
					for final_lf in ([]bool{false, true}) {
						for k in 0 ..< 130 {
							clear(&text)
							clear(&want)
							for _ in 0 ..< k {
								append(&text, '\n')
							}
							append(&want, core.Token{0, 0, .Array, .Value, 0})
							header_spans: [SPANS_MAX]Span
							spans: [SPANS_MAX]Span
							if header {
								append_record(&text, HEADER, sep, quoted, &header_spans)
								append(&text, '\n')
							} else {
								lo := append_record(&text, FIRST, sep, quoted, &spans)
								append_record_tokens(&want, lo, spans, len(FIRST), header_spans, false, tsv, quoted, len(text), true)
								append(&text, '\n')
							}
							lo := append_record(&text, VALID, sep, quoted, &spans)
							append_record_tokens(&want, lo, spans, len(VALID), header_spans, header, tsv, quoted, len(text), true)
							append(&text, '\n')
							bad_lo := append_record(&text, bad, sep, quoted, &spans)
							bad_cells := min(len(bad), len(HEADER))
							append_record_tokens(&want, bad_lo, spans, bad_cells, header_spans, header, tsv, quoted, len(text), false)
							fault_at := len(text)
							if len(bad) > len(HEADER) {
								// The delimiter after the last kept cell opens the cell past the width.
								fault_at = spans[len(HEADER) - 1].lo + spans[len(HEADER) - 1].n
							}
							if final_lf {
								append(&text, '\n')
							}
							log^ = {}
							hi, fault := walk(text[:], tsv, !header, log, &core.Hook_Regs{}, log_hook)
							want_fault := core.Fault{u64(fault_at), &dsv.RULES, .Bad_Structure, u8(dsv.Detail.Field_Count)}
							if !testing.expectf(t, hi == u64(fault_at) && fault == want_fault, "%q tsv %v header %v quoted %v lf %v: %d %v, want %d %v", text[:], tsv, header, quoted, final_lf, hi, fault, fault_at, want_fault) {
								return
							}
							if !testing.expectf(t, slice_eq(log.tokens[:log.n], want[:]), "%q tsv %v header %v quoted %v lf %v: %v", text[:], tsv, header, quoted, final_lf, log.tokens[:log.n]) {
								return
							}
						}
					}
				}
			}
		}
	}
}

@(test)
walked_tokens :: proc(t: ^testing.T) {
	log := new(Log)
	defer free(log)
	for c in WALKED {
		log^ = {}
		hi, fault := walk(transmute([]u8)c.text, false, false, log, &core.Hook_Regs{}, log_hook, c.lo)
		want: Maybe(core.Fault)
		if c.fault.kind != nil {
			want = core.Fault{c.fault.at, &dsv.RULES, c.fault.kind, u8(c.fault.detail)}
		}
		testing.expectf(t, hi == c.hi && fault == want, "%q from %d: %d %v, want %d %v", c.text, c.lo, hi, fault, c.hi, want)
		testing.expectf(t, slice_eq(log.tokens[:log.n], c.tokens), "%q from %d: %v", c.text, c.lo, log.tokens[:log.n])
	}
}

// Every value of `Detail` has a rule, named under the format's own name.
@(test)
detail_rules :: proc(t: ^testing.T) {
	testing.expect_value(t, len(dsv.RULES.details), len(dsv.Detail))
	b := strings.builder_make(context.temp_allocator)
	f := core.Fault{4, &dsv.RULES, .Bad_Structure, u8(dsv.Detail.Field_Count)}
	core.write_code(strings.to_writer(&b), f)
	testing.expect_value(t, strings.to_string(b), "dsv.field_count")
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), transmute([]u8)string("a,b\n1,2,3\n"), f)
	testing.expect_value(t, strings.to_string(b), "2:1: Record has the wrong number of fields")
	f = {1, &dsv.RULES, .Bad_Char, u8(dsv.Detail.Bare_Quote)}
	strings.builder_reset(&b)
	core.write_code(strings.to_writer(&b), f)
	testing.expect_value(t, strings.to_string(b), "dsv.bare_quote")
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), transmute([]u8)string("a\"b\n"), f)
	testing.expect_value(t, strings.to_string(b), "1:2: Quote in an unquoted cell")
}

// Whether a token's span holds what its kind says: a cell holds no line end outside quotes and is quoted where its
// spelling says, a record's `End` is its line end, and an opening token and the text's `End` are empty.
spans :: proc(src: []u8, t: core.Token, tsv: bool) -> bool {
	b := src[t.lo:][:t.n]
	switch t.kind {
	case .Plain:
		quoted := !tsv && len(b) > 0 && b[0] == '"'
		if t.spelling != u16(quoted) {
			return false
		}
		if !quoted {
			for c in b {
				if c == '\n' || c == '\r' || c == ('\t' if tsv else ',') {
					return false
				}
			}
		}
		return true
	case .Array, .Map:
		return t.n == 0 && t.role == .Value
	case .End:
		return string(b) == "" || string(b) == "\n" || string(b) == "\r\n"
	case .Null, .False, .True, .Number, .String:
	}
	return false
}

slice_eq :: proc(a, b: []core.Token) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}
