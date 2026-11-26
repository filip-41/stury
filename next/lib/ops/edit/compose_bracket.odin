package edit

import "base:runtime"
import "core:bytes"
import "core:container/handle_map"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"

// Bracket-family composer (JSON, JSONC, JSON5).
//
// Preserves every untargeted byte verbatim: indentation, spacing, trailing commas, comments (including comments of
// removed members and comments on multi-item flow lines attached to the preceding item — Group 2), JSON5 unquoted
// keys / single quotes, and style inheritance from neighbours for newly inserted values.
// Under `Options.reflow`, rewrites only the smallest enclosing container that cannot be locally spliced, reporting
// its output range in `Commit_Result.rewritten`.

Bracket_Comment_Syntax :: struct {
	line:  string, // "//"
	open:  string, // "/*"
	close: string, // "*/"
}

Bracket_Spec :: struct {
	// Target format handle (e.g. json.as(.Jsonc)).
	target:         ^tape.Format,
	// Whether the target spec allows comments (`.Jsonc`, `.Json5`) and trailing commas.
	allows_comments: bool,
	trailing_comma:  bool,
	comment:         Bracket_Comment_Syntax,
	// Spells `ov`'s node `h` (which may be a newly built or replaced subtree) into `out` at `indent` using `unit`/`eol`.
	// `style` is an optional `.Style` override (e.g. "single", "double", "unquoted").
	spell_value: proc(
		data: rawptr,
		ov: ^Overlay,
		h: Handle,
		out: ^[dynamic]u8,
		indent: string,
		unit: string,
		eol: string,
		style: string,
	) -> Error,
	// Spells an object key `key` into `out` (inheriting neighbour quote style when `quote` is '\'' or '"' or 0 for bare/default).
	spell_key: proc(data: rawptr, key: string, out: ^[dynamic]u8, quote: u8) -> Error,
	// Optional validator for `.Raw` value texts and final output.
	validate:  proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:      rawptr,
}

// Commits `ov` through the bracket-family composer.
commit_bracket :: proc(
	ov: ^Overlay,
	spec: ^Bracket_Spec,
	opts := Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Error,
) {
	extra_clean := ov != nil && ov.base != nil && (spec.allows_comments || (ov.base.present & tape.COMMENTS) == {})
	cx := Bracket_Cx {
		ov   = ov,
		doc  = ov.base if ov != nil else nil,
		src  = ov.base.src if ov != nil && ov.base != nil else nil,
		spec = spec,
		opts = opts,
	}
	tc := Text_Composer {
		target        = spec.target,
		extra_clean   = extra_clean,
		req_root      = .End,
		validate      = spec.validate,
		validate_data = spec.data,
		fast_emit     = bracket_fast_emit,
		struct_emit   = bracket_struct_emit,
		frag_check    = bracket_frag_check,
		user          = &cx,
	}
	return run_text_commit(ov, &tc, opts, allocator)
}

@(private = "file")
bracket_fast_emit :: proc(
	user: rawptr,
	ov: ^Overlay,
	doc: ^tape.Document,
	splices: ^[dynamic]Splice,
	scratch: runtime.Allocator,
) -> (ok: bool, err: Error) {
	cx := (^Bracket_Cx)(user)
	if !cx.spec.allows_comments && (doc.present & tape.COMMENTS) != {} {
		return false, nil
	}
	cx.allocator = scratch
	cx.splices = splices
	sorted_bases := true
	prev_base := tape.Node_Index(0)
	has_prev := false
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		if n.state == .Replaced && n.has_edits && n.base != tape.NO_NODE && doc.nodes[n.base].role == .Value {
			if has_prev && n.base < prev_base {
				sorted_bases = false
			}
			prev_base = n.base
			has_prev = true
			emit_bracket_replace(cx, n.handle, n) or_return
		}
	}
	if !bracket_fast_has_duplicate_key(doc, cx.splices^[:], sorted_bases, scratch) {
		return true, nil
	}
	clear(cx.splices)
	return false, nil
}

@(private = "file")
bracket_struct_emit :: proc(
	user: rawptr,
	ov: ^Overlay,
	doc: ^tape.Document,
	eol: string,
	splices: ^[dynamic]Splice,
	dropped: ^tape.Facts,
	scratch: runtime.Allocator,
) -> Error {
	cx := (^Bracket_Cx)(user)
	cx.allocator = scratch
	cx.splices = splices
	cx.eol = eol
	if !cx.spec.allows_comments && (doc.present & tape.COMMENTS) != {} {
		cx.dropped += doc.present & tape.COMMENTS
		strip_source_comments(cx) or_return
	}
	if ov.root != NO_HANDLE {
		compose_bracket_walk(cx, ov.root) or_return
	}
	dropped^ = cx.dropped
	return nil
}

@(private = "file")
bracket_frag_check :: proc(user: rawptr, out: []u8, recs: []Splice_Record, scratch: runtime.Allocator) -> (bool, Error) {
	cx := (^Bracket_Cx)(user)
	for rec in recs {
		if !rec.subtree_only || rec.full_rewalk {
			return true, nil
		}
		frag := out[rec.dst_lo:rec.dst_hi]
		if is_simple_json_scalar(frag) {
			continue
		}
		if has_utf8_bom(frag) ||
			bytes.index_byte(frag, '[') >= 0 ||
			bytes.index_byte(frag, '{') >= 0 ||
			(cx.spec.allows_comments && bytes.index(frag, transmute([]u8)string("//")) >= 0) {
			return true, nil
		}
		if verr := cx.spec.validate(cx.spec.data, frag, scratch); verr != nil {
			return false, convert_tape_error(verr)
		}
	}
	return false, nil
}

@(private)
convert_tape_error :: proc "contextless" (err: tape.Error) -> Error {
	switch e in err {
	case tape.Fault:
		return e
	case tape.Exceeded:
		return e
	case tape.Bad_Option:
		return e
	case runtime.Allocator_Error:
		return e
	case tape.Piece_Gap:
		return refuse(.Invalid_Result, "unexpected piece gap")
	}
	return nil
}

@(private = "file")
Bracket_Cx :: struct {
	ov:        ^Overlay,
	doc:       ^tape.Document,
	src:       []u8,
	spec:      ^Bracket_Spec,
	opts:      Options,
	eol:       string,
	splices:   ^[dynamic]Splice,
	dropped:   tape.Facts,
	allocator: runtime.Allocator,
}

@(private = "file")
bracket_default_unit :: proc(cx: ^Bracket_Cx) -> string {
	if cx.opts.tab {
		return "\t"
	}
	switch cx.opts.indent {
	case 0, 2:
		return "  "
	case 4:
		return "    "
	case 1:
		return " "
	case 3:
		return "   "
	}
	return "  "
}

@(private = "file")
strip_source_comments :: proc(cx: ^Bracket_Cx) -> Error {
	for f in cx.doc.facts {
		if f.kind not_in tape.COMMENTS {
			continue
		}
		lo := f.lo
		hi := f.lo + u64(f.n)
		// If comment occupies its own line, drop the entire line; otherwise drop comment and leading horizontal spaces.
		if first_on_line(cx.src, lo) {
			q := hi
			for q < u64(len(cx.src)) && (cx.src[q] == ' ' || cx.src[q] == '\t' || cx.src[q] == '\r') {
				q += 1
			}
			if q < u64(len(cx.src)) && cx.src[q] == '\n' {
				lo = line_start(cx.src, lo)
				hi = q + 1
			}
		} else {
			for lo > 0 && (cx.src[lo - 1] == ' ' || cx.src[lo - 1] == '\t') {
				lo -= 1
			}
		}
		if _, aerr := append(cx.splices, Splice{lo = lo, hi = hi, seq = len(cx.splices), base_node = f.node, full_rewalk = true}); aerr != nil {
			return aerr
		}
	}
	return nil
}

@(private = "file")
compose_bracket_walk :: proc(cx: ^Bracket_Cx, root: Handle) -> Error {
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
			emit_bracket_replace(cx, h, n) or_return
			continue
		}
		// Check duplicate-key reflow BEFORE emitting facts (so inner `.Comment_Foot` never collides with reflow span!).
		if n.base != tape.NO_NODE && cx.doc.nodes[n.base].kind == .Object {
			has_dup, derr := bracket_has_edited_duplicate_key(cx, n)
			if derr != nil {
				return derr
			}
			if has_dup {
				c_lo, c_hi, cok := node_byte_span(cx.doc, n.base)
				if !cx.opts.reflow || !cok {
					return refuse(.Layout_Reflow_Needed, "editing a duplicated object key requires reflow", n.base, c_lo)
				}
				emit_bracket_reflow(cx, h, n, n.base, c_lo, c_hi) or_return
				continue
			}
		}
		// Apply fact edits on `.Ancestor` or `.Container_Delta`.
		if len(n.facts) > 0 {
			emit_bracket_facts(cx, h, n) or_return
		}
		if n.state == .Container_Delta {
			emit_bracket_container_delta(cx, h, n, &stack) or_return
			continue
		}
		// `.Ancestor`: push any direct child base nodes that have edits in `ov.by_base`.
		if n.base != tape.NO_NODE {
			push_edited_base_children(cx, h, n.base, &stack) or_return
		}
	}
	return nil
}

@(private = "file")
push_edited_base_children :: proc(cx: ^Bracket_Cx, parent_h: Handle, base_container: tape.Node_Index, stack: ^[dynamic]Handle) -> Error {
	node := cx.doc.nodes[base_container]
	if node.kind < .Array {
		return nil
	}
	// Sparse fast path: when `ov.by_base` is smaller than this container's child count (e.g. 1 edit inside a
	// 37,000-element array), scan `ov.by_base` directly in O(|edited|) instead of walking every base child!
	if cc := tape.child_count(cx.doc, base_container, node); cc > 16 && len(cx.ov.by_base) < cc {
		for _, ch in cx.ov.by_base {
			if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits && cn.parent == parent_h {
				if _, aerr := append(stack, ch); aerr != nil {
					return aerr
				}
			}
		}
		return nil
	}
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_container, cx.allocator)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if p != .Found {
		return nil
	}
	for {
		_, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
		if np != .Found {
			break
		}
		if ch, has := cx.ov.by_base[vn]; has {
			if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits {
				if _, aerr := append(stack, ch); aerr != nil {
					return aerr
				}
			}
		}
	}
	return nil
}

@(private = "file")
style_override_of :: proc "contextless" (n: ^Edit_Node) -> string {
	for f in n.facts {
		if f.kind == .Style && !f.deleted && len(f.values) > 0 {
			return f.values[0]
		}
	}
	return ""
}

@(private = "file")
emit_bracket_replace :: proc(cx: ^Bracket_Cx, h: Handle, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE {
		return nil
	}
	lo, hi, ok := node_byte_span(cx.doc, n.base)
	if !ok {
		return refuse(.Bad_Handle, "cannot locate base node span", n.base)
	}
	text: []u8
	has_foot := false
	foot_override: Fact_Override
	for f in n.facts {
		if f.kind == .Comment_Foot {
			has_foot = true
			foot_override = f
		}
	}
	if n.val.kind == .Raw {
		text = transmute([]u8)n.val.text
		if has_foot && !foot_override.deleted && len(foot_override.values) > 0 && cx.spec.allows_comments {
			if injected, iok := inject_raw_bracket_foot(cx, text, lo, foot_override); iok {
				text = injected
			}
		}
	} else {
		needs_indent := n.val.kind == .Array || n.val.kind == .Object ||
			(n.val.kind == .Base_Ref && n.val.base_ref != tape.NO_NODE && cx.doc.nodes[n.val.base_ref].kind >= .Array) ||
			(has_foot && !foot_override.deleted && len(foot_override.values) > 0 && cx.spec.allows_comments)
		indent := line_indent(cx.src, lo) if needs_indent else ""
		eol := cx.eol
		if needs_indent && len(eol) == 0 {
			eol = detect_eol(cx.src)
			cx.eol = eol
		}
		unit := bracket_default_unit(cx) if needs_indent else ""
		buf := make([dynamic]u8, 0, 64, cx.allocator)
		if err := cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, indent, unit, eol, style_override_of(n)); err != nil {
			return err
		}
		text = buf[:]
	}
	if _, aerr := append(cx.splices, Splice {
		lo           = lo,
		hi           = hi,
		text         = text,
		seq          = len(cx.splices),
		base_node    = n.base,
		subtree_only = true,
	}); aerr != nil {
		return aerr
	}
	// Emit outer fact edits attached directly to `h`, skipping `.Comment_Foot` (already spelled inside `[lo, hi)`).
	if len(n.facts) > 0 {
		emit_bracket_facts(cx, h, n, skip_foot = true, skip_span = {lo, hi}) or_return
	}
	return nil
}

@(private = "file")
inject_raw_bracket_foot :: proc(cx: ^Bracket_Cx, raw: []u8, base_lo: u64, f: Fact_Override) -> ([]u8, bool) {
	if len(raw) < 2 {
		return nil, false
	}
	close_idx := len(raw) - 1
	for close_idx > 0 && (raw[close_idx] == ' ' || raw[close_idx] == '\t' || raw[close_idx] == '\r' || raw[close_idx] == '\n') {
		close_idx -= 1
	}
	if raw[close_idx] != ']' && raw[close_idx] != '}' {
		return nil, false
	}
	syn := cx.spec.comment
	if syn.line == "" {
		syn = {line = "//", open = "/*", close = "*/"}
	}
	eol := cx.eol if len(cx.eol) > 0 else "\n"
	c_indent := line_indent(cx.src, base_lo)
	inner_indent := strings.concatenate({c_indent, bracket_default_unit(cx)}, cx.allocator)
	b := make([dynamic]u8, 0, len(raw) + 32, cx.allocator)
	append(&b, ..raw[:close_idx])
	if close_idx > 0 && raw[close_idx - 1] != '\n' {
		append(&b, eol)
	}
	for line in f.values {
		append(&b, inner_indent)
		append_comment_line(&b, syn, line, f.padded)
		append(&b, eol)
	}
	append(&b, c_indent)
	append(&b, ..raw[close_idx:])
	return b[:], true
}

@(private = "file")
emit_bracket_facts :: proc(cx: ^Bracket_Cx, h: Handle, n: ^Edit_Node, skip_foot := false, skip_span := Byte_Range{}) -> Error {
	if n.base == tape.NO_NODE {
		return nil
	}
	lo, hi, ok := node_byte_span(cx.doc, n.base)
	if !ok {
		return nil
	}
	// For object member values, head comments go before the member's key!
	head_anchor := lo
	if n.base > 0 && cx.doc.nodes[n.base - 1].role == .Key {
		if klo, _, kok := node_byte_span(cx.doc, n.base - 1); kok {
			head_anchor = klo
		}
	}
	for f in n.facts {
		#partial switch f.kind {
		case .Comment, .Comment_Inline, .Comment_Foot:
			if !cx.spec.allows_comments {
				if !f.deleted {
					cx.dropped += {f.kind}
				}
				continue
			}
			if skip_foot && f.kind == .Comment_Foot {
				continue
			}
			emit_bracket_comment_fact(cx, n.base, f, head_anchor, hi, skip_span) or_return
		case .Style:
			// Style-only edit on an unreplaced scalar (e.g., changing quote style in JSON5).
			if n.state != .Replaced && !f.deleted && len(f.values) > 0 {
				buf := make([dynamic]u8, 0, 32, cx.allocator)
				cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, "", "", cx.eol, f.values[0]) or_return
				append(cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = n.base, subtree_only = true}) or_return
			}
		case:
			// Facts JSON/JSONC/JSON5 cannot emit (tags, anchors, attributes, etc.) are dropped cleanly per analysis.md §2.
			if !f.deleted {
				cx.dropped += {f.kind}
			}
		}
	}
	return nil
}

@(private = "file")
emit_bracket_comment_fact :: proc(
	cx: ^Bracket_Cx,
	node: tape.Node_Index,
	f: Fact_Override,
	head_anchor, val_hi: u64,
	skip_span := Byte_Range{},
) -> Error {
	// Find existing base facts of this kind on `node`.
	existing := collect_base_facts(cx.doc, node, f.kind, cx.allocator)
	defer delete(existing)
	if f.deleted || len(f.values) == 0 {
		// Remove existing comments of this kind (skipping any strictly inside an already-replaced `skip_span`).
		for bf in existing {
			lo := bf.lo
			hi := bf.lo + u64(bf.n)
			if f.kind != .Comment_Inline && first_on_line(cx.src, lo) {
				q := hi
				for q < u64(len(cx.src)) && (cx.src[q] == ' ' || cx.src[q] == '\t' || cx.src[q] == '\r') {
					q += 1
				}
				if q < u64(len(cx.src)) && cx.src[q] == '\n' {
					lo = line_start(cx.src, lo)
					hi = q + 1
				}
			} else if f.kind == .Comment_Inline {
				for lo > 0 && (cx.src[lo - 1] == ' ' || cx.src[lo - 1] == '\t') {
					lo -= 1
				}
			}
			if skip_span.hi > skip_span.lo && lo >= skip_span.lo && hi <= skip_span.hi {
				continue
			}
			if _, aerr := append(cx.splices, Splice{lo = lo, hi = hi, seq = len(cx.splices), base_node = node, full_rewalk = true}); aerr != nil {
				return aerr
			}
		}
		return nil
	}

	syn := cx.spec.comment
	if syn.line == "" {
		syn = {line = "//", open = "/*", close = "*/"}
	}
	indent := line_indent(cx.src, head_anchor)

	// Build replacement comment text.
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	switch f.kind {
	case .Comment:
		for line, i in f.values {
			if i > 0 {
				append(&buf, indent)
			}
			append_comment_line(&buf, syn, line, f.padded)
			append(&buf, cx.eol)
		}
		if len(existing) > 0 {
			lo := line_start(cx.src, existing[0].lo) if first_on_line(cx.src, existing[0].lo) else existing[0].lo
			last := existing[len(existing) - 1]
			hi := next_line(cx.src, last.lo + u64(last.n)) if first_on_line(cx.src, last.lo) else last.lo + u64(last.n)
			full := make([dynamic]u8, 0, len(indent) + len(buf), cx.allocator)
			if first_on_line(cx.src, existing[0].lo) {
				append(&full, indent)
			}
			append(&full, ..buf[:])
			append(cx.splices, Splice{lo = lo, hi = hi, text = full[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		} else {
			ins_at := line_start(cx.src, head_anchor) if first_on_line(cx.src, head_anchor) else head_anchor
			full := make([dynamic]u8, 0, len(indent) + len(buf), cx.allocator)
			if first_on_line(cx.src, head_anchor) {
				append(&full, indent)
			}
			append(&full, ..buf[:])
			append(cx.splices, Splice{lo = ins_at, hi = ins_at, text = full[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
	case .Comment_Inline:
		append(&buf, " ")
		append_comment_line(&buf, syn, f.values[0], f.padded)
		if len(existing) > 0 {
			lo := existing[0].lo
			for lo > 0 && (cx.src[lo - 1] == ' ' || cx.src[lo - 1] == '\t') {
				lo -= 1
			}
			hi := existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n)
			append(cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		} else {
			ins_at := val_hi
			q := val_hi
			for q < u64(len(cx.src)) && (cx.src[q] == ' ' || cx.src[q] == '\t') {
				q += 1
			}
			if q < u64(len(cx.src)) && cx.src[q] == ',' {
				ins_at = q + 1
			}
			append(cx.splices, Splice{lo = ins_at, hi = ins_at, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
	case .Comment_Foot:
		close_at := val_hi - 1 if val_hi > 0 else val_hi
		c_indent := line_indent(cx.src, close_at)
		inner_indent := strings.concatenate({c_indent, bracket_default_unit(cx)}, cx.allocator)
		if len(existing) > 0 {
			for line, i in f.values {
				if i > 0 {
					append(&buf, cx.eol)
				}
				append(&buf, inner_indent)
				append_comment_line(&buf, syn, line, f.padded)
			}
			lo := line_start(cx.src, existing[0].lo) if first_on_line(cx.src, existing[0].lo) else existing[0].lo
			hi := existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n)
			append(cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		} else {
			if !first_on_line(cx.src, close_at) {
				append(&buf, cx.eol)
			}
			for line in f.values {
				append(&buf, inner_indent)
				append_comment_line(&buf, syn, line, f.padded)
				append(&buf, cx.eol)
			}
			ins_at := line_start(cx.src, close_at) if first_on_line(cx.src, close_at) else close_at
			append(cx.splices, Splice{lo = ins_at, hi = ins_at, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
	case .Tag, .Anchor, .Alias, .Instruction, .Instruction_Foot, .Doctype, .Directive, .Attribute, .Style, .Name, .Namespace, .Content, .Absent:
	}
	return nil
}

@(private = "file")
append_comment_line :: proc(b: ^[dynamic]u8, syn: Bracket_Comment_Syntax, body: string, padded: bool) {
	if bytes.index_byte(transmute([]u8)body, '\n') >= 0 || bytes.index_byte(transmute([]u8)body, '\r') >= 0 {
		append(b, syn.open)
		if padded {
			append(b, " ")
		}
		append(b, body)
		if padded {
			append(b, " ")
		}
		append(b, syn.close)
		return
	}
	append(b, syn.line)
	if padded && len(body) > 0 {
		append(b, " ")
	}
	append(b, body)
}

// Item span inside a bracket container (`[...]` or `{...}`).
@(private = "file")
Bracket_Item :: struct {
	key_node:  tape.Node_Index, // tape.NO_NODE for array element
	val_node:  tape.Node_Index,
	lo:        u64,             // start of key (or value for array)
	hi:        u64,             // end of value
	head_lo:   u64,             // start of head comments on this item (or `lo`)
	inline_hi: u64,             // end of inline comment on this item (or `hi`)
	deleted:   bool,
}

@(private = "file")
emit_bracket_container_delta :: proc(cx: ^Bracket_Cx, h: Handle, n: ^Edit_Node, stack: ^[dynamic]Handle) -> Error {
	base_c := n.base
	d := n.delta
	if d == nil {
		return push_edited_base_children(cx, h, base_c, stack)
	}
	c_lo, c_hi, cok := node_byte_span(cx.doc, base_c)
	if !cok || c_hi < c_lo + 2 {
		return refuse(.Bad_Handle, "cannot locate container span", base_c)
	}
	is_obj := cx.doc.nodes[base_c].kind == .Object

	items := make([dynamic]Bracket_Item, 0, 8, cx.allocator)
	defer delete(items)
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if p == .Found {
		idx := u32(0)
		for {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found {
				break
			}
			vlo, vhi, vok := node_byte_span(cx.doc, vn)
			if !vok {
				return refuse(.Bad_Handle, "cannot locate child span", vn)
			}
			ilo := vlo
			if is_obj && kn != tape.NO_NODE {
				if klo, _, kok := node_byte_span(cx.doc, kn); kok {
					ilo = klo
				}
			}
			head_lo := ilo
			inline_hi := vhi
			for f in tape.facts_of(cx.doc, vn) {
				if f.kind == .Comment && f.lo < head_lo {
					head_lo = f.lo
				} else if f.kind == .Comment_Inline && f.lo + u64(f.n) > inline_hi {
					inline_hi = f.lo + u64(f.n)
				}
			}
			is_del := false
			if is_obj {
				kstr := decode_node_text_tmp(cx.doc, kn, cx.allocator)
				for dk in d.deleted_keys {
					if dk == kstr.text {
						is_del = true
						break
					}
				}
				if !is_del {
					for r in d.renamed_members {
						if r.old_key == kstr.text {
							klo, khi, kok := node_byte_span(cx.doc, kn)
							if kok {
								q := cx.src[klo] if klo < u64(len(cx.src)) && (cx.src[klo] == '"' || cx.src[klo] == '\'') else u8('"')
								kb := make([dynamic]u8, 0, len(r.new_key) + 2, cx.allocator)
								cx.spec.spell_key(cx.spec.data, r.new_key, &kb, q) or_return
								append(cx.splices, Splice{lo = klo, hi = khi, text = kb[:], seq = len(cx.splices), base_node = base_c}) or_return
							}
							break
						}
					}
				}
				free_tmp_text(kstr, cx.allocator)
			} else {
				for di in d.deleted_indices {
					if di == idx {
						is_del = true
						break
					}
				}
			}
			if _, aerr := append(&items, Bracket_Item{key_node = kn, val_node = vn, lo = ilo, hi = vhi, head_lo = head_lo, inline_hi = inline_hi, deleted = is_del}); aerr != nil {
				return aerr
			}
			idx += 1
		}
	}

	for it in items {
		if it.deleted {
			continue
		}
		if ch, has := cx.ov.by_base[it.val_node]; has {
			if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits {
				if _, aerr := append(stack, ch); aerr != nil {
					return aerr
				}
			}
		}
	}

	layout := detect_bracket_layout(cx, c_lo, c_hi, items[:], is_obj)

	ins_count := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	ins_texts := make([][]u8, ins_count, cx.allocator)
	ins_ats := make([]int, ins_count, cx.allocator)
	if is_obj {
		for ins, i in d.inserted_members {
			ins_texts[i] = spell_bracket_insert(cx, ins.key, ins.value, true, layout) or_return
			ins_ats[i] = ins.at
		}
	} else {
		for ins, i in d.inserted_elems {
			ins_texts[i] = spell_bracket_insert(cx, "", ins.value, false, layout) or_return
			ins_ats[i] = ins.at
		}
	}

	has_del := false
	for it in items {
		if it.deleted {
			has_del = true
			break
		}
	}
	has_order := len(d.order) > 0
	if !has_del && ins_count == 0 && !has_order {
		return nil
	}

	if has_order {
		deleted_flags := make_deleted_flags(items[:], cx.allocator) or_return
		defer delete(deleted_flags, cx.allocator)
		validate_order(d.order, deleted_flags, ins_count, cx.allocator) or_return
		ok_move, merr := emit_bracket_reorder(cx, base_c, c_lo, c_hi, items[:], d.order, ins_texts, layout)
		if merr != nil {
			return merr
		}
		if ok_move {
			return nil
		}
		if !cx.opts.reflow {
			return refuse(.Layout_Reflow_Needed, "container reorder requires reflow", base_c, c_lo)
		}
		return emit_bracket_reflow(cx, h, n, base_c, c_lo, c_hi, reemit_outer = false)
	}

	return emit_bracket_insert_delete(cx, base_c, c_lo, c_hi, items[:], ins_texts, ins_ats, layout)
}

@(private = "file")
spell_bracket_insert :: proc(cx: ^Bracket_Cx, key: string, val_h: Handle, is_obj: bool, layout: Bracket_Layout) -> (out: []u8, err: Error) {
	b := make([dynamic]u8, 0, 64, cx.allocator)
	ins_n, has_n := get_node(cx.ov, val_h)
	style := ""
	if has_n {
		style = style_override_of(ins_n)
		for f in ins_n.facts {
			if f.deleted {
				continue
			}
			#partial switch f.kind {
			case .Comment:
				if !cx.spec.allows_comments {
					cx.dropped += {.Comment}
					continue
				}
				syn := cx.spec.comment
				if syn.line == "" {
					syn = {line = "//", open = "/*", close = "*/"}
				}
				for line in f.values {
					if layout.multiline {
						append_comment_line(&b, syn, line, f.padded)
						append(&b, cx.eol)
						append(&b, layout.item_indent)
					} else {
						append(&b, syn.open)
						if f.padded && len(line) > 0 {
							append(&b, " ")
						}
						append(&b, line)
						if f.padded && len(line) > 0 {
							append(&b, " ")
						}
						append(&b, syn.close)
						append(&b, " ")
					}
				}
			case .Comment_Inline, .Comment_Foot, .Style:
			case:
				cx.dropped += {f.kind}
			}
		}
	}
	if is_obj {
		cx.spec.spell_key(cx.spec.data, key, &b, layout.key_quote) or_return
		append(&b, layout.colon)
	}
	cx.spec.spell_value(cx.spec.data, cx.ov, val_h, &b, layout.item_indent, layout.unit, cx.eol, style) or_return
	if has_n {
		for f in ins_n.facts {
			if !f.deleted && f.kind == .Comment_Inline && len(f.values) > 0 {
				if !cx.spec.allows_comments {
					cx.dropped += {.Comment_Inline}
					continue
				}
				syn := cx.spec.comment
				if syn.line == "" {
					syn = {line = "//", open = "/*", close = "*/"}
				}
				append(&b, " ")
				append(&b, syn.open)
				if f.padded && len(f.values[0]) > 0 {
					append(&b, " ")
				}
				append(&b, f.values[0])
				if f.padded && len(f.values[0]) > 0 {
					append(&b, " ")
				}
				append(&b, syn.close)
			}
		}
	}
	return b[:], nil
}

@(private = "file")
Bracket_Layout :: struct {
	multiline:      bool,
	trailing_comma: bool,
	key_quote:      u8,
	colon:          string,
	sep:            string,
	item_indent:    string,
	close_indent:   string,
	unit:           string,
}

@(private = "file")
detect_bracket_layout :: proc(cx: ^Bracket_Cx, c_lo, c_hi: u64, items: []Bracket_Item, is_obj: bool) -> Bracket_Layout {
	l := Bracket_Layout {
		key_quote    = '"',
		colon        = ": ",
		sep          = ", ",
		close_indent = line_indent(cx.src, c_lo),
		unit         = bracket_default_unit(cx),
	}
	if len(items) == 0 {
		// Check if empty container spans multiple lines (`{\n}`).
		if bytes.index_byte(cx.src[c_lo:c_hi], '\n') >= 0 {
			l.multiline = true
		}
		return l
	}
	first := items[0]
	l.multiline = first_on_line(cx.src, first.lo) && bytes.index_byte(cx.src[c_lo:first.lo], '\n') >= 0
	if l.multiline {
		l.item_indent = line_indent(cx.src, first.lo)
		// Infer unit from `item_indent` minus `close_indent`.
		if len(l.item_indent) > len(l.close_indent) && bytes.has_prefix(transmute([]u8)l.item_indent, transmute([]u8)l.close_indent) {
			l.unit = l.item_indent[len(l.close_indent):]
		}
	}
	if is_obj && first.key_node != tape.NO_NODE {
		klo, khi, kok := node_byte_span(cx.doc, first.key_node)
		vlo, _, vok := node_byte_span(cx.doc, first.val_node)
		if kok && klo < u64(len(cx.src)) {
			c := cx.src[klo]
			if c == '"' || c == '\'' {
				l.key_quote = c
			} else {
				l.key_quote = 0
			}
		}
		if kok && vok && khi < vlo {
			gap := cx.src[khi:vlo]
			if bytes.index_byte(gap, '/') < 0 && bytes.index_byte(gap, '\n') < 0 {
				l.colon = string(gap)
			}
		}
	}
	if len(items) >= 2 && !l.multiline {
		gap := cx.src[items[0].hi:items[1].lo]
		if bytes.index_byte(gap, '/') < 0 && bytes.index_byte(gap, '\n') < 0 && bytes.index_byte(gap, ',') >= 0 {
			l.sep = string(gap)
		}
	}
	// Check trailing comma after last item.
	last := items[len(items) - 1]
	if cx.spec.trailing_comma && scan_for_comma(cx.src, last.hi, c_hi - 1) >= 0 {
		l.trailing_comma = true
	}
	return l
}

// Scans `[lo, hi)` outside comments for a `,` byte, returning its offset or -1.
@(private = "file")
scan_for_comma :: proc "contextless" (src: []u8, lo, hi: u64) -> i64 {
	p := lo
	for p < hi {
		switch src[p] {
		case ',':
			return i64(p)
		case '/':
			if p + 1 < hi && src[p + 1] == '*' {
				p += 2
				for p + 1 < hi && !(src[p] == '*' && src[p + 1] == '/') {
					p += 1
				}
				p = min(p + 2, hi)
			} else if p + 1 < hi && src[p + 1] == '/' {
				for p < hi && src[p] != '\n' {
					p += 1
				}
			} else {
				p += 1
			}
		case:
			p += 1
		}
	}
	return -1
}

@(private = "file")
key_has_duplicate :: #force_inline proc "contextless" (
	doc: ^tape.Document,
	obj, end, kn: tape.Node_Index,
) -> bool #no_bounds_check {
	src := doc.src
	knode := doc.nodes[kn]
	if knode.spelling & tape.SPELLING_DECODE == 0 {
		klen := knode.n
		kbytes := string(src[knode.lo : knode.lo + u64(klen)])
		for ok := obj + 1; ok < end; ok = tape.node_after(doc, ok + 1) {
			if ok == kn {
				continue
			}
			on := doc.nodes[ok]
			if on.spelling & tape.SPELLING_DECODE == 0 {
				if on.n == klen && string(src[on.lo : on.lo + u64(klen)]) == kbytes {
					return true
				}
			} else if tape.same_keys(doc.format, src, knode, src, on) {
				return true
			}
		}
		return false
	}
	for ok := obj + 1; ok < end; ok = tape.node_after(doc, ok + 1) {
		if ok != kn && tape.same_keys(doc.format, src, knode, src, doc.nodes[ok]) {
			return true
		}
	}
	return false
}

// Fast O(K) check whether small unescaped object `obj` (<= 64 keys) has zero duplicate keys using a stack hash set.
// Returns `true` only when every key is unescaped and pairwise distinct; any escaped key, >64 keys, or collision
// returns `false` so the caller checks the edited key via `key_has_duplicate`.
@(private = "file")
object_keys_all_unique :: proc "contextless" (doc: ^tape.Document, obj, end: tape.Node_Index, n_keys: int) -> bool #no_bounds_check {
	nodes := doc.nodes
	src := doc.src
	mask := u32(15)
	if n_keys > 8 {
		mask = 31 if n_keys <= 16 else (63 if n_keys <= 32 else 127)
	}
	slots: [128]tape.Node_Index = ---
	slice.zero(slots[:mask + 1])
	max_seen := int(mask >> 1) + 1
	seen := 0
	for ok := obj + 1; ok < end; ok = tape.node_after(doc, ok + 1) {
		if seen >= max_seen {
			return false
		}
		seen += 1
		kn := nodes[ok]
		if kn.spelling & tape.SPELLING_DECODE != 0 {
			return false
		}
		h := kn.n * 2654435761
		if kn.n > 0 {
			h ~= u32(src[kn.lo]) * 16777619 ~ u32(src[kn.lo + u64(kn.n) - 1])
		}
		slot := h & mask
		for {
			prev := slots[slot]
			if prev == 0 {
				slots[slot] = ok
				break
			}
			pn := nodes[prev]
			if pn.n == kn.n && string(src[pn.lo : pn.lo + u64(pn.n)]) == string(src[kn.lo : kn.lo + u64(kn.n)]) {
				return false
			}
			slot = (slot + 1) & mask
		}
	}
	return true
}

// Forward skip-cursor check over all ancestor objects of `splices` (zero `ensure_parents` scan).
// Checks each ancestor object at most once via `object_keys_all_unique`, falling back to exact `key_has_duplicate`
// only when an object has >64 keys, escaped keys, or an actual duplicate key.
@(private = "file")
bracket_fast_has_duplicate_key :: proc(
	doc: ^tape.Document,
	splices: []Splice,
	sorted: bool,
	scratch: runtime.Allocator,
) -> bool #no_bounds_check {
	if len(splices) == 0 || len(doc.nodes) == 0 || doc.nodes[0].kind < .Array {
		return false
	}
	nodes := doc.nodes
	edited_buf: []tape.Node_Index
	if !sorted {
		eb, aerr := make([]tape.Node_Index, len(splices), scratch)
		if aerr != nil {
			return true
		}
		for s, i in splices {
			eb[i] = s.base_node
		}
		slice.sort(eb)
		edited_buf = eb
	}
	Skip_Frame :: struct {
		node:     tape.Node_Index,
		end:      tape.Node_Index,
		cur:      tape.Node_Index,
		last_kn:  tape.Node_Index,
		n_keys:   int,
		is_obj:   bool,
		dup_free: bool,
		has_dups: bool,
	}
	stack_buf: [64]Skip_Frame = ---
	stack_len := 1
	root_is_obj := nodes[0].kind == .Object
	root_nk := tape.child_count(doc, 0, nodes[0]) if root_is_obj else 0
	stack_buf[0] = Skip_Frame {
		node     = 0,
		end      = tape.Node_Index(nodes[0].n),
		cur      = 1,
		last_kn  = tape.NO_NODE,
		n_keys   = root_nk,
		is_obj   = root_is_obj,
		dup_free = !root_is_obj || (root_nk >= 0 && root_nk <= 1),
	}
	for si := 0; si < len(splices); si += 1 {
		target := splices[si].base_node if sorted else edited_buf[si]
		for stack_len > 0 && target >= stack_buf[stack_len - 1].end {
			stack_len -= 1
		}
		if stack_len == 0 {
			return true
		}
		descend: for stack_buf[stack_len - 1].node < target {
			fr := &stack_buf[stack_len - 1]
			if fr.is_obj {
				kn := fr.cur
				for kn < fr.end {
					vn := kn + 1
					if vn >= fr.end {
						return true
					}
					after := tape.node_after(doc, vn)
					if after <= target {
						kn = after
						continue
					}
					fr.cur = kn
					if !fr.dup_free && kn != fr.last_kn {
						fr.last_kn = kn
						if !fr.has_dups {
							if fr.n_keys >= 0 && fr.n_keys <= 64 && object_keys_all_unique(doc, fr.node, fr.end, fr.n_keys) {
								fr.dup_free = true
							} else {
								fr.has_dups = true
							}
						}
						if fr.has_dups && key_has_duplicate(doc, fr.node, fr.end, kn) {
							return true
						}
					}
					if vn == target {
						break descend
					}
					if nodes[vn].kind < .Array || stack_len >= len(stack_buf) {
						return true
					}
					child_is_obj := nodes[vn].kind == .Object
					nk := tape.child_count(doc, vn, nodes[vn]) if child_is_obj else 0
					stack_buf[stack_len] = Skip_Frame {
						node     = vn,
						end      = after,
						cur      = vn + 1,
						last_kn  = tape.NO_NODE,
						n_keys   = nk,
						is_obj   = child_is_obj,
						dup_free = !child_is_obj || (nk >= 0 && nk <= 1),
					}
					stack_len += 1
					continue descend
				}
				return true
			} else {
				en := fr.cur
				for en < fr.end {
					after := tape.node_after(doc, en)
					if after <= target {
						en = after
						continue
					}
					fr.cur = en
					if en == target {
						break descend
					}
					if nodes[en].kind < .Array || stack_len >= len(stack_buf) {
						return true
					}
					child_is_obj := nodes[en].kind == .Object
					nk := tape.child_count(doc, en, nodes[en]) if child_is_obj else 0
					stack_buf[stack_len] = Skip_Frame {
						node     = en,
						end      = after,
						cur      = en + 1,
						last_kn  = tape.NO_NODE,
						n_keys   = nk,
						is_obj   = child_is_obj,
						dup_free = !child_is_obj || (nk >= 0 && nk <= 1),
					}
					stack_len += 1
					continue descend
				}
				return true
			}
		}
	}
	return false
}

// Checks whether an edited base object contains duplicate keys where either a duplicated key is edited/deleted/renamed,
// OR the object has ANY structural delta (preventing shadowed-key slice panics!).
@(private = "file")
bracket_has_edited_duplicate_key :: proc(cx: ^Bracket_Cx, n: ^Edit_Node) -> (dup: bool, err: Error) {
	if n.base == tape.NO_NODE {
		return false, nil
	}
	obj_node := cx.doc.nodes[n.base]
	if obj_node.kind != .Object || obj_node.n <= 1 {
		return false, nil
	}
	Key_Count :: struct {
		count:  int,
		edited: bool,
	}
	seen := make(map[string]Key_Count, 8, cx.allocator)
	d := n.delta
	end := n.base + tape.Node_Index(obj_node.n)
	for kn := n.base + 1; kn < end; kn = tape.node_after(cx.doc, kn + 1) {
		vn := kn + 1
		if vn >= end {
			break
		}
		tk := decode_node_text_tmp(cx.doc, kn, cx.allocator)
		is_ed := n.state == .Container_Delta
		if !is_ed {
			if ch, has := cx.ov.by_base[vn]; has {
				if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits {
					is_ed = true
				}
			}
		}
		if !is_ed && d != nil {
			for dk in d.deleted_keys {
				if dk == tk.text {
					is_ed = true
					break
				}
			}
		}
		if !is_ed && d != nil {
			for r in d.renamed_members {
				if r.old_key == tk.text {
					is_ed = true
					break
				}
			}
		}
		cur := seen[tk.text]
		cur.count += 1
		if is_ed {
			cur.edited = true
		}
		seen[tk.text] = cur
	}
	for _, kc in seen {
		if kc.count > 1 && kc.edited {
			return true, nil
		}
	}
	return false, nil
}

// Emits a reflow rewrite of container `h` (smallest enclosing container), dropping any inner splices inside `[c_lo, c_hi)`
// and preserving outer facts on `n` when `reemit_outer` is true, marking `rewritten = true`.
@(private = "file")
emit_bracket_reflow :: proc(cx: ^Bracket_Cx, h: Handle, n: ^Edit_Node, base_c: tape.Node_Index, c_lo, c_hi: u64, reemit_outer := true) -> Error {
	drop_splices_in_range(cx.splices, c_lo, c_hi, cx.allocator)
	is_multiline := bytes.index_byte(cx.src[c_lo:c_hi], '\n') >= 0
	indent := line_indent(cx.src, c_lo)
	unit := bracket_default_unit(cx) if is_multiline else ""
	buf := make([dynamic]u8, 0, 128, cx.allocator)
	cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, indent, unit, cx.eol, "") or_return
	append(cx.splices, Splice{lo = c_lo, hi = c_hi, text = buf[:], seq = len(cx.splices), base_node = base_c, subtree_only = true, rewritten = true}) or_return
	if reemit_outer && len(n.facts) > 0 {
		emit_bracket_facts(cx, h, n, skip_foot = true, skip_span = {c_lo, c_hi}) or_return
	}
	return nil
}

// Reorders items inside a bracket container using `Move` splices.
// Group 2 support: handles comments on multi-item flow lines by attaching each comment to the item preceding it!
@(private = "file")
emit_bracket_reorder :: proc(
	cx: ^Bracket_Cx,
	base_c: tape.Node_Index,
	c_lo, c_hi: u64,
	items: []Bracket_Item,
	order: []u32,
	ins_texts: [][]u8,
	layout: Bracket_Layout,
) -> (
	ok: bool,
	err: Error,
) {
	n := len(items)
	if n == 0 || len(order) == 0 {
		return false, nil
	}
	// Each item owns `[item_lo[k], item_hi[k])` where any inline/trailing comment before the next item on the
	// same line (or after the comma on its line) attaches to item `k` (Group 2: comments in multi-item flow lines!).
	item_lo := make([]u64, n, cx.allocator)
	item_hi := make([]u64, n, cx.allocator)
	defer delete(item_lo, cx.allocator)
	defer delete(item_hi, cx.allocator)

	for it, k in items {
		lo := it.head_lo
		hi := it.hi
		// Attach any block comment immediately following `it.hi` before its comma, or inline comment on its line.
		next_bound := items[k + 1].head_lo if k + 1 < n else c_hi - 1
		comma_pos := scan_for_comma(cx.src, hi, next_bound)
		if comma_pos >= 0 {
			// Check for inline comment after comma on same line (e.g. `1, // c1` or `1, /* c1 */ 2`).
			q := u64(comma_pos) + 1
			for q < next_bound && (cx.src[q] == ' ' || cx.src[q] == '\t') {
				q += 1
			}
			if q + 1 < next_bound && cx.src[q] == '/' && cx.src[q + 1] == '/' {
				// Line comment belongs to item `k`! Keep item span through end of comment, comma handled separately.
				end_c := q + 2
				for end_c < next_bound && cx.src[end_c] != '\n' && cx.src[end_c] != '\r' {
					end_c += 1
				}
				hi = end_c
			} else if q + 1 < next_bound && cx.src[q] == '/' && cx.src[q + 1] == '*' {
				end_c := q + 2
				for end_c + 1 < next_bound && !(cx.src[end_c] == '*' && cx.src[end_c + 1] == '/') {
					end_c += 1
				}
				if end_c + 1 < next_bound {
					hi = end_c + 2
				}
			}
		} else if it.inline_hi > hi {
			hi = it.inline_hi
		}
		item_lo[k] = lo
		item_hi[k] = hi
	}

	moves := make([dynamic]Move, 0, len(order) * 3, cx.allocator)

	for raw, pos in order {
		k := int(raw)
		if pos > 0 {
			sep_buf := make([dynamic]u8, 0, 16, cx.allocator)
			if layout.multiline {
				append(&sep_buf, cx.eol)
				append(&sep_buf, layout.item_indent)
			} else {
				// Each non-last item already emits its own comma right after its value (before any attached comment);
				// emit only the whitespace that follows the comma in `layout.sep`!
				if ci := bytes.index_byte(transmute([]u8)layout.sep, ','); ci >= 0 {
					append(&sep_buf, layout.sep[ci + 1:])
				} else {
					append(&sep_buf, " ")
				}
			}
			if _, aerr := append(&moves, Move{text = sep_buf[:], written = true}); aerr != nil {
				delete(sep_buf)
				return false, aerr
			}
		}
		want_comma := pos + 1 < len(order) || layout.trailing_comma
		if k < n {
			it := items[k]
			// Check whether `item_lo[k]..item_hi[k]` already contains a comma after `it.hi`.
			comma_pos := scan_for_comma(cx.src, it.hi, item_hi[k])
			if comma_pos >= 0 {
				if want_comma {
					append(&moves, Move{lo = item_lo[k], hi = item_hi[k]})
				} else {
					// Strip the comma while preserving any trailing comment attached to this item!
					append(&moves, Move{lo = item_lo[k], hi = u64(comma_pos)})
					if u64(comma_pos) + 1 < item_hi[k] {
						append(&moves, Move{lo = u64(comma_pos) + 1, hi = item_hi[k]})
					}
				}
			} else {
				if want_comma {
					// Insert comma right after value `it.hi`, before any trailing comment!
					append(&moves, Move{lo = item_lo[k], hi = it.hi})
					cbuf := make([]u8, 1, cx.allocator)
					cbuf[0] = ','
					append(&moves, Move{text = cbuf, written = true})
					if it.hi < item_hi[k] {
						append(&moves, Move{lo = it.hi, hi = item_hi[k]})
					}
				} else {
					append(&moves, Move{lo = item_lo[k], hi = item_hi[k]})
				}
			}
		} else {
			txt := ins_texts[k - n]
			tbuf := make([dynamic]u8, 0, len(txt) + 1, cx.allocator)
			append(&tbuf, ..txt)
			if want_comma {
				append(&tbuf, ',')
			}
			append(&moves, Move{text = tbuf[:], written = true})
		}
	}

	// Span from first item's `item_lo[0]` through last item's `item_hi[n-1]` (including any trailing comma of last item).
	span_lo := item_lo[0]
	span_hi := item_hi[n - 1]
	if tc := scan_for_comma(cx.src, span_hi, c_hi - 1); tc >= 0 {
		span_hi = u64(tc) + 1
	}
	if _, aerr := append(cx.splices, Splice {
		lo          = span_lo,
		hi          = span_hi,
		moves       = moves[:],
		seq         = len(cx.splices),
		base_node   = base_c,
		full_rewalk = false,
	}); aerr != nil {
		return false, aerr
	}
	return true, nil
}

// Unified local splicer for deletions and insertions inside a bracket container:
// - Groups all insertions by target slot (no overlapping splices on multi-insert or delete+insert!)
// - Preserves comments (including `/* block */` before `,` and comments of removed items)
// - Prevents `//` line comments from commenting out `]`/`}`!
@(private = "file")
emit_bracket_insert_delete :: proc(
	cx: ^Bracket_Cx,
	base_c: tape.Node_Index,
	c_lo, c_hi: u64,
	items: []Bracket_Item,
	ins_texts: [][]u8,
	ins_ats: []int,
	layout: Bracket_Layout,
) -> Error {
	n := len(items)
	// Identify surviving base items and map each insert to its slot (`0..n-1` = before item `slot`, `n` = tail).
	first_surv, last_surv := -1, -1
	for it, k in items {
		if !it.deleted {
			if first_surv < 0 {
				first_surv = k
			}
			last_surv = k
		}
	}

	// Empty container (or all base items deleted): remove deleted items preserving comments, and emit all inserts as ONE block!
	if last_surv < 0 {
		for k in 0 ..< n {
			it := items[k]
			bound := items[k + 1].lo if k + 1 < n else c_hi - 1
			del_lo, del_hi, extra_comma := bracket_delete_item_span(cx.src, it.lo, it.hi, bound, layout.multiline, true)
			if _, aerr := append(cx.splices, Splice{lo = del_lo, hi = del_hi, seq = len(cx.splices), base_node = base_c}); aerr != nil {
				return aerr
			}
			if extra_comma >= 0 {
				if _, aerr := append(cx.splices, Splice{lo = u64(extra_comma), hi = u64(extra_comma) + 1, seq = len(cx.splices), base_node = base_c}); aerr != nil {
					return aerr
				}
			}
		}
		if len(ins_texts) == 0 {
			return nil
		}
		b := make([dynamic]u8, 0, 64, cx.allocator)
		for t, i in ins_texts {
			if i > 0 {
				if layout.multiline {
					append(&b, ',')
					append(&b, cx.eol)
					append(&b, layout.close_indent)
					append(&b, layout.unit)
				} else {
					append(&b, layout.sep)
				}
			} else if layout.multiline {
				append(&b, cx.eol)
				append(&b, layout.close_indent)
				append(&b, layout.unit)
			}
			append(&b, ..t)
		}
		if layout.multiline {
			if layout.trailing_comma {
				append(&b, ',')
			}
			append(&b, cx.eol)
			append(&b, layout.close_indent)
		}
		ins_lo := c_lo + 1 if n == 0 else c_hi - 1
		ins_hi := c_hi - 1
		append(cx.splices, Splice{lo = ins_lo, hi = ins_hi, text = b[:], seq = len(cx.splices), base_node = base_c}) or_return
		return nil
	}

	// Group inserts by slot: `slot = next surviving item index >= at`, or `n` for tail after `last_surv`.
	slots := make([][dynamic]int, n + 1, cx.allocator)
	for ins_i in 0 ..< len(ins_texts) {
		at := ins_ats[ins_i]
		slot := n
		if at >= 0 && at < n {
			for k := at; k < n; k += 1 {
				if !items[k].deleted {
					slot = k
					break
				}
			}
		}
		if slots[slot].allocator.procedure == nil {
			slots[slot] = make([dynamic]int, 0, 2, cx.allocator)
		}
		append(&slots[slot], ins_i)
	}
	has_tail_ins := len(slots[n]) > 0

	// 1. Emit deletions for deleted base items (preserving comments and `/* block */` comments before `,`).
	for k in 0 ..< n {
		if !items[k].deleted {
			continue
		}
		it := items[k]
		bound := items[k + 1].lo if k + 1 < n else c_hi - 1
		// Drop preceding comma on `last_surv` ONLY when deleting the first trailing deleted item (`k == last_surv + 1`)
		// and there are no tail inserts and no trailing comma requested.
		if k == last_surv + 1 && !has_tail_ins && !layout.trailing_comma {
			if comma := scan_for_comma(cx.src, items[last_surv].hi, it.lo); comma >= 0 {
				if _, aerr := append(cx.splices, Splice{lo = u64(comma), hi = u64(comma) + 1, seq = len(cx.splices), base_node = base_c}); aerr != nil {
					return aerr
				}
			}
		}
		drop_comma := k < last_surv || has_tail_ins || !layout.trailing_comma
		del_lo, del_hi, extra_comma := bracket_delete_item_span(cx.src, it.lo, it.hi, bound, layout.multiline, drop_comma)
		if !layout.multiline && k == last_surv + 1 {
			if comma := scan_for_comma(cx.src, items[last_surv].hi, it.lo); comma >= 0 {
				q := u64(comma) + 1
				if q <= del_lo && bytes.index_byte(cx.src[q:del_lo], '/') < 0 {
					del_lo = q
				}
			}
		}
		if _, aerr := append(cx.splices, Splice{lo = del_lo, hi = del_hi, seq = len(cx.splices), base_node = base_c}); aerr != nil {
			return aerr
		}
		if extra_comma >= 0 {
			if _, aerr := append(cx.splices, Splice{lo = u64(extra_comma), hi = u64(extra_comma) + 1, seq = len(cx.splices), base_node = base_c}); aerr != nil {
				return aerr
			}
		}
	}

	// 2. Emit grouped inserts before each surviving item slot `k < n`.
	for k in 0 ..< n {
		if len(slots[k]) == 0 {
			continue
		}
		b := make([dynamic]u8, 0, 64, cx.allocator)
		for ins_i in slots[k] {
			append(&b, ..ins_texts[ins_i])
			if layout.multiline {
				append(&b, ',')
				append(&b, cx.eol)
				append(&b, layout.item_indent)
			} else {
				append(&b, layout.sep)
			}
		}
		ins_pos := items[k].head_lo
		append(cx.splices, Splice{lo = ins_pos, hi = ins_pos, text = b[:], seq = len(cx.splices), base_node = base_c}) or_return
	}

	// 3. Emit grouped tail inserts after `items[last_surv]` as ONE splice!
	if has_tail_ins {
		ls := items[last_surv]
		next_bound := items[last_surv + 1].lo if last_surv + 1 < n else c_hi - 1
		existing_comma := scan_for_comma(cx.src, ls.hi, next_bound)
		b := make([dynamic]u8, 0, 64, cx.allocator)
		ins_pos: u64
		if existing_comma >= 0 {
			// Insert after existing comma (and after any inline comment on that line in multiline mode).
			ins_pos = u64(existing_comma) + 1
			if layout.multiline {
				ins_pos = next_line(cx.src, ins_pos)
				for ins_i, idx in slots[n] {
					if idx > 0 {
						append(&b, ',')
						append(&b, cx.eol)
					}
					append(&b, layout.item_indent)
					append(&b, ..ins_texts[ins_i])
				}
				if layout.trailing_comma {
					append(&b, ',')
				}
				append(&b, cx.eol)
			} else {
				for ins_i, idx in slots[n] {
					append(&b, layout.sep if idx > 0 else " ")
					append(&b, ..ins_texts[ins_i])
				}
			}
		} else {
			ins_pos = ls.hi
			for ins_i in slots[n] {
				if layout.multiline {
					append(&b, ',')
					append(&b, cx.eol)
					append(&b, layout.item_indent)
					append(&b, ..ins_texts[ins_i])
				} else {
					append(&b, layout.sep)
					append(&b, ..ins_texts[ins_i])
				}
			}
			if layout.multiline && layout.trailing_comma {
				append(&b, ',')
			}
		}
		// Guard against a trailing `//` comment before `]`/`}` on single-line containers.
		if !layout.multiline && bytes.index(b[:], transmute([]u8)string("//")) >= 0 {
			append(&b, cx.eol)
		}
		append(cx.splices, Splice{lo = ins_pos, hi = ins_pos, text = b[:], seq = len(cx.splices), base_node = base_c}) or_return
	}
	return nil
}

// Computes the `[del_lo, del_hi)` removal span for a deleted item, preserving `/* block */` comments between `hi` and `,`.
// If a comment sits between `hi` and `,`, returns `extra_comma = comma` so the caller removes `,` separately!
@(private = "file")
bracket_delete_item_span :: proc "contextless" (src: []u8, lo, hi, bound: u64, multiline, drop_comma: bool) -> (del_lo, del_hi: u64, extra_comma: i64) {
	del_lo = lo
	del_hi = hi
	extra_comma = -1
	if drop_comma {
		if comma := scan_for_comma(src, hi, bound); comma >= 0 {
			if bytes.index_byte(src[hi:u64(comma)], '/') < 0 {
				del_hi = u64(comma) + 1
			} else {
				extra_comma = comma
			}
		}
	}
	if multiline && first_on_line(src, del_lo) && extra_comma < 0 {
		q := del_hi
		for q < bound && (src[q] == ' ' || src[q] == '\t' || src[q] == '\r') {
			q += 1
		}
		if q < bound && src[q] == '\n' {
			del_lo = line_start(src, del_lo)
			del_hi = q + 1
		}
	} else if !multiline && extra_comma < 0 {
		q := del_hi
		for q < bound && (src[q] == ' ' || src[q] == '\t') {
			q += 1
		}
		del_hi = q
	}
	return del_lo, del_hi, extra_comma
}
