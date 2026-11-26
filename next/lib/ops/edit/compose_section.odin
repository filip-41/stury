package edit

import "base:runtime"
import "core:bytes"
import "core:container/handle_map"
import "core:slice"
import "core:unicode/utf8"
import "stury:lib/core/tape"

// Section-tree composer (TOML 1.0 / 1.1).
//
// Preserves untargeted sections, inline tables, comments (including shared-line comments), key quoting, and number
// bases verbatim.
//
// Group 1 refusals (always refused, even under `Options.reflow = true`):
// - Non-object root (`Root_Shape`)
// - Null value (`Unspellable_Value` — TOML has no null)
// - Control byte in comment (`Fact_No_Place`)
// - Invalid datetime `.@tag` (`Fact_No_Place`)
//
// Group 2 acceptances (accepted by default in v2):
// - Moving a `[section]` before a top-level key line: automatically hoists top-level key lines above the first
//   section header so they remain in the root table!
// - Multi-range members (tables whose dotted keys or sub-sections lie apart around another member's): tracks
//   multiple `Byte_Range`s per member so removals and reorders handle split sections cleanly!
// - Comments in multi-item flow arrays: attaches each comment to the preceding item on its line.

Section_Spec :: struct {
	target:         ^tape.Format,
	v11:            bool,
	// Spells a value `h` as an inline TOML value (scalar, inline array, or inline table), honoring optional `style` and `tag`.
	spell_value:    proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8, style: string, tag: string) -> Error,
	// Spells a TOML key (bare when valid, else basic string).
	spell_key:      proc(data: rawptr, key: string, out: ^[dynamic]u8) -> Error,
	// Spells a full TOML document from `ov` (used for root replacement and reflow).
	spell_document: proc(data: rawptr, ov: ^Overlay, out: ^[dynamic]u8) -> Error,
	// Validates final TOML output.
	validate:       proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:           rawptr,
}

// A top-level or nested TOML section header (`[a.b]` or `[[a.b]]`) and its body span in `src`.
@(private = "file")
Toml_Section :: struct {
	header_lo:     u64,    // start of `[` (line start of header)
	header_key_lo: u64,    // start of raw path inside `[` / `[[`
	header_key_hi: u64,    // end of raw path before `]` / `]]`
	body_lo:       u64,    // start of first line after header
	body_hi:       u64,    // end of section (next header's head comments or EOF)
	head_lo:       u64,    // start of head comments immediately above header
	path:          string, // canonical spelled path (owned in `cx.allocator`)
	is_array:      bool,
}

commit_section :: proc(
	ov: ^Overlay,
	spec: ^Section_Spec,
	opts := Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Error,
) {
	cx := Section_Cx {
		ov   = ov,
		doc  = ov.base if ov != nil else nil,
		src  = ov.base.src if ov != nil && ov.base != nil else nil,
		spec = spec,
		opts = opts,
	}
	tc := Text_Composer {
		target        = spec.target,
		extra_clean   = true,
		req_root      = .Object,
		root_msg      = "TOML document root must be a table (object)",
		validate      = spec.validate,
		validate_data = spec.data,
		fast_emit     = section_fast_emit,
		struct_emit   = section_struct_emit,
		frag_check    = section_frag_check,
		user          = &cx,
	}
	return run_text_commit(ov, &tc, opts, allocator)
}

@(private = "file")
section_fast_emit :: proc(
	user: rawptr,
	ov: ^Overlay,
	doc: ^tape.Document,
	splices: ^[dynamic]Splice,
	scratch: runtime.Allocator,
) -> (ok: bool, err: Error) {
	cx := (^Section_Cx)(user)
	cx.allocator = scratch
	cx.splices = splices
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		if n.state == .Replaced && n.has_edits && n.base != tape.NO_NODE && doc.nodes[n.base].role == .Value {
			if n.val.kind == .Null || n.val.kind == .None {
				return false, refuse(.Unspellable_Value, "TOML has no null value", n.base)
			}
			if n.val.kind == .Raw {
				lo, hi, lok := node_byte_span(doc, n.base)
				if !lok {
					return false, refuse(.Bad_Handle, "cannot locate base value span", n.base)
				}
				append(cx.splices, Splice {
					lo           = lo,
					hi           = hi,
					text         = transmute([]u8)n.val.text,
					seq          = len(cx.splices),
					base_node    = n.base,
					subtree_only = true,
				}) or_return
			} else {
				emit_section_replace(cx, n.handle, n) or_return
			}
		}
	}
	return true, nil
}

@(private = "file")
section_struct_emit :: proc(
	user: rawptr,
	ov: ^Overlay,
	doc: ^tape.Document,
	eol: string,
	splices: ^[dynamic]Splice,
	dropped: ^tape.Facts,
	scratch: runtime.Allocator,
) -> Error {
	_ = doc
	cx := (^Section_Cx)(user)
	cx.allocator = scratch
	cx.splices = splices
	cx.eol = eol
	cx.sections = make([dynamic]Toml_Section, 0, 8, scratch)
	scan_toml_sections(cx) or_return
	if ov.root != NO_HANDLE {
		compose_section_walk(cx, ov.root) or_return
	}
	dropped^ = cx.dropped
	return nil
}

@(private = "file")
section_frag_check :: proc(user: rawptr, out: []u8, recs: []Splice_Record, scratch: runtime.Allocator) -> (bool, Error) {
	cx := (^Section_Cx)(user)
	chk: [256]u8
	chk[0], chk[1], chk[2], chk[3] = 'v', ' ', '=', ' '
	for rec in recs {
		if !rec.subtree_only || rec.full_rewalk {
			return true, nil
		}
		frag := out[rec.dst_lo:rec.dst_hi]
		if is_simple_toml_scalar(frag) {
			continue
		}
		if len(frag) > len(chk) - 4 ||
			bytes.index_byte(frag, '#') >= 0 ||
			bytes.index_byte(frag, '\n') >= 0 ||
			bytes.index_byte(frag, '\r') >= 0 ||
			bytes.index_byte(frag, '[') >= 0 ||
			bytes.index_byte(frag, '{') >= 0 {
			return true, nil
		}
		copy(chk[4:], frag)
		if verr := cx.spec.validate(cx.spec.data, chk[:4 + len(frag)], scratch); verr != nil {
			return false, convert_tape_error(verr)
		}
	}
	return false, nil
}

@(private = "file")
Section_Cx :: struct {
	ov:        ^Overlay,
	doc:       ^tape.Document,
	src:       []u8,
	spec:      ^Section_Spec,
	opts:      Options,
	eol:       string,
	sections:  [dynamic]Toml_Section,
	splices:   ^[dynamic]Splice,
	dropped:   tape.Facts,
	reflowed:  bool,
	allocator: runtime.Allocator,
}

@(private = "file")
path_matches_or_child :: proc(sec_path, pref: string) -> bool {
	if sec_path == pref {
		return true
	}
	return len(sec_path) > len(pref) &&
		bytes.has_prefix(transmute([]u8)sec_path, transmute([]u8)pref) &&
		sec_path[len(pref)] == '.'
}

// Parses raw TOML header key path (handling spaces, `'literal'`, `"basic"` with escapes, and bare keys)
// into canonical `spell_key`-joined dot path so `[ a . b ]` and `['a']` match `full_path`!
@(private = "file")
normalize_toml_header_path :: proc(cx: ^Section_Cx, raw: []u8) -> (string, Error) {
	out := make([dynamic]u8, 0, len(raw) + 4, cx.allocator)
	seg := make([dynamic]u8, 0, len(raw), cx.allocator)
	defer delete(seg)
	i := 0
	first := true
	for i < len(raw) {
		for i < len(raw) && (raw[i] == ' ' || raw[i] == '\t') {
			i += 1
		}
		if i >= len(raw) {
			break
		}
		clear(&seg)
		if raw[i] == '\'' {
			i += 1
			for i < len(raw) && raw[i] != '\'' {
				append(&seg, raw[i])
				i += 1
			}
			if i < len(raw) {
				i += 1
			}
		} else if raw[i] == '"' {
			i += 1
			for i < len(raw) && raw[i] != '"' {
				if raw[i] == '\\' && i + 1 < len(raw) {
					i += 1
					switch raw[i] {
					case 'b':
						append(&seg, '\b')
					case 't':
						append(&seg, '\t')
					case 'n':
						append(&seg, '\n')
					case 'f':
						append(&seg, '\f')
					case 'r':
						append(&seg, '\r')
					case '"', '\\':
						append(&seg, raw[i])
					case 'u', 'U':
						digits := 4 if raw[i] == 'u' else 8
						if i + digits < len(raw) {
							r: u32
							ok := true
							for d in 1 ..= digits {
								h := raw[i + d]
								v: u32
								switch h {
								case '0' ..= '9':
									v = u32(h - '0')
								case 'a' ..= 'f':
									v = u32(h - 'a' + 10)
								case 'A' ..= 'F':
									v = u32(h - 'A' + 10)
								case:
									ok = false
								}
								r = (r << 4) | v
							}
							if ok {
								enc, n := utf8.encode_rune(rune(r))
								append(&seg, ..enc[:n])
								i += digits
							}
						}
					case:
						append(&seg, raw[i])
					}
					i += 1
					continue
				}
				append(&seg, raw[i])
				i += 1
			}
			if i < len(raw) {
				i += 1
			}
		} else {
			start := i
			for i < len(raw) && raw[i] != '.' && raw[i] != ' ' && raw[i] != '\t' {
				i += 1
			}
			append(&seg, ..raw[start:i])
		}
		if !first {
			append(&out, '.')
		}
		first = false
		if serr := cx.spec.spell_key(cx.spec.data, string(seg[:]), &out); serr != nil {
			delete(out)
			return "", serr
		}
		for i < len(raw) && (raw[i] == ' ' || raw[i] == '\t') {
			i += 1
		}
		if i < len(raw) && raw[i] == '.' {
			i += 1
		}
	}
	return string(out[:]), nil
}

// Scans top-level `[table]` and `[[array]]` headers in `cx.src` (ignoring lines inside multiline strings/arrays).
@(private = "file")
scan_toml_sections :: proc(cx: ^Section_Cx) -> Error {
	src := cx.src
	n := u64(len(src))
	p := u64(0)
	in_bracket := 0
	for p < n {
		ls := p
		q := ls
		for q < n && (src[q] == ' ' || src[q] == '\t') {
			q += 1
		}
		if in_bracket == 0 && q < n && src[q] == '[' {
			is_arr := q + 1 < n && src[q + 1] == '['
			start := q + (2 if is_arr else 1)
			r := start
			in_quote: u8 = 0
			for r < n && src[r] != '\n' && src[r] != '\r' {
				c := src[r]
				if in_quote != 0 {
					if c == '\\' && in_quote == '"' && r + 1 < n {
						r += 2
						continue
					}
					if c == in_quote {
						in_quote = 0
					}
					r += 1
					continue
				}
				if c == '"' || c == '\'' {
					in_quote = c
					r += 1
					continue
				}
				if c == ']' {
					break
				}
				r += 1
			}
			norm := normalize_toml_header_path(cx, src[start:r]) or_return
			head_lo := ls
			for head_lo > 0 {
				prev_ls := line_start(src, head_lo - 1)
				pq := prev_ls
				for pq < head_lo && (src[pq] == ' ' || src[pq] == '\t') {
					pq += 1
				}
				if pq < head_lo && src[pq] == '#' {
					head_lo = prev_ls
				} else {
					break
				}
			}
			if len(cx.sections) > 0 {
				cx.sections[len(cx.sections) - 1].body_hi = head_lo
			}
			nl := next_line(src, r)
			if _, aerr := append(&cx.sections, Toml_Section {
				header_lo     = ls,
				header_key_lo = start,
				header_key_hi = r,
				head_lo       = head_lo,
				body_lo       = nl,
				body_hi       = n,
				path          = norm,
				is_array      = is_arr,
			}); aerr != nil {
				delete(norm, cx.allocator)
				return aerr
			}
			p = nl
			continue
		}
		for p < n && src[p] != '\n' {
			c := src[p]
			if c == '#' {
				for p < n && src[p] != '\n' {
					p += 1
				}
				break
			}
			if c == '"' || c == '\'' {
				if p + 2 < n && src[p + 1] == c && src[p + 2] == c {
					p += 3
					for p + 2 < n {
						if c == '"' && src[p] == '\\' {
							p += 2
							continue
						}
						if src[p] == c && src[p + 1] == c && src[p + 2] == c {
							p += 3
							// Consume up to 2 extra closing quotes in `"""...""""` / `"""..."""""`!
							for p < n && src[p] == c {
								p += 1
							}
							break
						}
						p += 1
					}
					continue
				}
				q_char := c
				p += 1
				for p < n && src[p] != '\n' {
					if q_char == '"' && src[p] == '\\' && p + 1 < n {
						p += 2
						continue
					}
					if src[p] == q_char {
						p += 1
						break
					}
					p += 1
				}
				continue
			}
			if c == '[' || c == '{' {
				in_bracket += 1
			} else if c == ']' || c == '}' {
				if in_bracket > 0 {
					in_bracket -= 1
				}
			}
			p += 1
		}
		if p < n && src[p] == '\n' {
			p += 1
		}
	}
	return nil
}

// Validates that a TOML comment body holds no disallowed control bytes (Group 1 refusal).
@(private = "file")
toml_comment_valid :: proc "contextless" (s: string) -> bool {
	for c in transmute([]u8)s {
		if (c < 0x20 && c != '\t') || c == 0x7F {
			return false
		}
	}
	return true
}

// Appends formatted TOML `#` comment line(s) into `out`, enforcing the Group 1 control-byte constraint.
@(private = "file")
append_toml_comments :: proc(cx: ^Section_Cx, values: []string, padded, inline: bool, out: ^[dynamic]u8, node: tape.Node_Index, lo: u64 = 0) -> Error {
	if inline && len(values) > 1 {
		return refuse(.Fact_No_Place, "a TOML line holds at most one inline comment", node, lo)
	}
	for line in values {
		if !toml_comment_valid(line) {
			return refuse(.Fact_No_Place, "TOML comment contains disallowed control byte", node, lo)
		}
		if inline {
			append(out, " #")
		} else {
			append(out, '#')
		}
		if padded && len(line) > 0 {
			append(out, ' ')
		}
		append(out, line)
		if !inline {
			append(out, cx.eol)
		}
	}
	return nil
}

@(private = "file")
toml_style_of :: #force_inline proc "contextless" (doc: ^tape.Document, node: tape.Node_Index) -> string {
	name, _ := tape.fact_name(doc, node, .Style)
	return name
}

@(private = "file")
node_style_and_tag :: proc(ov: ^Overlay, h: Handle) -> (style: string, tag: string) {
	n, ok := get_node(ov, h)
	if !ok {
		return "", ""
	}
	for f in n.facts {
		if f.deleted || len(f.values) == 0 {
			continue
		}
		if f.kind == .Style {
			style = f.values[0]
		} else if f.kind == .Tag {
			tag = f.values[0]
		}
	}
	return style, tag
}

// Emits a whole-document reflow rewrite via `cx.spec.spell_document` (discarding and freeing any prior partial splices).
@(private = "file")
emit_section_full_reflow :: proc(cx: ^Section_Cx) -> Error {
	if cx.spec.spell_document == nil {
		return refuse(.Layout_Reflow_Needed, "TOML document reflow requires spell_document", tape.ROOT)
	}
	drop_splices_in_range(cx.splices, 0, u64(len(cx.src)) + 1, cx.allocator)
	buf := make([dynamic]u8, 0, 128, cx.allocator)
	cx.spec.spell_document(cx.spec.data, cx.ov, &buf) or_return
	append(cx.splices, Splice{lo = 0, hi = u64(len(cx.src)), text = buf[:], seq = 0, base_node = tape.ROOT, full_rewalk = true, rewritten = true}) or_return
	cx.reflowed = true
	return nil
}

@(private = "file")
Section_Frame :: struct {
	h:         Handle,
	path_pref: string,
	owner_sec: string, // enclosing header/AOT section path (or "" at root) for dotted tables
	dot_pref:  string, // dotted key prefix relative to `owner_sec` when inside a dotted table
	span_lo:   u64,    // enclosing byte span bound (non-whole-doc only inside `[[arr]]` elements)
	span_hi:   u64,
}

@(private = "file")
Aot_Item :: struct {
	lo, hi:  u64,
	deleted: bool,
}

// Collects every `[[path_pref]]` item span (including its immediately following subtables) bounded within `[span_lo, span_hi)`.
@(private = "file")
collect_aot_items :: proc(
	cx: ^Section_Cx,
	path_pref: string,
	span_lo, span_hi: u64,
	deleted_indices: []u32,
) -> [dynamic]Aot_Item {
	aot_items := make([dynamic]Aot_Item, 0, 4, cx.allocator)
	for sec, si in cx.sections {
		if sec.head_lo < span_lo || sec.body_hi > span_hi {
			continue
		}
		if sec.is_array && sec.path == path_pref {
			hi := sec.body_hi
			for sj := si + 1; sj < len(cx.sections); sj += 1 {
				sub := cx.sections[sj]
				if sub.body_hi > span_hi || sub.path == path_pref {
					break
				}
				if path_matches_or_child(sub.path, path_pref) {
					hi = sub.body_hi
				} else {
					break
				}
			}
			append(&aot_items, Aot_Item{lo = sec.head_lo, hi = hi})
		}
	}
	for di in deleted_indices {
		if int(di) < len(aot_items) {
			aot_items[di].deleted = true
		}
	}
	return aot_items
}

@(private = "file")
join_dotted_path :: proc(cx: ^Section_Cx, pref, raw_key: string) -> (string, Error) {
	kb := make([dynamic]u8, 0, len(pref) + len(raw_key) + 4, cx.allocator)
	if len(pref) > 0 {
		append(&kb, pref)
		append(&kb, '.')
	}
	if serr := cx.spec.spell_key(cx.spec.data, raw_key, &kb); serr != nil {
		delete(kb)
		return "", serr
	}
	return string(kb[:]), nil
}

@(private = "file")
compose_section_walk :: proc(cx: ^Section_Cx, root: Handle) -> Error {
	stack := make([dynamic]Section_Frame, 0, 32, cx.allocator)
	append(&stack, Section_Frame{h = root, span_lo = 0, span_hi = u64(len(cx.src))}) or_return

	for len(stack) > 0 && !cx.reflowed {
		fr := pop(&stack)
		n, ok := get_node(cx.ov, fr.h)
		if !ok || !n.has_edits {
			continue
		}
		if n.state == .Replaced {
			if n.base == tape.ROOT {
				if cx.spec.spell_document != nil {
					emit_section_full_reflow(cx) or_return
					return nil
				}
				return refuse(.Root_Shape, "cannot replace TOML root table", tape.ROOT)
			}
			emit_section_replace(cx, fr.h, n) or_return
			continue
		}
		if len(n.facts) > 0 {
			emit_section_facts(cx, fr.h, n) or_return
		}
		if n.state == .Container_Delta {
			emit_section_container_delta(cx, fr.h, n, fr, &stack) or_return
			continue
		}
		if n.base != tape.NO_NODE {
			push_section_children(cx, n.base, fr, &stack) or_return
		}
	}
	return nil
}

@(private = "file")
push_section_child_frame :: proc(
	cx: ^Section_Cx,
	fr: Section_Frame,
	ch: Handle,
	kn, vn: tape.Node_Index,
	is_obj_parent: bool,
	idx: int,
	aot_items: []Aot_Item,
	stack: ^[dynamic]Section_Frame,
) -> Error {
	child_path := fr.path_pref
	child_owner := fr.owner_sec
	child_dot := fr.dot_pref
	child_lo := fr.span_lo
	child_hi := fr.span_hi
	if is_obj_parent && kn != tape.NO_NODE {
		k := decode_node_text_tmp(cx.doc, kn, cx.allocator)
		child_path = join_dotted_path(cx, fr.path_pref, k.text) or_return
		if toml_style_of(cx.doc, vn) == "dotted" {
			child_dot = join_dotted_path(cx, fr.dot_pref, k.text) or_return
		} else {
			child_owner = child_path
			child_dot = ""
		}
		free_tmp_text(k, cx.allocator)
	} else if !is_obj_parent && idx >= 0 && idx < len(aot_items) {
		// Isolate each `[[items]]` element frame to its exact byte span `[aot[i].lo, aot[i].hi)`.
		child_lo = aot_items[idx].lo
		child_hi = aot_items[idx].hi
		child_owner = fr.path_pref
		child_dot = ""
	}
	append(stack, Section_Frame {
		h         = ch,
		path_pref = child_path,
		owner_sec = child_owner,
		dot_pref  = child_dot,
		span_lo   = child_lo,
		span_hi   = child_hi,
	}) or_return
	return nil
}

@(private = "file")
push_section_children :: proc(
	cx: ^Section_Cx,
	base_c: tape.Node_Index,
	fr: Section_Frame,
	stack: ^[dynamic]Section_Frame,
) -> Error {
	node := cx.doc.nodes[base_c]
	if node.kind < .Array {
		return nil
	}
	aot_items: [dynamic]Aot_Item
	defer delete(aot_items)
	if node.kind == .Array && toml_style_of(cx.doc, base_c) != "inline" {
		aot_items = collect_aot_items(cx, fr.path_pref, fr.span_lo, fr.span_hi, nil)
	}
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if p != .Found {
		return nil
	}
	for idx := 0; ; idx += 1 {
		kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
		if np != .Found {
			break
		}
		ch, has := cx.ov.by_base[vn]
		if !has {
			continue
		}
		cn, ok := get_node(cx.ov, ch)
		if !ok || !cn.has_edits {
			continue
		}
		push_section_child_frame(cx, fr, ch, kn, vn, node.kind == .Object, idx, aot_items[:], stack) or_return
	}
	return nil
}

@(private = "file")
emit_section_replace :: proc(cx: ^Section_Cx, h: Handle, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE {
		return nil
	}
	if n.val.kind == .Null || n.val.kind == .None {
		return refuse(.Unspellable_Value, "TOML has no null value", n.base)
	}
	st := toml_style_of(cx.doc, n.base)
	if cx.doc.nodes[n.base].kind == .Object && st != "inline" {
		if !cx.opts.reflow {
			return refuse(.Layout_Reflow_Needed, "replacing a TOML header table requires reflow", n.base)
		}
		return emit_section_full_reflow(cx)
	}
	lo, hi, ok := node_byte_span(cx.doc, n.base)
	if !ok {
		return refuse(.Bad_Handle, "cannot locate base value span", n.base)
	}
	style_override, tag_override := node_style_and_tag(cx.ov, h)
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, style_override, tag_override) or_return
	append(cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = n.base, subtree_only = true}) or_return
	if len(n.facts) > 0 {
		emit_section_facts(cx, h, n) or_return
	}
	return nil
}

@(private = "file")
emit_section_facts :: proc(cx: ^Section_Cx, h: Handle, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE {
		return nil
	}
	lo, hi, ok := node_byte_span(cx.doc, n.base)
	if !ok {
		return nil
	}
	stmt_ls := line_start(cx.src, lo)
	need_respell := false
	style_override := ""
	tag_override := ""
	for f in n.facts {
		#partial switch f.kind {
		case .Comment, .Comment_Inline:
			if !f.deleted {
				for line in f.values {
					if !toml_comment_valid(line) {
						return refuse(.Fact_No_Place, "TOML comment contains disallowed control byte", n.base, lo)
					}
				}
			}
			emit_toml_comment(cx, n.base, f, stmt_ls, hi) or_return
		case .Comment_Foot:
			if n.base != tape.ROOT {
				return refuse(.Fact_No_Place, "TOML table has no foot comment", n.base, lo)
			}
			emit_toml_foot_comment(cx, f) or_return
		case .Tag:
			if f.deleted {
				if n.state != .Replaced {
					// Removing a datetime tag turns it back into a quoted string.
					need_respell = true
				}
				continue
			}
			if len(f.values) == 0 {
				return refuse(.Fact_No_Place, "TOML tag requires a datetime type name", n.base, lo)
			}
			if node_kind(cx.ov, h) != .String {
				return refuse(.Fact_No_Place, "TOML tag applies only to a datetime string", n.base, lo)
			}
			tag_override = f.values[0]
			if n.state != .Replaced {
				need_respell = true
			}
		case .Style:
			if !f.deleted && len(f.values) > 0 {
				style_override = f.values[0]
				if n.state != .Replaced {
					need_respell = true
				}
			}
		case:
			if !f.deleted {
				cx.dropped += {f.kind}
			}
		}
	}
	if need_respell {
		buf := make([dynamic]u8, 0, 32, cx.allocator)
		cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, style_override, tag_override) or_return
		append(cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = n.base, subtree_only = true}) or_return
	}
	return nil
}

@(private = "file")
emit_toml_comment :: proc(cx: ^Section_Cx, node: tape.Node_Index, f: Fact_Override, stmt_ls, val_hi: u64) -> Error {
	existing := collect_base_facts(cx.doc, node, f.kind, cx.allocator)
	defer delete(existing)
	if f.deleted || len(f.values) == 0 {
		for bf in existing {
			lo := bf.lo
			hi := bf.lo + u64(bf.n)
			if f.kind == .Comment && first_on_line(cx.src, lo) {
				lo = line_start(cx.src, lo)
				hi = next_line(cx.src, hi)
			} else if f.kind == .Comment_Inline {
				for lo > 0 && (cx.src[lo - 1] == ' ' || cx.src[lo - 1] == '\t') {
					lo -= 1
				}
			}
			append(cx.splices, Splice{lo = lo, hi = hi, seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
		return nil
	}
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	if f.kind == .Comment {
		append_toml_comments(cx, f.values, f.padded, false, &buf, node, stmt_ls) or_return
		if len(existing) > 0 {
			lo := line_start(cx.src, existing[0].lo)
			hi := next_line(cx.src, existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n))
			append(cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		} else {
			append(cx.splices, Splice{lo = stmt_ls, hi = stmt_ls, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
	} else {
		append_toml_comments(cx, f.values, f.padded, true, &buf, node, val_hi) or_return
		if len(existing) > 0 {
			lo := existing[0].lo
			for lo > 0 && (cx.src[lo - 1] == ' ' || cx.src[lo - 1] == '\t') {
				lo -= 1
			}
			hi := existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n)
			append(cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		} else {
			append(cx.splices, Splice{lo = val_hi, hi = val_hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
	}
	return nil
}

@(private = "file")
emit_toml_foot_comment :: proc(cx: ^Section_Cx, f: Fact_Override) -> Error {
	eof := u64(len(cx.src))
	if f.deleted || len(f.values) == 0 {
		for bf in tape.facts_of(cx.doc, tape.ROOT) {
			if bf.kind == .Comment_Foot {
				lo := line_start(cx.src, bf.lo)
				hi := next_line(cx.src, bf.lo + u64(bf.n))
				append(cx.splices, Splice{lo = lo, hi = hi, seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true}) or_return
			}
		}
		return nil
	}
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	if eof > 0 && cx.src[eof - 1] != '\n' {
		append(&buf, cx.eol)
	}
	append_toml_comments(cx, f.values, f.padded, false, &buf, tape.ROOT) or_return
	append(cx.splices, Splice{lo = eof, hi = eof, text = buf[:], seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true}) or_return
	return nil
}

@(private = "file")
emit_section_container_delta :: proc(
	cx: ^Section_Cx,
	h: Handle,
	n: ^Edit_Node,
	fr: Section_Frame,
	stack: ^[dynamic]Section_Frame,
) -> Error {
	base_c := n.base
	node := cx.doc.nodes[base_c]
	st := toml_style_of(cx.doc, base_c)

	if (node.kind == .Array || node.kind == .Object) && st == "inline" {
		return emit_toml_inline_delta(cx, h, n, fr, stack)
	}
	if node.kind == .Object {
		return emit_toml_table_delta(cx, h, n, fr, stack)
	}
	if node.kind == .Array {
		return emit_toml_aot_delta(cx, h, n, fr, stack)
	}
	return nil
}

// Composes edits to a TOML inline array `[...]` or inline table `{...}`.
@(private = "file")
emit_toml_inline_delta :: proc(
	cx: ^Section_Cx,
	h: Handle,
	n: ^Edit_Node,
	fr: Section_Frame,
	stack: ^[dynamic]Section_Frame,
) -> Error {
	_ = h
	d := n.delta
	if d == nil {
		return nil
	}
	base_c := n.base
	is_obj := cx.doc.nodes[base_c].kind == .Object
	c_lo, c_hi, cok := node_byte_span(cx.doc, base_c)
	if !cok || c_hi < c_lo + 2 {
		return refuse(.Bad_Handle, "cannot locate inline TOML container span", base_c)
	}

	Item :: struct {
		kn, vn:     tape.Node_Index,
		lo, hi:     u64,
		key_lo:     u64,
		key_hi:     u64,
		renamed_to: string,
		deleted:    bool,
	}
	items := make([dynamic]Item, 0, 8, cx.allocator)
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
				return refuse(.Bad_Handle, "cannot locate inline item span", vn)
			}
			ilo, klo, khi := vlo, u64(0), u64(0)
			if is_obj && kn != tape.NO_NODE {
				if lo_k, hi_k, kok := node_byte_span(cx.doc, kn); kok {
					ilo, klo, khi = lo_k, lo_k, hi_k
				}
			}
			is_del := false
			ren_to := ""
			if is_obj {
				k := decode_node_text_tmp(cx.doc, kn, cx.allocator)
				for dk in d.deleted_keys {
					if dk == k.text {
						is_del = true
						break
					}
				}
				if !is_del {
					for r in d.renamed_members {
						if r.old_key == k.text {
							ren_to = r.new_key
							break
						}
					}
				}
				free_tmp_text(k, cx.allocator)
			} else {
				for di in d.deleted_indices {
					if di == idx {
						is_del = true
						break
					}
				}
			}
			append(&items, Item{kn = kn, vn = vn, lo = ilo, hi = vhi, key_lo = klo, key_hi = khi, renamed_to = ren_to, deleted = is_del})
			idx += 1
		}
	}

	// Push surviving edited descendants.
	for it in items {
		if it.deleted {
			continue
		}
		if ch, has := cx.ov.by_base[it.vn]; has {
			if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits {
				append(stack, Section_Frame{h = ch, span_lo = fr.span_lo, span_hi = fr.span_hi})
			}
		}
	}

	// Spell inserted items (honoring child `.Style` and `.Tag` overrides).
	ins_count := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	ins_texts := make([][]u8, ins_count, cx.allocator)
	defer delete(ins_texts, cx.allocator)
	if is_obj {
		for ins, i in d.inserted_members {
			b := make([dynamic]u8, 0, 32, cx.allocator)
			cx.spec.spell_key(cx.spec.data, ins.key, &b) or_return
			append(&b, " = ")
			st_o, tg_o := node_style_and_tag(cx.ov, ins.value)
			cx.spec.spell_value(cx.spec.data, cx.ov, ins.value, &b, st_o, tg_o) or_return
			ins_texts[i] = b[:]
		}
	} else {
		for ins, i in d.inserted_elems {
			b := make([dynamic]u8, 0, 32, cx.allocator)
			st_o, tg_o := node_style_and_tag(cx.ov, ins.value)
			cx.spec.spell_value(cx.spec.data, cx.ov, ins.value, &b, st_o, tg_o) or_return
			ins_texts[i] = b[:]
		}
	}

	deleted_flags := make_deleted_flags(items[:], cx.allocator) or_return
	defer delete(deleted_flags, cx.allocator)
	order := make([dynamic]int, 0, len(items) + ins_count, cx.allocator)
	defer delete(order)
	if len(d.order) > 0 {
		validate_order(d.order, deleted_flags, ins_count, cx.allocator) or_return
		for raw in d.order {
			append(&order, int(raw))
		}
	} else {
		for j in 0 ..= len(items) {
			for ins_i in 0 ..< ins_count {
				at := d.inserted_members[ins_i].at if is_obj else d.inserted_elems[ins_i].at
				if at < 0 || at > len(items) {
					at = len(items)
				}
				if at == j {
					append(&order, len(items) + ins_i)
				}
			}
			if j < len(items) && !items[j].deleted {
				append(&order, j)
			}
		}
	}

	multiline := len(items) > 0 && bytes.index_byte(cx.src[c_lo:c_hi], '\n') >= 0
	item_indent := line_indent(cx.src, items[0].lo) if multiline else ""
	moves := make([dynamic]Move, 0, len(order) * 4 + 2, cx.allocator)
	if is_obj && len(order) > 0 && !multiline {
		pad := make([]u8, 1, cx.allocator)
		pad[0] = ' '
		append(&moves, Move{text = pad, written = true})
	}
	prev_had_comma := false
	for k, pos in order {
		if pos > 0 {
			sep := make([dynamic]u8, 0, 8, cx.allocator)
			if multiline {
				if !prev_had_comma {
					append(&sep, ',')
				}
				append(&sep, cx.eol)
				append(&sep, item_indent)
			} else {
				append(&sep, ", ")
			}
			append(&moves, Move{text = sep[:], written = true})
		} else if multiline {
			lead := make([dynamic]u8, 0, len(item_indent) + 2, cx.allocator)
			append(&lead, cx.eol)
			append(&lead, item_indent)
			append(&moves, Move{text = lead[:], written = true})
		}
		prev_had_comma = false
		if k < len(items) {
			it := items[k]
			// Emit item (with key renamed if applicable).
			if len(it.renamed_to) > 0 && it.key_hi > it.key_lo {
				kb := make([dynamic]u8, 0, len(it.renamed_to) + 2, cx.allocator)
				if serr := cx.spec.spell_key(cx.spec.data, it.renamed_to, &kb); serr != nil {
					delete(kb)
					return serr
				}
				append(&moves, Move{text = kb[:], written = true})
				append(&moves, Move{lo = it.key_hi, hi = it.hi})
			} else {
				append(&moves, Move{lo = it.lo, hi = it.hi})
			}
			// Attach any `#` inline comment on the same line after this item (Group 2!).
			hi := it.hi
			next_b := items[k + 1].lo if k + 1 < len(items) else c_hi - 1
			q := hi
			for q < next_b && (cx.src[q] == ' ' || cx.src[q] == '\t' || cx.src[q] == ',') {
				q += 1
			}
			if q < next_b && cx.src[q] == '#' {
				end_c := q
				for end_c < next_b && cx.src[end_c] != '\n' && cx.src[end_c] != '\r' {
					end_c += 1
				}
				if pos + 1 < len(order) {
					c_b := make([]u8, 1, cx.allocator)
					c_b[0] = ','
					append(&moves, Move{text = c_b, written = true})
					prev_had_comma = true
				}
				c_txt := slice.clone(cx.src[q - 1:end_c], cx.allocator)
				append(&moves, Move{text = c_txt, written = true})
			}
		} else {
			t := slice.clone(ins_texts[k - len(items)], cx.allocator)
			append(&moves, Move{text = t, written = true})
		}
	}
	if is_obj && len(order) > 0 && !multiline {
		pad := make([]u8, 1, cx.allocator)
		pad[0] = ' '
		append(&moves, Move{text = pad, written = true})
	} else if multiline && len(order) > 0 {
		tail := make([dynamic]u8, 0, 8, cx.allocator)
		append(&tail, cx.eol)
		append(&tail, line_indent(cx.src, c_hi - 1))
		append(&moves, Move{text = tail[:], written = true})
	}
	append(cx.splices, Splice {
		lo          = c_lo + 1,
		hi          = c_hi - 1,
		moves       = moves[:],
		seq         = len(cx.splices),
		base_node   = base_c,
		full_rewalk = false,
	}) or_return
	return nil
}

// Collects every leaf line range of a `"dotted"` TOML table `base_d` (plus any header/implicit subtables inside `[span_lo, span_hi)`).
@(private = "file")
collect_dotted_member_ranges :: proc(
	cx: ^Section_Cx,
	base_d: tape.Node_Index,
	base_path: string,
	span_lo, span_hi: u64,
	ranges: ^[dynamic]Byte_Range,
) {
	Frame :: struct {
		node: tape.Node_Index,
		path: string,
	}
	stack := make([dynamic]Frame, 0, 4, cx.allocator)
	defer delete(stack)
	append(&stack, Frame{node = base_d, path = base_path})
	for len(stack) > 0 {
		fr := pop(&stack)
		c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, fr.node, cx.allocator)
		if cerr != nil {
			continue
		}
		if p == .Found {
			for {
				kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
				if np != .Found {
					break
				}
				st := toml_style_of(cx.doc, vn)
				vnode := cx.doc.nodes[vn]
				if (vnode.kind == .Object || vnode.kind == .Array) && (st == "header" || st == "implicit") {
					tk := decode_node_text_tmp(cx.doc, kn, cx.allocator)
					cp, jerr := join_dotted_path(cx, fr.path, tk.text)
					free_tmp_text(tk, cx.allocator)
					if jerr == nil {
						for sec in cx.sections {
							if sec.head_lo >= span_lo && sec.body_hi <= span_hi && path_matches_or_child(sec.path, cp) {
								append(ranges, Byte_Range{sec.head_lo, sec.body_hi})
							}
						}
					}
					continue
				}
				if vnode.kind == .Object && st == "dotted" {
					tk := decode_node_text_tmp(cx.doc, kn, cx.allocator)
					cp, jerr := join_dotted_path(cx, fr.path, tk.text)
					free_tmp_text(tk, cx.allocator)
					if jerr == nil {
						append(&stack, Frame{node = vn, path = cp})
					}
					continue
				}
				if kn == tape.NO_NODE {
					continue
				}
				klo, _, kok := node_byte_span(cx.doc, kn)
				_, vhi, vok := node_byte_span(cx.doc, vn)
				if kok && vok {
					ls := line_start(cx.src, klo)
					hi := next_line(cx.src, vhi)
					for f in tape.facts_of(cx.doc, vn) {
						if f.kind == .Comment && line_start(cx.src, f.lo) < ls {
							ls = line_start(cx.src, f.lo)
						}
					}
					append(ranges, Byte_Range{ls, hi})
				}
			}
		}
		tape.destroy_children(&c)
	}
}

// Finds byte offsets `(lo, hi)` of the `seg_idx`-th dot-separated TOML key segment starting on the line containing `key_token_lo`.
@(private = "file")
toml_dotted_segment_span :: proc "contextless" (src: []u8, key_token_lo: u64, seg_idx: int) -> (lo, hi: u64, ok: bool) {
	p := line_start(src, key_token_lo)
	n := u64(len(src))
	for s := 0; s <= seg_idx; s += 1 {
		for p < n && (src[p] == ' ' || src[p] == '\t') {
			p += 1
		}
		if p >= n || src[p] == '=' || src[p] == '\n' || src[p] == '\r' {
			return 0, 0, false
		}
		seg_lo := p
		if src[p] == '\'' {
			p += 1
			for p < n && src[p] != '\'' && src[p] != '\n' {
				p += 1
			}
			if p < n && src[p] == '\'' {
				p += 1
			}
		} else if src[p] == '"' {
			p += 1
			for p < n && src[p] != '"' && src[p] != '\n' {
				if src[p] == '\\' && p + 1 < n {
					p += 2
					continue
				}
				p += 1
			}
			if p < n && src[p] == '"' {
				p += 1
			}
		} else {
			for p < n && src[p] != '.' && src[p] != '=' && src[p] != ' ' && src[p] != '\t' && src[p] != '\n' && src[p] != '\r' {
				p += 1
			}
		}
		if s == seg_idx {
			return seg_lo, p, p > seg_lo
		}
		for p < n && (src[p] == ' ' || src[p] == '\t') {
			p += 1
		}
		if p >= n || src[p] != '.' {
			return 0, 0, false
		}
		p += 1
	}
	return 0, 0, false
}

// Counts dot-separated segments in canonical spelled `dot_pref` (respecting quotes!).
@(private = "file")
toml_dotted_depth :: proc "contextless" (dot_pref: string) -> int {
	if len(dot_pref) == 0 {
		return 0
	}
	count := 1
	in_q: u8 = 0
	b := transmute([]u8)dot_pref
	for i := 0; i < len(b); i += 1 {
		c := b[i]
		if in_q != 0 {
			if c == '\\' && in_q == '"' {
				i += 1
			} else if c == in_q {
				in_q = 0
			}
		} else if c == '"' || c == '\'' {
			in_q = c
		} else if c == '.' {
			count += 1
		}
	}
	return count
}

// Finds all source byte ranges belonging to member `vn` inside `[span_lo, span_hi)`.
@(private = "file")
toml_member_ranges :: proc(
	cx: ^Section_Cx,
	kn, vn: tape.Node_Index,
	full_path: string,
	span_lo, span_hi: u64,
	allocator: runtime.Allocator,
) -> (
	ranges: [dynamic]Byte_Range,
	is_section: bool,
	is_dotted: bool,
) {
	ranges = make([dynamic]Byte_Range, 0, 2, allocator)
	vnode := cx.doc.nodes[vn]
	st := toml_style_of(cx.doc, vn)
	if (vnode.kind == .Object || vnode.kind == .Array) && (st == "header" || st == "implicit") {
		for sec in cx.sections {
			if sec.head_lo >= span_lo && sec.body_hi <= span_hi && path_matches_or_child(sec.path, full_path) {
				append(&ranges, Byte_Range{sec.head_lo, sec.body_hi})
			}
		}
		if len(ranges) > 0 {
			return ranges, true, false
		}
	}
	if vnode.kind == .Object && st == "dotted" {
		collect_dotted_member_ranges(cx, vn, full_path, span_lo, span_hi, &ranges)
		return ranges, false, true
	}
	klo, _, kok := node_byte_span(cx.doc, kn)
	_, vhi, vok := node_byte_span(cx.doc, vn)
	if kok && vok {
		ls := line_start(cx.src, klo)
		hi := next_line(cx.src, vhi)
		for f in tape.facts_of(cx.doc, vn) {
			if f.kind == .Comment && line_start(cx.src, f.lo) < ls {
				ls = line_start(cx.src, f.lo)
			}
		}
		append(&ranges, Byte_Range{ls, hi})
	}
	return ranges, false, false
}

// Resolves insertion offset within `[span_lo, span_hi)` for section `sec_path` (explicit header or `[[aot]]` when `allow_array`).
@(private = "file")
toml_table_insert_pos_ex :: proc(cx: ^Section_Cx, sec_path: string, span_lo, span_hi: u64, allow_array := false) -> (pos: u64, found_sec: bool) {
	if len(sec_path) == 0 {
		for sec in cx.sections {
			if sec.head_lo >= span_lo && sec.body_hi <= span_hi {
				return sec.head_lo, true
			}
		}
		return span_hi, true
	}
	for sec in cx.sections {
		if sec.head_lo < span_lo || sec.body_hi > span_hi {
			continue
		}
		if sec.path == sec_path && (!sec.is_array || allow_array) {
			return sec.body_hi, true
		}
	}
	return span_hi, false
}

// Finds the last section end in `[span_lo, span_hi)` owned by `path_pref` or a child of `path_pref`.
@(private = "file")
toml_implicit_insert_pos :: proc(cx: ^Section_Cx, path_pref: string, span_lo, span_hi: u64) -> u64 {
	best := span_hi
	has_best := false
	for sec in cx.sections {
		if sec.head_lo >= span_lo && sec.body_hi <= span_hi && path_matches_or_child(sec.path, path_pref) {
			best = sec.body_hi
			has_best = true
		}
	}
	return best if has_best else span_hi
}

@(private = "file")
emit_toml_table_delta :: proc(
	cx: ^Section_Cx,
	h: Handle,
	n: ^Edit_Node,
	fr: Section_Frame,
	stack: ^[dynamic]Section_Frame,
) -> Error {
	_ = h
	d := n.delta
	if d == nil {
		return nil
	}
	base_c := n.base
	path_pref := fr.path_pref
	T_Member :: struct {
		kn, vn:     tape.Node_Index,
		key:        string,
		full_path:  string,
		ranges:     [dynamic]Byte_Range,
		is_section: bool,
		is_dotted:  bool,
		deleted:    bool,
		renamed_to: string,
	}
	members := make([dynamic]T_Member, 0, 8, cx.allocator)
	defer {
		for m in members {
			delete(m.ranges)
		}
		delete(members)
	}
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if p == .Found {
		for {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found {
				break
			}
			k := decode_node_text_tmp(cx.doc, kn, cx.allocator)
			k_owned := string(slice.clone(transmute([]u8)k.text, cx.allocator))
			free_tmp_text(k, cx.allocator)
			fp, jerr := join_dotted_path(cx, path_pref, k_owned)
			if jerr != nil {
				delete(k_owned, cx.allocator)
				return jerr
			}
			is_del := false
			for dk in d.deleted_keys {
				if dk == k_owned {
					is_del = true
					break
				}
			}
			ren_to := ""
			if !is_del {
				for r in d.renamed_members {
					if r.old_key == k_owned {
						ren_to = r.new_key
						break
					}
				}
			}
			ranges, is_sec, is_dot := toml_member_ranges(cx, kn, vn, fp, fr.span_lo, fr.span_hi, cx.allocator)
			append(&members, T_Member{kn = kn, vn = vn, key = k_owned, full_path = fp, ranges = ranges, is_section = is_sec, is_dotted = is_dot, deleted = is_del, renamed_to = ren_to})
		}
	}

	// Push surviving edited child subtrees with full owner/dotted/span isolation.
	for m in members {
		if m.deleted {
			continue
		}
		if ch, has := cx.ov.by_base[m.vn]; has {
			if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits {
				push_section_child_frame(cx, fr, ch, m.kn, m.vn, true, -1, nil, stack) or_return
			}
		}
	}

	// Apply key renames for surviving members!
	emit_toml_header_renames :: proc(cx: ^Section_Cx, path_pref, old_full, renamed_to: string, base_c: tape.Node_Index, span_lo, span_hi: u64) -> Error {
		new_pref := join_dotted_path(cx, path_pref, renamed_to) or_return
		defer delete(new_pref, cx.allocator)
		for sec in cx.sections {
			if sec.head_lo < span_lo || sec.body_hi > span_hi || !path_matches_or_child(sec.path, old_full) {
				continue
			}
			nb := make([dynamic]u8, 0, len(new_pref) + len(sec.path), cx.allocator)
			append(&nb, new_pref)
			if len(sec.path) > len(old_full) {
				append(&nb, sec.path[len(old_full):])
			}
			append(cx.splices, Splice{lo = sec.header_key_lo, hi = sec.header_key_hi, text = nb[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
		}
		return nil
	}
	for m in members {
		if m.deleted || len(m.renamed_to) == 0 {
			continue
		}
		if m.is_section {
			emit_toml_header_renames(cx, path_pref, m.full_path, m.renamed_to, base_c, fr.span_lo, fr.span_hi) or_return
		} else if m.is_dotted {
			// Rename every dotted line segment belonging to this dotted table (and any subtable headers).
			seg_idx := toml_dotted_depth(fr.dot_pref)
			new_seg := make([dynamic]u8, 0, len(m.renamed_to) + 2, cx.allocator)
			cx.spec.spell_key(cx.spec.data, m.renamed_to, &new_seg) or_return
			for r in m.ranges {
				trimmed := r.lo
				for trimmed < r.hi && (cx.src[trimmed] == ' ' || cx.src[trimmed] == '\t') {
					trimmed += 1
				}
				if trimmed < r.hi && cx.src[trimmed] == '[' {
					continue
				}
				if slo, shi, sok := toml_dotted_segment_span(cx.src, r.lo, seg_idx); sok {
					append(cx.splices, Splice{lo = slo, hi = shi, text = slice.clone(new_seg[:], cx.allocator), seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
				}
			}
			delete(new_seg)
			emit_toml_header_renames(cx, path_pref, m.full_path, m.renamed_to, base_c, fr.span_lo, fr.span_hi) or_return
		} else {
			if klo, khi, kok := node_byte_span(cx.doc, m.kn); kok {
				kb := make([dynamic]u8, 0, len(m.renamed_to) + 2, cx.allocator)
				cx.spec.spell_key(cx.spec.data, m.renamed_to, &kb) or_return
				append(cx.splices, Splice{lo = klo, hi = khi, text = kb[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
			}
		}
	}

	// Handle explicit reorder (including Group 2: moving a section before a top-level line!).
	allow_arr_owner := len(fr.owner_sec) > 0 && n.base != tape.NO_NODE && n.base != tape.ROOT
	if len(d.order) > 0 {
		for ins in d.inserted_members {
			if node_kind(cx.ov, ins.value) == .Null {
				return refuse(.Unspellable_Value, "TOML has no null value", base_c)
			}
		}
		deleted_flags := make_deleted_flags(members[:], cx.allocator) or_return
		defer delete(deleted_flags, cx.allocator)
		validate_order(d.order, deleted_flags, len(d.inserted_members), cx.allocator) or_return

		span_lo := fr.span_hi
		span_hi := fr.span_lo
		for m in members {
			for r in m.ranges {
				span_lo = min(span_lo, r.lo)
				span_hi = max(span_hi, r.hi)
			}
		}
		// Guard against swallowing a foreign section sitting between non-contiguous ranges of this table!
		if span_lo < span_hi {
			has_foreign := false
			for sec in cx.sections {
				if sec.head_lo >= span_lo && sec.head_lo < span_hi {
					owned_by_member := false
					for m in members {
						for r in m.ranges {
							if sec.head_lo >= r.lo && sec.body_hi <= r.hi {
								owned_by_member = true
								break
							}
						}
						if owned_by_member {
							break
						}
					}
					if !owned_by_member {
						has_foreign = true
						break
					}
				}
			}
			if has_foreign {
				if cx.opts.reflow {
					return emit_section_full_reflow(cx)
				}
				return refuse(.Layout_Reflow_Needed, "TOML table reorder spans a foreign section; pass reflow=true", base_c)
			}

			_, found_sec := toml_table_insert_pos_ex(cx, path_pref, fr.span_lo, fr.span_hi, allow_array = allow_arr_owner)
			need_implicit_hdr := len(fr.dot_pref) == 0 && len(path_pref) > 0 && !found_sec
			if need_implicit_hdr {
				has_base_nonsec := false
				has_pass1_ins_scalar := false
				for raw in d.order {
					k := int(raw)
					if k < len(members) {
						if !members[k].is_section {
							has_base_nonsec = true
						}
					} else {
						ins := d.inserted_members[k - len(members)]
						if node_kind(cx.ov, ins.value) != .Object {
							has_pass1_ins_scalar = true
						}
					}
				}
				if has_base_nonsec && has_pass1_ins_scalar {
					if cx.opts.reflow {
						return emit_section_full_reflow(cx)
					}
					return refuse(.Layout_Reflow_Needed, "TOML table reorder with dotted keys and implicit header requires reflow=true", base_c)
				}
			}

			moves := make([dynamic]Move, 0, len(d.order) * 2 + 1, cx.allocator)
			emitted_implicit_hdr := false
			// Pass 1: key-value lines (and inserted scalar/inline members) stay before any `[section]` header.
			for raw in d.order {
				k := int(raw)
				if k < len(members) {
					m := members[k]
					if !m.is_section {
						for r in m.ranges {
							append(&moves, Move{lo = r.lo, hi = r.hi})
						}
					}
				} else {
					ins := d.inserted_members[k - len(members)]
					if len(fr.dot_pref) > 0 || node_kind(cx.ov, ins.value) != .Object {
						if need_implicit_hdr && !emitted_implicit_hdr {
							emitted_implicit_hdr = true
							hb := make([dynamic]u8, 0, len(path_pref) + 4, cx.allocator)
							append(&hb, '[')
							append(&hb, path_pref)
							append(&hb, ']')
							append(&hb, cx.eol)
							append(&moves, Move{text = hb[:], written = true})
						}
						line := spell_toml_member_line(cx, ins.key, ins.value, path_pref, fr.dot_pref) or_return
						append(&moves, Move{text = line, written = true})
					}
				}
			}
			// Pass 2: `[section]` members in requested order!
			if len(fr.dot_pref) == 0 {
				for raw in d.order {
					k := int(raw)
					if k < len(members) {
						m := members[k]
						if m.is_section {
							for r in m.ranges {
								append(&moves, Move{lo = r.lo, hi = r.hi})
							}
						}
					} else {
						ins := d.inserted_members[k - len(members)]
						if node_kind(cx.ov, ins.value) == .Object {
							sec_txt := spell_toml_member_line(cx, ins.key, ins.value, path_pref, "") or_return
							append(&moves, Move{text = sec_txt, written = true})
						}
					}
				}
			}
			append(cx.splices, Splice{lo = span_lo, hi = span_hi, moves = moves[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
			return nil
		}
	}

	// Non-reorder deletions: remove all byte ranges of each deleted member.
	for m in members {
		if !m.deleted {
			continue
		}
		for r in m.ranges {
			append(cx.splices, Splice{lo = r.lo, hi = r.hi, seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
		}
	}

	if len(d.inserted_members) == 0 {
		return nil
	}

	// Non-reorder insertions (handling dotted tables, implicit super-tables, bounded `[[arr]]` elements, and explicit headers!):
	for ins in d.inserted_members {
		if node_kind(cx.ov, ins.value) == .Null {
			return refuse(.Unspellable_Value, "TOML has no null value", base_c)
		}
	}
	if len(fr.dot_pref) > 0 {
		// Inside a dotted-key table (`a.b = 1`): NEVER emit `[a]` (forbidden in TOML!), emit `a.k = v` lines inside owning section/root!
		dot_ins_pos := u64(0)
		has_non_sec := false
		for m in members {
			if !m.is_section {
				for r in m.ranges {
					if !has_non_sec || r.hi > dot_ins_pos {
						dot_ins_pos = r.hi
						has_non_sec = true
					}
				}
			}
		}
		if !has_non_sec {
			dot_ins_pos, _ = toml_table_insert_pos_ex(cx, fr.owner_sec, fr.span_lo, fr.span_hi, allow_array = allow_arr_owner)
		}
		for ins in d.inserted_members {
			txt := spell_toml_member_line(cx, ins.key, ins.value, path_pref, fr.dot_pref) or_return
			pos := dot_ins_pos
			if ins.at >= 0 && ins.at < len(members) && !members[ins.at].is_section && len(members[ins.at].ranges) > 0 {
				pos = members[ins.at].ranges[0].lo
			}
			append_toml_line_splice(cx, pos, txt, base_c) or_return
		}
		return nil
	}

	ins_pos, found_sec := toml_table_insert_pos_ex(cx, path_pref, fr.span_lo, fr.span_hi, allow_array = allow_arr_owner)
	impl_pos := toml_implicit_insert_pos(cx, path_pref, fr.span_lo, fr.span_hi) if !found_sec && len(path_pref) > 0 else fr.span_hi
	if !found_sec && len(path_pref) > 0 {
		// Implicit super-table (`[a.b]` present, `[a]` absent): batch all non-Object inserts under ONE `[a]` header at `impl_pos`!
		scalar_batch := make([dynamic]u8, 0, 64, cx.allocator)
		has_scalar_batch := false
		for ins in d.inserted_members {
			if node_kind(cx.ov, ins.value) == .Object {
				txt := spell_toml_member_line(cx, ins.key, ins.value, path_pref, "") or_return
				append_toml_line_splice(cx, impl_pos, txt, base_c) or_return
				continue
			}
			if !has_scalar_batch {
				has_scalar_batch = true
				append(&scalar_batch, '[')
				append(&scalar_batch, path_pref)
				append(&scalar_batch, ']')
				append(&scalar_batch, cx.eol)
			}
			line := spell_toml_member_line(cx, ins.key, ins.value, path_pref, "") or_return
			append(&scalar_batch, ..line)
			delete(line, cx.allocator)
		}
		if has_scalar_batch {
			append_toml_line_splice(cx, impl_pos, scalar_batch[:], base_c) or_return
		} else {
			delete(scalar_batch)
		}
		return nil
	}

	for ins in d.inserted_members {
		txt := spell_toml_member_line(cx, ins.key, ins.value, path_pref, "") or_return
		is_obj_val := node_kind(cx.ov, ins.value) == .Object
		pos := fr.span_hi if is_obj_val else ins_pos
		if ins.at >= 0 && ins.at < len(members) && len(members[ins.at].ranges) > 0 {
			if is_obj_val == members[ins.at].is_section {
				pos = members[ins.at].ranges[0].lo
			}
		}
		append_toml_line_splice(cx, pos, txt, base_c) or_return
	}
	return nil
}

@(private = "file")
append_toml_line_splice :: proc(cx: ^Section_Cx, pos: u64, txt: []u8, base_node: tape.Node_Index) -> Error {
	out_txt := txt
	if pos > 0 && pos <= u64(len(cx.src)) && cx.src[pos - 1] != '\n' {
		prefixed := make([dynamic]u8, 0, len(cx.eol) + len(txt), cx.allocator)
		append(&prefixed, cx.eol)
		append(&prefixed, ..txt)
		delete(txt, cx.allocator)
		out_txt = prefixed[:]
	}
	append(cx.splices, Splice{lo = pos, hi = pos, text = out_txt, seq = len(cx.splices), base_node = base_node, full_rewalk = true}) or_return
	return nil
}

@(private = "file")
spell_toml_table_body :: proc(cx: ^Section_Cx, obj_h: Handle, out: ^[dynamic]u8) -> Error {
	mems, owned, merr := effective_members(cx.ov, obj_h, cx.allocator)
	if merr != nil {
		return merr
	}
	defer destroy_effective_members(mems, owned, cx.allocator)
	for m in mems {
		cx.spec.spell_key(cx.spec.data, m.key, out) or_return
		append(out, " = ")
		vh := m.handle
		if vh == NO_HANDLE && m.base_val != tape.NO_NODE {
			vh = handle_for_base(cx.ov, m.base_val) or_return
		}
		st_o, tg_o := node_style_and_tag(cx.ov, vh)
		cx.spec.spell_value(cx.spec.data, cx.ov, vh, out, st_o, tg_o) or_return
		append(out, cx.eol)
	}
	return nil
}

@(private = "file")
spell_toml_member_line :: proc(cx: ^Section_Cx, key: string, val_h: Handle, path_pref: string, dot_pref: string) -> (out: []u8, err: Error) {
	b := make([dynamic]u8, 0, 64, cx.allocator)
	if node_kind(cx.ov, val_h) == .Object && len(dot_pref) == 0 {
		append(&b, cx.eol)
		append(&b, '[')
		if len(path_pref) > 0 {
			append(&b, path_pref)
			append(&b, '.')
		}
		cx.spec.spell_key(cx.spec.data, key, &b) or_return
		append(&b, ']')
		append(&b, cx.eol)
		spell_toml_table_body(cx, val_h, &b) or_return
		return b[:], nil
	}
	if vn, vok := get_node(cx.ov, val_h); vok {
		for f in vn.facts {
			if f.kind == .Comment && !f.deleted {
				append_toml_comments(cx, f.values, f.padded, false, &b, tape.NO_NODE) or_return
			}
		}
	}
	if len(dot_pref) > 0 {
		append(&b, dot_pref)
		append(&b, '.')
	}
	cx.spec.spell_key(cx.spec.data, key, &b) or_return
	append(&b, " = ")
	st_o, tg_o := node_style_and_tag(cx.ov, val_h)
	cx.spec.spell_value(cx.spec.data, cx.ov, val_h, &b, st_o, tg_o) or_return
	if vn, vok := get_node(cx.ov, val_h); vok {
		for f in vn.facts {
			if f.kind == .Comment_Inline && !f.deleted && len(f.values) > 0 {
				append_toml_comments(cx, f.values, f.padded, true, &b, tape.NO_NODE) or_return
			}
		}
	}
	append(&b, cx.eol)
	return b[:], nil
}

@(private = "file")
emit_toml_aot_delta :: proc(
	cx: ^Section_Cx,
	h: Handle,
	n: ^Edit_Node,
	fr: Section_Frame,
	stack: ^[dynamic]Section_Frame,
) -> Error {
	_ = h
	d := n.delta
	if d == nil {
		return nil
	}
	path_pref := fr.path_pref
	aot_items := collect_aot_items(cx, path_pref, fr.span_lo, fr.span_hi, d.deleted_indices[:])
	defer delete(aot_items)

	// Push ONLY surviving edited child tables, bounded strictly to their own `[aot[i].lo, aot[i].hi)` span!
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, n.base, cx.allocator)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if p == .Found {
		for idx := 0; ; idx += 1 {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found {
				break
			}
			if idx < len(aot_items) && aot_items[idx].deleted {
				continue
			}
			if ch, has := cx.ov.by_base[vn]; has {
				if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits {
					push_section_child_frame(cx, fr, ch, kn, vn, false, idx, aot_items[:], stack) or_return
				}
			}
		}
	}

	// Spell inserted AOT elements.
	ins_texts := make([][]u8, len(d.inserted_elems), cx.allocator)
	defer delete(ins_texts, cx.allocator)
	for ins, i in d.inserted_elems {
		if node_kind(cx.ov, ins.value) != .Object {
			return refuse(.Unspellable_Value, "TOML array of tables requires table elements", n.base)
		}
		b := make([dynamic]u8, 0, 64, cx.allocator)
		append(&b, "[[")
		append(&b, path_pref)
		append(&b, "]]")
		append(&b, cx.eol)
		spell_toml_table_body(cx, ins.value, &b) or_return
		ins_texts[i] = b[:]
	}

	// Handle explicit reorder on `[[arr]]`!
	if len(d.order) > 0 {
		deleted_flags := make_deleted_flags(aot_items[:], cx.allocator) or_return
		defer delete(deleted_flags, cx.allocator)
		validate_order(d.order, deleted_flags, len(d.inserted_elems), cx.allocator) or_return
		if len(aot_items) > 0 {
			span_lo := aot_items[0].lo
			span_hi := aot_items[len(aot_items) - 1].hi
			// Check for foreign sections between non-contiguous AOT blocks.
			for sec in cx.sections {
				if sec.head_lo >= span_lo && sec.head_lo < span_hi && !path_matches_or_child(sec.path, path_pref) {
					if cx.opts.reflow {
						return emit_section_full_reflow(cx)
					}
					return refuse(.Layout_Reflow_Needed, "TOML array-of-tables reorder spans a foreign section; pass reflow=true", n.base)
				}
			}
			moves := make([dynamic]Move, 0, len(d.order), cx.allocator)
			for raw in d.order {
				k := int(raw)
				if k < len(aot_items) {
					append(&moves, Move{lo = aot_items[k].lo, hi = aot_items[k].hi})
				} else {
					t := slice.clone(ins_texts[k - len(aot_items)], cx.allocator)
					append(&moves, Move{text = t, written = true})
				}
			}
			append(cx.splices, Splice{lo = span_lo, hi = span_hi, moves = moves[:], seq = len(cx.splices), base_node = n.base, full_rewalk = true}) or_return
			return nil
		}
	}

	// Non-reorder deletions.
	for it in aot_items {
		if it.deleted {
			append(cx.splices, Splice{lo = it.lo, hi = it.hi, seq = len(cx.splices), base_node = n.base, full_rewalk = true}) or_return
		}
	}

	// Non-reorder insertions (honoring `ins.at`!).
	for ins, i in d.inserted_elems {
		pos := fr.span_hi
		if ins.at >= 0 && ins.at < len(aot_items) {
			pos = aot_items[ins.at].lo
		} else if len(aot_items) > 0 {
			pos = aot_items[len(aot_items) - 1].hi
		}
		b := make([dynamic]u8, 0, len(ins_texts[i]) + 2, cx.allocator)
		if pos > 0 && pos <= u64(len(cx.src)) && cx.src[pos - 1] != '\n' {
			append(&b, cx.eol)
		}
		append(&b, ..ins_texts[i])
		delete(ins_texts[i], cx.allocator)
		if _, aerr := append(cx.splices, Splice{lo = pos, hi = pos, text = b[:], seq = len(cx.splices), base_node = n.base, full_rewalk = true}); aerr != nil {
			delete(b)
			return aerr
		}
	}
	return nil
}
