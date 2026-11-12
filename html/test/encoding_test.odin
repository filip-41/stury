// Runs the html5lib encoding cases on the sniffing: each must find the encoding the case lists, windows-1252 where
// none is named, as html5lib's default is. Then the tree's reading of what the sniffing finds.
package html_tests

import "core:strings"
import "core:testing"
import html ".."

@(private)
ENCODING_CASES := #load_directory("conformance/html5lib/encoding")

@(test)
encoding_sniff :: proc(t: ^testing.T) {
	cases := 0
	for f in ENCODING_CASES {
		text := string(f.data)
		for chunk in strings.split(text, "#data\n", context.temp_allocator)[1:] {
			data, _, want := strings.partition(chunk, "\n#encoding\n")
			want = strings.trim_space(want)
			src := transmute([]u8)data
			name, found := html.internal_sniff(src)
			if !found {
				// The tree reads the text, and a `meta` it inserts may name the encoding. The build faults at the label
				// when that encoding reads the text otherwise than UTF-8.
				tree, fault := html.internal_build(src)
				if bad, faulted := fault.?; faulted {
					testing.expectf(t, bad.kind == .Bad_Char && html.Detail(bad.detail) == .Encoding, "%s %q: %v", f.name, data, fault)
					name, found = html.internal_label(src, bad.at)
				} else {
					name, found = html.internal_tree_encoding(&tree)
					html.internal_tree_destroy(&tree)
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

// A document whose byte order mark or `meta` names another encoding than UTF-8 faults at the mark or the label, unless
// that encoding reads its bytes as UTF-8 does. A UTF-8 byte order mark is no character of the document.
@(test)
encoding_faults :: proc(t: ^testing.T) {
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
		tree, fault := html.internal_build(transmute([]u8)c.src)
		f, faulted := fault.?
		if c.faults {
			testing.expectf(t, faulted && f.kind == .Bad_Char && f.at == c.at && html.Detail(f.detail) == .Encoding, "%q: %v", c.src, fault)
		} else {
			testing.expectf(t, !faulted, "%q: %v", c.src, fault)
			html.internal_tree_destroy(&tree)
		}
	}
	tree, fault := html.internal_build(transmute([]u8)string("\xef\xbb\xbfx"))
	defer html.internal_tree_destroy(&tree)
	testing.expect(t, fault == nil)
	body := tree.nodes[tree.nodes[tree.nodes[1].first].last]
	testing.expect_value(t, html.internal_decoded(&tree, tree.pieces[tree.nodes[body.first].a].span), "x")
}
