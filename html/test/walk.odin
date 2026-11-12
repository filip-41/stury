// The tokens a walk over the tree passes, and the parse errors `validate` names.
package html_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import html ".."
import walktest "../../walktest"

@(private)
tokens_of :: proc(text: string, spec := html.Spec.Fragment, opts := html.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, fault: Maybe(core.Fault)) {
	r := walktest.Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
	}
	strings.builder_init(&r.out, context.temp_allocator)
	switch spec {
	case .Document:
		hi, fault = html.walk(r.text, 0, .Document, opts, &r, nil, walktest.log_token)
	case .Fragment:
		hi, fault = html.walk(r.text, 0, .Fragment, opts, &r, nil, walktest.log_token)
	}
	return walktest.log_line(&r), hi, fault
}

// The fault `validate` returns for `text`, as `code@at`, or "" for a text it accepts.
@(private)
refusal :: proc(text: string, spec := html.Spec.Document, opts := html.Options{}) -> string {
	f, bad := walktest.fault_in(html.validate(transmute([]u8)text, spec, opts))
	if !bad {
		return ""
	}
	return fmt.tprintf("%s@%d", walktest.rule_code(f), f.at)
}

@(test)
a_walk_gives_the_tree_in_preorder :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got, hi, fault := tokens_of("<a>hi</a>")
	testing.expect(t, fault == nil)
	testing.expect_value(t, hi, 9)
	testing.expect_value(t, got, "Object Key:a Plain:hi End")
	got, _, _ = tokens_of("<p>x", .Document)
	testing.expect_value(t, got, "Object Key Object Key Plain Key Object Key:p Plain:x End End End")
	got, _, _ = tokens_of("<!DOCTYPE html><html lang=en><!--c--><p class='a b'>one<br>two</p>", .Document)
	testing.expect_value(t, got, "Doctype:<!DOCTYPE html> Object Key:html Attribute:lang=en Comment:<!--c--> Object:<html lang=en> Key Plain Key Object Key:p Attribute:class='a b' Object:<p class='a b'> Key Plain:one Key:br Plain Key Plain:two End End End End")
	got, _, _ = tokens_of("<table>a<tr><td>1</td></tr>b</table>")
	testing.expect_value(t, got, "Object Key Plain*:a<tr><td>1</td></tr>b Key:table Object:<table> Key Object Key:tr Object:<tr> Key:td Plain:1 End End End End")
	got, _, _ = tokens_of("<p>a<!--x-->b <i>c</i></p>")
	testing.expect_value(t, got, "Object Key:p Comment:<!--x--> Object:<p> Key Plain*:a<!--x-->b  Key:i Plain:c End End")
}

@(test)
a_hook_skips_and_stops :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got, _, _ := tokens_of("<a><b x=1><c>1</c></b><d>2</d></a>", skip = "b")
	testing.expect_value(t, got, "Object Key:a Object:<a> Key:b Key:d Plain:2 End End")
	hi: u64
	fault: Maybe(core.Fault)
	got, hi, fault = tokens_of("<a><b>1</b><d>2</d></a>", stop = 4)
	testing.expect(t, fault == nil)
	testing.expect_value(t, got, "Object Key:a Object:<a> Key:b")
	testing.expect_value(t, hi, 5)
}

@(test)
validate_names_the_first_parse_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, refusal("<!DOCTYPE html><title>x</title><p>y</p>"), "")
	testing.expect_value(t, refusal("<p>x"), "html.missing_doctype@0")
	testing.expect_value(t, refusal("<!DOCTYPE html><p a=1 a=2>"), "html.duplicate_attribute@23")
	testing.expect_value(t, refusal("<!DOCTYPE html><p>&notit;</p>"), "html.missing_semicolon_after_character_reference@22")
	testing.expect_value(t, refusal("<!DOCTYPE html><!-- x"), "html.eof_in_comment@21")
	testing.expect_value(t, refusal("<!DOCTYPE html></b>"), "html.unexpected_end_tag@15")
	testing.expect_value(t, refusal("<b>x</b>", .Fragment), "")
	f, _ := walktest.fault_in(html.validate(transmute([]u8)string("<!DOCTYPE html><div"), .Document))
	testing.expect_value(t, f.kind, core.Fault_Kind.Truncated)
	// Every text builds, whatever its parse errors.
	doc, err := html.build(transmute([]u8)string("</x><p a=1 a=2>&notit;<!-- x"), .Document)
	walktest.expect_nil(t, err)
	core.destroy(&doc)
}

@(test)
a_build_refuses_only_what_no_tree_holds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	deep := strings.repeat("<div>", 40, context.temp_allocator)
	_, err := html.build(transmute([]u8)deep, .Fragment, {max_depth = 10})
	f, bad := walktest.fault_in(err)
	testing.expect(t, bad)
	testing.expect_value(t, f.kind, core.Fault_Kind.Too_Deep)
	testing.expect_value(t, refusal(deep, .Fragment, {max_depth = 10}), fmt.tprintf("too_deep@%d", 9 * 5))
	_, err = html.build(transmute([]u8)string("<meta charset=latin2><p>caf\xe9"), .Document)
	f, bad = walktest.fault_in(err)
	testing.expect(t, bad)
	testing.expect_value(t, walktest.rule_code(f), "html.encoding")
	_, fault := html.walk(transmute([]u8)string("\xfe\xffx"), 0, .Document, {}, &walktest.Token_Log{}, nil, walktest.log_token)
	testing.expect(t, fault != nil)
}
