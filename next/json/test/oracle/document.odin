// Compares the document with the current tree's `.Dom` document: every value read back, kinds, strings, numbers,
// member order, and accept or refuse. `make test-oracle` builds this package from a copy of next/.
package json_oracle

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:math/rand"
import "core:testing"
import cur "stury:json"
import core "../../../core"
import walktest "../../../walktest"
import json "../.."
import gen "../gen"

@(test)
documents_agree :: proc(t: ^testing.T) {
	state := rand.create(SEED + 7)
	context.random_generator = rand.default_random_generator(&state)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	compared := 0
	suites: [dynamic][]runtime.Load_Directory_File
	defer delete(suites)
	append(&suites, #load_directory("../conformance/JSONTestSuite/test_parsing"))
	for suite in walktest.JSON5_TESTS {
		append(&suites, suite)
	}
	for suite in suites {
		for file in suite {
			compared += 1
			if !check_all(t, file.data, .Last) || !check_all(t, file.data, .Refuse) {
				return
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
		for src in ([][]u8{text[:], broken[:]}) {
			compared += 2
			if !check_all(t, src, .Last) || !check_all(t, src, .Refuse) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("seed %d: %d documents compared", SEED, compared)
}

// JSON5's `.Refuse` is left out: the current tree does not read an unquoted key as a duplicate and this tree decodes
// every key. The two `Duplicates` enums name the same readings in a different order.
old_dups :: proc(d: core.Duplicates) -> cur.Duplicates {
	switch d {
	case .First:
		return .First
	case .Last:
		return .Last
	case .All:
		return .All
	case .Refuse:
		return .Refuse
	}
	return .Last
}

check_all :: proc(t: ^testing.T, src: []u8, dups: core.Duplicates) -> bool {
	if !check_document(t, src, .Json, dups) || !check_document(t, src, .Jsonc, dups) {
		return false
	}
	return dups == .Refuse || check_document(t, src, .Json5, dups)
}

check_document :: proc(t: ^testing.T, src: []u8, $S: json.Spec, dups: core.Duplicates) -> bool {
	old, old_err := cur.build(src, cur.Read_Opts{dialect = cur.Dialect(S), duplicates = old_dups(dups)})
	defer cur.destroy(&old)
	doc, err := json.build(src, S, {}, dups)
	defer core.destroy(&doc)
	if old_err != nil || err.kind != .None {
		return refuses_agree(t, src, S, old_err, err)
	}
	// Where `comment_parts` finds a control byte or a `//` comment ending at U+2028 or U+2029, the current tree's
	// document may differ, so the case is skipped.
	when S == .Json5 {
		if comment_parts(src) {
			return true
		}
	}
	return compare(t, src, &doc, 0, &old, 0)
}

// Checks that both refuse or both accept. A case the current tree caps on digits or exponent is skipped, and a JSON5
// case is skipped where `json5_parts` gives a part.
refuses_agree :: proc(t: ^testing.T, src: []u8, $S: json.Spec, old: Maybe(cur.Error), new: core.Document_Error) -> bool {
	want, refused := old.?
	bad := new.kind != .None
	if refused && (want.kind == .Limit_Digits || want.kind == .Limit_Scale) {
		return true
	}
	if refused == bad {
		if !refused {
			return true
		}
		if want.kind == .Duplicate_Key && new.kind == .Duplicate_Key {
			return testing.expectf(t, u64(want.offset) == new.at, "%v %q: duplicate at %d, current tree %d", S, src, new.at, want.offset)
		}
		return true
	}
	when S == .Json5 {
		got := new.inner if new.kind == .Walk else core.Fault{}
		if part := json5_parts(src, got, want if refused else {}); part != .None {
			return true
		}
	}
	return testing.expectf(t, false, "%v %q: document %v, current tree %v", S, src, new, old)
}

compare :: proc(t: ^testing.T, src: []u8, ours: ^core.Document, oi: u32, theirs: ^cur.Document, ti: cur.Node) -> bool {
	tk, tok := cur.kind(theirs, ti)
	ok := testing.expectf(t, tok && kind_agrees(core.kind(ours, oi), tk), "%q node %d: kind %v, current tree %v", src, oi, core.kind(ours, oi), tk)
	if !ok {
		return false
	}
	switch core.kind(ours, oi) {
	case .Null, .False, .True:
	case .String:
		buf: [4096]u8
		s, sok := core.text(ours, oi, buf[:])
		w, wok := cur.get_string(theirs, ti)
		ok = testing.expectf(t, sok && wok && s == w, "%q node %d: string %q, current tree %q", src, oi, s, w)
	case .Number:
		n := core.number(ours, oi)
		w, wok := cur.get_number(theirs, ti)
		ok = testing.expectf(t, wok && number_agrees(src, ours, oi, n, w), "%q node %d: number %v, current tree %v", src, oi, n, w)
	case .Array:
		ok = walktest.count_agrees(t, src, oi, core.length(ours, oi), cur.child_count(theirs, ti))
		if ok {
			if !walktest.child_at_agrees(t, src, ours, oi) {
				return false
			}
			oit := core.children(ours, oi)
			tit := cur.members(theirs, ti)
			for {
				ov, ov_ok := core.child_next(&oit)
				tv, tv_ok := cur.children(&tit)
				if !ov_ok || !tv_ok {
					ok = testing.expectf(t, ov_ok == tv_ok, "%q node %d: child counts", src, oi)
					break
				}
				if !compare(t, src, ours, ov, theirs, tv) {
					return false
				}
			}
		}
	case .Map:
		ok = walktest.count_agrees(t, src, oi, core.length(ours, oi), cur.child_count(theirs, ti))
		if ok {
			if !walktest.child_at_agrees(t, src, ours, oi) {
				return false
			}
			oit := core.children(ours, oi)
			tit := cur.members(theirs, ti)
			buf: [4096]u8
			for {
				ov, ov_ok := core.child_next(&oit)
				name, tv, tv_ok := cur.members(&tit)
				if !ov_ok || !tv_ok {
					ok = testing.expectf(t, ov_ok == tv_ok, "%q node %d: member counts", src, oi)
					break
				}
				key, kok := core.text(ours, ov - 1, buf[:])
				if !testing.expectf(t, kok && key == name, "%q node %d: key %q, current tree %q", src, oi, key, name) {
					return false
				}
				if !compare(t, src, ours, ov, theirs, tv) {
					return false
				}
			}
		}
	case .End, .Plain:
		ok = false
	}
	return ok
}

kind_agrees :: proc(a: core.Kind, b: cur.Kind) -> bool {
	switch a {
	case .Null:
		return b == .Null
	case .False:
		return b == .False
	case .True:
		return b == .True
	case .Number:
		return b == .Number
	case .String:
		return b == .String
	case .Array:
		return b == .Array
	case .Map:
		return b == .Object
	case .Plain, .End:
	}
	return false
}

number_agrees :: proc(src: []u8, ours: ^core.Document, i: u32, n: core.Number, w: cur.Number) -> bool {
	if math.is_nan(w.value) {
		return n.kind == .Float && math.is_nan(transmute(f64)n.bits)
	}
	// An `Int` or `Uint` is compared against its span through `strconv`, because a binary64 cannot tell integers above
	// 2^53 apart.
	if n.kind == .Int || n.kind == .Uint {
		s := string(core.span(ours, i))
		if !strings.contains(s, "x") && !strings.contains(s, "X") {
			if s[0] == '+' {
				s = s[1:]
			}
			if n.kind == .Int {
				if v, ok := strconv.parse_i64(s); ok && u64(v) == n.bits {
					return true
				}
			} else if v, ok := strconv.parse_u64(s); ok && v == n.bits {
				return true
			}
		}
	}
	switch n.kind {
	case .Wide:
		return w.exactness == .None
	case .Int:
		v := f64(i64(n.bits))
		if transmute(u64)v == transmute(u64)w.value {
			return true
		}
		// `-0` is `.Int` 0 here, and the current tree keeps its sign in the binary64.
		return n.bits == 0 && w.value == 0 && transmute(u64)w.value == 0x8000_0000_0000_0000
	case .Uint:
		v := f64(n.bits)
		return transmute(u64)v == transmute(u64)w.value
	case .Float:
		return n.bits == transmute(u64)w.value
	}
	return false
}
