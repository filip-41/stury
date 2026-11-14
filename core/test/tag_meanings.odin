// The law that a tag keeps its meaning through a write to another format that spells that meaning.
package core_test

import "core:strings"
import "core:testing"
import core ".."
import cbor "../../cbor"
import toml "../../toml"
import yaml "../../yaml"

// A text of a format with a tag of each meaning it has on a member of the root, and the meanings the format spells.
@(private = "file")
Tagged :: struct {
	name:  string,
	as:    core.As,
	src:   string,
	holds: bit_set[core.Tag_Meaning],
}

@(test)
tags_keep_their_meaning_in_every_format :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	texts := []Tagged {
		{"yaml", yaml.as(.Yaml_1_2), "a: !!timestamp 2013-03-21T20:04:00Z\nb: !!timestamp 2013-03-21T20:04:00\nc: !!timestamp 2013-03-21\nd: !!binary aGk=\n", {.Datetime, .Local_Datetime, .Local_Date, .Binary}},
		{"toml", toml.as(.Toml_1_0), "a = 2013-03-21T20:04:00Z\nb = 2013-03-21T20:04:00\nc = 2013-03-21\nt = 20:04:00\n", {.Datetime, .Local_Datetime, .Local_Date, .Local_Time}},
		{"cbor", cbor.as(.Cbor), "\xa3\x61a\xc0\x742013-03-21T20:04:00Z\x61c\xd9\x03\xec\x6a2013-03-21\x61d\x42hi", {.Datetime, .Local_Date, .Binary}},
	}
	for x in texts {
		doc, err := core.build(transmute([]u8)x.src, x.as, allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s: %v", x.name, err) {
			continue
		}
		from := meanings(&doc)
		testing.expectf(t, len(from) == card(x.holds), "%s reads %v", x.name, from)
		for y in texts {
			if y.name == x.name {
				continue
			}
			text, dropped, werr := core.write(&doc, {}, y.as, allocator = context.temp_allocator)
			if !testing.expectf(t, werr == nil, "%s as %s: %v", x.name, y.name, werr) {
				continue
			}
			back, berr := core.build(text, y.as, allocator = context.temp_allocator)
			if !testing.expectf(t, berr == nil, "%s as %s: %v\n%s", x.name, y.name, berr, string(text)) {
				continue
			}
			to := meanings(&back)
			lost := 0
			for key, m in from {
				if m in y.holds {
					testing.expectf(t, to[key] == m, "%s as %s reads %s as %v, not %v\n%s", x.name, y.name, key, to[key], m, string(text))
				} else {
					testing.expectf(t, key not_in to, "%s as %s reads %s as %v\n%s", x.name, y.name, key, to[key], string(text))
					lost += 0 if x.name == "toml" || m == .Binary && x.name == "cbor" else 1
				}
			}
			testing.expectf(t, dropped == lost, "%s as %s drops %d, not %d", x.name, y.name, dropped, lost)
		}
	}
}

// The meaning of each member of the root that has one, by its key. A byte string means binary.
@(private = "file")
meanings :: proc(doc: ^core.Document) -> map[string]core.Tag_Meaning {
	out := make(map[string]core.Tag_Meaning, context.temp_allocator)
	buf: [64]u8
	it := core.pairs(doc, core.ROOT)
	for key, value in core.pair_next(&it) {
		name, _ := core.text(doc, key, buf[:])
		m := core.Tag_Meaning.Binary if core.kind(doc, value) == .Bytes else .Own
		if tag, tagged := core.fact_value(doc, value, .Tag); tagged {
			m = tag.meaning
		}
		if m != .Own {
			out[strings.clone(name, context.temp_allocator)] = m
		}
	}
	return out
}
