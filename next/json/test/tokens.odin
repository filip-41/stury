package json_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import json ".."
import gen "gen"

// The tokens a walk under `rule` gives, from the tokens of the walk that asked for nothing, and where a Stop ends it.
expect :: proc(all: []core.Token, rule: u64, out: ^[dynamic]core.Token) -> (stop_hi: u64, stopped: bool) {
	clear(out)
	for j := 0; j < len(all); j += 1 {
		t := all[j]
		a := walktest.ask(rule, u64(len(out)), t)
		append(out, t)
		switch a {
		case .Stop:
			return t.lo + u64(t.n), true
		case .Skip:
			// A key's Skip passes the comments up to its member's value, and the value.
			if t.role == .Key {
				j += 1
				for j < len(all) && all[j].role > .Key {
					j += 1
				}
			}
			// Past the container, or the scalar after a key, that the walk skips.
			if j < len(all) && (all[j].kind == .Array || all[j].kind == .Map) {
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

// On valid and broken texts of each spec, a hook that keeps its state behind `h` and one that keeps it in `Hook_Regs`
// see the same tokens, with Skip and Stop at random, and those are the tokens Skip and Stop leave of the full walk.
@(test)
hooks_agree :: proc(t: ^testing.T) {
	_ = hooks_agree_in(t, .Json) && hooks_agree_in(t, .Jsonc) && hooks_agree_in(t, .Json5)
}

hooks_agree_in :: proc(t: ^testing.T, $S: json.Spec) -> bool {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	log := new(walktest.Log)
	defer free(log)
	full := new(walktest.Log)
	defer free(full)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	want: [dynamic]core.Token
	defer delete(want)
	for round in 0 ..< 4000 {
		clear(&text)
		if round % 3 == 2 {
			gen.pretty(&text, 1 + round % 6, S)
		} else {
			gen.text(&text, 1 + round % 6, S)
		}
		src := text[:]
		if round % 2 == 1 {
			walktest.mutate(&broken, text[:], gen.SHARP)
			src = broken[:]
		}
		full^ = {}
		hi, fault := json.walk(src, 0, S, {}, full, &core.Hook_Regs{}, walktest.log_hook)
		if round % 2 == 0 && !testing.expectf(t, fault == nil, "%q: %v", src, fault) {
			return false
		}
		for tok in full.tokens[:full.n] {
			if !testing.expectf(t, spans(src, tok), "%q: %v", src, tok) {
				return false
			}
		}
		for _ in 0 ..< 4 {
			rule := rand.uint64() | 1 << 63
			if full.n > 0 {
				rule = rule &~ 0xffff_ffff | u64(rand.int_max(full.n + 4))
			}
			stop_hi, was_stopped := expect(full.tokens[:full.n], rule, &want)
			log^ = {rule = rule}
			hi1, fault1 := json.walk(src, 0, S, {}, log, &core.Hook_Regs{}, walktest.log_hook)
			regs := core.Hook_Regs{0, 0, rule}
			hi2, fault2 := json.walk(src, 0, S, {}, &struct {}{}, &regs, walktest.regs_hook)
			ok := testing.expectf(t, slice_eq(log.tokens[:log.n], want[:]), "%q rule %x: tokens", src, rule)
			if was_stopped {
				ok &&= testing.expectf(t, hi1 == stop_hi && fault1 == nil, "%q rule %x: stop at %d %v", src, rule, hi1, fault1)
			} else {
				ok &&= testing.expectf(t, hi1 == hi && fault1 == fault, "%q rule %x: %d %v, want %d %v", src, rule, hi1, fault1, hi, fault)
			}
			ok &&= testing.expectf(t, hi2 == hi1 && fault2 == fault1 && regs.a == log.hash && regs.b == u64(log.n), "%q rule %x: regs", src, rule)
			if !ok {
				return false
			}
		}
	}
	return true
}

// A walk from the text's first byte passes over one leading BOM, as `validate` does, and one from any other byte
// reads a BOM as the bad byte it is there.
@(test)
bom_at_the_start :: proc(t: ^testing.T) {
	log := new(walktest.Log)
	defer free(log)
	hi, fault := json.walk(transmute([]u8)string("\xef\xbb\xbf [1]"), 0, .Json, {}, log, &core.Hook_Regs{}, walktest.log_hook)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, hi, 7)
	testing.expect_value(t, log.tokens[0], core.Token{4, 1, .Array, .Value, 0})
	_, fault = json.walk(transmute([]u8)string(" \xef\xbb\xbf[1]"), 0, .Json, {}, log, &core.Hook_Regs{}, walktest.log_hook)
	testing.expect_value(t, fault, core.Fault{1, &json.RULES, .Bad_Char, 0})
}

// A walk reads one document. A stream is a loop of walks, each from where the last one ended, passing over
// whitespace and the record separator 0x1E before each document. Nothing but those left is no document and no fault,
// and `validate` holds a text to one document with nothing before it.
@(test)
documents_one_walk_each :: proc(t: ^testing.T) {
	log := new(walktest.Log)
	defer free(log)
	src := transmute([]u8)string("1 2[3]{}\n\x1e\"s\"\n\x1e true \x1e\n ")
	ends := [?]u64{1, 3, 6, 8, 13, 20, u64(len(src))}
	lo: u64
	for want, i in ends {
		log^ = {}
		hi, fault := json.walk(src, lo, .Json, {}, log, &core.Hook_Regs{}, walktest.log_hook)
		testing.expectf(t, hi == want && fault == nil, "document %d from %d: %d %v, want %d", i, lo, hi, fault, want)
		testing.expectf(t, (log.n == 0) == (i == len(ends) - 1), "document %d: %d tokens", i, log.n)
		lo = hi
	}
	hi, fault := json.walk(src, 1000, .Json, {}, log, &core.Hook_Regs{}, walktest.log_hook)
	testing.expectf(t, hi == u64(len(src)) && fault == nil, "past the end: %d %v", hi, fault)
	for empty in ([]string{"", "   ", "\x1e \x1e ", "\xef\xbb\xbf", "\xef\xbb\xbf \x1e"}) {
		log^ = {}
		hi, fault = json.walk(transmute([]u8)empty, 0, .Json, {}, log, &core.Hook_Regs{}, walktest.log_hook)
		testing.expectf(t, hi == u64(len(empty)) && fault == nil && log.n == 0, "%q: %d %v, %d tokens", empty, hi, fault, log.n)
	}
	_, fault = json.walk(transmute([]u8)string(" \x1e x"), 0, .Json, {}, log, &core.Hook_Regs{}, walktest.log_hook)
	testing.expect_value(t, fault, core.Fault{3, &json.RULES, .Bad_Char, 0})
	testing.expect_value(t, json.validate(transmute([]u8)string("\x1e1"), .Json), core.Fault{0, &json.RULES, .Bad_Char, 0})
	testing.expect_value(t, json.validate(transmute([]u8)string("1 2"), .Json), core.Fault{2, &json.RULES, .Trailing, 0})
	testing.expect_value(t, json.validate(transmute([]u8)string(" \n"), .Json), core.Fault{2, &json.RULES, .Truncated, 0})
}

// Whether a token's span holds what its kind says, and its spelling says whether a string holds an escape.
spans :: proc(src: []u8, t: core.Token) -> bool {
	b := src[t.lo:][:t.n]
	switch t.kind {
	case .String:
		escaped := false
		for c in b {
			escaped ||= c == '\\'
		}
		// A JSON5 key may go unquoted.
		quoted := len(b) >= 2 && (b[0] == '"' || b[0] == '\'') && b[len(b) - 1] == b[0]
		return (quoted || t.role == .Key && len(b) > 0) && t.spelling == u16(escaped)
	case .Number:
		spelling := json.Number_Spelling.Json
		for c in b {
			switch c {
			case 'x', 'X':
				spelling = .Hex
			case 'I':
				spelling = .Infinity
			case 'N':
				spelling = .Nan
			}
		}
		// JSON's grammar starts with `-` or a digit, and has a digit on both sides of a `.`.
		if spelling == .Json && (b[0] == '+' || b[0] == '.' || b[len(b) - 1] == '.' || strings.contains(string(b), ".e") || strings.contains(string(b), ".E") || strings.contains(string(b), "-.")) {
			spelling = .Decimal
		}
		return len(b) > 0 && t.spelling == u16(spelling)
	case .Null:
		return string(b) == "null"
	case .False:
		return string(b) == "false"
	case .True:
		return string(b) == "true"
	case .Array, .Map, .End:
		return string(b) == "[" || string(b) == "{" || string(b) == "]" || string(b) == "}"
	case .Plain:
		block := len(b) >= 4 && string(b[:2]) == "/*" && string(b[len(b) - 2:]) == "*/"
		line := len(b) >= 2 && string(b[:2]) == "//" && b[len(b) - 1] != '\n' && b[len(b) - 1] != '\r' && !strings.has_suffix(string(b), "\u2028") && !strings.has_suffix(string(b), "\u2029")
		return t.role > .Key && (block || line) && t.spelling == u16(block)
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

// Each comment of a JSONC text gets its role by `core.Role`'s rule, and a `/* */` comment its spelling.
@(test)
comment_roles :: proc(t: ^testing.T) {
	src := "/* a */ {\n  \"k\" /* b */ : /* c */ 1, // d\n  // e\n  \"l\": [ /* f */ ], // g\n  \"n\": {\"x\": 1, \"y\": 2, // o\n    \"z\": 3},\n  \"m\": [1, /* h */ 2 /* i */ , ] /* j\n  */ /* p */\n  // k\n} // l\n// m\n"
	Want :: struct {
		text: string,
		role: core.Role,
	}
	want := []Want{{"/* a */", .Comment}, {"/* b */", .Comment}, {"/* c */", .Comment}, {"// d", .Comment_Inline}, {"// e", .Comment}, {"/* f */", .Comment_Foot}, {"// g", .Comment_Inline}, {"// o", .Comment_Inline}, {"/* h */", .Comment_Inline}, {"/* i */", .Comment_Inline}, {"/* j\n  */", .Comment_Inline}, {"/* p */", .Comment_Foot}, {"// k", .Comment_Foot}, {"// l", .Comment_Inline}, {"// m", .Comment_Foot}}
	log := new(walktest.Log)
	defer free(log)
	hi, fault := json.walk(transmute([]u8)src, 0, .Jsonc, {}, log, &core.Hook_Regs{}, walktest.log_hook)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, hi, u64(len(src) - 1))
	i := 0
	for tok in log.tokens[:log.n] {
		if tok.role <= .Key {
			continue
		}
		if !testing.expectf(t, i < len(want), "extra comment %v", tok) {
			return
		}
		text := src[tok.lo:][:tok.n]
		testing.expectf(t, text == want[i].text && tok.role == want[i].role && tok.kind == .Plain && tok.spelling == u16(text[1] == '*'), "comment %d: %q %v, want %q %v", i, text, tok.role, want[i].text, want[i].role)
		i += 1
	}
	testing.expect_value(t, i, len(want))
}

// After a document's root, comments past its line are its foot only where the text ends or a 0x1E follows them, else
// the next document's, read by the next walk. Comments with no document after them belong to none.
@(test)
comments_between_documents :: proc(t: ^testing.T) {
	log := new(walktest.Log)
	defer free(log)
	src := transmute([]u8)string("1 // a\n/* b */ 2 /* c */\n// d\n\x1e3\n// e")
	Want :: struct {
		hi:    u64,
		roles: []core.Role,
	}
	want := []Want{{6, {.Value, .Comment_Inline}}, {29, {.Comment, .Value, .Comment_Inline, .Comment_Foot}}, {u64(len(src)), {.Value, .Comment_Foot}}}
	lo: u64
	for w, i in want {
		log^ = {}
		hi, fault := json.walk(src, lo, .Jsonc, {}, log, &core.Hook_Regs{}, walktest.log_hook)
		testing.expectf(t, hi == w.hi && fault == nil && log.n == len(w.roles), "document %d: %d %v, %d tokens", i, hi, fault, log.n)
		for r, j in w.roles[:min(len(w.roles), log.n)] {
			testing.expectf(t, log.tokens[j].role == r, "document %d token %d: %v, want %v", i, j, log.tokens[j].role, r)
		}
		lo = hi
	}
	log^ = {}
	alone := " // a\n/* b */ \x1e // c"
	hi, fault := json.walk(transmute([]u8)alone, 0, .Jsonc, {}, log, &core.Hook_Regs{}, walktest.log_hook)
	testing.expectf(t, hi == u64(len(alone)) && fault == nil && log.n == 0, "comments alone: %d %v, %d tokens", hi, fault, log.n)
}

// A key's Skip passes the comments around its colon and the value after them, at the value's depth, and its object
// reads on.
@(test)
skip_past_comments :: proc(t: ^testing.T) {
	skip_keys :: proc "contextless" (h: ^walktest.Log, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		h.tokens[h.n] = t
		h.n += 1
		return s, .Skip if t.role == .Key else .Next
	}
	log := new(walktest.Log)
	defer free(log)
	src := transmute([]u8)string("{\"a\" /* b */ : /* c */ [1, {}], \"d\": /* e */ 2 /* f */}")
	_, fault := json.walk(src, 0, .Jsonc, {}, log, &core.Hook_Regs{}, skip_keys)
	testing.expect_value(t, fault, nil)
	want := []core.Kind{.Map, .String, .String, .Plain, .End}
	testing.expectf(t, log.n == len(want), "%d tokens, want %d", log.n, len(want))
	for k, i in want[:min(len(want), log.n)] {
		testing.expectf(t, log.tokens[i].kind == k, "token %d: %v, want %v", i, log.tokens[i].kind, k)
	}
	// The skipped value keeps its depth.
	deep := transmute([]u8)string("{\"a\": /* c */ [[1]]}")
	_, fault = json.walk(deep, 0, .Jsonc, {max_depth = 2}, log, &core.Hook_Regs{}, skip_keys)
	testing.expect_value(t, fault, json.validate(deep, .Jsonc, {max_depth = 2}))
	testing.expect_value(t, fault, core.Fault{15, &json.RULES, .Too_Deep, 0})
}
