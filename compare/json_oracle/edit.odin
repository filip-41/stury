// Holds one edit of each round against the current tree's `json.set`, `insert` and `remove` by path, and checks that
// the two committed texts read as the same document. The edit rounds' own model checks run in the private test suite.
// `make test-oracle` builds this package from a copy of next/.
package json_oracle

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import cur "stury:json"
import core "../../next/core"
import json "../../next/json"
import gen "../../next/json/test/gen"

// `VALUES` holds the values an edit may write, per spec. A JSON value holds no form another spec reads.
@(private)
VALUES := [3][]string {
	{"0", "1", "-2.5", "true", "false", "null", `"s"`, `"a\nb"`, "[]", "{}", "[1,2]", `{"k":1}`, "1e3", "9007199254740993", `[{"a":[true]}]`},
	{"0", "1", "-2.5", "true", "false", "null", `"s"`, `"a\nb"`, "[]", "{}", "[1,2]", `{"k":1}`, "1e3", "/*c*/2", "[1, /*c*/ 2]", "//c\n3"},
	{"0", "1", "-2.5", "true", "false", "null", `"s"`, `"a\nb"`, "[]", "{}", "[1,2]", `{"k":1}`, "0x10", "Infinity", "NaN", `'q'`, "{a:1}", "[1,]", "1e3"},
}

@(private)
KEY_TEXT := [3][]string {
	{`"a"`, `"b"`, `"k1"`, `""`, `"é"`, `"a b"`, `"x\u0041"`},
	{`"a"`, `"b"`, `"k1"`, `""`, `"é"`, `"a b"`},
	{`"a"`, "b", "k1", `""`, `é`, `"a b"`, `$x`, `\u0061`},
}

// A node an edit may name, the path the current tree reads, and for an insert the place it goes.
@(private)
Candidate :: struct {
	node:  core.Node_Index,
	path:  string,
	kind:  core.Kind,
	index: int,
}

@(private)
Candidates :: struct {
	sets:    [dynamic]Candidate,
	inserts: [dynamic]Candidate,
	removes: [dynamic]Candidate,
}

@(test)
second_edit_agrees :: proc(t: ^testing.T) {
	state := rand.create(SEED + 11)
	context.random_generator = rand.default_random_generator(&state)
	refused, checked, parted: int
	for round in 0 ..< ROUNDS {
		text: [dynamic]u8
		spec := json.Spec(round % len(json.Spec))
		if round % 4 == 3 {
			gen.pretty(&text, 1 + round % 4, spec)
		} else {
			gen.text(&text, 1 + round % 4, spec)
		}
		ok := second_round(t, text[:], spec, &refused, &checked, &parted)
		delete(text)
		free_all(context.temp_allocator)
		if !ok {
			return
		}
	}
	fmt.printfln("seed %d: %d path edits checked (%d parted, %d refused)", SEED, checked, parted, refused)
}

// Applies one edit through the edit list and through the current tree's path API, and compares the two texts.
@(private)
second_round :: proc(t: ^testing.T, src: []u8, spec: json.Spec, refused, checked, parted: ^int) -> bool {
	doc, err := build_ours(src, spec)
	if err.kind != .None {
		return true
	}
	defer core.destroy(&doc)
	if !unique_keys(&doc, 0) {
		return true
	}
	cands: Candidates
	cands.sets = make([dynamic]Candidate, 0, 8, context.temp_allocator)
	cands.inserts = make([dynamic]Candidate, 0, 8, context.temp_allocator)
	cands.removes = make([dynamic]Candidate, 0, 8, context.temp_allocator)
	collect(&doc, 0, ".", &cands)
	total := len(cands.sets) + len(cands.inserts) + len(cands.removes)
	if total == 0 {
		return true
	}
	pick := rand.int_max(total)
	c: Candidate
	inserting, removing := false, false
	if pick < len(cands.sets) {
		c = cands.sets[pick]
	} else if pick < len(cands.sets) + len(cands.inserts) {
		c = cands.inserts[pick - len(cands.sets)]
		inserting = true
	} else {
		c = cands.removes[pick - len(cands.sets) - len(cands.inserts)]
		removing = true
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	opts := cur.Read_Opts{dialect = cur.Dialect(spec)}
	text, key, name := "", "", ""
	at := c.index
	switch {
	case inserting:
		text = VALUES[spec][rand.int_max(len(VALUES[spec]))]
		if c.kind == .Array {
			at = rand.int_max(int(core.length(&doc, c.node)) + 1)
			if e := core.insert(&list, c.node, at, text); e.kind != .None {
				return true
			}
		} else {
			key = KEY_TEXT[spec][rand.int_max(len(KEY_TEXT[spec]))]
			if e := core.insert(&list, c.node, at, key, text); e.kind != .None {
				return true
			}
			name_ok: bool
			name, name_ok = key_value(transmute([]u8)key, spec)
			if !name_ok {
				return true
			}
		}
	case removing:
		if e := core.remove(&list, c.node); e.kind != .None {
			return true
		}
	case:
		text = VALUES[spec][rand.int_max(len(VALUES[spec]))]
		if e := core.set(&list, c.node, text); e.kind != .None {
			return true
		}
	}
	our, _, oerr := core.commit(&list)
	if oerr.kind != .None {
		return true
	}
	defer delete(our)
	found: []byte
	ferr: Maybe(cur.Path_Error)
	switch {
	case inserting:
		if c.kind == .Array {
			found, ferr = cur.insert(src, c.path, at, cur.Raw(text), opts)
		} else {
			found, ferr = cur.insert(src, c.path, name, cur.Raw(text), opts)
		}
	case removing:
		found, ferr = cur.remove(src, c.path, opts)
	case:
		found, ferr = cur.set(src, c.path, cur.Raw(text), opts)
	}
	if ferr != nil {
		refused^ += 1
		return true
	}
	defer delete(found)
	checked^ += 1
	ours, berr := build_ours(our, spec)
	if berr.kind != .None {
		return testing.expectf(t, false, "our commit does not read: %v in %q", berr, our)
	}
	defer core.destroy(&ours)
	theirs, terr := cur.build(found, opts)
	if terr != nil {
		parted^ += 1
		return true
	}
	defer cur.destroy(&theirs)
	return compare(t, src, &ours, 0, &theirs, 0)
}

// Appends every node an edit may name. A set names any value, an insert a container and the place it appends, and a
// removal a member of a container.
@(private)
collect :: proc(doc: ^core.Document, i: core.Node_Index, path: string, c: ^Candidates) {
	kind := core.kind(doc, i)
	if doc.nodes[i].role != .Key {
		append(&c.sets, Candidate{node = i, path = path, kind = kind})
	}
	if i > 0 {
		append(&c.removes, Candidate{node = i, path = path, kind = kind})
	}
	if kind != .Array && kind != .Map {
		return
	}
	append(&c.inserts, Candidate{node = i, path = path, kind = kind, index = int(core.length(doc, i))})
	it := core.children(doc, i)
	index := 0
	for {
		v, ok := core.child_next(&it)
		if !ok {
			break
		}
		child := path
		if kind == .Map {
			buf: [4096]u8
			key, _, kok := core.text(doc, v - 1, buf[:], context.temp_allocator)
			if !kok {
				return
			}
			child = path_name(path, key)
		} else {
			child = fmt.tprintf("%s[%d]", path, index)
		}
		collect(doc, v, child, c)
		index += 1
	}
}

// Returns a member's path: a bare name where jq reads one, else a quoted name.
@(private)
path_name :: proc(path, name: string) -> string {
	bare := len(name) > 0
	for c in name {
		bare &&= c == '_' || c == '$' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
	}
	if bare && !(name[0] >= '0' && name[0] <= '9') {
		return fmt.tprintf("%s.%s", path, name)
	}
	q, _ := cur.marshal(name)
	defer delete(q)
	return fmt.tprintf("%s[%s]", path, string(q))
}

// Returns true if no object in the document repeats a key, so a path names one value.
@(private)
unique_keys :: proc(doc: ^core.Document, i: core.Node_Index) -> bool {
	kind := core.kind(doc, i)
	if kind == .Map {
		seen: [dynamic]string
		defer delete(seen)
		it := core.children(doc, i)
		for {
			v, ok := core.child_next(&it)
			if !ok {
				break
			}
			buf: [4096]u8
			key, _, kok := core.text(doc, v - 1, buf[:], context.temp_allocator)
			if !kok {
				return false
			}
			for s in seen {
				if s == key {
					return false
				}
			}
			append(&seen, strings.clone(key, context.temp_allocator))
			if !unique_keys(doc, v) {
				return false
			}
		}
		return true
	}
	if kind == .Array {
		it := core.children(doc, i)
		for {
			v, ok := core.child_next(&it)
			if !ok {
				break
			}
			if !unique_keys(doc, v) {
				return false
			}
		}
	}
	return true
}

// Returns the key `text` names, decoded under `spec`, or false.
@(private)
key_value :: proc(text: []u8, spec: json.Spec) -> (string, bool) {
	buf, aerr := make([]u8, len(text) + 4)
	if aerr != nil {
		return "", false
	}
	defer delete(buf)
	buf[0] = '{'
	copy(buf[1:], text)
	buf[len(text) + 1] = ':'
	buf[len(text) + 2] = '0'
	buf[len(text) + 3] = '}'
	doc, err := build_ours(buf, spec)
	defer core.destroy(&doc)
	if err.kind != .None || len(doc.nodes) < 2 {
		return "", false
	}
	out: [4096]u8
	s, _, ok := core.text(&doc, 1, out[:], context.temp_allocator)
	if !ok {
		return "", false
	}
	return strings.clone(s, context.temp_allocator), true
}

@(private)
build_ours :: proc(src: []u8, spec: json.Spec) -> (core.Document, core.Document_Error) {
	switch spec {
	case .Json:
		return json.build(src, .Json)
	case .Jsonc:
		return json.build(src, .Jsonc)
	case .Json5:
		return json.build(src, .Json5)
	}
	return {}, {kind = .Bad_Value}
}
