// Runs the html5lib encoding sniffing suite (82 cases) and encoding fault checks.
package html_tests

import "core:strings"
import "core:testing"
import "stury:html"
import "stury:testkit"

@(private = "file")
ENCODING_CASES := #load_directory("conformance/html5lib/encoding")

@(test)
encoding_sniff :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := 0
	for f in ENCODING_CASES {
		text := string(f.data)
		for chunk in strings.split(text, "#data\n", context.temp_allocator)[1:] {
			data, _, want := strings.partition(chunk, "\n#encoding\n")
			want = strings.trim_space(want)
			src := transmute([]u8)data
			name, found := html.internal_sniff(src)
			if !found {
				tree, fault := html.internal_build(src, allocator = context.temp_allocator)
				if bad, faulted := fault.(html.Fault); faulted {
					testing.expectf(t, bad.kind == .Bad_Char && html.Detail(bad.detail) == .Encoding, "%s %q: %v", f.name, data, fault)
					name, found = html.internal_label(src, bad.at)
				} else if fault == nil {
					name, found = html.internal_tree_encoding(&tree)
					html.internal_tree_destroy(&tree)
				} else {
					testing.expectf(t, false, "%s %q: %v", f.name, data, fault)
				}
			}
			if !found {
				name = "windows-1252"
			}
			testing.expectf(t, strings.equal_fold(name, want), "%s %q: got %s, want %s", f.name, data, name, want)
			cases += 1
		}
	}
	testing.expect_value(t, cases, 82)
}

@(test)
encoding_faults :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:    string,
		faults: bool,
		at:     u64,
	}
	cases := [?]Case {
		{"<meta charset=\"iso-8859-2\"><p>\xe9", true, 15},
		{"<meta http-equiv=content-type content='text/html; charset=shift_jis'>\xe9", true, 58},
		{"<meta charset=\"iso-8859-2\"><p>plain", false, 0},
		{"<meta charset=\"iso-2022-jp\"><p>\x1b$B", true, 15},
		{"<meta charset=\"iso-2022-jp\"><p>plain", false, 0},
		{"<meta charset=\"replacement\"><p>plain", true, 15},
		{"<meta charset=\"hz-gb-2312\"><p>plain", true, 15},
		{"<meta charset=\"utf-16le\"><p>\xc3\xa9", false, 0},
		{"<meta charset=\"x-user-defined\"><p>\xe9", true, 15},
		{"<meta charset=\"no-such-label\"><p>\xe9", false, 0},
		{"\xfe\xff\x00<", true, 0},
		{"\xff\xfe<\x00", true, 0},
	}
	for c in cases {
		tree, err := html.internal_build(transmute([]u8)c.src)
		f, faulted := err.(html.Fault)
		if c.faults {
			testing.expectf(t, faulted && f.kind == .Bad_Char && f.at == c.at && html.Detail(f.detail) == .Encoding, "%q: %v", c.src, err)
		} else {
			testing.expectf(t, err == nil, "%q: %v", c.src, err)
			html.internal_tree_destroy(&tree)
		}
	}
	tree, err := html.internal_build(transmute([]u8)string("\xef\xbb\xbfx"))
	defer html.internal_tree_destroy(&tree)
	testing.expect(t, err == nil)
	body := html.internal_node(&tree, html.internal_node(&tree, html.internal_node(&tree, 1).first).last)^
	testing.expect_value(t, html.internal_decoded(&tree, tree.pieces[html.internal_node(&tree, body.first).a].span), "x")
}
