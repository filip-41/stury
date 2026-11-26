package edit

import "base:runtime"
import "core:bytes"
import "core:container/handle_map"
import "core:container/xar"
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
	fast, target, fast_res, gerr := commit_guard(ov, spec.target, opts, true, spec.validate, spec.data, allocator)
	if gerr != nil {
		return {}, gerr
	}
	if fast {
		return fast_res, nil
	}
	doc := ov.base
	// Group 1 check: root must remain an object.
	if ov.root != NO_HANDLE && node_kind(ov, ov.root) != .Object {
		return {}, refuse(.Root_Shape, "TOML document root must be a table (object)", tape.ROOT)
	}

	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 4096}
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)

	cx := Section_Cx {
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
				if n.val.kind == .Null || n.val.kind == .None {
					return {}, refuse(.Unspellable_Value, "TOML has no null value", n.base)
				}
				if n.val.kind == .Raw {
					lo, hi, ok := node_byte_span(doc, n.base)
					if !ok {
						return {}, refuse(.Bad_Handle, "cannot locate base value span", n.base)
					}
					append(&cx.splices, Splice {
						lo           = lo,
						hi           = hi,
						text         = transmute([]u8)n.val.text,
						seq          = len(cx.splices),
						base_node    = n.base,
						subtree_only = true,
					}) or_return
				} else {
					emit_section_replace(&cx, n.handle, n) or_return
				}
			}
		}
	} else {
		if ov.unlinked_parents {
			ensure_linked(ov) or_return
		}
		cx.eol = detect_eol(doc.src)
		cx.sections = make([dynamic]Toml_Section, 0, 8, scratch)
		scan_toml_sections(&cx) or_return
		if ov.root != NO_HANDLE {
			if err = compose_section_walk(&cx, ov.root); err != nil {
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
			chk: [256]u8
			chk[0], chk[1], chk[2], chk[3] = 'v', ' ', '=', ' '
			for rec in recs {
				if !rec.subtree_only || rec.full_rewalk {
					need_full = true
					break
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
					need_full = true
					break
				}
				copy(chk[4:], frag)
				if verr := spec.validate(spec.data, chk[:4 + len(frag)], scratch); verr != nil {
					return fail_commit_validation(out, recs, rew, verr, allocator)
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
Section_Cx :: struct {
	ov:        ^Overlay,
	doc:       ^tape.Document,
	src:       []u8,
	spec:      ^Section_Spec,
	opts:      Options,
	eol:       string,
	sections:  [dynamic]Toml_Section,
	splices:   [dynamic]Splice,
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

@(private = "file")
toml_style_of :: proc "contextless" (doc: ^tape.Document, node: tape.Node_Index) -> string {
	if doc.format != nil && doc.format.fact_name != nil {
		if name, ok := doc.format.fact_name(doc, node, .Style); ok {
			return name
		}
	}
	return ""
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

// Emits a whole-document reflow rewrite via `cx.spec.spell_document` (discarding any partial splices).
@(private = "file")
emit_section_full_reflow :: proc(cx: ^Section_Cx) -> Error {
	if cx.spec.spell_document == nil {
		return refuse(.Layout_Reflow_Needed, "TOML document reflow requires spell_document", tape.ROOT)
	}
	// Clear prior partial splices so whole-document splice is the sole splice!
	clear(&cx.splices)
	buf := make([dynamic]u8, 0, 128, cx.allocator)
	cx.spec.spell_document(cx.spec.data, cx.ov, &buf) or_return
	append(&cx.splices, Splice{lo = 0, hi = u64(len(cx.src)), text = buf[:], seq = 0, base_node = tape.ROOT, full_rewalk = true, rewritten = true}) or_return
	cx.reflowed = true
	return nil
}

@(private = "file")
Section_Frame :: struct {
	h:         Handle,
	path_pref: string,
}

@(private = "file")
compose_section_walk :: proc(cx: ^Section_Cx, root: Handle) -> Error {
	stack := make([dynamic]Section_Frame, 0, 32, cx.allocator)
	owned_paths := make([dynamic]string, 0, 8, cx.allocator)
	append(&stack, Section_Frame{h = root}) or_return

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
			emit_section_container_delta(cx, fr.h, n, fr.path_pref, &stack, &owned_paths) or_return
			continue
		}
		if n.base != tape.NO_NODE {
			push_section_children(cx, n.base, fr.path_pref, &stack, &owned_paths) or_return
		}
	}
	return nil
}

@(private = "file")
push_section_children :: proc(
	cx: ^Section_Cx,
	base_c: tape.Node_Index,
	path_pref: string,
	stack: ^[dynamic]Section_Frame,
	owned_paths: ^[dynamic]string,
) -> Error {
	node := cx.doc.nodes[base_c]
	if node.kind < .Array {
		return nil
	}
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if p != .Found {
		return nil
	}
	for {
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
		child_path := path_pref
		if node.kind == .Object && kn != tape.NO_NODE {
			k := decode_node_text_tmp(cx.doc, kn, cx.allocator)
			kb := make([dynamic]u8, 0, len(path_pref) + len(k.text) + 4, cx.allocator)
			if len(path_pref) > 0 {
				append(&kb, path_pref)
				append(&kb, '.')
			}
			if serr := cx.spec.spell_key(cx.spec.data, k.text, &kb); serr != nil {
				delete(kb)
				free_tmp_text(k, cx.allocator)
				return serr
			}
			free_tmp_text(k, cx.allocator)
			child_path = string(kb[:])
			if _, aerr := append(owned_paths, child_path); aerr != nil {
				delete(kb)
				return aerr
			}
		}
		if _, aerr := append(stack, Section_Frame{h = ch, path_pref = child_path}); aerr != nil {
			return aerr
		}
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
	append(&cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = n.base, subtree_only = true}) or_return
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
		append(&cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = n.base, subtree_only = true}) or_return
	}
	return nil
}

@(private = "file")
emit_toml_comment :: proc(cx: ^Section_Cx, node: tape.Node_Index, f: Fact_Override, stmt_ls, val_hi: u64) -> Error {
	existing := make([dynamic]tape.Fact, 0, 4, cx.allocator)
	for bf in tape.facts_of(cx.doc, node) {
		if bf.kind == f.kind {
			append(&existing, bf)
		}
	}
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
			append(&cx.splices, Splice{lo = lo, hi = hi, seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
		return nil
	}
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	if f.kind == .Comment {
		for line in f.values {
			append(&buf, '#')
			if f.padded && len(line) > 0 {
				append(&buf, ' ')
			}
			append(&buf, line)
			append(&buf, cx.eol)
		}
		if len(existing) > 0 {
			lo := line_start(cx.src, existing[0].lo)
			hi := next_line(cx.src, existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n))
			append(&cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		} else {
			append(&cx.splices, Splice{lo = stmt_ls, hi = stmt_ls, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
	} else {
		if len(f.values) > 1 {
			return refuse(.Fact_No_Place, "a TOML line holds at most one inline comment", node, val_hi)
		}
		append(&buf, " #")
		if f.padded && len(f.values[0]) > 0 {
			append(&buf, ' ')
		}
		append(&buf, f.values[0])
		if len(existing) > 0 {
			lo := existing[0].lo
			for lo > 0 && (cx.src[lo - 1] == ' ' || cx.src[lo - 1] == '\t') {
				lo -= 1
			}
			hi := existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n)
			append(&cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		} else {
			append(&cx.splices, Splice{lo = val_hi, hi = val_hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true}) or_return
		}
	}
	return nil
}

@(private = "file")
emit_toml_foot_comment :: proc(cx: ^Section_Cx, f: Fact_Override) -> Error {
	if !f.deleted {
		for line in f.values {
			if !toml_comment_valid(line) {
				return refuse(.Fact_No_Place, "TOML comment contains disallowed control byte", tape.ROOT)
			}
		}
	}
	eof := u64(len(cx.src))
	if f.deleted || len(f.values) == 0 {
		for bf in tape.facts_of(cx.doc, tape.ROOT) {
			if bf.kind == .Comment_Foot {
				lo := line_start(cx.src, bf.lo)
				hi := next_line(cx.src, bf.lo + u64(bf.n))
				if _, aerr := append(&cx.splices, Splice{lo = lo, hi = hi, seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true}); aerr != nil {
					return aerr
				}
			}
		}
		return nil
	}
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	if eof > 0 && cx.src[eof - 1] != '\n' {
		append(&buf, cx.eol)
	}
	for line in f.values {
		append(&buf, '#')
		if f.padded && len(line) > 0 {
			append(&buf, ' ')
		}
		append(&buf, line)
		append(&buf, cx.eol)
	}
	append(&cx.splices, Splice{lo = eof, hi = eof, text = buf[:], seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true}) or_return
	return nil
}

@(private = "file")
emit_section_container_delta :: proc(
	cx: ^Section_Cx,
	h: Handle,
	n: ^Edit_Node,
	path_pref: string,
	stack: ^[dynamic]Section_Frame,
	owned_paths: ^[dynamic]string,
) -> Error {
	base_c := n.base
	node := cx.doc.nodes[base_c]
	st := toml_style_of(cx.doc, base_c)

	if (node.kind == .Array || node.kind == .Object) && st == "inline" {
		return emit_toml_inline_delta(cx, h, n, stack, owned_paths)
	}
	if node.kind == .Object {
		return emit_toml_table_delta(cx, h, n, path_pref, stack, owned_paths)
	}
	if node.kind == .Array {
		return emit_toml_aot_delta(cx, h, n, path_pref, stack, owned_paths)
	}
	return nil
}

// Composes edits to a TOML inline array `[...]` or inline table `{...}`.
@(private = "file")
emit_toml_inline_delta :: proc(
	cx: ^Section_Cx,
	h: Handle,
	n: ^Edit_Node,
	stack: ^[dynamic]Section_Frame,
	owned_paths: ^[dynamic]string,
) -> Error {
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
				append(stack, Section_Frame{h = ch})
			}
		}
	}

	// Spell inserted items (honoring child `.Style` and `.Tag` overrides).
	ins_count := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	ins_texts := make([][]u8, ins_count, cx.allocator)
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

	deleted_flags := make([]bool, len(items), cx.allocator)
	defer delete(deleted_flags, cx.allocator)
	for it, i in items {
		deleted_flags[i] = it.deleted
	}
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
	if _, aerr := append(&cx.splices, Splice {
		lo          = c_lo + 1,
		hi          = c_hi - 1,
		moves       = moves[:],
		seq         = len(cx.splices),
		base_node   = base_c,
		full_rewalk = false,
	}); aerr != nil {
		return aerr
	}
	return nil
}

// Finds all source byte ranges belonging to member `vn` (a key-value line, or one/several `[section]` blocks!).
@(private = "file")
toml_member_ranges :: proc(
	cx: ^Section_Cx,
	kn, vn: tape.Node_Index,
	full_path: string,
	allocator: runtime.Allocator,
) -> (
	ranges: [dynamic]Byte_Range,
	is_section: bool,
) {
	ranges = make([dynamic]Byte_Range, 0, 2, allocator)
	vnode := cx.doc.nodes[vn]
	st := toml_style_of(cx.doc, vn)
	if (vnode.kind == .Object || vnode.kind == .Array) && (st == "header" || st == "implicit") {
		is_section = true
		for sec in cx.sections {
			if path_matches_or_child(sec.path, full_path) {
				append(&ranges, Byte_Range{sec.head_lo, sec.body_hi})
			}
		}
		if len(ranges) > 0 {
			return ranges, true
		}
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
	return ranges, false
}

@(private = "file")
toml_table_insert_pos :: proc(cx: ^Section_Cx, path_pref: string) -> u64 {
	if len(path_pref) == 0 {
		if len(cx.sections) > 0 {
			return cx.sections[0].head_lo
		}
		return u64(len(cx.src))
	}
	for sec in cx.sections {
		if sec.path == path_pref && !sec.is_array {
			return sec.body_hi
		}
	}
	return u64(len(cx.src))
}

@(private = "file")
emit_toml_table_delta :: proc(
	cx: ^Section_Cx,
	h: Handle,
	n: ^Edit_Node,
	path_pref: string,
	stack: ^[dynamic]Section_Frame,
	owned_paths: ^[dynamic]string,
) -> Error {
	d := n.delta
	if d == nil {
		return nil
	}
	base_c := n.base
	T_Member :: struct {
		kn, vn:     tape.Node_Index,
		key:        string,
		full_path:  string,
		ranges:     [dynamic]Byte_Range,
		is_section: bool,
		deleted:    bool,
		renamed_to: string,
	}
	members := make([dynamic]T_Member, 0, 8, cx.allocator)
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
			fpb := make([dynamic]u8, 0, len(path_pref) + len(k_owned) + 4, cx.allocator)
			if len(path_pref) > 0 {
				append(&fpb, path_pref)
				append(&fpb, '.')
			}
			if serr := cx.spec.spell_key(cx.spec.data, k_owned, &fpb); serr != nil {
				delete(fpb)
				delete(k_owned, cx.allocator)
				return serr
			}
			fp := string(fpb[:])
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
			ranges, is_sec := toml_member_ranges(cx, kn, vn, fp, cx.allocator)
			append(&members, T_Member{kn = kn, vn = vn, key = k_owned, full_path = fp, ranges = ranges, is_section = is_sec, deleted = is_del, renamed_to = ren_to})
		}
	}

	// Push surviving edited child subtrees.
	for m in members {
		if m.deleted {
			continue
		}
		if ch, has := cx.ov.by_base[m.vn]; has {
			if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits {
				fp_copy := string(slice.clone(transmute([]u8)m.full_path, cx.allocator))
				append(owned_paths, fp_copy)
				append(stack, Section_Frame{h = ch, path_pref = fp_copy})
			}
		}
	}

	// Apply key renames for surviving members!
	for m in members {
		if m.deleted || len(m.renamed_to) == 0 {
			continue
		}
		if m.is_section {
			// Rewrite every section header whose path equals `m.full_path` or starts with `m.full_path.`!
			new_pref := make([dynamic]u8, 0, len(path_pref) + len(m.renamed_to) + 4, cx.allocator)
			defer delete(new_pref)
			if len(path_pref) > 0 {
				append(&new_pref, path_pref)
				append(&new_pref, '.')
			}
			cx.spec.spell_key(cx.spec.data, m.renamed_to, &new_pref) or_return
			for sec in cx.sections {
				if !path_matches_or_child(sec.path, m.full_path) {
					continue
				}
				nb := make([dynamic]u8, 0, len(new_pref) + len(sec.path), cx.allocator)
				append(&nb, ..new_pref[:])
				if len(sec.path) > len(m.full_path) {
					append(&nb, sec.path[len(m.full_path):])
				}
				append(&cx.splices, Splice{lo = sec.header_key_lo, hi = sec.header_key_hi, text = nb[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
			}
		} else {
			if klo, khi, kok := node_byte_span(cx.doc, m.kn); kok {
				kb := make([dynamic]u8, 0, len(m.renamed_to) + 2, cx.allocator)
				cx.spec.spell_key(cx.spec.data, m.renamed_to, &kb) or_return
				append(&cx.splices, Splice{lo = klo, hi = khi, text = kb[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
			}
		}
	}

	// Handle explicit reorder (including Group 2: moving a section before a top-level line!).
	if len(d.order) > 0 {
		deleted_flags := make([]bool, len(members), cx.allocator)
		defer delete(deleted_flags, cx.allocator)
		for m, i in members {
			deleted_flags[i] = m.deleted
		}
		validate_order(d.order, deleted_flags, len(d.inserted_members), cx.allocator) or_return

		span_lo := u64(len(cx.src))
		span_hi := u64(0)
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

			moves := make([dynamic]Move, 0, len(d.order) * 2, cx.allocator)
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
					if node_kind(cx.ov, ins.value) != .Object {
						line := spell_toml_member_line(cx, ins.key, ins.value, path_pref) or_return
						append(&moves, Move{text = line, written = true})
					}
				}
			}
			// Pass 2: `[section]` members in requested order!
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
						sec_txt := spell_toml_member_line(cx, ins.key, ins.value, path_pref) or_return
						append(&moves, Move{text = sec_txt, written = true})
					}
				}
			}
			if _, aerr := append(&cx.splices, Splice{lo = span_lo, hi = span_hi, moves = moves[:], seq = len(cx.splices), base_node = base_c, full_rewalk = true}); aerr != nil {
				return aerr
			}
			return nil
		}
	}

	// Non-reorder deletions: remove all byte ranges of each deleted member.
	for m in members {
		if !m.deleted {
			continue
		}
		for r in m.ranges {
			if _, aerr := append(&cx.splices, Splice{lo = r.lo, hi = r.hi, seq = len(cx.splices), base_node = base_c, full_rewalk = true}); aerr != nil {
				return aerr
			}
		}
	}

	// Non-reorder insertions (honoring `ins.at` when specified!).
	ins_pos := toml_table_insert_pos(cx, path_pref)
	for ins in d.inserted_members {
		if node_kind(cx.ov, ins.value) == .Null {
			return refuse(.Unspellable_Value, "TOML has no null value", base_c)
		}
		txt := spell_toml_member_line(cx, ins.key, ins.value, path_pref) or_return
		is_obj_val := node_kind(cx.ov, ins.value) == .Object
		pos := u64(len(cx.src)) if is_obj_val else ins_pos
		if ins.at >= 0 && ins.at < len(members) && len(members[ins.at].ranges) > 0 {
			if is_obj_val == members[ins.at].is_section {
				pos = members[ins.at].ranges[0].lo
			}
		}
		if pos > 0 && pos <= u64(len(cx.src)) && cx.src[pos - 1] != '\n' {
			prefixed := make([dynamic]u8, 0, len(cx.eol) + len(txt), cx.allocator)
			append(&prefixed, cx.eol)
			append(&prefixed, ..txt)
			txt = prefixed[:]
		}
		append(&cx.splices, Splice{lo = pos, hi = pos, text = txt, seq = len(cx.splices), base_node = base_c, full_rewalk = true}) or_return
	}
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
spell_toml_member_line :: proc(cx: ^Section_Cx, key: string, val_h: Handle, path_pref: string) -> (out: []u8, err: Error) {
	b := make([dynamic]u8, 0, 64, cx.allocator)
	if node_kind(cx.ov, val_h) == .Object {
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
	cx.spec.spell_key(cx.spec.data, key, &b) or_return
	append(&b, " = ")
	st_o, tg_o := node_style_and_tag(cx.ov, val_h)
	cx.spec.spell_value(cx.spec.data, cx.ov, val_h, &b, st_o, tg_o) or_return
	append(&b, cx.eol)
	return b[:], nil
}

@(private = "file")
emit_toml_aot_delta :: proc(
	cx: ^Section_Cx,
	h: Handle,
	n: ^Edit_Node,
	path_pref: string,
	stack: ^[dynamic]Section_Frame,
	owned_paths: ^[dynamic]string,
) -> Error {
	d := n.delta
	if d == nil {
		return nil
	}
	// Collect each `[[path_pref]]` element's full byte range including any immediately following `[path_pref.sub]` / `[[path_pref.sub]]` subtables!
	Aot_Item :: struct {
		lo, hi:  u64,
		deleted: bool,
	}
	aot_items := make([dynamic]Aot_Item, 0, 4, cx.allocator)
	defer delete(aot_items)
	for sec, si in cx.sections {
		if sec.is_array && sec.path == path_pref {
			hi := sec.body_hi
			// Extend `hi` across any immediately following subtables of this AOT entry!
			for sj := si + 1; sj < len(cx.sections); sj += 1 {
				sub := cx.sections[sj]
				if sub.path == path_pref {
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
	for di in d.deleted_indices {
		if int(di) < len(aot_items) {
			aot_items[di].deleted = true
		}
	}

	// Push surviving edited child tables.
	push_section_children(cx, n.base, path_pref, stack, owned_paths) or_return

	// Spell inserted AOT elements.
	ins_texts := make([][]u8, len(d.inserted_elems), cx.allocator)
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
		deleted_flags := make([]bool, len(aot_items), cx.allocator)
		defer delete(deleted_flags, cx.allocator)
		for it, i in aot_items {
			deleted_flags[i] = it.deleted
		}
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
			if _, aerr := append(&cx.splices, Splice{lo = span_lo, hi = span_hi, moves = moves[:], seq = len(cx.splices), base_node = n.base, full_rewalk = true}); aerr != nil {
				return aerr
			}
			return nil
		}
	}

	// Non-reorder deletions.
	for it in aot_items {
		if it.deleted {
			if _, aerr := append(&cx.splices, Splice{lo = it.lo, hi = it.hi, seq = len(cx.splices), base_node = n.base, full_rewalk = true}); aerr != nil {
				return aerr
			}
		}
	}

	// Non-reorder insertions (honoring `ins.at`!).
	for ins, i in d.inserted_elems {
		pos := u64(len(cx.src))
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
		if _, aerr := append(&cx.splices, Splice{lo = pos, hi = pos, text = b[:], seq = len(cx.splices), base_node = n.base, full_rewalk = true}); aerr != nil {
			delete(b)
			return aerr
		}
	}
	return nil
}
