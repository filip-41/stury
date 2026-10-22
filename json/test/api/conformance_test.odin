package json_tests

// JSONTestSuite (nst/JSONTestSuite `test_parsing/`, vendored under `json/test/conformance/`, commit in its UPSTREAM file):
// `y_` files must be accepted, `n_` files refused, and an `i_` file's result is implementation-defined, so it is pinned in
// `i_verdicts` and any change shows up as a diff there. `validate` and a `.Strict` scan must agree on every file.

import json "../.."
import "core:strings"
import "core:testing"

@(private = "file")
corpus := #load_directory("../conformance/JSONTestSuite/test_parsing")

@(private = "file")
I_VERDICT :: struct {
	file:   string,
	accept: bool,
}

@(private = "file")
i_verdicts := [?]I_VERDICT{
	{"i_number_double_huge_neg_exp.json", true},
	{"i_number_huge_exp.json", false}, // Limit_Scale at 1
	{"i_number_neg_int_huge_exp.json", false}, // Limit_Scale at 1
	{"i_number_pos_double_huge_exp.json", false}, // Limit_Scale at 1
	{"i_number_real_neg_overflow.json", false}, // Limit_Scale at 1
	{"i_number_real_pos_overflow.json", false}, // Limit_Scale at 1
	{"i_number_real_underflow.json", false}, // Limit_Scale at 1
	{"i_number_too_big_neg_int.json", true},
	{"i_number_too_big_pos_int.json", true},
	{"i_number_very_big_negative_int.json", true},
	{"i_object_key_lone_2nd_surrogate.json", false}, // Bad_Escape at 2
	{"i_string_1st_surrogate_but_2nd_missing.json", false}, // Bad_Escape at 2
	{"i_string_1st_valid_surrogate_2nd_invalid.json", false}, // Bad_Escape at 2
	{"i_string_UTF-16LE_with_BOM.json", false}, // Bad_Char at 0
	{"i_string_UTF-8_invalid_sequence.json", false}, // Bad_Char at 7
	{"i_string_UTF8_surrogate_U+D800.json", false}, // Bad_Char at 2
	{"i_string_incomplete_surrogate_and_escape_valid.json", false}, // Bad_Escape at 2
	{"i_string_incomplete_surrogate_pair.json", false}, // Bad_Escape at 2
	{"i_string_incomplete_surrogates_escape_valid.json", false}, // Bad_Escape at 2
	{"i_string_invalid_lonely_surrogate.json", false}, // Bad_Escape at 2
	{"i_string_invalid_surrogate.json", false}, // Bad_Escape at 2
	{"i_string_invalid_utf-8.json", false}, // Bad_Char at 2
	{"i_string_inverted_surrogates_U+1D11E.json", false}, // Bad_Escape at 2
	{"i_string_iso_latin_1.json", false}, // Bad_Char at 2
	{"i_string_lone_second_surrogate.json", false}, // Bad_Escape at 2
	{"i_string_lone_utf8_continuation_byte.json", false}, // Bad_Char at 2
	{"i_string_not_in_unicode_range.json", false}, // Bad_Char at 2
	{"i_string_overlong_sequence_2_bytes.json", false}, // Bad_Char at 2
	{"i_string_overlong_sequence_6_bytes.json", false}, // Bad_Char at 2
	{"i_string_overlong_sequence_6_bytes_null.json", false}, // Bad_Char at 2
	{"i_string_truncated-utf-8.json", false}, // Bad_Char at 2
	{"i_string_utf16BE_no_BOM.json", false}, // Bad_Char at 0
	{"i_string_utf16LE_no_BOM.json", false}, // Bad_Char at 1
	{"i_structure_500_nested_arrays.json", true},
	{"i_structure_UTF-8_BOM_empty_object.json", true},
}

@(private = "file")
file_faults :: proc(src: []byte) -> (by_validate, by_scan: Maybe(json.Error)) {
	return json.validate(src), verdict_under(src, .Strict, {})
}

@(test)
test_jsontestsuite_y_and_n_files_are_judged_as_the_suite_says :: proc(t: ^testing.T) {
	y_seen, n_seen: int
	for f in corpus {
		want_accept := strings.has_prefix(f.name, "y_")
		if !want_accept && !strings.has_prefix(f.name, "n_") {
			continue
		}
		y_seen += int(want_accept)
		n_seen += int(!want_accept)
		src := f.data
		by_validate, by_scan := file_faults(src)
		testing.expectf(t, (by_validate == nil) == want_accept, "%s: validate gave %v, want accept=%v", f.name, by_validate, want_accept)
		testing.expectf(t, (by_scan == nil) == want_accept, "%s: scan(.Strict) gave %v, want accept=%v", f.name, by_scan, want_accept)
		testing.expectf(t, by_validate == by_scan, "%s: validate %v, scan %v", f.name, by_validate, by_scan)
		// The deep reading a raised cap takes agrees, but where the default cap refused first.
		raised := json.validate(src, limits = {max_depth = json.DEPTH_CEILING})
		if e, bad := by_validate.?; bad && e.kind == .Too_Deep {
			testing.expectf(t, raised != nil, "%s: refused past MAX_DEPTH, but accepted under a raised cap", f.name)
		} else {
			testing.expectf(t, raised == by_validate, "%s: validate %v, raised cap %v", f.name, by_validate, raised)
		}
	}
	// A moved or truncated corpus must not read as a pass.
	testing.expect_value(t, y_seen, 95)
	testing.expect_value(t, n_seen, 188)
}

@(test)
test_jsontestsuite_i_files_keep_their_recorded_verdict :: proc(t: ^testing.T) {
	table := i_verdicts
	seen: [len(table)]bool
	for f in corpus {
		if !strings.has_prefix(f.name, "i_") {
			continue
		}
		src := f.data
		by_validate, by_scan := file_faults(src)
		testing.expectf(t, by_validate == by_scan, "%s: validate %v, scan %v", f.name, by_validate, by_scan)

		row := -1
		for r, i in table {
			if r.file == f.name {
				row = i
			}
		}
		if row < 0 {
			testing.expectf(t, false, "%s has no recorded verdict (validate gave %v)", f.name, by_validate)
			continue
		}
		seen[row] = true
		testing.expectf(t, (by_validate == nil) == table[row].accept, "%s: recorded accept=%v, validate gave %v", f.name, table[row].accept, by_validate)
	}
	for ok, i in seen {
		testing.expectf(t, ok, "%s is recorded but not in the corpus", table[i].file)
	}
}

// `unmarshal` into a `Raw` is a validating walk too: it accepts what `validate` accepts, refuses with the same
// kind at the same offset, and the `Raw` is the document without its outer whitespace.
@(test)
test_jsontestsuite_unmarshal_raw_agrees_with_validate :: proc(t: ^testing.T) {
	seen := 0
	for f in corpus {
		src := f.data
		want := json.validate(src)
		for lazy in ([?]bool{false, true}) {
			r: json.Raw
			err, read_refused := json.unmarshal(src, &r, {strictness = .Lazy if lazy else .Strict}, nil, context.temp_allocator).?
			if w, refused := want.?; refused {
				testing.expectf(t, err.kind == .Syntax && err.syntax == w.kind && err.offset == w.offset,
					"%s (lazy=%v): unmarshal %v/%v at %d, validate %v at %d", f.name, lazy, err.kind, err.syntax, err.offset, w.kind, w.offset)
			} else {
				testing.expectf(t, !read_refused, "%s (lazy=%v): unmarshal %v at %d", f.name, lazy, err.kind, err.offset)
				// `validate` skips a leading UTF-8 BOM (i_structure_UTF-8_BOM_empty_object.json), and so does the Raw.
				doc := strings.trim_prefix(string(src), "\xef\xbb\xbf")
				testing.expectf(t, string(r) == strings.trim(doc, " \t\r\n"), "%s: Raw is not the trimmed document", f.name)
			}
		}
		seen += 1
		free_all(context.temp_allocator)
	}
	testing.expect(t, seen == 95 + 188 + 35, "the corpus is all there")
}
