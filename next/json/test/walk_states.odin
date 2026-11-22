package json_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// Expects the nodes of `doc` from `from` on to be those of `part`, a text at offset `at` of `doc`'s.
expect_nodes_of :: proc(t: ^testing.T, doc, part: ^tape.Document, from: int, at: u64, loc := #caller_location) {
	if !testing.expectf(t, len(doc.nodes) - from == len(part.nodes), "%d nodes, want %d", len(doc.nodes) - from, len(part.nodes), loc = loc) {
		return
	}
	for n, i in part.nodes {
		got := doc.nodes[from + i]
		got.lo -= at
		if got != n {
			testing.expectf(t, false, "node %d: %v, want %v", i, got, n, loc = loc)
			return
		}
	}
}

// An object whose keys never repeat retires only its own row of gaps: the records that follow it in another member
// read as they do alone, and a broken one is refused where it breaks, whatever spells the colons.
@(test)
gaps_retire_the_row_that_misses :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for colon in ([]string{":", "\n:", " :\n  "}) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"index":{`)
		join_each(&b, 3000, ",", strings.concatenate({`"k%[0]d"`, colon, `%[0]d`}, context.temp_allocator))
		strings.write_string(&b, `},"records":`)
		head := strings.builder_len(b)
		good, _ := records(`{"id":1,"name":"a","tags":{"x":1,"y":"z"}}`, ",", `{"id":2,"name":"b","tags":{"x":1,"y":"z"}}`, 40)
		text := strings.concatenate({strings.to_string(b), good, "}"}, context.temp_allocator)
		doc, err := build(t, text)
		alone, aerr := build(t, good)
		if testing.expectf(t, err == nil && aerr == nil, "%q: %v, %v", colon, err, aerr) {
			// The root, the key and value of `index` and its members, then the key of `records`.
			expect_nodes_of(t, &doc, &alone, 3 + 2 * 3000 + 1, u64(head))
		}
		tape.destroy(&doc)
		tape.destroy(&alone)
		bad, at := records(`{"id":1,"name":"a"}`, ",", `{"id":1"name":"a"}`, 40)
		doc, err = build(t, strings.concatenate({strings.to_string(b), bad, "}"}, context.temp_allocator))
		f, faulted := err.(tape.Fault)
		testing.expectf(t, faulted && f.kind == .Bad_Char && f.at == u64(head + at + 7), "%q: %v", colon, err)
		tape.destroy(&doc)
	}
}

// Records with one member whose object varies keep reading as they do one at a time, and a record that breaks after
// the varying member's row is retired is refused where it breaks.
@(test)
gaps_of_a_varying_member :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	for i in 0 ..< 3000 {
		fmt.sbprintf(&b, `%s{{"id":%d,"meta":{{"m%d":1,"n%d":2}},"ok":true,"s":"x"}}`, "," if i > 0 else "", i, i, i * 7)
	}
	last := strings.builder_len(b)
	strings.write_string(&b, `,{"id":1,"meta":{"a":1},"ok":true "s":"x"}]`)
	text := strings.to_string(b)
	doc, err := build(t, text)
	f, faulted := err.(tape.Fault)
	testing.expectf(t, faulted && f.kind == .Bad_Char && f.at == u64(last + 34), "%v", err)
	tape.destroy(&doc)
	text = strings.concatenate({text[:last], `,{"id":1,"meta":{"a":1},"ok":true,"s":"x"}]`}, context.temp_allocator)
	doc, err = build(t, text)
	testing.expect_value(t, err, nil)
	expect_key_spans(t, text, &doc)
	testing.expect_value(t, len(doc.nodes), 1 + 3000 * 13 + 11)
	tape.destroy(&doc)
}

// A key past ASCII reads in each of the key readers: within the probe's bytes, across them and past 64 bytes, at the
// start, middle and end of the key, flush and among records whose gaps match. Bad UTF-8 and a control byte in a key
// are refused where they are.
@(test)
keys_past_ascii :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [256]u8
	for lead in ([]int{0, 1, 14, 29, 30, 31, 32, 33, 62, 70}) {
		for tail in ([]int{0, 1, 3, 31}) {
			key := strings.concatenate({strings.repeat("k", lead, context.temp_allocator), "é名", strings.repeat("v", tail, context.temp_allocator)}, context.temp_allocator)
			q := strings.concatenate({`"`, key, `"`}, context.temp_allocator)
			forms := [][]string {
				{"{", q, `:1,"b":2}`},
				{"[{", q, `:1,"b":2},{`, q, `:3,"b":4},{`, q, `:5,"b":6}]`},
				{"{\n  ", q, ": 1,\n  \"b\": [2]\n}"},
			}
			for spec in JSON_SPECS {
				for form in forms {
					src := strings.concatenate(form, context.temp_allocator)
					doc := expect_builds(t, spec, src)
					found := 0
					for n in doc.nodes {
						if n.role == .Key && n.n > 1 {
							got, ok := tape.node_text(&doc, n, buf[:])
							testing.expectf(t, ok && got == key, "%v %q: key %q", spec, src, got)
							found += 1
						}
					}
					testing.expectf(t, found == (len(form) - 1) / 2, "%v %q: %d keys", spec, src, found)
					tape.destroy(&doc)
				}
				broken := strings.concatenate({key[:lead], "\xc3(", key[lead + 2:]}, context.temp_allocator)
				expect_fault(t, spec, strings.concatenate({"{", q, `:1,"`, broken, `":2}`}, context.temp_allocator), .Bad_Char, 7 + len(key) + lead)
				// JSON5 takes a control byte in a string, which JSON refuses.
				if spec != .Json5 {
					expect_fault(t, spec, strings.concatenate({`{"`, key, "\x01\":1}"}, context.temp_allocator), .Bad_Char, 2 + len(key))
				}
			}
		}
	}
}

// A single-quoted JSON5 string with an escape before, inside or past its first 32 bytes reads as its escapes say, and
// one with a JSON5 escape or an escaped quote keeps the spelling that says so.
@(test)
single_quoted_escapes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		body, want: string,
	}
	cases := []Case {
		{`a\tb`, "a\tb"},
		{`it\'s`, "it's"},
		{`say \"x\" and "y"`, `say "x" and "y"`},
		{`é\x41\0`, "éA\x00"},
		{`line\
next`, "linenext"},
		{`é\nü`, "é\nü"},
	}
	buf: [512]u8
	for c in cases {
		for lead in ([]int{0, 5, 30, 31, 33, 60, 64, 100}) {
			pad := strings.repeat("x", lead, context.temp_allocator)
			body := strings.concatenate({pad, c.body, pad}, context.temp_allocator)
			want := strings.concatenate({pad, c.want, pad}, context.temp_allocator)
			src := strings.concatenate({"['", body, "', 1]", strings.repeat(" ", 80, context.temp_allocator)}, context.temp_allocator)
			doc := expect_builds(t, .Json5, src)
			got, ok := tape.node_text(&doc, doc.nodes[1], buf[:])
			testing.expectf(t, ok && got == want, "%q: %q", src, got)
			tape.destroy(&doc)
		}
	}
	expect_fault(t, .Json5, strings.concatenate({"['", strings.repeat("x", 40, context.temp_allocator), "\n', 1]"}, context.temp_allocator), .Bad_Char, 42)
	// A backslash as the text's last byte, where the block reader stops.
	expect_fault(t, .Json5, strings.concatenate({"['", strings.repeat("x", 63, context.temp_allocator), "\\"}, context.temp_allocator), .Truncated, 66)
}

// The states after a value inside an object whose gaps matched read a close, white space and the root's end the same
// as the state after any value: trailing white space reads and a byte past the root is refused at its offset.
@(test)
values_end_the_same_after_matched_gaps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for value in ([]string{`"s"`, `12`, `true`, `[1]`, `{"z":0}`}) {
		for tail in ([]string{"", " ", "\n\t \r\n", " x", "]"}) {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "[")
			for i in 0 ..< 6 {
				fmt.sbprintf(&b, `%s{{"a":%d,"b":`, "," if i > 0 else "", i)
				strings.write_string(&b, value)
				strings.write_string(&b, "}")
			}
			strings.write_string(&b, "]")
			body := strings.to_string(b)
			src := strings.concatenate({body, tail}, context.temp_allocator)
			doc, err := build(t, src)
			bad := strings.index_any(tail, "x]")
			if bad < 0 {
				testing.expectf(t, err == nil && doc.root_close == u64(len(body)), "%q: %v", src, err)
			} else {
				f, faulted := err.(tape.Fault)
				testing.expectf(t, faulted && f.kind == .Bad_Char && f.at == u64(len(body) + bad), "%q: %v", src, err)
			}
			tape.destroy(&doc)
			found, ferr := json.find(transmute([]u8)src, {tape.Index(4), tape.Name("b")})
			if bad < 0 {
				testing.expectf(t, ferr == nil && src[found.lo:found.hi] == value, "find in %q: %v %v", src, found, ferr)
			}
		}
	}
}

// Arrays of arrays of numbers read in blocks give the same nodes as one at a time, and a scan that keeps one whole
// under a node budget the blocks exceed is refused with no document.
@(test)
number_blocks_honour_the_hook :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"data":[[0,1]`)
	for i in 0 ..< 4000 {
		fmt.sbprintf(&b, ",[%d,-%d.5,[%d]]", i, i, i)
	}
	strings.write_string(&b, `],"n":1}`)
	text := transmute([]u8)strings.to_string(b)
	whole, err := json.build(text)
	defer tape.destroy(&whole)
	testing.expect_value(t, err, nil)
	d, _ := tape.demand_of({{tape.Name("data")}})
	defer tape.destroy(&d)
	kept, kerr := json.scan(text, &d)
	testing.expect_value(t, kerr, nil)
	// The data array is the third node of both.
	testing.expectf(t, len(kept.nodes) > 3 && kept.nodes[2] == whole.nodes[2], "kept %v, built %v", kept.nodes[2], whole.nodes[2])
	expect_nodes_of(t, &kept, &tape.Document{nodes = whole.nodes[2:][:whole.nodes[2].n]}, 2, 0)
	tape.destroy(&kept)
	for budget in ([]u32{100, 1000, 9000}) {
		r, rerr := json.scan(text, &d, opts = {budget = {nodes = budget}})
		_, faulted := rerr.(tape.Fault)
		testing.expectf(t, rerr != nil && !faulted && len(r.nodes) == 0, "budget %d: %v", budget, rerr)
		tape.destroy(&r)
	}
}

// Comments past the root are its inline comment and its foot, emitted only once the text past the root is checked,
// whatever room the build has left when it reaches them. A refused allocation of their facts is the build's error.
@(test)
root_tail_comments :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		spec:  json.Spec,
		src:   string,
		kinds: []tape.Fact_Kind,
		fault: tape.Fault_Kind,
		at:    int, // the fault's offset, or the root's end
	}
	cases := []Case {
		{.Jsonc, "[1, 2] // a\n/* b */\n// c", {.Comment_Inline, .Comment_Foot, .Comment_Foot}, .None, 6},
		{.Json5, "{a: 1} /* a */ /* b */\n", {.Comment_Inline, .Comment_Inline}, .None, 6},
		{.Jsonc, "1\n// a", {.Comment_Foot}, .None, 1},
		{.Jsonc, "[1] // a\n x", nil, .Bad_Char, 10},
		{.Jsonc, "[1] /* a", nil, .Truncated, 8},
		{.Jsonc, "[1] / a", nil, .Bad_Char, 4},
		{.Json, "[1] // a", nil, .Bad_Char, 4},
	}
	for c in cases {
		doc, err := build_spec(t, c.src, c.spec)
		kind, at := fault_of(err)
		testing.expectf(t, kind == c.fault && (kind == .None || at == u64(c.at)), "%q: %v", c.src, err)
		if err == nil {
			testing.expectf(t, len(doc.facts) == len(c.kinds), "%q: %d facts", c.src, len(doc.facts))
			for f, i in doc.facts[:min(len(doc.facts), len(c.kinds))] {
				testing.expectf(t, f.kind == c.kinds[i] && f.node == tape.ROOT, "%q fact %d: %v", c.src, i, f)
			}
			testing.expect_value(t, doc.root_close, u64(c.at))
		}
		tape.destroy(&doc)
	}
	src := "[1, [2, 3], {\"a\": 4}] // a\n/* b */"
	ref, _ := json.build(transmute([]u8)src, .Jsonc)
	defer tape.destroy(&ref)
	for k in 0 ..= len(ref.nodes) + 1 {
		padded := strings.concatenate({strings.repeat(" ", 16 * k, context.temp_allocator), src}, context.temp_allocator)
		doc, err := json.build(transmute([]u8)padded, .Jsonc)
		testing.expectf(t, err == nil && len(doc.nodes) == len(ref.nodes) && len(doc.facts) == 2 && doc.facts[1].kind == .Comment_Foot, "pad %d: %v", k, err)
		tape.destroy(&doc)
	}
	for left := 0; ; left += 1 {
		f := Failing{backing = context.allocator, left = left}
		doc, err := json.build(transmute([]u8)src, .Jsonc, allocator = failing_allocator(&f))
		facts := len(doc.facts)
		tape.destroy(&doc)
		testing.expectf(t, f.live == 0, "%d allocations: %d live", left, f.live)
		if err == nil {
			testing.expect(t, left > 0 && facts == 2)
			break
		}
		testing.expectf(t, err == runtime.Allocator_Error.Out_Of_Memory, "%d allocations: %v", left, err)
		if left > 100 {
			break
		}
	}
}

// The room for nodes runs out at each node of records whose gaps the walk has learned, after a string, a number, a
// literal, a container and at a key, and a growth there leaves the nodes of a build that never grows, with no write
// past the room.
@(test)
room_grows_inside_learned_gaps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	shapes := [?]string {
		`{"id":1,"name":"a","ok":true,"n":null,"f":-1.5,"t":[1],"u":{"k":"v"}}`,
		"{\n  \"id\": 1,\n  \"name\": \"a\",\n  \"ok\": false,\n  \"n\": null,\n  \"f\": 2,\n  \"t\": [],\n  \"u\": {}\n}",
		`{ "id" : 1 , "name" : "a" , "ok" : true , "n" : null , "f" : 3 , "t" : [ 1 ] , "u" : { "k" : "v" } }`,
	}
	for spec in ([]json.Spec{.Json, .Json5}) {
		for record in shapes {
			text, _ := records(record, ",", record, 40)
			pad := strings.repeat(" ", 16 * len(text), context.temp_allocator)
			ref, rerr := json.build(transmute([]u8)strings.concatenate({pad, text}, context.temp_allocator), spec)
			defer tape.destroy(&ref)
			if !testing.expectf(t, rerr == nil, "%v: %v", spec, rerr) {
				continue
			}
			// Each pad moves the end of the first room one node on.
			for k in 0 ..= len(ref.nodes) {
				guarded: testkit.Guarded
				testkit.guarded_init(&guarded, context.allocator)
				defer testkit.guarded_destroy(&guarded)
				doc, err := json.build(transmute([]u8)strings.concatenate({pad[:16 * k], text}, context.temp_allocator), spec, allocator = testkit.guarded_allocator(&guarded))
				defer tape.destroy(&doc)
				if !testing.expectf(t, err == nil && testkit.guarded_check(&guarded), "%v pad %d: %v, a write past a block %v", spec, k, err, guarded.broken) {
					break
				}
				if !testing.expectf(t, len(doc.nodes) == len(ref.nodes), "%v pad %d: %d nodes, want %d", spec, k, len(doc.nodes), len(ref.nodes)) {
					break
				}
				for node, i in doc.nodes {
					want := ref.nodes[i]
					want.lo -= u64(len(pad) - 16 * k)
					if node != want {
						testing.expectf(t, false, "%v pad %d node %d: %v, want %v", spec, k, i, node, want)
						break
					}
				}
			}
		}
	}
}
