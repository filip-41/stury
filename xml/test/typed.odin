// `xml.unmarshal` reads an element at a struct as its attributes, child elements and `#text`, collects the siblings a
// list member names, and reads a text into a number or a boolean by the member's type.
package xml_tests

import "core:testing"
import core "../../core"
import typed "../../core/typed"
import xml ".."
import testkit "../../testkit"

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
	testkit.expect_nil(t, err)
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
	testkit.expect_nil(t, xml.unmarshal(transmute([]u8)string(src), .Xml, &v))
	testing.expect_value(t, v.a.n, 2)
	dup := xml.unmarshal(transmute([]u8)string(src), .Xml, &v, read = typed.Read_Options{dups = .Refuse})
	testing.expect(t, dup != nil)
}

// A text or an attribute whose decode is exactly a JSON number reads into a number, its sign that of the decode.
@(test)
unmarshal_reads_a_number_a_text_decodes_to :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	v: struct {
		r: struct {
			a, b: int,
			m:    i8,
			z:    f64,
			f:    f32,
		},
	}
	src := `<!DOCTYPE r [<!ENTITY e "7">]><r a="&#55;1"><b>&e;</b><m>&#45;8</m><z>&#45;0</z><f>&#49;.5</f></r>`
	testkit.expect_nil(t, xml.unmarshal(transmute([]u8)string(src), .Xml, &v))
	testing.expect_value(t, v.r.a, 71)
	testing.expect_value(t, v.r.b, 7)
	testing.expect_value(t, v.r.m, -8)
	testing.expect_value(t, transmute(u64)v.r.z, transmute(u64)f64(-0.0))
	testing.expect_value(t, v.r.f, 1.5)
	refusals := [?]struct {
		src:  string,
		kind: core.Typed_Error_Kind,
	}{{`<r><b>&#55;x</b></r>`, .Wrong_Kind}, {`<r><b>&#55;.5</b></r>`, .Wrong_Kind}, {`<r><m>&#55;00</m></r>`, .Above_Maximum}}
	for c in refusals {
		refused, _ := xml.unmarshal(transmute([]u8)c.src, .Xml, &v).(core.Typed_Error)
		testing.expect_value(t, refused.kind, c.kind)
	}
}

@(test)
a_value_member_groups_a_repeated_name_as_a_built_value_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	v: struct {
		r: core.Value,
	}
	src := `<r><b>1</b><c/><b>2</b></r>`
	testkit.expect_nil(t, xml.unmarshal(transmute([]u8)string(src), .Xml, &v))
	b, _ := core.member(v.r, "b")
	testing.expect_value(t, core.kind(b), core.Kind.Array)
	testing.expect_value(t, core.length(b), 2)
	testkit.expect_nil(t, xml.unmarshal(transmute([]u8)string(src), .Xml, &v, read = typed.Read_Options{dups = .First}))
	b, _ = core.member(v.r, "b")
	testing.expect_value(t, core.kind(b), core.Kind.String)
}

@(test)
unmarshal_reads_a_document_node_and_a_chosen_spec :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	src := transmute([]u8)string(`<r k="v"><x>5</x></r>`)
	doc, built := xml.build(src, .Xml)
	testkit.expect_nil(t, built)
	defer xml.destroy(&doc)
	R :: struct {
		k: string,
		x: u8,
	}
	r: R
	plan, made := xml.plan_make(R)
	testkit.expect_nil(t, made)
	defer xml.destroy(&plan)
	testkit.expect_nil(t, typed.unmarshal(&doc, 2, &r, &plan))
	testing.expect_value(t, r, R{k = "v", x = 5})
	w: struct {
		r: R,
	}
	spec :: xml.Spec.Xml
	testkit.expect_nil(t, xml.unmarshal(src, spec, &w))
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
	testkit.expect_nil(t, ierr)
	testing.expect_value(t, string(item), "<item><n>0</n></item>")
	laid, lerr := xml.marshal(struct {item: Item}{}, write = core.PRETTY)
	testkit.expect_nil(t, lerr)
	testing.expect_value(t, string(laid), "<item>\n  <n>0</n>\n</item>")
	v := Library{shelf = {name = "a & b"}}
	append(&v.shelf.book, Book{id = 1, title = "One", price = {"EUR", 12.5}, instock = true, note = 4})
	append(&v.shelf.book[0].tags, "x", "y")
	append(&v.shelf.book, Book{id = 2, title = "Two", price = {"USD", 3}})
	append(&v.shelf.book[1].tags, "z")
	text, err := xml.marshal(v)
	testkit.expect_nil(t, err)
	testing.expect_value(t, string(text), "<shelf><book><id>1</id><title>One</title><tag>x</tag><tag>y</tag><price><currency>EUR</currency>12.5</price><instock>true</instock><note>4</note></book><book><id>2</id><title>Two</title><tag>z</tag><price><currency>USD</currency>3.0</price><instock>false</instock><note/></book><name>a &amp; b</name></shelf>")
	back: Library
	testkit.expect_nil(t, xml.unmarshal(text, .Xml, &back))
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
	testkit.expect_nil(t, perr)
	defer typed.plan_destroy(&plan)
	v: V
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	testkit.expect_nil(t, xml.check(transmute([]u8)string(`<ul><li>1</li><li>2</li></ul>`), .Xml, &v, &plan, {sink = &sink}))
	testing.expect_value(t, len(sink.entries), 0)
	testing.expect_value(t, len(v.ul.li), 2)
}

// A nil `any` is a null, which XML cannot write at the top, so it is refused as any null is.
@(test)
a_nil_any_is_refused_as_a_null :: proc(t: ^testing.T) {
	nothing: any
	text, err := xml.marshal(nothing, allocator = context.temp_allocator)
	testing.expect(t, text == nil)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
}

// A plan from `plan_make` reads a text.
@(test)
plans_read_xml :: proc(t: ^testing.T) {
	Doc :: struct {
		a: struct {
			n: int,
		},
	}
	plan, perr := xml.plan_make(Doc, .Xml)
	testkit.expect_nil(t, perr)
	defer xml.destroy(&plan)
	v: Doc
	testkit.expect_nil(t, xml.unmarshal(transmute([]u8)string(`<a><n>4</n></a>`), .Xml, &v, &plan))
	testing.expect_value(t, v.a.n, 4)
}

// An attribute is read by its plain name, so a tag that names it `@id` is refused when the plan is made, with the
// spelling to use, where it would read nothing.
@(test)
a_tag_spelled_as_an_attribute_member_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	Order :: struct {
		id: string `xml:"@id"`,
	}
	_, err := xml.plan_make(Order)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Bad_Tag)
	typed_err, _ := err.(core.Typed_Error)
	testing.expect_value(t, typed_err.want.text, "@id")
	Plain :: struct {
		order: struct {
			id: string `xml:"id"`,
		},
	}
	plan, perr := xml.plan_make(Plain)
	testkit.expect_nil(t, perr)
	defer typed.plan_destroy(&plan)
	v: Plain
	testkit.expect_nil(t, xml.unmarshal(transmute([]u8)string(`<order id="7"/>`), .Xml, &v, &plan))
	testing.expect_value(t, v.order.id, "7")
}
