// Texts that cross the 64-byte blocks, the attribute table and the frame stack's growth.
package xml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import xml ".."

@(test)
a_fault_is_found_at_every_offset_across_blocks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pads := [?]string{"a", "é", "中", "\U0001F600", " ", "&amp;", "\n"}
	for pad in pads {
		for n in 0 ..< 200 {
			body := strings.repeat(pad, n, context.temp_allocator)
			whole := fmt.tprintf("<r>%s</r>", body)
			testing.expect_value(t, refusal(whole), "")
			whole = fmt.tprintf("<r a='%s'>%s</r>", body, body)
			testing.expect_value(t, refusal(whole), "")
			bad := fmt.tprintf("<r>%s\x01</r>", body)
			testing.expect_value(t, refusal(bad), fmt.tprintf("xml.control_char@%d", 3 + n * len(pad)))
			bad = fmt.tprintf("<r a='%s<'/>", body)
			testing.expect_value(t, refusal(bad), fmt.tprintf("xml.attribute_lt@%d", 6 + n * len(pad)))
			bad = fmt.tprintf("<r>%s\xff</r>", body)
			testing.expect_value(t, refusal(bad), fmt.tprintf("xml.invalid_utf8@%d", 3 + n * len(pad)))
		}
	}
}

@(test)
a_truncated_multibyte_rune_is_refused_at_its_head :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for n in 0 ..< 130 {
		body := strings.repeat("a", n, context.temp_allocator)
		for tail in ([]string{"\xe4\xb8", "\xf0\x9f\x98", "\xc3"}) {
			text := fmt.tprintf("<r>%s%s</r>", body, tail)
			testing.expect_value(t, refusal(text), fmt.tprintf("xml.invalid_utf8@%d", 3 + n))
		}
	}
}

@(test)
many_attributes_are_checked_for_repeats :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for count in ([]int{15, 16, 17, 40, 300}) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<r")
		for i in 0 ..< count {
			fmt.sbprintf(&b, " n%d='v'", i)
		}
		plain := fmt.tprintf("%s/>", strings.to_string(b))
		testing.expect_value(t, refusal(plain), "")
		for again in ([]int{0, count / 2, count - 1}) {
			twice := fmt.tprintf("%s n%d='w'/>", strings.to_string(b), again)
			got := refusal(twice)
			testing.expectf(t, strings.has_prefix(got, "xml.duplicate_attribute@"), "%d attributes, repeat of %d: %s", count, again, got)
		}
	}
}

@(test)
deep_nesting_grows_the_frame_stack :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for depth in ([]int{2, 63, 64, 65, 1000, 1024, 1025, 20000}) {
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< depth {
			strings.write_string(&b, "<a x='1'>")
		}
		strings.write_string(&b, "t")
		for _ in 0 ..< depth {
			strings.write_string(&b, "</a>")
		}
		testing.expect(t, xml.validate(transmute([]u8)strings.to_string(b), .Xml, {max_depth = u32(depth)}) == nil)
		testing.expect(t, xml.validate(transmute([]u8)strings.to_string(b), .Xml, {max_depth = u32(depth - 1)}) != nil)
	}
}

@(test)
a_name_of_the_fifth_edition_is_accepted :: proc(t: ^testing.T) {
	for text in ([]string{"<\U00010000z/>", "<a\xdb\xa9/>", "<a\xef\xbb\xbf/>", "<a\xc2\xb7/>", "<_/>"}) {
		testing.expect_value(t, refusal(text), "")
	}
	for text in ([]string{"<\xc2\xb7a/>", "<-a/>", "<.a/>", "<\xcc\x80a/>"}) {
		testing.expect_value(t, refusal(text), "xml.name@1")
	}
	testing.expect_value(t, refusal("<a\xc3\x97/>"), "xml.space@2")
	testing.expect_value(t, refusal("<:a/>"), "xml.qualified_name@0")
}
