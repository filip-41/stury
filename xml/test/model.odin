// A model and a JSON Schema read an XML text through `xml.checks`: attributes and child elements as members, and the
// text of an element with attributes as its `#text` member.
package xml_tests

import "core:testing"
import core "../../core"
import typed "../../core/typed"
import schema "../../core/schema"
import json "../../json"
import xml ".."
import model "../../core/model"
import walktest "../../walktest"

@(private = "file")
Price :: struct {
	currency: string `model:"pattern=^[A-Z]+$"`,
	amount:   f64 `xml:"#text" model:">0"`,
}

@(private = "file")
Item :: struct {
	id:    i64,
	name:  string `model:"len>=3"`,
	stock: bool `model:"optional"`,
	note:  string `model:"optional"`,
	price: Price,
}

@(private = "file")
Order :: struct {
	item: Item,
}

@(test)
a_model_loads_attributes_and_elements_as_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, cerr := model.compile(&reg, Order, xml.checks(.Xml))
	walktest.expect_nil(t, cerr)
	text := `<?xml version="1.0"?>
<!DOCTYPE item [<!ENTITY co "Acme &amp; Sons"><!ATTLIST item stock (true|false) "true">]>
<item id="7">
  <name>&co;</name>
  <note>a <![CDATA[<b>]]> c</note>
  <price currency="EUR">12.50</price>
</item>`
	v: Order
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	err := model.load(&m, transmute([]u8)string(text), &v, &sink)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(sink.entries), 0)
	testing.expect_value(t, v.item.id, 7)
	testing.expect_value(t, v.item.name, "Acme & Sons")
	testing.expect_value(t, v.item.stock, true)
	testing.expect_value(t, v.item.note, "a <b> c")
	testing.expect_value(t, v.item.price.currency, "EUR")
	testing.expect_value(t, v.item.price.amount, 12.5)
}

@(test)
a_model_reports_every_rule_an_xml_text_fails :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, cerr := model.compile(&reg, Order, xml.checks(.Xml))
	walktest.expect_nil(t, cerr)
	text := `<item id="x"><name>ab</name><price currency="eur">-1</price></item>`
	v: Order
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	err := model.load(&m, transmute([]u8)string(text), &v, &sink)
	testing.expect(t, err != nil)
	kinds := [?]core.Typed_Error_Kind{.Wrong_Kind, .Too_Short, .No_Match, .Below_Minimum}
	testing.expect_value(t, len(sink.entries), len(kinds))
	for e, i in sink.entries[:min(len(sink.entries), len(kinds))] {
		testing.expect_value(t, e.kind, kinds[i])
	}
	// A text that is not well formed is the walk's fault, and a repeated element is refused unless the load says which
	// one it reads.
	_, bad := walktest.fault_in(model.load(&m, transmute([]u8)string(`<item id="1"><name>abc</name></item`), &v))
	testing.expect(t, bad)
	twice := `<item id="1"><name>abc</name><name>abd</name><price currency="EUR">1</price></item>`
	f, repeated := walktest.fault_in(model.load(&m, transmute([]u8)string(twice), &v))
	testing.expect(t, repeated)
	testing.expect_value(t, f.kind, core.Fault_Kind.Duplicate_Key)
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(twice), &v, nil, {dups = .Last}))
	testing.expect_value(t, v.item.name, "abd")
}

@(test)
a_schema_checks_an_xml_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text := `{"type": "object", "required": ["item"], "properties": {"item": {"type": "object", "required": ["id", "name"], "additionalProperties": false,
		"properties": {"id": {"type": "integer", "minimum": 1}, "name": {"type": "string", "minLength": 3}, "tag": {"type": "array", "items": {"enum": ["a", "b"]}, "maxItems": 2},
		"price": {"type": "object", "properties": {"currency": {"enum": ["EUR", "USD"]}, "#text": {"type": "number"}}, "required": ["currency", "#text"]}}}}}`
	s, serr := json.load_schema(transmute([]u8)string(text))
	walktest.expect_nil(t, serr)
	bound, berr := xml.bind_schema(s, .Xml)
	walktest.expect_nil(t, berr)
	defer schema.unbind(&bound)
	cases := [?]struct {
		text:   string,
		errors: int,
	} {
		{`<item id="7"><name>abc</name><tag>a</tag><tag>b</tag><price currency="EUR">1.5</price></item>`, 0},
		{`<item id="0"><name>ab</name><tag>a</tag><tag>c</tag><tag>b</tag><price currency="PLN">x</price><extra/></item>`, 7},
		{`<item/>`, 2},
	}
	for c in cases {
		sink: typed.Sink
		defer typed.sink_destroy(&sink)
		err := schema.check(&bound, transmute([]u8)c.text, &sink)
		testing.expectf(t, len(sink.entries) == c.errors && (err == nil) == (c.errors == 0), "%s: %d entries, %v", c.text, len(sink.entries), err)
	}
	_, bad := walktest.fault_in(schema.check(&bound, transmute([]u8)string(`<item>`)))
	testing.expect(t, bad)
}

// A document built once is checked by its nodes, and a text an entity expands past its span is judged whole.
@(test)
a_built_document_is_checked_by_a_model_and_a_schema :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	Note :: struct {
		lang: string `model:"len<=2"`,
		text: string `xml:"#text" model:"len<=20"`,
	}
	reg: model.Registry
	m, cerr := model.compile(&reg, struct{ note: Note }, xml.checks(.Xml))
	walktest.expect_nil(t, cerr)
	text := "<!DOCTYPE note [<!ENTITY e 'twelve bytes'><!ENTITY f '&e;&e;&e;&e;&e;&e;&e;&e;'><!ENTITY g '&f;&f;&f;&f;'>]><note lang='&e;'>&g;</note>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	v: struct{ note: Note }
	sink: typed.Sink
	typed.check_document(&doc, core.ROOT, &v, type_of(v), &m.load_plan, {dups = .Last, sink = &sink})
	testing.expect_value(t, len(sink.entries), 2)
	testing.expect_value(t, v.note.lang, "twelve bytes")
	testing.expect_value(t, len(v.note.text), 12 * 32)
	s, serr := json.load_schema(transmute([]u8)string(`{"properties": {"note": {"properties": {"lang": {"maxLength": 12}, "#text": {"minLength": 385}}}}}`))
	walktest.expect_nil(t, serr)
	bound, berr := xml.bind_schema(s, .Xml)
	walktest.expect_nil(t, berr)
	judged: typed.Sink
	testing.expect(t, schema.check_node(&bound, &doc, core.ROOT, &judged) != nil)
	testing.expect_value(t, len(judged.entries), 1)
	testing.expect_value(t, judged.entries[0].kind, core.Typed_Error_Kind.Too_Short)
}
