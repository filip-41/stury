// The tokens a walk passes and the faults it returns, for small texts.
package xml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import xml ".."
import walktest "../../walktest"

@(private)
tokens_of :: proc(text: string, opts := xml.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, fault: Maybe(core.Fault)) {
	r := walktest.Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
	}
	strings.builder_init(&r.out, context.temp_allocator)
	hi, fault = xml.walk(r.text, 0, .Xml, opts, &r, nil, walktest.log_token)
	return walktest.log_line(&r), hi, fault
}

// The fault `validate` returns for `text`, as `code@at`, or "" for a text it accepts.
@(private)
refusal :: proc(text: string) -> string {
	f, bad := walktest.fault_in(xml.validate(transmute([]u8)text, .Xml))
	if !bad {
		return ""
	}
	return fmt.tprintf("%s@%d", walktest.rule_code(f), f.at)
}

@(test)
a_text_only_element_is_its_text :: proc(t: ^testing.T) {
	got, hi, fault := tokens_of("<a>hi</a>")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, hi, 9)
	testing.expect_value(t, got, "Object Key:a Plain:hi End")
}

@(test)
an_empty_element_is_null :: proc(t: ^testing.T) {
	got, _, _ := tokens_of("<a/>")
	testing.expect_value(t, got, "Object Key:a Plain End")
	got, _, _ = tokens_of("<a></a>")
	testing.expect_value(t, got, "Object Key:a Plain End")
}

@(test)
attributes_are_facts_after_the_key :: proc(t: ^testing.T) {
	got, _, _ := tokens_of(`<a x="1" y='2'>t</a>`)
	testing.expect_value(t, got, `Object Key:a Attribute:x="1" Attribute:y='2' Plain:t End`)
}

@(test)
an_element_with_children_is_an_object :: proc(t: ^testing.T) {
	got, _, _ := tokens_of("<r><a>1</a><b/></r>")
	testing.expect_value(t, got, "Object Key:r Object:<r> Key:a Plain:1 Key:b Plain End:</r> End")
}

@(test)
text_between_children_is_a_text_member :: proc(t: ^testing.T) {
	got, _, _ := tokens_of("<r>x<a/>y</r>")
	testing.expect_value(t, got, "Object Key:r Object:<r> Key Plain:x Key:a Plain Key Plain:y End:</r> End")
}

@(test)
whitespace_between_children_is_not_text :: proc(t: ^testing.T) {
	got, _, _ := tokens_of("<r>\n  <a/>\n  <b/>\n</r>")
	testing.expect_value(t, got, "Object Key:r Object:<r> Key:a Plain Key:b Plain End:</r> End")
}

@(test)
references_and_cdata_mark_the_run_for_decoding :: proc(t: ^testing.T) {
	got, _, _ := tokens_of("<a>x&amp;y</a>")
	testing.expect_value(t, got, "Object Key:a Plain*:x&amp;y End")
	got, _, _ = tokens_of("<a><![CDATA[<b>]]></a>")
	testing.expect_value(t, got, "Object Key:a Plain*:<![CDATA[<b>]]> End")
	got, _, _ = tokens_of("<a>x\r\ny</a>")
	testing.expect_value(t, got, "Object Key:a Plain*:x\r\ny End")
}

@(test)
comments_follow_the_position_rule :: proc(t: ^testing.T) {
	got, _, _ := tokens_of("<!--p--><r><!--a--><x/> <!--i-->\n<!--n--><y/>\n<!--f--></r><!--e-->")
	testing.expect_value(
		t,
		got,
		"Comment:<!--p--> Object Key:r Comment:<!--a--> Object:<r> Key:x Plain Inline:<!--i--> Comment:<!--n--> Key:y Plain Foot:<!--f--> End:</r> Inline:<!--e--> End",
	)
}

@(test)
instructions_and_the_doctype_stand_before_the_document :: proc(t: ^testing.T) {
	got, _, _ := tokens_of(`<?xml version="1.0"?><?pi data?><!DOCTYPE r SYSTEM "r.dtd"><r/>`)
	testing.expect_value(t, got, "Instruction:<?pi data?> Doctype:<!DOCTYPE r SYSTEM \"r.dtd\"> Object Key:r Plain End")
}

@(test)
a_skip_hides_the_value_and_its_end :: proc(t: ^testing.T) {
	got, _, fault := tokens_of("<r><a><b>1</b></a><c>2</c></r>", skip = "a")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Object Key:r Object:<r> Key:a Key:c Plain:2 End:</r> End")
}

@(test)
a_stop_ends_the_walk_with_no_fault :: proc(t: ^testing.T) {
	_, _, fault := tokens_of("<r><a>1</a>", stop = 3)
	testing.expect_value(t, fault == nil, true)
}

@(test)
well_formed_texts_are_accepted :: proc(t: ^testing.T) {
	for text in ([]string {
			"<a/>",
			"\xef\xbb\xbf<a/>",
			"<a b='1'/>",
			"<a>&#65;&#x42;&lt;&gt;&amp;&apos;&quot;</a>",
			"<a>é中\U0001F600</a>",
			"<élément à=\"x\"/>",
			"<a b = \"1\" c='2' />",
			"<?xml version='1.0' encoding='UTF-8' standalone='yes'?>\n<a/>\n<!-- c -->\n<?p?>\n",
			"<a><!-- - --></a>",
			"<a>]</a>",
			"<a>]]</a>",
			"<a><![CDATA[]]]></a>",
			"<!DOCTYPE a PUBLIC \"-//X//Y\" \"y.dtd\"><a/>",
		}) {
		testing.expect_value(t, refusal(text), "")
	}
}

@(test)
ill_formed_texts_are_refused_at_their_byte :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		fault: string,
	}
	for c in ([]Case {
			{"", "truncated@0"},
			{"   ", "truncated@3"},
			{"<a>", "truncated@3"},
			{"<a", "truncated@2"},
			{"<a></b>", "xml.mismatched_tag@5"},
			{"<a></ab>", "xml.mismatched_tag@6"},
			{"<a/><b/>", "xml.junk_after_root@4"},
			{"<a/>x", "xml.junk_after_root@4"},
			{"x<a/>", "xml.prolog@0"},
			{"<a b='1' b='2'/>", "xml.duplicate_attribute@9"},
			{"<a b=1/>", "xml.quote@5"},
			{"<a b/>", "xml.equals@4"},
			{"<a b='<'/>", "xml.attribute_lt@6"},
			{"<a>]]></a>", "xml.cdata_end@3"},
			{"<a>&nbsp;</a>", "xml.undeclared_entity@3"},
			{"<a>&#0;</a>", "xml.char_reference@3"},
			{"<a>&#xD800;</a>", "xml.char_reference@3"},
			{"<a>& </a>", "xml.reference@3"},
			{"<a>\x01</a>", "xml.control_char@3"},
			{"<a>\xff</a>", "xml.invalid_utf8@3"},
			{"<a>\xef\xbf\xbe</a>", "xml.non_char@3"},
			{"<a><!-- -- --></a>", "xml.comment_dashes@8"},
			{"<a><!-- a ---></a>", "xml.comment_dashes@10"},
			{"<a><?xml x?></a>", "xml.reserved_target@5"},
			{"<a><?1 x?></a>", "xml.instruction@5"},
			{"<?xml version='2.0'?><a/>", "xml.declaration@5"},
			{"<?xml version='1.0' encoding='latin1'?><a/>", "xml.encoding@19"},
			{"<a/><?xml version='1.0'?>", "xml.reserved_target@6"},
			{"<a x='1'y='2'/>", "xml.space@8"},
			{"<1/>", "xml.name@1"},
			{"<a><!x></a>", "xml.markup@3"},
		}) {
		testing.expect_value(t, refusal(c.text), c.fault)
	}
}

@(test)
nesting_past_the_limit_is_refused :: proc(t: ^testing.T) {
	text := strings.repeat("<a>", 5, context.temp_allocator)
	f, bad := walktest.fault_in(xml.validate(transmute([]u8)text, .Xml, {max_depth = 4}))
	testing.expect_value(t, bad, true)
	testing.expect_value(t, f.kind, core.Fault_Kind.Too_Deep)
}
