package json_tests

import "core:math/rand"
import "core:testing"
import core "../../core"
import json ".."
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
				j += 1
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

// On valid and broken texts, a hook that keeps its state behind `h` and one that keeps it in `Hook_Regs` see the
// same tokens, with Skip and Stop at random, and those are the tokens Skip and Stop leave of the full walk.
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
		clear(&text)
		gen.text(&text, 1 + round % 6)
		src := text[:]
		if round % 2 == 1 {
			gen.mutate(&broken, text[:])
			src = broken[:]
		}
		full^ = {}
		hi, fault := json.walk(src, 0, .Strict, {}, full, &core.Hook_Regs{}, log_hook)
		for tok in full.tokens[:full.n] {
			if !testing.expectf(t, spans(src, tok), "%q: %v", src, tok) {
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
			hi1, fault1 := json.walk(src, 0, .Strict, {}, log, &core.Hook_Regs{}, log_hook)
			regs := core.Hook_Regs{0, 0, rule}
			hi2, fault2 := json.walk(src, 0, .Strict, {}, &struct {}{}, &regs, regs_hook)
			ok := testing.expectf(t, slice_eq(log.tokens[:log.n], want[:]), "%q rule %x: tokens", src, rule)
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

// Whether a token's span holds what its kind says, and its spelling says whether a string holds an escape.
spans :: proc(src: []u8, t: core.Token) -> bool {
	b := src[t.lo:][:t.n]
	switch t.kind {
	case .String:
		escaped := false
		for c in b {
			escaped ||= c == '\\'
		}
		return len(b) >= 2 && b[0] == '"' && b[len(b) - 1] == '"' && t.spelling == u16(escaped)
	case .Number:
		return len(b) > 0 && (b[0] == '-' || b[0] - '0' < 10) && t.spelling == 0
	case .Null:
		return string(b) == "null"
	case .False:
		return string(b) == "false"
	case .True:
		return string(b) == "true"
	case .Array, .Map, .End:
		return string(b) == "[" || string(b) == "{" || string(b) == "]" || string(b) == "}"
	case .Plain:
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
