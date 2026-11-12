// Namespaces in XML 1.0 as the walk judges them: prefix scope, the reserved prefixes and URIs, and attribute names
// unique by namespace and local name.
package xml_tests

import "core:testing"

@(test)
a_declared_prefix_is_accepted_wherever_its_scope_reaches :: proc(t: ^testing.T) {
	for text in ([]string {
			`<p:a xmlns:p="u"/>`,
			`<a xmlns:p="u"><p:b p:c="1"/></a>`,
			`<p:a p:b="1" xmlns:p="u"/>`,
			`<a xmlns:p="u"><b xmlns:p="v"><p:c/></b><p:d/></a>`,
			`<a xmlns="u"><b xmlns=""><c/></b></a>`,
			`<xml:a xml:lang="en"/>`,
			`<a xmlns:xml="http://www.w3.org/XML/1998/namespace"/>`,
			`<a xmlns:p="u" xmlns:q="u" p:x="1" y="2"/>`,
			`<a xmlns:p="u" xmlns:q="v" p:x="1" q:x="2"/>`,
			`<r><a xmlns:p="u&#32;v"><p:b/></a><a xmlns:p="w"><p:b/></a></r>`,
		}) {
		testing.expect_value(t, refusal(text), "")
	}
}

@(test)
a_prefix_with_no_declaration_in_scope_is_refused :: proc(t: ^testing.T) {
	testing.expect_value(t, refusal(`<p:a/>`), "xml.unbound_prefix@0")
	testing.expect_value(t, refusal(`<a p:b="1"/>`), "xml.unbound_prefix@0")
	testing.expect_value(t, refusal(`<a><b xmlns:p="u"/><p:c/></a>`), "xml.unbound_prefix@19")
	testing.expect_value(t, refusal(`<a xmlns:p="u"><b xmlns:p="v"/><p:c p:d="1" q:e="2"/></a>`), "xml.unbound_prefix@31")
}

@(test)
a_name_that_is_no_qualified_name_is_refused :: proc(t: ^testing.T) {
	for text in ([]string{`<:a/>`, `<a:/>`, `<a:b:c xmlns:a="u"/>`, `<a:1 xmlns:a="u"/>`, `<a xmlns:p="u" p:/>`, `<a xmlns:p:q="u"/>`, `<a xmlns:="u"/>`}) {
		testing.expect(t, refusal(text) != "", text)
	}
	testing.expect_value(t, refusal(`<?a:b c?><a/>`), "xml.qualified_name@2")
}

@(test)
the_reserved_prefixes_and_uris_are_kept :: proc(t: ^testing.T) {
	testing.expect_value(t, refusal(`<a xmlns:xmlns="u"/>`), "xml.reserved_prefix@3")
	testing.expect_value(t, refusal(`<a xmlns:xml="u"/>`), "xml.reserved_prefix@3")
	testing.expect_value(t, refusal(`<xmlns:a/>`), "xml.reserved_prefix@0")
	testing.expect_value(t, refusal(`<a xmlns:p="http://www.w3.org/XML/1998/namespace"/>`), "xml.reserved_namespace@3")
	testing.expect_value(t, refusal(`<a xmlns="http://www.w3.org/2000/xmlns/"/>`), "xml.reserved_namespace@3")
	testing.expect_value(t, refusal(`<a xmlns:p=""/>`), "xml.empty_binding@3")
}

@(test)
two_attributes_of_one_expanded_name_are_refused :: proc(t: ^testing.T) {
	testing.expect_value(t, refusal(`<a xmlns:p="u" xmlns:q="u" p:x="1" q:x="2"/>`), "xml.duplicate_expanded@0")
	testing.expect_value(t, refusal(`<a xmlns:p="u" p:x="1" p:x="2"/>`), "xml.duplicate_attribute@23")
	testing.expect_value(t, refusal(`<a xmlns:p="u v" xmlns:q="u&#32;v"><b p:x="1" q:x="2"/></a>`), "xml.duplicate_expanded@35")
	testing.expect_value(t, refusal(`<a xmlns:p="u v" xmlns:q="u&#9;v"><b p:x="1" q:x="2"/></a>`), "")
	tokenized := `<!DOCTYPE a [<!ATTLIST a xmlns:q NMTOKEN #IMPLIED>]><a xmlns:p="u" xmlns:q=" u "><b p:x="1" q:x="2"/></a>`
	testing.expect_value(t, refusal(tokenized), "xml.duplicate_expanded@81")
}
