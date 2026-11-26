// Preorder walk tokens, hook skip/stop actions, validation parse errors, and build budget/encoding refusals.
package html_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

@(test)
a_walk_gives_the_tree_in_preorder :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	got, hi, err := tokens_of("<a>hi</a>")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, hi, 9)
	testing.expect_value(t, got, "Object Key:a Plain:hi End")

	got, _, err = tokens_of("<p>x", .Html)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, got, "Object Key Object Key Null Key Object Key:p Plain:x End End End")

	got, _, err = tokens_of("<!DOCTYPE html><html lang=en><!--c--><p class='a b'>one<br>two</p>", .Html)
	testing.expect_value(t, err, nil)
	testing.expect_value(
		t,
		got,
		"Doctype:<!DOCTYPE html> Object Key:html Attribute:lang=en Object:<html lang=en> Comment:<!--c--> Key Null Key Object Key:p Attribute:class='a b' Object:<p class='a b'> Key Plain:one Key:br Null Key Plain:two End End End End",
	)

	got, _, err = tokens_of("<table>a<tr><td>1</td></tr>b</table>")
	testing.expect_value(t, err, nil)
	testing.expect_value(
		t,
		got,
		"Object Key Plain*:a<tr><td>1</td></tr>b Key:table Object:<table> Key Object Key:tr Object:<tr> Key:td Plain:1 End End End End",
	)

	got, _, err = tokens_of("<p>a<!--x-->b <i>c</i></p>")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, got, "Object Key:p Object:<p> Comment:<!--x--> Key Plain*:a<!--x-->b  Key:i Plain:c End End")

	got, _, err = tokens_of("<!--a-->\n\n<!--b-->\n<html><body><!--c--><p>1</p><e><!--z--></e></body></html>", .Html)
	testing.expect_value(t, err, nil)
	testing.expect_value(
		t,
		got,
		"Comment:<!--a--> Object Comment:<!--b--> Key:html Object:<html> Key Null Key:body Object:<body> Comment:<!--c--> Key:p Plain:1 Key:e Foot:<!--z--> Null End End End",
	)
}

@(test)
a_hook_skips_and_stops :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	got, _, err := tokens_of("<a><b x=1><c>1</c></b><d>2</d></a>", skip = "b")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, got, "Object Key:a Object:<a> Key:b Attribute:x=1 Object:<b x=1> End Key:d Plain:2 End End")

	hi: u64
	got, hi, err = tokens_of("<a><b>1</b><d>2</d></a>", stop = 4)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, got, "Object Key:a Object:<a> Key:b")
	testing.expect_value(t, hi, 5)
}

@(test)
validate_names_the_first_parse_error :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, refusal("<!DOCTYPE html><title>x</title><p>y</p>", .Html), "")
	testing.expect_value(t, refusal("<p>x", .Html), "missing_doctype@0")
	testing.expect_value(t, refusal("<!DOCTYPE html><p a=1 a=2>", .Html), "duplicate_attribute@23")
	testing.expect_value(t, refusal("<!DOCTYPE html><p>&notit;</p>", .Html), "missing_semicolon_after_character_reference@22")
	testing.expect_value(t, refusal("<!DOCTYPE html><!-- x", .Html), "eof_in_comment@21")
	testing.expect_value(t, refusal("<!DOCTYPE html></b>", .Html), "unexpected_end_tag@15")
	testing.expect_value(t, refusal("<b>x</b>", .Fragment), "")

	err := html.validate(transmute([]u8)string("<!DOCTYPE html><div"), .Html)
	f, is_f := err.(tape.Fault)
	testing.expect(t, is_f && f.kind == .Truncated)

	// `build` recovers parse errors per HTML5.
	doc, berr := html.build(transmute([]u8)string("</x><p a=1 a=2>&notit;<!-- x"), .Html, {}, context.temp_allocator)
	testing.expect_value(t, berr, nil)
	_ = doc
}

@(test)
a_build_refuses_only_what_no_tree_holds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	deep := strings.repeat("<div>", 40, context.temp_allocator)
	_, err := html.build(transmute([]u8)deep, .Fragment, {budget = {depth = 10}}, context.temp_allocator)
	ex, is_ex := err.(tape.Exceeded)
	testing.expect(t, is_ex && ex.kind == .Depth)

	verr := html.validate(transmute([]u8)deep, .Fragment, {budget = {depth = 10}})
	vex, vis_ex := verr.(tape.Exceeded)
	testing.expect(t, vis_ex && vex.kind == .Depth)

	_, err = html.build(transmute([]u8)string("<meta charset=latin2><p>caf\xe9"), .Html, {}, context.temp_allocator)
	f, bad := err.(tape.Fault)
	testing.expect(t, bad && code_of(err) == "encoding" && f.at == 14)

	_, werr, _ := html.walk(transmute([]u8)string("\xfe\xffx"), .Html, {}, &Token_Log{ctx = context}, &{}, log_token, context.temp_allocator)
	testing.expect(t, werr != nil && code_of(werr) == "encoding")
}

@(test)
budgets_limit_nodes_steps_and_memory :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string(fmt.tprintf("<!DOCTYPE html><div>%s</div>", strings.repeat("<p>x</p>", 20, context.temp_allocator)))

	// Steps budget
	verr := html.validate(src, .Html, {budget = {steps = 3}})
	ex_s, is_s := verr.(tape.Exceeded)
	testing.expect(t, is_s && ex_s.kind == .Steps)

	// Nodes budget
	_, berr := html.build(src, .Html, {budget = {nodes = 5}}, context.temp_allocator)
	ex_n, is_n := berr.(tape.Exceeded)
	testing.expect(t, is_n && ex_n.kind == .Nodes)

	// Tight memory budget refuses gracefully
	_, merr := html.build(src, .Html, {budget = {memory = 128}}, context.temp_allocator)
	testing.expect(t, merr != nil)
}

@(test)
walk_keep_stop_on_end_and_sparse_scan_state :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Custom hook returning `.Keep` on `.Object` and `.Stop` on `.End` (`emit_close` honors `.Keep` end-action).
	Keep_Stop_Hook :: struct {
		seen_end: bool,
		protocol: hook.Protocol(hook.Capabilities{.Skips}, hook.Unused, hook.Unused, hook.Unused),
	}
	on_tok :: proc "contextless" (h: ^Keep_Stop_Hook, regs: hook.Regs, tok: tape.Token) -> (hook.Regs, hook.Action) {
		if tok.role == .Value && tok.kind == .Object {
			return regs, .Keep
		}
		if tok.role == .Value && tok.kind == .End {
			h.seen_end = true
			return regs, .Stop
		}
		return regs, .Next
	}
	kh: Keep_Stop_Hook
	regs: hook.Regs
	at, err, _ := html.walk(transmute([]u8)string("<a><b>1</b></a><c>2</c>"), .Fragment, {}, &kh, &regs, on_tok, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, kh.seen_end && at < 16)

	// Sparse `scan` onto a later container preserves `close_end` and `STATE_FLAG_INFER` via monotonic `subdoc_state`.
	demand, derr := html.demand_of({{tape.Name("div"), tape.Name("b"), tape.All{}}}, nil, nil, false, context.temp_allocator)
	testing.expect_value(t, derr, nil)
	sdoc, serr := html.scan(
		transmute([]u8)string("<div><a><i>1</i></a><b><c>2</c></b></div>"),
		&demand,
		.Fragment,
		{},
		{format = html.Xml_Options{infer = true}},
		context.temp_allocator,
	)
	testing.expect_value(t, serr, nil)
	bnode, bfound := member_at(&sdoc, {"div", "b"})
	cnode, cfound := member_at(&sdoc, {"div", "b", "c"})
	testing.expect(t, bfound && cfound)
	testing.expect_value(t, sdoc.nodes[cnode].kind, tape.Kind.Number)
	bend, has_end := sdoc.format.close_end(&sdoc, bnode)
	testing.expect(t, has_end && bend == 35)
}
