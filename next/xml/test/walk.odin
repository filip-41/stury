// The tokens a walk passes and the faults it returns, for small texts.
package xml_tests

import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

@(test)
a_text_only_element_is_its_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, hi, err := tokens_of("<a>hi</a>")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, hi, 9)
	testing.expect_value(t, got, "Object Key:a String:hi End")
}

@(test)
an_empty_element_is_null :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of("<a/>")
	testing.expect_value(t, got, "Object Key:a Null End")
	got, _, _ = tokens_of("<a></a>")
	testing.expect_value(t, got, "Object Key:a Null End")
}

@(test)
attributes_are_facts_after_the_key :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of(`<a x="1" y='2'>t</a>`)
	testing.expect_value(t, got, `Object Key:a Attribute:x="1" Attribute:y='2' String:t End`)
}

@(test)
an_element_with_children_is_an_object :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of("<r><a>1</a><b/></r>")
	testing.expect_value(t, got, "Object Key:r Object:<r> Key:a String:1 Key:b Null End:</r> End")
}

@(test)
text_between_children_is_a_text_member :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of("<r>x<a/>y</r>")
	testing.expect_value(t, got, "Object Key:r Object:<r> Key String:x Key:a Null Key String:y End:</r> End")
}

@(test)
whitespace_between_children_is_not_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of("<r>\n  <a/>\n  <b/>\n</r>")
	testing.expect_value(t, got, "Object Key:r Object:<r> Key:a Null Key:b Null End:</r> End")
}

@(test)
references_and_cdata_mark_the_run_for_decoding :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of("<a>x&amp;y</a>")
	testing.expect_value(t, got, "Object Key:a String*:x&amp;y End")
	got, _, _ = tokens_of("<a><![CDATA[<b>]]></a>")
	testing.expect_value(t, got, "Object Key:a String*:<![CDATA[<b>]]> End")
	got, _, _ = tokens_of("<a>x\r\ny</a>")
	testing.expect_value(t, got, "Object Key:a String*:x\r\ny End")
}

@(test)
comments_follow_the_position_rule :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of("<!--p--><r><!--a--><x/> <!--i-->\n<!--n--><y/>\n<!--f--></r><!--e-->")
	testing.expect_value(
		t,
		got,
		"Object Comment:<!--p--> Key:r Object:<r> Comment:<!--a--> Key:x Null Inline:<!--i--> Comment:<!--n--> Key:y Null Foot:<!--f--> End:</r> Inline:<!--e--> End",
	)
}

// A comment before an element's first child is the child's, one in an element with no child element is the element's
// foot, and the prolog's comments are the document's up to the last blank line and the root element's past it.
@(test)
comments_belong_to_the_first_child_and_the_empty_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of("<!--a-->\n\n<!--b-->\n<r><!--c--><x>1</x><e><!--z--></e><t>v<!--w--></t></r>")
	testing.expect_value(
		t,
		got,
		"Comment:<!--a--> Object Comment:<!--b--> Key:r Object:<r> Comment:<!--c--> Key:x String:1 Key:e Foot:<!--z--> Null:<!--z--> Key:t Foot:<!--w--> String*:v<!--w--> End:</r> End",
	)
}

@(test)
the_declaration_instructions_and_the_doctype_stand_before_the_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, _ := tokens_of(`<?xml version="1.0"?><?pi data?><!DOCTYPE r SYSTEM "r.dtd"><r/>`)
	testing.expect_value(t, got, "Directive:<?xml version=\"1.0\"?> Instruction:<?pi data?> Doctype:<!DOCTYPE r SYSTEM \"r.dtd\"> Object Key:r Null End")
}

// A hook skips a container, not a key, so the skip is answered at the object of the member it names.
@(test)
a_skip_hides_the_value_and_its_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, err := tokens_of("<r><a><b>1</b></a><c>2</c></r>", skip = "a")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, got, "Object Key:r Object:<r> Key:a Object:<a> End:</a> Key:c String:2 End:</r> End")
}

@(test)
a_stop_ends_the_walk_with_no_fault :: proc(t: ^testing.T) {
	testkit.deadline(t)
	_, _, err := tokens_of("<r><a>1</a>", stop = 3)
	testing.expect_value(t, err, nil)
}

@(test)
well_formed_texts_are_accepted :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
	testkit.deadline(t)
	Case :: struct {
		text:  string,
		fault: string,
	}
	for c in ([]Case {
			{"", "truncated@0"},
			{"   ", "truncated@3"},
			{"<a>", "truncated@3"},
			{"<a", "truncated@2"},
			{"<a></b>", "mismatched_tag@5"},
			{"<a></ab>", "mismatched_tag@6"},
			{"<a/><b/>", "junk_after_root@4"},
			{"<a/>x", "junk_after_root@4"},
			{"x<a/>", "prolog@0"},
			{"<a b='1' b='2'/>", "duplicate_attribute@9"},
			{"<a b=1/>", "quote@5"},
			{"<a b/>", "equals@4"},
			{"<a b='<'/>", "attribute_lt@6"},
			{"<a>]]></a>", "cdata_end@3"},
			{"<a>&nbsp;</a>", "undeclared_entity@3"},
			{"<a>&#0;</a>", "char_reference@3"},
			{"<a>&#xD800;</a>", "char_reference@3"},
			{"<a>& </a>", "reference@3"},
			{"<a>\x01</a>", "control_char@3"},
			{"<a>\xff</a>", "invalid_utf8@3"},
			{"<a>\xef\xbf\xbe</a>", "non_char@3"},
			{"<a><!-- -- --></a>", "comment_dashes@8"},
			{"<a><!-- a ---></a>", "comment_dashes@10"},
			{"<a><?xml x?></a>", "reserved_target@5"},
			{"<a><?1 x?></a>", "instruction@5"},
			{"<?xml version='2.0'?><a/>", "declaration@5"},
			{"<?xml version='1.0' encoding='latin1'?><a/>", "encoding@19"},
			{"<a/><?xml version='1.0'?>", "reserved_target@6"},
			{"<a x='1'y='2'/>", "space@8"},
			{"<1/>", "name@1"},
			{"<a><!x></a>", "markup@3"},
		}) {
		testing.expect_value(t, refusal(c.text), c.fault)
	}
}

@(test)
nesting_past_the_limit_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.repeat("<a>", 5, context.temp_allocator)
	err := xml.validate(transmute([]u8)text, .Xml, {budget = {depth = 4}})
	e, bad := err.(tape.Exceeded)
	testing.expect_value(t, bad, true)
	testing.expect_value(t, e.kind, tape.Budget_Kind.Depth)
}
