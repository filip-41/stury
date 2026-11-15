// A walk stopped and resumed through a cursor against an unbroken walk.
package html_tests

import "core:fmt"
import "core:testing"
import core "../../core"
import html ".."
import walktest "../../walktest"

@(private = "file")
walk_as :: proc(text: string, $S: html.Spec, skip: string, stop, every: int) -> (h: walktest.Stopping, end: string) {
	src := transmute([]u8)text
	h = walktest.Stopping{src = src, skip = skip, stop = stop, every = every}
	h.tokens = make([dynamic]core.Token, 0, 64)
	regs: core.Hook_Regs
	cursor: html.Cursor
	hi, fault := html.walk(src, 0, S, {}, &h, &regs, walktest.stopping_hook, &cursor)
	for html.can_resume(&cursor) {
		hi, fault = html.walk_resume(src, &cursor, S, {}, &h, &regs, walktest.stopping_hook)
	}
	return h, fmt.tprint(hi, fault, regs.a)
}

// `walk_as` as a document, then as a fragment.
@(private = "file")
walk_stopping :: proc(text: string, skip: string, stop, every, variant: int) -> (walktest.Stopping, string) {
	if variant == 0 {
		return walk_as(text, .Document, skip, stop, every)
	}
	return walk_as(text, .Fragment, skip, stop, every)
}

// A walk stopped at any one token, or at every one, and resumed gives the tokens, end and fault of an unbroken walk,
// with skipped elements, implied ones and the ones the tree moved among them, and a resume over another text, or of a
// cursor that holds no stop, is refused.
@(test)
cursor_resumes_after_any_token :: proc(t: ^testing.T) {
	texts := [?]string {
		"<!doctype html><!--h--><p>1<a x=1>2<b>3</a>4<p><b>t</b><!--k--> u",
		"<table><a>x</a><tr><td>1<td><p>2</table><b>z",
		"<p>a<!--c--></p><b>",
	}
	walktest.expect_resumes(t, texts[:], {"", "a", "b", "*a", "*b", "*p", "p"}, 2, walk_stopping)
	src := transmute([]u8)string("<p>1</p>")
	h := walktest.Stopping{src = src, stop = 2}
	h.tokens = make([dynamic]core.Token, 0, 16)
	defer delete(h.tokens)
	cursor: html.Cursor
	_, fault := html.walk(src, 0, .Fragment, {}, &h, nil, walktest.stopping_hook, &cursor)
	testing.expect(t, fault == nil && html.can_resume(&cursor))
	_, fault = html.walk_resume(transmute([]u8)string("<p>2</p>"), &cursor, .Fragment, {}, &h, nil, walktest.stopping_hook)
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Bad_Option && html.can_resume(&cursor))
	html.destroy(&cursor)
	testing.expect(t, !html.can_resume(&cursor))
}
