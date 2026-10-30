// Compares `json.validate` with the current tree's `json.validate`, each spec against the dialect of its name, on
// seeded texts, mutations, JSONTestSuite and json5-tests. `json5_parts` names the cases where the two part on JSON5 by
// design. `make test-oracle` builds this package from a copy of next/ with its packages renamed, because both trees
// have packages named `core` and `json`.
package json_oracle

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:testing"
import cur "stury:json"
import core "../../../core"
import walktest "../../../walktest"
import json "../.."
import gen "../gen"

SEED :: #config(SEED, 1)
ROUNDS :: #config(ROUNDS, 100_000)

@(test)
agrees_with_current_tree :: proc(t: ^testing.T) {
	state := rand.create(SEED)
	context.random_generator = rand.default_random_generator(&state)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	tally: Tally
	check :: proc(t: ^testing.T, src: []u8, $S: json.Spec, tally: ^Tally) -> bool {
		want, refused := cur.validate(src, {dialect = cur.Dialect(S)}).?
		got, bad := json.validate(src, S).?
		// The current tree's digit and exponent caps are not the walk's, so a case it caps is skipped.
		if refused && (want.kind == .Limit_Digits || want.kind == .Limit_Scale) {
			tally.capped += 1
			return true
		}
		tally.compared += 1
		same := refused == bad && (!bad || fmt.tprint(want.kind) == fmt.tprint(got.kind) && want.offset == got.at && detail_agrees(want, got))
		when S == .Json5 {
			if !same {
				if part := json5_parts(src, got if bad else {}, want if refused else {}); part != .None {
					tally.parted[part] += 1
					return true
				}
			}
		}
		return testing.expectf(t, same, "%v %q: %v, current tree %v", S, src, got, want)
	}
	check_all :: proc(t: ^testing.T, src: []u8, tally: ^Tally) -> bool {
		return check(t, src, .Json, tally) && check(t, src, .Jsonc, tally) && check(t, src, .Json5, tally)
	}
	suites: [dynamic][]runtime.Load_Directory_File
	defer delete(suites)
	append(&suites, #load_directory("../conformance/JSONTestSuite/test_parsing"))
	for suite in walktest.JSON5_TESTS {
		append(&suites, suite)
	}
	for suite in suites {
		for file in suite {
			if !check_all(t, file.data, &tally) {
				return
			}
			for _ in 0 ..< 20 {
				walktest.mutate(&broken, file.data, gen.SHARP)
				if !check_all(t, broken[:], &tally) {
					return
				}
			}
		}
	}
	for round in 0 ..< ROUNDS {
		clear(&text)
		spec := json.Spec(round % len(json.Spec))
		if round % 4 == 3 {
			gen.pretty(&text, 1 + round % 6, spec)
		} else {
			gen.text(&text, 1 + round % 6, spec)
		}
		walktest.mutate(&broken, text[:], gen.SHARP)
		if !check_all(t, text[:], &tally) || !check_all(t, broken[:], &tally) {
			return
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("seed %d: %d compared, %d skipped for digit caps, JSON5 parted by design %v", SEED, tally.compared, tally.capped, tally.parted)
}

// The current tree has no `Bad_Char` detail: its `detail` is 0 where the walk says `Identifier` or `Colon`.
detail_agrees :: proc(want: cur.Error, got: core.Fault) -> bool {
	if want.detail == got.detail {
		return true
	}
	return want.detail == 0 && got.kind == .Bad_Char && (got.detail == u8(json.Detail.Identifier) || got.detail == u8(json.Detail.Colon))
}

Tally :: struct {
	compared, capped: int,
	parted:           [Part]int,
}

// `Part` names why the walk and the current tree part on a JSON5 text. The walk follows JSON5 1.0.0 and its own
// JSON rules.
Part :: enum {
	None,
	Comment, // a comment holds a control byte, or a `//` comment ends at U+2028 or U+2029: the current tree differs
	Escape, // a bad escape is refused at the byte that breaks it, the current tree at its backslash
	Key, // an unquoted key the text cuts short is `Truncated`, and a byte that starts no key has `Detail.Identifier`
	Word, // `Infinity` or `NaN` broken is `Bad_Number` at the byte that breaks it, the current tree at a bad literal
}

// Returns the `Part` that explains the walk's fault `got` against the current tree's `want`, or `.None`.
json5_parts :: proc(src: []u8, got: core.Fault, want: cur.Error) -> Part {
	if comment_parts(src) {
		return .Comment
	}
	// In a surrogate pair the byte that breaks the escape is at most 11 past its backslash.
	if want.kind == .Bad_Escape && src[want.offset] == '\\' && got.at > want.offset && got.at - want.offset <= 11 && got.kind != .None {
		return .Escape
	}
	if got.kind == .Truncated && got.at == u64(len(src)) && got.at - want.offset < 4 && want.kind == .Bad_Char && src[want.offset] >= 0x80 {
		return .Key
	}
	if got.kind == .Bad_Char && want.kind == .Bad_Char && got.at == want.offset && got.detail == u8(json.Detail.Identifier) && want.detail == 0 {
		return .Key
	}
	if got.kind == .Bad_Number && want.kind == .Bad_Char && want.detail == u8(json.Detail.Literal) && (src[want.offset] == 'I' || src[want.offset] == 'N') {
		return .Word
	}
	return .None
}

// Returns true if a comment holds a control byte other than tab, LF or CR, or a `//` comment ends at U+2028 or
// U+2029. Strings are passed over.
comment_parts :: proc(src: []u8) -> bool {
	quote: u8
	for i := 0; i < len(src); i += 1 {
		c := src[i]
		switch {
		case quote != 0:
			if c == '\\' {
				i += 1
			} else if c == quote {
				quote = 0
			}
		case c == '"' || c == '\'':
			quote = c
		case c == '/' && i + 1 < len(src) && (src[i + 1] == '/' || src[i + 1] == '*'):
			block := src[i + 1] == '*'
			i += 2
			for ; i < len(src); i += 1 {
				b := src[i]
				if block && b == '*' && i + 1 < len(src) && src[i + 1] == '/' {
					i += 1
					break
				}
				if !block && (b == '\n' || b == '\r') {
					break
				}
				if !block && b == 0xe2 && i + 2 < len(src) && src[i + 1] == 0x80 && src[i + 2] | 1 == 0xa9 {
					return true
				}
				if b < 0x20 && b != '\t' && b != '\n' && b != '\r' {
					return true
				}
			}
		}
	}
	return false
}
