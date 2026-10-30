// The dsv document against the current tree's `csv.build`: every cell's text read back, member order, structure, and
// accept or refuse, on seeded texts and mutations of them. `make test-oracle` builds it from a copy of next/.
package dsv_oracle

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:testing"
import cur "stury:csv"
import core "../../../core"
import dsv "../.."
import gen "../gen"
import walktest "../../../walktest"

@(test)
documents_agree :: proc(t: ^testing.T) {
	state := rand.create(SEED + 11)
	context.random_generator = rand.default_random_generator(&state)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	compared := 0
	for round in 0 ..< ROUNDS {
		tsv := round % 2 == 1
		gen.text(&text, tsv)
		walktest.mutate(&broken, text[:], gen.SHARP)
		for src in ([][]u8{text[:], broken[:]}) {
			for no_header in ([]bool{false, true}) {
				compared += 2
				if !check_document(t, src, tsv, no_header, .Last) || !check_document(t, src, tsv, no_header, .Refuse) {
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("seed %d: %d documents compared", SEED, compared)
}

// The two `Duplicates` enums name the same readings in a different order, and the old tree's `Document` and `Node`
// differ, so each oracle adapts its own tree's type.
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

check_document :: proc(t: ^testing.T, src: []u8, tsv, no_header: bool, dups: core.Duplicates) -> bool {
	old_opts := cur.Read_Opts{no_header = no_header, duplicates = old_dups(dups)}
	if tsv {
		old_opts.dialect = cur.TSV
	}
	old, old_err := cur.build(src, old_opts)
	defer cur.destroy(&old)
	doc: core.Document
	err: core.Document_Error
	if tsv {
		doc, err = dsv.build(src, .Tsv, {no_header = no_header}, dups)
	} else {
		doc, err = dsv.build(src, .Csv, {no_header = no_header}, dups)
	}
	defer core.destroy(&doc)
	if old_err != nil || err.kind != .None {
		return refuses_agree(t, src, tsv, old_err, err)
	}
	return compare(t, src, &doc, 0, &old, 0, !no_header && doc.header != 0)
}

// Whether a TSV header cell begins and ends with the same quote byte, the cell whose text the old tree spells
// differently.
@(private)
quoted_header_cell :: proc(src: []u8) -> bool {
	lo := 0
	for i in 0 ..< len(src) {
		if src[i] == '\t' || src[i] == '\n' || i == len(src) - 1 {
			hi := i if src[i] == '\t' || src[i] == '\n' else i + 1
			if hi > lo && (src[lo] == '"' || src[lo] == '\'') && src[hi - 1] == src[lo] {
				return true
			}
			if src[i] == '\n' {
				return false
			}
			lo = i + 1
		}
	}
	return false
}

refuses_agree :: proc(t: ^testing.T, src: []u8, tsv: bool, old: Maybe(cur.Error), new: core.Document_Error) -> bool {
	want, refused := old.?
	bad := new.kind != .None
	if refused == bad {
		if !refused {
			return true
		}
		if want.kind == .Duplicate_Key && new.kind == .Duplicate_Key {
			// The old tree strips a TSV header cell's quote pair for the key's text but compares raw spans, so two
			// identical quoted cells are no repeat there and the byte it names differs. Both still refuse.
			if tsv && quoted_header_cell(src) {
				return true
			}
			return testing.expectf(t, u64(want.offset) == new.at, "%q: duplicate at %d, current tree %d", src, new.at, want.offset)
		}
		return true
	}
	return testing.expectf(t, false, "%q: document %v, current tree %v", src, new, old)
}

compare :: proc(t: ^testing.T, src: []u8, ours: ^core.Document, oi: u32, theirs: ^cur.Document, ti: cur.Node, headed: bool) -> bool {
	tk, tok := cur.kind(theirs, ti)
	record := headed && oi != core.ROOT && core.kind(ours, oi) == .Array
	ok: bool
	if record {
		// A headed record is our `Array` of cells where the current tree has an object.
		ok = testing.expectf(t, tok && tk == .Object, "%q node %d: kind %v, current tree %v", src, oi, core.kind(ours, oi), tk)
	} else {
		ok = testing.expectf(t, tok && kind_agrees(core.kind(ours, oi), tk), "%q node %d: kind %v, current tree %v", src, oi, core.kind(ours, oi), tk)
	}
	if !ok {
		return false
	}
	if record {
		return compare_members(t, src, ours, oi, theirs, ti, true)
	}
	switch core.kind(ours, oi) {
	case .Array:
		if !walktest.count_agrees(t, src, oi, core.length(ours, oi), cur.child_count(theirs, ti)) {
			return false
		}
		if !walktest.child_at_agrees(t, src, ours, oi) {
			return false
		}
		oit := core.children(ours, oi)
		tit := cur.members(theirs, ti)
		for {
			ov, ov_ok := core.child_next(&oit)
			tv, tv_ok := cur.children(&tit)
			if !ov_ok || !tv_ok {
				return testing.expectf(t, ov_ok == tv_ok, "%q node %d: child counts", src, oi)
			}
			if !compare(t, src, ours, ov, theirs, tv, headed) {
				return false
			}
		}
	case .Map:
		return compare_members(t, src, ours, oi, theirs, ti, false)
	case .Plain:
		ok = cell_agrees(t, src, ours, oi, theirs, ti)
	case .Null, .False, .True, .Number, .String, .End:
		ok = false
	}
	return ok
}

// Checks a record's members in order: its cells against the current tree's fields, their names against its member
// names, and each name against the key the document stores for it, a headed record's header cell or a JSON object's
// key node.
compare_members :: proc(t: ^testing.T, src: []u8, ours: ^core.Document, oi: u32, theirs: ^cur.Document, ti: cur.Node, headed: bool) -> bool {
	if !walktest.count_agrees(t, src, oi, core.length(ours, oi), cur.child_count(theirs, ti)) {
		return false
	}
	if !walktest.child_at_agrees(t, src, ours, oi) {
		return false
	}
	oit := core.children(ours, oi)
	tit := cur.members(theirs, ti)
	buf: [4096]u8
	col := 0
	for {
		ov, ov_ok := core.child_next(&oit)
		name, tv, tv_ok := cur.members(&tit)
		if !ov_ok || !tv_ok {
			return testing.expectf(t, ov_ok == tv_ok, "%q node %d: member counts", src, oi)
		}
		key_node := ov - 1
		if headed {
			key_node = ours.header + 1 + u32(col)
		}
		key, kok := core.text(ours, key_node, buf[:])
		if !testing.expectf(t, kok && key == name, "%q node %d: key %q, current tree %q", src, oi, key, name) {
			return false
		}
		// The key's own text must be found by the key comparison and by `member`, at this member or an earlier member.
		if !testing.expectf(t, core.key_equals(ours, key_node, key), "%q node %d: key_equals disagrees with text %q", src, oi, key) {
			return false
		}
		found, fok := core.member(ours, oi, key, .First)
		ok := fok && found <= ov
		if ok {
			found_key := found - 1
			if headed {
				found_key = ours.header + 1 + (found - oi - 1)
			}
			ok = core.key_equals(ours, found_key, key)
		}
		if !testing.expectf(t, ok, "%q node %d: member %q -> %v %v, current %v", src, oi, key, found, fok, ov) {
			return false
		}
		if !compare(t, src, ours, ov, theirs, tv, headed) {
			return false
		}
		col += 1
	}
}

// Checks a cell's text. The current tree resolves an empty unquoted cell to null and every other cell to a string,
// so the text is what the two models agree on.
cell_agrees :: proc(t: ^testing.T, src: []u8, ours: ^core.Document, oi: u32, theirs: ^cur.Document, ti: cur.Node) -> bool {
	buf: [4096]u8
	s, sok := core.text(ours, oi, buf[:])
	w, _ := cur.get_string(theirs, ti)
	return testing.expectf(t, sok && s == w, "%q node %d: cell %q, current tree %q", src, oi, s, w)
}

kind_agrees :: proc(a: core.Kind, b: cur.Kind) -> bool {
	switch a {
	case .Array:
		return b == .Array
	case .Map:
		return b == .Object
	case .Plain:
		return b == .String || b == .Null
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
	case .End:
	}
	return false
}
