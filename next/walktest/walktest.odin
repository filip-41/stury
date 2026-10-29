// The harness the walk tests share: a hook that logs every token and keeps a hash of them, the rules that ask for
// Skip and Stop, a mutation of a seeded text, and the json5-tests suites.
package walktest

import "base:runtime"
import "core:math/rand"
import core "../core"

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

// `src` with one random edit: a byte replaced, deleted or inserted, or the text cut short. `sharp` holds the bytes a
// mutation may write.
mutate :: proc(out: ^[dynamic]u8, src: []u8, sharp: string) {
	clear(out)
	append(out, ..src)
	if len(src) == 0 {
		append(out, pick(sharp))
		return
	}
	i := rand.int_max(len(src))
	switch rand.int_max(4) {
	case 0:
		out[i] = pick(sharp)
	case 1:
		ordered_remove(out, i)
	case 2:
		inject_at(out, i, pick(sharp))
	case:
		resize(out, i)
	}
}

// A byte of `s`, at random.
pick :: proc(s: string) -> u8 {
	return s[rand.int_max(len(s))]
}

// The json5-tests suites, once for the walk's conformance test and once for its oracle.
JSON5_TESTS := [?][]runtime.Load_Directory_File {
	#load_directory("../json/test/conformance/json5-tests/arrays"),
	#load_directory("../json/test/conformance/json5-tests/comments"),
	#load_directory("../json/test/conformance/json5-tests/misc"),
	#load_directory("../json/test/conformance/json5-tests/new-lines"),
	#load_directory("../json/test/conformance/json5-tests/numbers"),
	#load_directory("../json/test/conformance/json5-tests/objects"),
	#load_directory("../json/test/conformance/json5-tests/strings"),
	#load_directory("../json/test/conformance/json5-tests/todo"),
}
