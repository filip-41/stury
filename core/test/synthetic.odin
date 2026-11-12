package core_test

import "core:testing"
import core ".."
import json "../../json"
import walktest "../../walktest"

// A format whose keys are the node's span with a `@` added, or `#text` for a span of none, as a markup format spells
// attribute and text members.
@(private = "file", rodata)
synthetic_readers := core.Readers {
	text = proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (string, bool) {
		name := "#text" if t.n == 0 else string(v.src[t.lo:t.lo + u64(t.n)])
		prefix := 0 if t.n == 0 else 1
		if len(buf) < len(name) + prefix {
			return "", false
		}
		if prefix == 1 {
			buf[0] = '@'
		}
		copy(buf[prefix:], name)
		return string(buf[:len(name) + prefix]), true
	},
	key_equals = proc "contextless" (v: ^core.Token_View, t: core.Token, name: string) -> bool {
		if t.n == 0 {
			return name == "#text"
		}
		return len(name) == int(t.n) + 1 && name[0] == '@' && name[1:] == string(v.src[t.lo:t.lo + u64(t.n)])
	},
	resolve = proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
		return .String
	},
}

// A key that no span of the source spells reads through the format's `text` and `key_equals`, in a buffer `text_room`
// sizes, and a path step finds it.
@(test)
synthetic_keys_read_through_the_format :: proc(t: ^testing.T) {
	src := transmute([]u8)string("id1xy")
	nodes := []core.Node {
		{n = 5, kind = .Object, spelling = 2},
		{lo = 0, n = 2, kind = .String, role = .Key, spelling = core.SPELLING_SYNTHETIC},
		{lo = 2, n = 1, kind = .Plain},
		{lo = 3, n = 0, kind = .String, role = .Key, spelling = core.SPELLING_SYNTHETIC},
		{lo = 3, n = 2, kind = .Plain},
	}
	doc := core.Document{view = {src = src, as = {readers = &synthetic_readers}}, nodes = nodes}
	key, _ := core.text_clone(&doc, 1)
	defer delete(key)
	testing.expect_value(t, key, "@id")
	text, _ := core.text_clone(&doc, 3)
	defer delete(text)
	testing.expect_value(t, text, "#text")
	testing.expect(t, core.text_room(&doc, 3) >= len("#text"))
	value, found := core.member(&doc, 0, "@id")
	testing.expect(t, found && value == 2)
	value, found = core.member(&doc, 0, "#text")
	testing.expect(t, found && value == 4)
	_, found = core.member(&doc, 0, "id")
	testing.expect(t, !found)

	// The JSON document writer spells them through `text` too.
	out, _, werr := core.write(&doc, as = json.as(.Json))
	defer delete(out)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(out), `{"@id":"1","#text":"xy"}`)
}
