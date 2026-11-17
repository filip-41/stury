// A walk stopped and resumed through a cursor against an unbroken walk.
package xml_tests

import "core:fmt"
import "core:testing"
import core "../../core"
import xml ".."
import testkit "../../testkit"

@(private)
walk_stopping :: proc(text: string, skip: string, stop, every, _: int) -> (h: testkit.Stopping, end: string) {
	src := transmute([]u8)text
	h = testkit.Stopping{src = src, skip = skip, stop = stop, every = every}
	h.tokens = make([dynamic]core.Token, 0, 64)
	regs: core.Hook_Regs
	cursor: xml.Cursor
	hi, fault := xml.walk(src, 0, .Xml, {}, &h, &regs, testkit.stopping_hook, &cursor)
	for xml.can_resume(&cursor) {
		hi, fault = xml.walk_resume(src, &cursor, .Xml, {}, &h, &regs, testkit.stopping_hook)
	}
	return h, fmt.tprint(hi, fault, regs.a)
}

@(private)
CURSOR_TEXTS := [?]string {
	"<r><a>1</a><b x='1'><c/>t<!--k--><c>2</c></b><?p q?></r>",
	"<?xml version='1.0'?><!DOCTYPE r [<!ENTITY e '<c>1</c>'><!ATTLIST b d CDATA 'v'>]><!--h--><r>&e;<b/><b>&e;</b></r><!--t-->",
	"<r xmlns:n='u'><n:a n:k='1'>x<![CDATA[y]]>z</n:a><a><b><c/></b></a></r>",
	"<r><a>1</a><b>",
	"<r><a>1</a></r>x",
	"<r/>",
}

// A walk stopped at any one token, or at every one, and resumed gives the tokens, end and fault of an unbroken walk,
// with skipped elements among them.
@(test)
cursor_resumes_after_any_token :: proc(t: ^testing.T) {
	testkit.expect_resumes(t, CURSOR_TEXTS[:], {"", "a", "b", "*a", "*b", "*r", "r"}, 1, walk_stopping)
}

// A resume over another text, or of a cursor that holds no stop, is refused, and `destroy` frees a cursor no resume
// ended.
@(test)
cursor_refuses_another_text :: proc(t: ^testing.T) {
	src := transmute([]u8)string("<r><a>1</a></r>")
	h := testkit.Stopping{src = src, stop = 2}
	h.tokens = make([dynamic]core.Token, 0, 16)
	defer delete(h.tokens)
	cursor: xml.Cursor
	_, fault := xml.walk(src, 0, .Xml, {}, &h, nil, testkit.stopping_hook, &cursor)
	testing.expect(t, fault == nil && xml.can_resume(&cursor))
	other := transmute([]u8)string("<r><a>2</a></r>")
	_, fault = xml.walk_resume(other, &cursor, .Xml, {}, &h, nil, testkit.stopping_hook)
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Bad_Option && xml.can_resume(&cursor))
	xml.destroy(&cursor)
	testing.expect(t, !xml.can_resume(&cursor))
	_, fault = xml.walk_resume(src, &cursor, .Xml, {}, &h, nil, testkit.stopping_hook)
	f, bad = fault.?
	testing.expect(t, bad && f.kind == .Bad_Option)
}
