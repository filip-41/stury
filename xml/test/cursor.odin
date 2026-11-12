// A walk stopped and resumed through a cursor against an unbroken walk.
package xml_tests

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:testing"
import core "../../core"
import xml ".."

// A hook that logs every token, skips the element named `skip` at its key or its object, and stops at token `stop`, or
// at every `every`th one when `every` is not 0. A skipped token is never a stop, so the tokens match those of a walk
// with no stops.
@(private)
Stopping :: struct {
	src:    []u8,
	tokens: [dynamic]core.Token,
	skip:   string,
	stop:   int,
	every:  int,
	// The last element key the hook saw, whose object a skip on the object hides.
	last:   string,
}

@(private)
stopping_hook :: proc "contextless" (h: ^Stopping, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = runtime.default_context()
	n := len(h.tokens)
	append(&h.tokens, t)
	r := core.Hook_Regs{s.a + 1, s.b, s.c}
	if t.role == .Key && t.n != 0 {
		h.last = string(h.src[t.lo:t.lo + u64(t.n)])
		if h.last == h.skip {
			return r, .Skip
		}
	}
	if t.kind == .Object && t.role == .Value && len(h.skip) > 1 && h.skip[0] == '*' && h.skip[1:] == h.last {
		return r, .Skip
	}
	if h.every != 0 && (n + 1) % h.every == 0 || n + 1 == h.stop {
		return r, .Stop
	}
	return r, .Next
}

@(private)
walk_stopping :: proc(src: []u8, skip: string, stop, every: int) -> (h: Stopping, end: string) {
	h = Stopping{src = src, skip = skip, stop = stop, every = every}
	h.tokens = make([dynamic]core.Token, 0, 64)
	regs: core.Hook_Regs
	cursor: xml.Cursor
	hi, fault := xml.walk(src, 0, .Xml, {}, &h, &regs, stopping_hook, &cursor)
	for xml.can_resume(&cursor) {
		hi, fault = xml.walk_resume(src, &cursor, .Xml, {}, &h, &regs, stopping_hook)
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
	for text in CURSOR_TEXTS {
		src := transmute([]u8)text
		for skip in ([]string{"", "a", "b", "*a", "*b", "*r", "r"}) {
			full, want := walk_stopping(src, skip, 0, 0)
			defer delete(full.tokens)
			for stop in 1 ..= len(full.tokens) + 1 {
				got, end := walk_stopping(src, skip, stop, 0)
				defer delete(got.tokens)
				ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%q skip %q stop %d: %d tokens, want %d", text, skip, stop, len(got.tokens), len(full.tokens))
				ok &&= testing.expectf(t, end == want, "%q skip %q stop %d: %v, want %v", text, skip, stop, end, want)
				if !ok {
					return
				}
			}
			for every in 1 ..= 3 {
				got, end := walk_stopping(src, skip, 0, every)
				defer delete(got.tokens)
				ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%q skip %q every %d: %d tokens, want %d", text, skip, every, len(got.tokens), len(full.tokens))
				ok &&= testing.expectf(t, end == want, "%q skip %q every %d: %v, want %v", text, skip, every, end, want)
				if !ok {
					return
				}
			}
		}
	}
}

// A resume over another text, or of a cursor that holds no stop, is refused, and `destroy` frees a cursor no resume
// ended.
@(test)
cursor_refuses_another_text :: proc(t: ^testing.T) {
	src := transmute([]u8)string("<r><a>1</a></r>")
	h := Stopping{src = src, stop = 2}
	h.tokens = make([dynamic]core.Token, 0, 16)
	defer delete(h.tokens)
	cursor: xml.Cursor
	_, fault := xml.walk(src, 0, .Xml, {}, &h, nil, stopping_hook, &cursor)
	testing.expect(t, fault == nil && xml.can_resume(&cursor))
	other := transmute([]u8)string("<r><a>2</a></r>")
	_, fault = xml.walk_resume(other, &cursor, .Xml, {}, &h, nil, stopping_hook)
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Bad_Option && xml.can_resume(&cursor))
	xml.destroy(&cursor)
	testing.expect(t, !xml.can_resume(&cursor))
	_, fault = xml.walk_resume(src, &cursor, .Xml, {}, &h, nil, stopping_hook)
	f, bad = fault.?
	testing.expect(t, bad && f.kind == .Bad_Option)
}
