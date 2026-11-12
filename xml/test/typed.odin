// `xml.unmarshal` reads an element at a struct as its attributes, child elements and `#text`, collects the siblings a
// list member names, and reads a text into a number or a boolean by the member's type.
package xml_tests

import "core:testing"
import core "../../core"
import typed "../../core/typed"
import xml ".."
import walktest "../../walktest"

@(private = "file")
Price :: struct {
	currency: string,
	amount:   f64 `xml:"#text"`,
}

@(private = "file")
Book :: struct {
	id:      i64,
	title:   string,
	tags:    [dynamic]string `xml:"tag"`,
	price:   Price,
	instock: bool,
	note:    Maybe(int),
}

@(private = "file")
Shelf :: struct {
	book: [dynamic]Book,
	name: string,
}

@(private = "file")
Library :: struct {
	shelf: Shelf,
}

@(test)
unmarshal_reads_attributes_elements_and_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text := `<?xml version="1.0"?>
<shelf name="a &amp; b">
  <book id="1"><title>One</title><tag>x</tag><price currency="EUR">12.5</price><tag>y</tag><instock>true</instock></book>
  <!-- between -->
  <book id="2"><title>Two</title><price currency="USD">3</price><note>4</note></book>
</shelf>`
	v: Library
	err := xml.unmarshal(transmute([]u8)string(text), .Xml, &v)
	walktest.expect_nil(t, err)
	testing.expect_value(t, v.shelf.name, "a & b")
	if !testing.expect_value(t, len(v.shelf.book), 2) {
		return
	}
	b := v.shelf.book[0]
	testing.expect_value(t, b.id, 1)
	testing.expect_value(t, b.title, "One")
	testing.expect_value(t, len(b.tags), 2)
	testing.expect_value(t, b.tags[1] if len(b.tags) > 1 else "", "y")
	testing.expect_value(t, b.price.currency, "EUR")
	testing.expect_value(t, b.price.amount, 12.5)
	testing.expect_value(t, b.instock, true)
	testing.expect_value(t, b.note, nil)
	testing.expect_value(t, v.shelf.book[1].note, 4)
	testing.expect_value(t, v.shelf.book[1].price.amount, 3)
}

@(test)
unmarshal_refuses_a_text_of_the_wrong_type :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	v: struct {
		a: struct {
			n: int,
		},
	}
	err := xml.unmarshal(transmute([]u8)string(`<a><n>x1</n></a>`), .Xml, &v)
	refused, is_typed := err.(core.Typed_Error)
	testing.expect(t, is_typed)
	testing.expect_value(t, refused.kind, core.Typed_Error_Kind.Wrong_Kind)
	src := `<a><n>1</n><n>2</n></a>`
	walktest.expect_nil(t, xml.unmarshal(transmute([]u8)string(src), .Xml, &v))
	testing.expect_value(t, v.a.n, 2)
	dup := xml.unmarshal(transmute([]u8)string(src), .Xml, &v, read = typed.Read_Options{dups = .Refuse})
	testing.expect(t, dup != nil)
}

@(test)
a_value_member_groups_a_repeated_name_as_a_built_value_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	v: struct {
		r: core.Value,
	}
	src := `<r><b>1</b><c/><b>2</b></r>`
	walktest.expect_nil(t, xml.unmarshal(transmute([]u8)string(src), .Xml, &v))
	b, _ := core.member(v.r, "b")
	testing.expect_value(t, core.kind(b), core.Kind.Array)
	testing.expect_value(t, core.length(b), 2)
	walktest.expect_nil(t, xml.unmarshal(transmute([]u8)string(src), .Xml, &v, read = typed.Read_Options{dups = .First}))
	b, _ = core.member(v.r, "b")
	testing.expect_value(t, core.kind(b), core.Kind.String)
}

@(test)
unmarshal_reads_a_document_node_and_a_chosen_spec :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	src := transmute([]u8)string(`<r k="v"><x>5</x></r>`)
	doc, built := xml.build(src, .Xml)
	walktest.expect_nil(t, built)
	defer xml.destroy(&doc)
	R :: struct {
		k: string,
		x: u8,
	}
	r: R
	plan, made := xml.plan_make(R)
	walktest.expect_nil(t, made)
	defer xml.destroy(&plan)
	walktest.expect_nil(t, typed.unmarshal(&doc, 2, &r, &plan))
	testing.expect_value(t, r, R{k = "v", x = 5})
	w: struct {
		r: R,
	}
	spec := xml.Spec.Xml
	walktest.expect_nil(t, xml.unmarshal(src, spec, &w))
	testing.expect_value(t, w.r, R{k = "v", x = 5})
}

@(test)
unmarshal_reads_what_marshal_writes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	Item :: struct {
		tags: [dynamic]string `xml:"tag,omitempty"`,
		kind: string `xml:",omitempty"`,
		n:    int,
	}
	_, refused := xml.marshal(struct {item: struct {tags: [dynamic]string `xml:"tag"`}}{})
	testing.expect_value(t, refused.(core.Typed_Error).kind, core.Typed_Error_Kind.Unwritable)
	item, ierr := xml.marshal(struct {item: Item}{})
	walktest.expect_nil(t, ierr)
	testing.expect_value(t, string(item), "<item><n>0</n></item>")
	laid, lerr := xml.marshal(struct {item: Item}{}, write = core.PRETTY)
	walktest.expect_nil(t, lerr)
	testing.expect_value(t, string(laid), "<item>\n  <n>0</n>\n</item>")
	v := Library{shelf = {name = "a & b"}}
	append(&v.shelf.book, Book{id = 1, title = "One", price = {"EUR", 12.5}, instock = true, note = 4})
	append(&v.shelf.book[0].tags, "x", "y")
	append(&v.shelf.book, Book{id = 2, title = "Two", price = {"USD", 3}})
	append(&v.shelf.book[1].tags, "z")
	text, err := xml.marshal(v)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), "<shelf><book><id>1</id><title>One</title><tag>x</tag><tag>y</tag><price><currency>EUR</currency>12.5</price><instock>true</instock><note>4</note></book><book><id>2</id><title>Two</title><tag>z</tag><price><currency>USD</currency>3.0</price><instock>false</instock><note/></book><name>a &amp; b</name></shelf>")
	back: Library
	walktest.expect_nil(t, xml.unmarshal(text, .Xml, &back))
	if !testing.expect_value(t, len(back.shelf.book), 2) {
		return
	}
	testing.expect_value(t, back.shelf.name, "a & b")
	testing.expect_value(t, back.shelf.book[0].tags[1], "y")
	testing.expect_value(t, back.shelf.book[0].price.amount, 12.5)
	testing.expect_value(t, back.shelf.book[0].note, 4)
	testing.expect_value(t, back.shelf.book[1].note, nil)
}

// A check of a list member over repeated elements takes every element, as `unmarshal` does.
@(test)
check_takes_a_list_of_repeated_elements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	V :: struct {
		ul: struct {
			li: [dynamic]int,
		},
	}
	plan, perr := xml.plan_make(V, .Xml)
	walktest.expect_nil(t, perr)
	defer typed.plan_destroy(&plan)
	v: V
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	walktest.expect_nil(t, xml.check(transmute([]u8)string(`<ul><li>1</li><li>2</li></ul>`), .Xml, &v, &plan, {sink = &sink}))
	testing.expect_value(t, len(sink.entries), 0)
	testing.expect_value(t, len(v.ul.li), 2)
}
