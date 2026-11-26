package edit

import "base:runtime"
import "core:container/handle_map"
import "core:container/xar"
import "core:slice"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// Markup-family composer (XML 1.0 + Namespaces).
//
// Preserves untargeted tags, attribute bytes/order/quoting/case, CDATA sections, PIs (`<?...?>`),
// `<!DOCTYPE ...>`, and comments verbatim.
//
// Group 1 refusals (always refused, even under `Options.reflow = true`):
// - XML comment containing `--` or ending with `-` (`Bad_Xml_Comment`)
// - Invalid XML element or attribute name (`Bad_Name`)
// - Content placed inside a void element (`Void_Content`)
// - Array or non-single-element root (`Root_Shape`)
// - Empty array for an element (`Empty_Markup_Array`)
// - Nested array inside an array (`Nested_Markup_Array`)
// - Markup/array placed into a `#text` run (`Text_Markup`)
// - Fact with no place (`Fact_No_Place`)

// Element tag offsets in `src`:
// `lo` at `<`, `name` one past tag name, `open` one past start tag `>` (or at `/` of `<a/>`),
// `close` at `</` (or end of content), `hi` one past `>`.
Markup_Element :: struct {
	lo, name, open, close, hi: u64,
	empty, end_tag:            bool,
}

Markup_Spec :: struct {
	target:       ^tape.Format,
	self_closing: bool,
	element:      proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> Markup_Element,
	is_name:      proc "contextless" (name: []u8) -> bool,
	is_void:      proc "contextless" (name: string) -> bool,
	// Spells `ov`'s node `h` as XML element content (escaped text for scalar, child elements for object, empty for null).
	// Refuses arrays inside non-top positions (`Nested_Markup_Array`) and empty arrays (`Empty_Markup_Array`).
	spell_content: proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8) -> Error,
	// Escapes an XML attribute value `val` for quote character `quote` (`"` or `'`).
	spell_attr_val: proc(data: rawptr, val: string, quote: u8, out: ^[dynamic]u8) -> Error,
	// Validates final XML output.
	validate:     proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:         rawptr,
}

commit_markup :: proc(
	ov: ^Overlay,
	spec: ^Markup_Spec,
	opts := Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Error,
) {
	fast, target, fast_res, gerr := commit_guard(ov, spec.target, opts, true, spec.validate, spec.data, allocator)
	if gerr != nil {
		return {}, gerr
	}
	if fast {
		return fast_res, nil
	}
	doc := ov.base
	if ov.root != NO_HANDLE {
		rk := node_kind(ov, ov.root)
		if rk != .Object {
			return {}, refuse(.Root_Shape, "XML document root must be an object with one root element", tape.ROOT)
		}
	}

	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 4096}
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)

	cx := Markup_Cx {
		ov        = ov,
		doc       = doc,
		src       = doc.src,
		spec      = spec,
		opts      = opts,
		allocator = scratch,
	}
	cx.splices = make([dynamic]Splice, 0, max(8, xar.len(ov.nodes.items)), scratch)

	if !ov.has_structural {
		it := handle_map.dynamic_iterator_make(&ov.nodes)
		for n in dynamic_iter_next(&it) {
			if n.state == .Replaced && n.has_edits && n.base != tape.NO_NODE && doc.nodes[n.base].role == .Value {
				bn := doc.nodes[n.base]
				if spec.is_void == nil && n.val.kind == .Raw && !(bn.n == 0 && bn.lo < u64(len(doc.src)) && doc.src[bn.lo] == '/') {
					append(&cx.splices, Splice {
						lo           = bn.lo,
						hi           = bn.lo + u64(bn.n),
						text         = transmute([]u8)n.val.text,
						seq          = len(cx.splices),
						base_node    = n.base,
						subtree_only = true,
					}) or_return
				} else {
					emit_markup_replace(&cx, n.handle, n) or_return
				}
			}
		}
	} else {
		if ov.unlinked_parents {
			ensure_linked(ov) or_return
		}
		cx.eol = detect_eol(doc.src)
		if ov.root != NO_HANDLE {
			if err = compose_markup_walk(&cx, ov.root); err != nil {
				return {}, err
			}
		}
	}

	out, recs, rew, serr := apply_splices(doc.src, cx.splices[:], allocator)
	if serr != nil {
		return {}, serr
	}
	if spec.validate != nil {
		need_full := target != doc.format || len(recs) == 0
		if !need_full {
			for rec in recs {
				if !rec.subtree_only || rec.full_rewalk || !is_simple_xml_text(out[rec.dst_lo:rec.dst_hi]) {
					need_full = true
					break
				}
			}
		}
		if need_full {
			if verr := spec.validate(spec.data, out, allocator); verr != nil {
				return fail_commit_validation(out, recs, rew, verr, allocator)
			}
		}
	}
	return Commit_Result {
		bytes     = out,
		dropped   = cx.dropped,
		rewritten = rew,
		splices   = recs,
		allocator = allocator,
	}, nil
}

@(private = "file")
Markup_Cx :: struct {
	ov:        ^Overlay,
	doc:       ^tape.Document,
	src:       []u8,
	spec:      ^Markup_Spec,
	opts:      Options,
	eol:       string,
	splices:   [dynamic]Splice,
	dropped:   tape.Facts,
	allocator: runtime.Allocator,
}

@(private = "file")
xml_comment_valid :: proc "contextless" (body: string) -> bool {
	if len(body) > 0 && body[len(body) - 1] == '-' {
		return false
	}
	for i := 0; i + 1 < len(body); i += 1 {
		if body[i] == '-' && body[i + 1] == '-' {
			return false
		}
	}
	return true
}

@(private = "file")
is_text_run :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> bool {
	return v != tape.ROOT && v > 0 && markup.is_text_key(doc.nodes[v - 1])
}

@(private = "file")
ws_before_markup :: proc "contextless" (src: []u8, at: u64) -> u64 {
	lo := at
	for lo > 0 && kernel.is_markup_ws(src[lo - 1]) {
		lo -= 1
	}
	return lo
}

@(private = "file")
markup_extent :: proc(cx: ^Markup_Cx, v: tape.Node_Index) -> (lead, lo, hi: u64) {
	if is_text_run(cx.doc, v) {
		n := cx.doc.nodes[v]
		return n.lo, n.lo, n.lo + u64(n.n)
	}
	el := cx.spec.element(cx.doc, v)
	lead = ws_before_markup(cx.src, el.lo)
	if lead == 0 || cx.src[lead - 1] != '>' {
		lead = el.lo
	}
	return lead, el.lo, el.hi
}

@(private = "file")
compose_markup_walk :: proc(cx: ^Markup_Cx, root: Handle) -> Error {
	stack := make([dynamic]Handle, 0, 32, cx.allocator)
	defer delete(stack)
	if _, aerr := append(&stack, root); aerr != nil {
		return aerr
	}
	for len(stack) > 0 {
		h := pop(&stack)
		n, ok := get_node(cx.ov, h)
		if !ok || !n.has_edits {
			continue
		}
		if n.state == .Replaced {
			emit_markup_replace(cx, h, n) or_return
			continue
		}
		if len(n.facts) > 0 {
			emit_markup_facts(cx, n) or_return
		}
		if n.state == .Container_Delta {
			emit_markup_container_delta(cx, h, n, &stack) or_return
			continue
		}
		// `.Ancestor`: push edited direct children, handling repeated-name array replacement on a child element.
		if n.base != tape.NO_NODE && cx.doc.nodes[n.base].kind == .Object {
			c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, n.base, cx.allocator)
			if cerr != nil {
				return cerr
			}
			defer tape.destroy_children(&c)
			if p == .Found {
				// Track element names replaced with `.Array` so extra unedited siblings of the same name are dropped!
				array_replaced := make([dynamic]string, 0, 2, cx.allocator)
				defer delete(array_replaced)
				for {
					kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c, .Group)
					if np != .Found {
						break
					}
					is_txt := is_text_run(cx.doc, vn)
					ename := markup.TEXT_KEY if is_txt else string(tape.span_bytes(cx.doc, cx.doc.nodes[kn].lo, cx.doc.nodes[kn].n))
					if ch, has := cx.ov.by_base[vn]; has {
						if cn, cok := get_node(cx.ov, ch); cok && cn.has_edits {
							if cn.state == .Replaced && cn.val.kind == .Array && !is_txt {
								append(&array_replaced, ename)
							}
							if _, aerr := append(&stack, ch); aerr != nil {
								return aerr
							}
							continue
						}
					}
					if !is_txt {
						for rep_name in array_replaced {
							if rep_name == ename {
								lead, _, hi := markup_extent(cx, vn)
								if _, aerr := append(&cx.splices, Splice{lo = lead, hi = hi, seq = len(cx.splices), base_node = n.base, full_rewalk = true}); aerr != nil {
									return aerr
								}
								break
							}
						}
					}
				}
			}
		}
	}
	return nil
}

@(private = "file")
emit_markup_replace :: proc(cx: ^Markup_Cx, h: Handle, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE {
		return nil
	}
	v := n.base
	if v == tape.ROOT {
		if n.val.kind != .Object || len(n.members) != 1 {
			return refuse(.Root_Shape, "XML document root must have exactly one root element", v)
		}
		el := cx.spec.element(cx.doc, v)
		m := n.members[0]
		if !cx.spec.is_name(transmute([]u8)m.key) {
			return refuse(.Bad_Name, "invalid XML root element name", v)
		}
		buf := make([dynamic]u8, 0, 64, cx.allocator)
		spell_xml_element(cx, m.key, m.value, &buf) or_return
		append(&cx.splices, Splice{lo = el.lo, hi = el.hi, text = buf[:], seq = len(cx.splices), base_node = v, full_rewalk = true}) or_return
		return nil
	}

	// `#text` run replacement.
	if is_text_run(cx.doc, v) {
		if n.val.kind == .Array || n.val.kind == .Object {
			return refuse(.Text_Markup, "cannot replace #text run with element or array", v)
		}
		node := cx.doc.nodes[v]
		buf := make([dynamic]u8, 0, 32, cx.allocator)
		cx.spec.spell_content(cx.spec.data, cx.ov, h, &buf) or_return
		append(&cx.splices, Splice{lo = node.lo, hi = node.lo + u64(node.n), text = buf[:], seq = len(cx.splices), base_node = v, subtree_only = true}) or_return
		return nil
	}

	el := cx.spec.element(cx.doc, v)
	tag_name := string(cx.src[el.lo + 1:el.name])

	// Repeated-name array replacement on element `v`:
	// Updates `v` with item 0 and appends items 1..k as sibling `<tag_name>` elements!
	if n.val.kind == .Array {
		if len(n.elems) == 0 {
			return refuse(.Empty_Markup_Array, "XML element cannot be replaced by an empty array", v)
		}
		for eh in n.elems {
			if node_kind(cx.ov, eh) == .Array {
				return refuse(.Nested_Markup_Array, "XML does not support nested arrays", v)
			}
		}
		emit_element_content_splice(cx, v, el, tag_name, n.elems[0]) or_return
		if len(n.elems) > 1 {
			lead, lo, hi := markup_extent(cx, v)
			sep := string(cx.src[lead:lo])
			more := make([dynamic]u8, 0, 64, cx.allocator)
			for eh in n.elems[1:] {
				append(&more, sep)
				spell_xml_element(cx, tag_name, eh, &more) or_return
			}
			append(&cx.splices, Splice{lo = hi, hi = hi, text = more[:], seq = len(cx.splices), base_node = v, full_rewalk = true}) or_return
		}
		if len(n.facts) > 0 {
			emit_markup_facts(cx, n) or_return
		}
		return nil
	}

	emit_element_content_splice(cx, v, el, tag_name, h) or_return
	if len(n.facts) > 0 {
		emit_markup_facts(cx, n) or_return
	}
	return nil
}

@(private = "file")
emit_element_content_splice :: proc(cx: ^Markup_Cx, v: tape.Node_Index, el: Markup_Element, tag_name: string, val_h: Handle) -> Error {
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	cx.spec.spell_content(cx.spec.data, cx.ov, val_h, &buf) or_return
	if len(buf) > 0 && cx.spec.is_void != nil && cx.spec.is_void(tag_name) {
		return refuse(.Void_Content, "void element cannot hold content", v, el.lo)
	}
	if !el.empty {
		append(&cx.splices, Splice{lo = el.open, hi = el.close, text = buf[:], seq = len(cx.splices), base_node = v, subtree_only = true}) or_return
	} else if len(buf) > 0 {
		expanded := make([dynamic]u8, 0, len(buf) + len(tag_name) + 5, cx.allocator)
		append(&expanded, '>')
		append(&expanded, ..buf[:])
		append(&expanded, "</")
		append(&expanded, tag_name)
		append(&expanded, '>')
		append(&cx.splices, Splice{lo = el.open, hi = el.hi, text = expanded[:], seq = len(cx.splices), base_node = v, subtree_only = true}) or_return
	}
	return nil
}

@(private = "file")
spell_xml_element :: proc(cx: ^Markup_Cx, name: string, val_h: Handle, out: ^[dynamic]u8) -> Error {
	if !cx.spec.is_name(transmute([]u8)name) {
		return refuse(.Bad_Name, "invalid XML element name")
	}
	content := make([dynamic]u8, 0, 64, cx.allocator)
	defer delete(content)
	if err := cx.spec.spell_content(cx.spec.data, cx.ov, val_h, &content); err != nil {
		return err
	}
	void_el := cx.spec.is_void != nil && cx.spec.is_void(name)
	if len(content) > 0 && void_el {
		return refuse(.Void_Content, "void element cannot hold content")
	}
	append(out, '<')
	append(out, name)
	// Emit any attributes attached to the newly created node!
	if vn, ok := get_node(cx.ov, val_h); ok {
		for f in vn.facts {
			if f.kind == .Attribute && !f.deleted && len(f.values) > 0 {
				if !cx.spec.is_name(transmute([]u8)f.attr) {
					return refuse(.Bad_Name, "invalid XML attribute name")
				}
				append(out, ' ')
				append(out, f.attr)
				append(out, `="`)
				cx.spec.spell_attr_val(cx.spec.data, f.values[0], '"', out) or_return
				append(out, '"')
			}
		}
	}
	if len(content) == 0 && (void_el || cx.spec.self_closing) {
		append(out, "/>" if cx.spec.self_closing else ">")
	} else {
		append(out, '>')
		append(out, ..content[:])
		append(out, "</")
		append(out, name)
		append(out, '>')
	}
	return nil
}

@(private = "file")
emit_markup_facts :: proc(cx: ^Markup_Cx, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE {
		return nil
	}
	v := n.base
	if is_text_run(cx.doc, v) {
		// `#text` run has no tag for attributes or element comments.
		for f in n.facts {
			if !f.deleted {
				return refuse(.Fact_No_Place, "cannot attach fact to #text run", v)
			}
		}
		return nil
	}
	el := cx.spec.element(cx.doc, v)
	for f in n.facts {
		#partial switch f.kind {
		case .Attribute:
			if v == tape.ROOT {
				return refuse(.Fact_No_Place, "document root has no attributes (target the root element instead)", v)
			}
			emit_xml_attribute_fact(cx, v, el, f) or_return
		case .Comment, .Comment_Inline, .Comment_Foot:
			if !f.deleted {
				for body in f.values {
					if !xml_comment_valid(body) {
						return refuse(.Bad_Xml_Comment, "XML comment cannot contain '--' or end with '-'", v, el.lo)
					}
				}
			}
			emit_xml_comment_fact(cx, v, el, f) or_return
		case:
			if !f.deleted {
				cx.dropped += {f.kind}
			}
		}
	}
	return nil
}

@(private = "file")
emit_xml_attribute_fact :: proc(cx: ^Markup_Cx, v: tape.Node_Index, el: Markup_Element, f: Fact_Override) -> Error {
	if len(f.attr) == 0 || !cx.spec.is_name(transmute([]u8)f.attr) {
		return refuse(.Bad_Name, "invalid XML attribute name", v, el.lo)
	}
	// Check if this attribute modifies an `xmlns` declaration (forces full_rewalk for namespace scopes).
	touches_xmlns := f.attr == "xmlns" || strings.has_prefix(f.attr, "xmlns:")

	// Search existing attributes on `v` in `doc.facts`.
	found_fact: tape.Fact
	has_existing := false
	for bf in tape.facts_of(cx.doc, v) {
		if bf.kind != .Attribute {
			continue
		}
		// Skip DTD `<!ATTLIST>` defaulted attributes (their spans lie outside this element's start tag!).
		if bf.lo < el.lo || bf.lo >= el.open {
			continue
		}
		kt, _ := cx.doc.format.attribute(cx.doc, bf)
		if string(tape.span_bytes(cx.doc, kt.lo, kt.n)) == f.attr {
			found_fact = bf
			has_existing = true
			break
		}
	}

	if f.deleted || len(f.values) == 0 {
		if !has_existing {
			return nil
		}
		// Remove attribute and its preceding whitespace inside the start tag!
		lo := found_fact.lo
		hi := found_fact.lo + u64(found_fact.n)
		for lo > el.name && kernel.is_markup_ws(cx.src[lo - 1]) {
			lo -= 1
		}
		if _, aerr := append(&cx.splices, Splice{lo = lo, hi = hi, seq = len(cx.splices), base_node = v, full_rewalk = touches_xmlns}); aerr != nil {
			return aerr
		}
		return nil
	}

	if has_existing {
		// Replace value in place, preserving original quote character (`"` or `'`) and attribute order!
		_, vt := cx.doc.format.attribute(cx.doc, found_fact)
		quote := u8('"')
		if vt.lo > 0 && (cx.src[vt.lo - 1] == '"' || cx.src[vt.lo - 1] == '\'') {
			quote = cx.src[vt.lo - 1]
		}
		buf := make([dynamic]u8, 0, len(f.values[0]) + 4, cx.allocator)
		cx.spec.spell_attr_val(cx.spec.data, f.values[0], quote, &buf) or_return
		append(&cx.splices, Splice{lo = vt.lo, hi = vt.lo + u64(vt.n), text = buf[:], seq = len(cx.splices), base_node = v, full_rewalk = touches_xmlns}) or_return
		return nil
	}

	// Append new attribute just before `>` (or `/>`).
	ins_at := el.open if el.empty else el.open - 1
	buf := make([dynamic]u8, 0, len(f.attr) + len(f.values[0]) + 6, cx.allocator)
	append(&buf, ' ')
	append(&buf, f.attr)
	append(&buf, `="`)
	cx.spec.spell_attr_val(cx.spec.data, f.values[0], '"', &buf) or_return
	append(&buf, '"')
	append(&cx.splices, Splice{lo = ins_at, hi = ins_at, text = buf[:], seq = len(cx.splices), base_node = v, full_rewalk = touches_xmlns}) or_return
	return nil
}

@(private = "file")
emit_xml_comment_fact :: proc(cx: ^Markup_Cx, v: tape.Node_Index, el: Markup_Element, f: Fact_Override) -> Error {
	existing := make([dynamic]tape.Fact, 0, 4, cx.allocator)
	for bf in tape.facts_of(cx.doc, v) {
		if bf.kind == f.kind {
			append(&existing, bf)
		}
	}
	if f.deleted || len(f.values) == 0 {
		for bf in existing {
			append(&cx.splices, Splice{lo = bf.lo, hi = bf.lo + u64(bf.n), seq = len(cx.splices), base_node = v, full_rewalk = true}) or_return
		}
		return nil
	}
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	for body, i in f.values {
		if !xml_comment_valid(body) {
			return refuse(.Bad_Xml_Comment, "XML comment cannot contain '--' or end with '-'", v, el.lo)
		}
		if i > 0 {
			append(&buf, cx.eol)
		}
		append(&buf, "<!--")
		if f.padded {
			append(&buf, ' ')
		}
		append(&buf, body)
		if f.padded {
			append(&buf, ' ')
		}
		append(&buf, "-->")
	}
	if len(existing) > 0 {
		lo := existing[0].lo
		hi := existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n)
		append(&cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = v, full_rewalk = true}) or_return
		return nil
	}
	ins_at: u64
	#partial switch f.kind {
	case .Comment:
		ins_at = el.lo
	case .Comment_Inline:
		ins_at = el.hi
	case .Comment_Foot:
		if v == tape.ROOT {
			ins_at = el.hi
		} else {
			if el.empty {
				return refuse(.Fact_No_Place, "self-closing XML element cannot hold a foot comment", v, el.lo)
			}
			ins_at = el.close
		}
	}
	append(&cx.splices, Splice{lo = ins_at, hi = ins_at, text = buf[:], seq = len(cx.splices), base_node = v, full_rewalk = true}) or_return
	return nil
}

@(private = "file")
emit_markup_container_delta :: proc(cx: ^Markup_Cx, h: Handle, n: ^Edit_Node, stack: ^[dynamic]Handle) -> Error {
	d := n.delta
	if d == nil {
		return nil
	}
	base_c := n.base
	Child_Item :: struct {
		kn, vn:     tape.Node_Index,
		name:       string,
		lead, lo, hi: u64,
		head_lo:    u64,
		inline_hi:  u64,
		deleted:    bool,
		is_text:    bool,
	}
	items := make([dynamic]Child_Item, 0, 8, cx.allocator)

	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if p == .Found {
		for {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c, .Group)
			if np != .Found {
				break
			}
			is_txt := is_text_run(cx.doc, vn)
			name := markup.TEXT_KEY if is_txt else string(tape.span_bytes(cx.doc, cx.doc.nodes[kn].lo, cx.doc.nodes[kn].n))
			lead, lo, hi := markup_extent(cx, vn)
			head_lo, inline_hi := lo, hi
			for f in tape.facts_of(cx.doc, vn) {
				if f.kind == .Comment && f.lo < head_lo {
					head_lo = f.lo
				} else if f.kind == .Comment_Inline && f.lo + u64(f.n) > inline_hi {
					inline_hi = f.lo + u64(f.n)
				}
			}
			is_del := false
			for dk in d.deleted_keys {
				if dk == name {
					is_del = true
					break
				}
			}
			if !is_del {
				for r in d.renamed_members {
					if r.old_key == name {
						if is_txt || !cx.spec.is_name(transmute([]u8)r.new_key) {
							return refuse(.Bad_Name, "cannot rename #text or use invalid XML name", kn)
						}
						el := cx.spec.element(cx.doc, vn)
						n1 := slice.clone(transmute([]u8)r.new_key, cx.allocator)
						append(&cx.splices, Splice{lo = el.lo + 1, hi = el.name, text = n1, seq = len(cx.splices), base_node = base_c, full_rewalk = true})
						if el.end_tag {
							n2 := slice.clone(transmute([]u8)r.new_key, cx.allocator)
							append(&cx.splices, Splice{lo = el.close + 2, hi = el.close + 1 + el.name - el.lo, text = n2, seq = len(cx.splices), base_node = base_c, full_rewalk = true})
						}
						break
					}
				}
			}
			append(&items, Child_Item{kn = kn, vn = vn, name = name, lead = lead, lo = lo, hi = hi, head_lo = head_lo, inline_hi = inline_hi, deleted = is_del, is_text = is_txt})
		}
	}

	// Push surviving edited child subtrees (marking extra unedited siblings deleted if first sibling was array-replaced).
	array_replaced := make([dynamic]string, 0, 2, cx.allocator)
	for &it in items {
		if it.deleted {
			continue
		}
		if ch, has := cx.ov.by_base[it.vn]; has {
			if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits {
				if cn.state == .Replaced && cn.val.kind == .Array && !it.is_text {
					append(&array_replaced, it.name)
				}
				append(stack, ch)
				continue
			}
		}
		if !it.is_text {
			for rep_name in array_replaced {
				if rep_name == it.name {
					it.deleted = true
					break
				}
			}
		}
	}

	// Reorder children via `Move` splices.
	if len(d.order) > 0 {
		deleted_flags := make([]bool, len(items), cx.allocator)
		for it, i in items {
			if it.is_text {
				return refuse(.Layout_Reflow_Needed, "cannot reorder XML element containing #text runs", base_c)
			}
			deleted_flags[i] = it.deleted
		}
		validate_order(d.order, deleted_flags, len(d.inserted_members), cx.allocator) or_return

		places := make([dynamic]int, 0, len(items), cx.allocator)
		for it, i in items {
			if !it.deleted {
				append(&places, i)
			}
		}
		if len(places) > 0 {
			last := items[places[len(places) - 1]]
			sep := string(cx.src[last.lead:last.lo])
			moves := make([dynamic]Move, 0, len(d.order) * 2, cx.allocator)
			for raw, pos in d.order {
				k := int(raw)
				if pos > 0 {
					if pos < len(places) {
						append(&moves, Move{lo = items[places[pos - 1]].inline_hi, hi = items[places[pos]].head_lo})
					} else if len(sep) > 0 {
						append(&moves, Move{text = slice.clone(transmute([]u8)sep, cx.allocator), written = true})
					}
				}
				if k < len(items) {
					append(&moves, Move{lo = items[k].head_lo, hi = items[k].inline_hi})
				} else {
					ins := d.inserted_members[k - len(items)]
					b := make([dynamic]u8, 0, 64, cx.allocator)
					spell_xml_element(cx, ins.key, ins.value, &b) or_return
					append(&moves, Move{text = b[:], written = true})
				}
			}
			append(&cx.splices, Splice {
				lo          = items[places[0]].head_lo,
				hi          = last.inline_hi,
				moves       = moves[:],
				seq         = len(cx.splices),
				base_node   = base_c,
				full_rewalk = true,
			})
			return nil
		}
	}

	// Deletions.
	surviving := 0
	for it in items {
		if it.deleted {
			append(&cx.splices, Splice{lo = it.lead, hi = it.hi, seq = len(cx.splices), base_node = base_c, full_rewalk = true})
		} else {
			surviving += 1
		}
	}
	if surviving == 0 && len(d.inserted_members) == 0 && base_c != tape.ROOT && len(items) > 0 {
		el := cx.spec.element(cx.doc, base_c)
		last_hi := items[len(items) - 1].hi
		if last_hi < el.close {
			all_ws := true
			for q := last_hi; q < el.close; q += 1 {
				if !kernel.is_markup_ws(cx.src[q]) {
					all_ws = false
					break
				}
			}
			if all_ws {
				append(&cx.splices, Splice{lo = last_hi, hi = el.close, seq = len(cx.splices), base_node = base_c, full_rewalk = true})
			}
		}
	}

	// Insertions.
	if len(d.inserted_members) > 0 {
		parent_el := cx.spec.element(cx.doc, base_c)
		// Self-closing parent `<p/>` with zero base children: expand `<p/>` ONCE for all inserted children!
		if len(items) == 0 && parent_el.empty {
			p_name := string(cx.src[parent_el.lo + 1:parent_el.name])
			b := make([dynamic]u8, 0, 64, cx.allocator)
			append(&b, '>')
			for ins in d.inserted_members {
				if ins.key == markup.TEXT_KEY {
					if node_kind(cx.ov, ins.value) == .Array || node_kind(cx.ov, ins.value) == .Object {
						return refuse(.Text_Markup, "cannot insert element or array as #text", base_c)
					}
					cx.spec.spell_content(cx.spec.data, cx.ov, ins.value, &b) or_return
				} else {
					spell_xml_element(cx, ins.key, ins.value, &b) or_return
				}
			}
			append(&b, "</")
			append(&b, p_name)
			append(&b, '>')
			append(&cx.splices, Splice{lo = parent_el.open, hi = parent_el.hi, text = b[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
			return nil
		}
		sep := string(cx.src[items[len(items) - 1].lead:items[len(items) - 1].lo]) if len(items) > 0 else ""
		for ins in d.inserted_members {
			if ins.key == markup.TEXT_KEY {
				if node_kind(cx.ov, ins.value) == .Array || node_kind(cx.ov, ins.value) == .Object {
					return refuse(.Text_Markup, "cannot insert element or array as #text", base_c)
				}
				b := make([dynamic]u8, 0, 32, cx.allocator)
				cx.spec.spell_content(cx.spec.data, cx.ov, ins.value, &b) or_return
				pos := items[ins.at].lo if ins.at >= 0 && ins.at < len(items) else (items[len(items) - 1].hi if len(items) > 0 else parent_el.close)
				append(&cx.splices, Splice{lo = pos, hi = pos, text = b[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true})
				continue
			}
			b := make([dynamic]u8, 0, 64, cx.allocator)
			if ins.at >= 0 && ins.at < len(items) {
				spell_xml_element(cx, ins.key, ins.value, &b) or_return
				append(&b, sep)
				pos := items[ins.at].lo
				append(&cx.splices, Splice{lo = pos, hi = pos, text = b[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true})
			} else if len(items) > 0 {
				append(&b, sep)
				spell_xml_element(cx, ins.key, ins.value, &b) or_return
				pos := items[len(items) - 1].hi
				append(&cx.splices, Splice{lo = pos, hi = pos, text = b[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true})
			} else {
				spell_xml_element(cx, ins.key, ins.value, &b) or_return
				append(&cx.splices, Splice{lo = parent_el.close, hi = parent_el.close, text = b[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true})
			}
		}
	}
	return nil
}
