// A model and a JSON Schema read an HTML text through `html.checks` as they read XML: attributes and child elements as
// members, and the text of an element with attributes as its `#text` member.
package html_tests

import "core:testing"
import core "../../core"
import typed "../../core/typed"
import schema "../../core/schema"
import json "../../json"
import html ".."
import model "../../core/model"
import walktest "../../walktest"

@(private = "file")
Price :: struct {
	currency: string `model:"pattern=^[A-Z]+$"`,
	amount:   f64 `html:"#text" model:">0"`,
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
	m, cerr := model.compile(&reg, Order, html.checks(.Fragment))
	walktest.expect_nil(t, cerr)
	text := `<ITEM id=7 stock=true>
  <name>Acme &amp; Sons</name>
  <note>a <!-- c --> c</note>
  <price currency=EUR>12.50</price>
</ITEM>`
	v: Order
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	err := model.load(&m, transmute([]u8)string(text), &v, &sink)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(sink.entries), 0)
	testing.expect_value(t, v.item.id, 7)
	testing.expect_value(t, v.item.name, "Acme & Sons")
	testing.expect_value(t, v.item.stock, true)
	testing.expect_value(t, v.item.note, "a  c")
	testing.expect_value(t, v.item.price.currency, "EUR")
	testing.expect_value(t, v.item.price.amount, 12.5)
}

@(test)
a_model_reports_every_rule_an_html_text_fails :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, cerr := model.compile(&reg, Order, html.checks(.Fragment))
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
	// A text with parse errors still loads, and a repeated element is refused unless the load says which one it reads.
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`<item id=1><name>abc</name><price currency=EUR>1`), &v))
	twice := `<item id="1"><name>abc</name><name>abd</name><price currency="EUR">1</price></item>`
	f, repeated := walktest.fault_in(model.load(&m, transmute([]u8)string(twice), &v))
	testing.expect(t, repeated)
	testing.expect_value(t, f.kind, core.Fault_Kind.Duplicate_Key)
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(twice), &v, nil, {dups = .Last}))
	testing.expect_value(t, v.item.name, "abd")
}

@(test)
a_schema_checks_an_html_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text := `{"type": "object", "required": ["item"], "properties": {"item": {"type": "object", "required": ["id", "name"], "additionalProperties": false,
		"properties": {"id": {"type": "integer", "minimum": 1}, "name": {"type": "string", "minLength": 3}, "tag": {"type": "array", "items": {"enum": ["a", "b"]}, "maxItems": 2},
		"price": {"type": "object", "properties": {"currency": {"enum": ["EUR", "USD"]}, "#text": {"type": "number"}}, "required": ["currency", "#text"]}}}}}`
	s, serr := json.load_schema(transmute([]u8)string(text))
	walktest.expect_nil(t, serr)
	bound, berr := html.bind_schema(s, .Fragment)
	walktest.expect_nil(t, berr)
	defer schema.unbind(&bound)
	cases := [?]struct {
		text:   string,
		errors: int,
	} {
		{`<item id=7><name>abc</name><tag>a</tag><tag>b</tag><price currency=EUR>1.5</price></item>`, 0},
		{`<item id=0><name>ab</name><tag>a</tag><tag>c</tag><tag>b</tag><price currency=PLN>x</price><extra></extra></item>`, 7},
		{`<item></item>`, 2},
	}
	for c in cases {
		sink: typed.Sink
		defer typed.sink_destroy(&sink)
		err := schema.check(&bound, transmute([]u8)c.text, &sink)
		testing.expectf(t, len(sink.entries) == c.errors && (err == nil) == (c.errors == 0), "%s: %d entries, %v", c.text, len(sink.entries), err)
	}
	// A whole document is checked from its root, the `html` element.
	page, perr := json.load_schema(transmute([]u8)string(`{"properties": {"html": {"properties": {"@lang": {"const": "en"}, "body": {"required": ["main"]}}}}}`))
	walktest.expect_nil(t, perr)
	doc_bound, dberr := html.bind_schema(page, .Document)
	walktest.expect_nil(t, dberr)
	defer schema.unbind(&doc_bound)
	walktest.expect_nil(t, schema.check(&doc_bound, transmute([]u8)string(`<!DOCTYPE html><html lang=en><main>x</main>`)))
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	testing.expect(t, schema.check(&doc_bound, transmute([]u8)string(`<p>x`), &sink) != nil)
	testing.expect_value(t, len(sink.entries), 1)
}

// A document built once is checked by its nodes, and text the tree moved is read whole.
@(test)
a_built_document_is_checked_by_a_model_and_a_schema :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	Note :: struct {
		lang: string `model:"len<=2"`,
		text: string `html:"#text" model:"len<=5"`,
	}
	reg: model.Registry
	m, cerr := model.compile(&reg, struct{ note: Note }, html.checks(.Fragment))
	walktest.expect_nil(t, cerr)
	doc, ok := built(t, "<note lang=english>one<!--x--> two &amp; three</note>", .Fragment)
	if !ok {
		return
	}
	v: struct{ note: Note }
	sink: typed.Sink
	typed.check_document(&doc, core.ROOT, &v, type_of(v), &m.load_plan, {dups = .Last, sink = &sink})
	testing.expect_value(t, len(sink.entries), 2)
	testing.expect_value(t, v.note.lang, "english")
	testing.expect_value(t, v.note.text, "one two & three")
	s, serr := json.load_schema(transmute([]u8)string(`{"properties": {"note": {"properties": {"lang": {"maxLength": 7}, "#text": {"minLength": 16}}}}}`))
	walktest.expect_nil(t, serr)
	bound, berr := html.bind_schema(s, .Fragment)
	walktest.expect_nil(t, berr)
	judged: typed.Sink
	testing.expect(t, schema.check_node(&bound, &doc, core.ROOT, &judged) != nil)
	testing.expect_value(t, len(judged.entries), 1)
	testing.expect_value(t, judged.entries[0].kind, core.Typed_Error_Kind.Too_Short)
}
