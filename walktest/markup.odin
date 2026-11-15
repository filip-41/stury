package walktest

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../core"
import compose "../core/compose"
import json "../json"

// The reads the markup formats' tests share over a built document: a node's text, a member reached by names, an
// element's attributes, and the shape of a whole document as one line, which an XML text and an HTML text with the
// same markup give alike.

// The decoded text of string or plain node `i`, in the temp allocator.
node_text :: proc(t: ^testing.T, doc: ^core.Document, i: core.Node_Index, loc := #caller_location) -> string {
	buf := make([]u8, core.text_room(doc, i), context.temp_allocator)
	s, ok := core.text(doc, i, buf)
	testing.expect(t, ok, loc = loc)
	return s
}

// The node `path`, a path of names from the root, reaches, and false when a name is missing.
member_at :: proc(t: ^testing.T, doc: ^core.Document, path: string, loc := #caller_location) -> (node: core.Node_Index, found: bool) {
	p, perr := core.parse_path(path)
	testing.expect(t, perr == nil, loc = loc)
	defer core.path_destroy(&p)
	node = core.ROOT
	for step in p.steps {
		name, is_name := step.(core.Name)
		testing.expect(t, is_name, loc = loc)
		node = core.member(doc, node, string(name)) or_return
	}
	return node, true
}

// The text and the kind of the node `path` reaches, `.Null` with no text when a name is missing.
text_at :: proc(t: ^testing.T, doc: ^core.Document, path: string, loc := #caller_location) -> (string, core.Kind) {
	node, found := member_at(t, doc, path, loc)
	if !found {
		return "", .Null
	}
	return node_text(t, doc, node, loc), core.kind(doc, node)
}

// The next attribute of `it` as its name and its decoded value, in the temp allocator.
attribute_texts :: proc(it: ^core.Attribute_Iter) -> (name, value: string, found: bool) {
	n, v := core.attribute_next(it) or_return
	doc := it.doc
	name, _ = core.token_text(doc.readers, &doc.view, n, context.temp_allocator)
	value, _ = core.token_text(doc.readers, &doc.view, v, context.temp_allocator)
	return name, value, true
}

// The decoded value of the attribute of node `i` written `name`, in the temp allocator.
attribute_text :: proc(doc: ^core.Document, i: core.Node_Index, name: string) -> (value: string, found: bool) {
	it := core.attributes_of(doc, i)
	for written, v in attribute_texts(&it) {
		if written == name {
			return v, true
		}
	}
	return "", false
}

// The document as one line, in the temp allocator: each value's facts in source order, an attribute as `@name="value"`,
// a comment as `<!--body-->` with `^` after it for an inline one and `$` for a foot, an instruction as `<?body?>` and
// the DOCTYPE as `<!body>`, then an object's members as `"key": value` or a scalar as JSON writes its text.
markup_shape :: proc(doc: ^core.Document) -> string {
	b := strings.builder_make(context.temp_allocator)
	shape_node(&b, doc, core.ROOT)
	return strings.to_string(b)
}

@(private = "file")
shape_node :: proc(b: ^strings.Builder, doc: ^core.Document, i: core.Node_Index) {
	facts := strings.builder_make(context.temp_allocator)
	attributes := core.attributes_of(doc, i)
	for name, value in attribute_texts(&attributes) {
		fmt.sbprintf(&facts, "@%s=%q ", name, value)
	}
	for f in core.all_facts(doc, i) {
		body := string(doc.src[f.lo + core.comment_lead(f.spelling):f.lo + u64(f.n) - core.comment_tail(f.spelling)])
		#partial switch f.role {
		case .Comment:
			fmt.sbprintf(&facts, "<!--%s--> ", body)
		case .Comment_Inline:
			fmt.sbprintf(&facts, "<!--%s-->^ ", body)
		case .Comment_Foot:
			fmt.sbprintf(&facts, "<!--%s-->$ ", body)
		case .Instruction:
			fmt.sbprintf(&facts, "<?%s?> ", body)
		case .Doctype:
			fmt.sbprintf(&facts, "<!%s> ", body)
		}
	}
	if core.kind(doc, i) != .Object {
		if strings.builder_len(facts) > 0 {
			fmt.sbprintf(b, "(%s", strings.to_string(facts))
		}
		switch core.kind(doc, i) {
		case .Null:
			strings.write_string(b, "null")
		case .True, .False, .Number:
			buf := make([]u8, max(core.text_room(doc, i), 1), context.temp_allocator)
			s, _ := core.text(doc, i, buf)
			strings.write_string(b, s)
		case .Bytes, .String, .Plain, .Array, .Object, .End:
			buf := make([]u8, core.text_room(doc, i), context.temp_allocator)
			s, _ := core.text(doc, i, buf)
			fmt.sbprintf(b, "%q", s)
		}
		if strings.builder_len(facts) > 0 {
			strings.write_byte(b, ')')
		}
		return
	}
	fmt.sbprintf(b, "{{%s", strings.to_string(facts))
	it := core.doc_pairs(doc, i)
	first := true
	for k, v in core.doc_pair_next(&it) {
		if !first {
			strings.write_string(b, ", ")
		}
		first = false
		buf := make([]u8, core.text_room(doc, k), context.temp_allocator)
		name, _ := core.text(doc, k, buf)
		fmt.sbprintf(b, "%q: ", name)
		shape_node(b, doc, v)
	}
	strings.write_byte(b, '}')
}

// The fault arm of `err`, and whether `err` is one.
fault_in :: proc "contextless" (err: core.Error) -> (core.Fault, bool) {
	f, bad := err.(core.Fault)
	return f, bad
}

// A fault's rule as `format.code`, or the kind's code for a fault with no detail.
rule_code :: proc(f: core.Fault) -> string {
	if f.detail == 0 {
		return core.rule_of(f).code
	}
	return fmt.tprintf("%s.%s", f.rules.format, core.rule_of(f).code)
}

// A hook's log of a walk's tokens as one line: each token as its kind for a value, `Key`, `Comment`, `Inline`,
// `Foot` or its role, a `*` after a value whose text needs decoding, and `:` and its span when it has one. The hook
// skips the value of the key spelled `skip` and stops after `stop` tokens, 0 for never.
Token_Log :: struct {
	text:   []u8,
	out:    strings.Builder,
	skip:   string,
	stop:   int,
	tokens: int,
}

log_token :: proc "contextless" (r: ^Token_Log, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = runtime.default_context()
	text := string(r.text[t.lo:t.lo + u64(t.n)])
	name: string
	switch t.role {
	case .Value:
		name = fmt.tprint(t.kind)
	case .Key:
		name = "Key"
	case .Comment:
		name = "Comment"
	case .Comment_Inline:
		name = "Inline"
	case .Comment_Foot:
		name = "Foot"
	case .Instruction, .Doctype, .Directive, .Attribute, .Tag, .Anchor, .Alias, .Partial:
		name = fmt.tprint(t.role)
	}
	if t.spelling & core.SPELLING_DECODE != 0 && t.role == .Value {
		name = fmt.tprintf("%s*", name)
	}
	if text != "" {
		fmt.sbprintf(&r.out, "%s:%s ", name, text)
	} else {
		fmt.sbprintf(&r.out, "%s ", name)
	}
	r.tokens += 1
	if r.stop != 0 && r.tokens >= r.stop {
		return s, .Stop
	}
	if t.role == .Key && r.skip != "" && text == r.skip {
		return s, .Skip
	}
	return s, .Next
}

// The log a walk wrote, without its last space.
log_line :: proc(r: ^Token_Log) -> string {
	return strings.trim_space(strings.to_string(r.out))
}

// A hook of a walk with a cursor that logs every token, skips the element named `skip` at its key or its object,
// and stops at token `stop`, or at every `every`th one when `every` is not 0. A skipped token is never a stop, so the
// tokens match those of a walk with no stops.
Stopping :: struct {
	src:    []u8,
	tokens: [dynamic]core.Token,
	skip:   string,
	stop:   int,
	every:  int,
	// The last element key the hook saw, whose object a skip on the object hides.
	last:   string,
}

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

// A format's walk of `text` under its spec number `variant`, with `skip` and the stops `Stopping` takes, resumed after
// each stop. It gives the hook's tokens and the end, fault and registers as text.
Walk_Stopping :: proc(text: string, skip: string, stop, every, variant: int) -> (h: Stopping, end: string)

// Checks that a walk stopped at any one token of each of `texts`, or at every one of the first three strides, and
// resumed gives the tokens, end and fault of an unbroken walk, for each of `skips` and of the `variants` specs.
expect_resumes :: proc(t: ^testing.T, texts, skips: []string, variants: int, walk: Walk_Stopping, loc := #caller_location) -> bool {
	for text in texts {
		for variant in 0 ..< variants {
			for skip in skips {
				full, want := walk(text, skip, 0, 0, variant)
				defer delete(full.tokens)
				for stop in 1 ..= len(full.tokens) + 1 {
					got, end := walk(text, skip, stop, 0, variant)
					defer delete(got.tokens)
					ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%q v%d skip %q stop %d: %d tokens, want %d", text, variant, skip, stop, len(got.tokens), len(full.tokens), loc = loc)
					ok &&= testing.expectf(t, end == want, "%q v%d skip %q stop %d: %v, want %v", text, variant, skip, stop, end, want, loc = loc)
					if !ok {
						return false
					}
				}
				for every in 1 ..= 3 {
					got, end := walk(text, skip, 0, every, variant)
					defer delete(got.tokens)
					ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%q v%d skip %q every %d: %d tokens, want %d", text, variant, skip, every, len(got.tokens), len(full.tokens), loc = loc)
					ok &&= testing.expectf(t, end == want, "%q v%d skip %q every %d: %v, want %v", text, variant, skip, every, end, want, loc = loc)
					if !ok {
						return false
					}
				}
			}
		}
	}
	return true
}

// A format's answers of `paths` over `src` under its spec number `variant`: `each` through `each_answer`, `iter`
// through the iterator at largest batch `batch`. Each gives the answers and the error that ended the read.
Answer_Run :: struct {
	each: proc(src: []u8, paths: []core.Path, variant: int, early: bool, out: ^[dynamic]core.Token_Answer) -> core.Error,
	iter: proc(src: []u8, paths: []core.Path, variant: int, early: bool, batch: int, out: ^[dynamic]core.Token_Answer) -> core.Error,
}

// Collects the answers `each_answer` gives into the `[dynamic]core.Token_Answer` at `state`.
collect_answer :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	append((^[dynamic]core.Token_Answer)(state), a)
	return true
}

// Checks that the iterator gives the answers `each_answer` gives and ends with its error, at batch 1, 3 and 64 and
// with the stop at the last answer on and off, over each of `texts` under each spec number below `variants`, for each
// of the paths `path_texts` alone and for all of them together, and that some read gave an answer.
expect_answers_agree :: proc(t: ^testing.T, texts, path_texts: []string, variants: int, run: Answer_Run, loc := #caller_location) -> bool {
	paths := make([]core.Path, len(path_texts))
	defer {
		for &p in paths {
			core.path_destroy(&p)
		}
		delete(paths)
	}
	for text, i in path_texts {
		e: core.Error
		paths[i], e = core.parse_path(text)
		if !testing.expectf(t, e == nil, "%s: %v", text, e, loc = loc) {
			return false
		}
	}
	want, got: [dynamic]core.Token_Answer
	defer delete(want)
	defer delete(got)
	answered := 0
	for text in texts {
		src := transmute([]u8)text
		for variant in 0 ..< variants {
			for early in ([]bool{false, true}) {
				for i in 0 ..= len(paths) {
					set := paths[i:i + 1] if i < len(paths) else paths
					clear(&want)
					err := run.each(src, set, variant, early, &want)
					answered += len(want)
					for batch in ([]int{1, 3, 64}) {
						clear(&got)
						got_err := run.iter(src, set, variant, early, batch, &got)
						ok := testing.expectf(t, slice.equal(got[:], want[:]), "%q v%d path %d early %v batch %d: %d answers, want %d", text, variant, i, early, batch, len(got), len(want), loc = loc)
						ok &&= testing.expectf(t, fmt.tprint(got_err) == fmt.tprint(err), "%q v%d path %d early %v batch %d: %v, want %v", text, variant, i, early, batch, got_err, err, loc = loc)
						if !ok {
							return false
						}
					}
				}
			}
		}
	}
	return testing.expect(t, answered > 0, "no read gave an answer", loc = loc)
}

Edits :: proc(list: ^core.Edit_List, doc: ^core.Document) -> core.Error

// The text `src` read as `as` becomes when `edits` records its edits and the list is committed.
markup_edited :: proc(src: string, as: core.As, edits: Edits) -> (out: string, err: core.Error) {
	doc := core.build(transmute([]u8)src, as, allocator = context.temp_allocator) or_return
	list := core.edit_list_init(&doc, context.temp_allocator)
	edits(&list, &doc) or_return
	bytes, _, cerr := compose.commit(&list, allocator = context.temp_allocator)
	return string(bytes), cerr
}

// The `k`-th member of element `parent` named `name`, or `core.NO_NODE`.
nth :: proc(doc: ^core.Document, parent: core.Node_Index, name: string, k: int) -> core.Node_Index {
	it := core.members_named(doc, parent, name)
	for i := 0; ; i += 1 {
		node, ok := core.member_next(&it)
		if !ok || i == k {
			return node if ok else core.NO_NODE
		}
	}
}

// The value of the JSON text `src`, which the test's temp allocator holds.
from_json :: proc(src: string) -> core.Value {
	doc := new(core.Document, context.temp_allocator)
	doc^, _ = json.build(transmute([]u8)src, .Json, allocator = context.temp_allocator)
	return core.Node_Ref{doc, core.ROOT}
}

// An attribute fact `name="value"` read as a format with attributes reads one, its value a string with nothing to decode.
markup_attribute :: proc "contextless" (doc: ^core.Document, f: core.Fact) -> (name, value: core.Token) {
	lead := u32(core.comment_lead(f.spelling))
	return {lo = f.lo, n = lead - 2, kind = .String, role = .Key}, {lo = f.lo + u64(lead), n = f.n - lead - 1, kind = .String}
}

// A markup document made by hand: `model` is the JSON text of its data model, where an element is a member whose value
// is its text, empty when it is, or an object of its children and `#text` runs, and each attribute `name="value"` is a
// fact of its node, written past the model.
markup_doc :: proc(model: string, attributes: []Markup_Attribute, readers: ^core.Readers, dups := core.Duplicates.Last) -> core.Document {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, model)
	facts := make([]core.Fact, len(attributes), context.temp_allocator)
	for a, i in attributes {
		strings.write_byte(&b, ' ')
		name, _, _ := strings.partition(a.text, "=")
		facts[i] = {lo = u64(len(b.buf)), node = a.node, n = u32(len(a.text)), role = .Attribute, kind = .Plain, spelling = core.comment_spelling(u8(len(name) + 2), 1)}
		strings.write_string(&b, a.text)
	}
	doc, _ := core.build(b.buf[:len(model)], json.as(.Json), dups)
	doc.src, doc.facts, doc.readers = b.buf[:], facts, readers
	return doc
}

Markup_Attribute :: struct {
	node: core.Node_Index,
	text: string,
}
