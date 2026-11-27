package html

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import ops_write "stury:lib/ops/write"

// HTML5 writer, the inverse of HTML5's markup document model.
// - Never allocates from `context.temp_allocator`.
// - Never recurses on the native stack during serialization OR read-back verification (`same_tree_iter`).
// - Handles void elements, rawtext (`script`, `style`, ...), `keeps_space` (`pre`, `listing`, `textarea`),
//   entity escaping (`&`, U+00A0 -> `&nbsp;`, `<`, `>`, attribute `"`), `opts.ascii` (`&#NNN;`), verbatim
//   DOCTYPE/comment/instruction/attribute spans on native HTML documents, trailing `</body></html>\n` gluing,
//   `foot_line` separation, and dropped-fact accounting.

Write_Options :: ops_write.Options
Write_Error :: ops_write.Error
Token_Kind :: ops_write.Token_Kind
Record_Framing :: ops_write.Record_Framing
Refused :: ops_write.Refused
Refusal :: ops_write.Refusal

write :: proc(doc: ^tape.Document, spec := Spec.Html, opts := Write_Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Write_Error) {
	return ops_write.to_buffer(doc, u8(spec), opts, allocator, write_out)
}

write_to :: proc(sink: io.Writer, doc: ^tape.Document, spec := Spec.Html, opts := Write_Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Write_Error) {
	return ops_write.to_sink(sink, doc, u8(spec), opts, allocator, write_out)
}

@(private)
HELD_HTML :: tape.COMMENTS + {.Doctype, .Attribute, .Instruction, .Instruction_Foot}

@(private)
Ending :: enum u8 {
	None,
	Chain,
	Text,
}

@(private)
Write_Frame :: struct {
	name:       tape.Node_Index,
	name_str:   string,
	name_owned: bool,
	level:      int,
	array:      bool,
	root:       bool,
	pretty:     bool,
	text:       bool,
	in_foreign: bool,
	keeps:      bool,
	void:       bool,
	raw:        bool,
	closing:    bool,
	ending:     Ending,
}

@(private)
Writing :: struct {
	out:       ^ops_write.Out,
	w:         ^ops_write.Tree,
	doc:       ^tape.Document,
	stack:     [dynamic]Write_Frame,
	attr_buf:  [dynamic]u8,
	width:     int,
	fill:      u64,
	html:      bool,
	wrote:     bool,
	pretty:    bool,
	ascii:     bool,
	line_end:  bool,
	glued:     bool,
	foot_line: bool,
	tail_elem: bool,
	allocator: runtime.Allocator,
}

@(private)
write_out :: proc(out: ^ops_write.Out, doc: ^tape.Document, spec: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, Write_Error) {
	if e := write_check(spec, opts); e != nil {
		return {}, e
	}
	if int(opts.node) >= len(doc.nodes) || doc.nodes[opts.node].role != .Value {
		return {}, tape.Bad_Option{"node"}
	}
	if doc.nodes[opts.node].kind != .Object {
		return {}, Refused{opts.node, .No_Spelling}
	}
	compact_opts := opts
	compact_opts.indent, compact_opts.tab = 0, false
	pretty := !ops_write.compact(opts)

	// Serialize compact first (directly into output buffer when compact & non-sink).
	if !pretty && out.sink.procedure == nil {
		dropped, err := serialize_into(out, doc, compact_opts, allocator)
		if err != nil {
			return {}, err
		}
		if rerr := read_back(out.buf[:out.cursor], doc, opts.node, compact_opts, allocator); rerr != nil {
			return {}, rerr
		}
		return dropped, nil
	}

	first_out: ops_write.Out
	if e := ops_write.out_start(&first_out, allocator, {}, len(doc.src) + ops_write.ROOM_MAX); e != nil {
		return {}, e
	}
	_, cerr := serialize_into(&first_out, doc, compact_opts, allocator)
	if cerr != nil {
		ops_write.out_drop(&first_out)
		return {}, cerr
	}
	first_bytes, ferr := ops_write.out_finish(&first_out)
	if ferr != nil {
		return {}, ferr
	}
	defer delete(first_bytes, allocator)

	if rerr := read_back(first_bytes, doc, opts.node, compact_opts, allocator); rerr != nil {
		return {}, rerr
	}
	return serialize_into(out, doc, opts, allocator)
}

@(private)
write_check :: proc "contextless" (spec: u8, opts: Write_Options) -> Write_Error {
	if spec > u8(max(Spec)) {
		return tape.Bad_Option{"spec"}
	}
	if opts.format != nil || opts.sort_keys || opts.framing != .None || opts.grow_header || len(opts.header) > 0 {
		opt := "format" if opts.format != nil else "header" if len(opts.header) > 0 || opts.grow_header else "options"
		return tape.Bad_Option{opt}
	}
	return nil
}

// Writes `doc` without running read-back (for nested fragment/edit spelling where the caller validates whole output).
@(private)
write_unverified :: proc(doc: ^tape.Document, opts: Write_Options, allocator: runtime.Allocator) -> (text: []u8, err: Write_Error) {
	out: ops_write.Out
	if e := ops_write.out_start(&out, allocator, {}, len(doc.src) + 256); e != nil {
		return nil, e
	}
	_, err = serialize_into(&out, doc, opts, allocator)
	if err != nil {
		ops_write.out_drop(&out)
		return nil, err
	}
	return ops_write.out_finish(&out)
}

@(private)
serialize_into :: proc(out: ^ops_write.Out, doc: ^tape.Document, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, Write_Error) {
	w: ops_write.Tree
	is_own := doc.format == &FORMATS[.Html] || doc.format == &FORMATS[.Fragment]
	holds := HELD_HTML if is_own else (tape.COMMENTS + {.Attribute})
	if e := ops_write.tree_start(&w, doc, opts, holds, allocator); e != nil {
		return {}, e
	}
	width, fill := int(opts.indent), u64(0x2020202020202020)
	if opts.tab {
		width, fill = 1, 0x0909090909090909
	}
	s := Writing {
		out       = out,
		w         = &w,
		doc       = doc,
		width     = width,
		fill      = fill,
		html      = is_own,
		pretty    = !ops_write.compact(opts),
		ascii     = opts.ascii,
		allocator = allocator,
	}
	s.stack.allocator = allocator
	s.attr_buf.allocator = allocator
	defer {
		for &fr in s.stack {
			if fr.name_owned {
				delete(fr.name_str, allocator)
			}
		}
		delete(s.stack)
		delete(s.attr_buf)
	}
	facts, tables := ops_write.tree_facts(&w), ops_write.tree_tables(&w)
	switch {
	case facts && tables: write_steps(&s, true, true)
	case facts:           write_steps(&s, true, false)
	case tables:          write_steps(&s, false, true)
	case:                 write_steps(&s, false, false)
	}
	dropped := ops_write.tree_end(&w)
	if w.err == nil {
		w.err = out.err
	}
	return dropped, w.err
}

@(private)
read_back :: proc(text: []u8, orig_doc: ^tape.Document, orig_root: tape.Node_Index, compact: Write_Options, allocator: runtime.Allocator) -> Write_Error {
	doc_shape := is_document_root(orig_doc, orig_root)
	spec := Spec.Html if doc_shape else Spec.Fragment
	depth_need := u32(min(u64(len(orig_doc.nodes)) + 16, u64(max(u32))))
	rb_build := Options{budget = {depth = max(u32(tape.DEFAULT_DEPTH), depth_need)}}
	rebuilt, err := build(text, spec, rb_build, allocator)
	if err != nil {
		if _, is_alloc := err.(runtime.Allocator_Error); is_alloc {
			return runtime.Allocator_Error.Out_Of_Memory
		}
		return Refused{orig_root, .No_Spelling}
	}
	defer tape.destroy(&rebuilt)

	if orig_doc.format == &FORMATS[.Html] || orig_doc.format == &FORMATS[.Fragment] {
		same, oom := same_tree_iter(orig_doc, orig_root, &rebuilt, tape.ROOT, allocator)
		if oom {
			return runtime.Allocator_Error.Out_Of_Memory
		}
		if same {
			return nil
		}
	}
	rb_opts := compact
	rb_opts.node = tape.ROOT
	again, aerr := write_unverified(&rebuilt, rb_opts, allocator)
	if aerr != nil {
		return aerr
	}
	defer delete(again, allocator)
	if string(again) != string(text) {
		return Refused{orig_root, .No_Spelling}
	}
	return nil
}

@(private)
is_document_root :: proc(doc: ^tape.Document, root: tape.Node_Index) -> bool {
	if doc.nodes[root].kind != .Object || tape.child_count(doc, root, doc.nodes[root]) != 1 {
		return false
	}
	k := root + 1
	val := tape.node_after(doc, k)
	if doc.nodes[val].kind == .Array {
		return false
	}
	buf: [16]u8 = ---
	s, ok := tape.node_text(doc, k, buf[:])
	return ok && s == "html"
}

@(private)
same_facts :: proc(a: ^tape.Document, fa: []tape.Fact, b: ^tape.Document, fb: []tape.Fact) -> bool {
	if len(fa) != len(fb) {
		return false
	}
	for f, i in fa {
		g := fb[i]
		if f.kind != g.kind || string(tape.span_bytes(a, f.lo, f.n)) != string(tape.span_bytes(b, g.lo, g.n)) {
			return false
		}
	}
	return true
}

// Iterative deep tree equality between `x` (rooted at `root_a`) and `y` (rooted at `root_b`).
@(private)
same_tree_iter :: proc(x: ^tape.Document, root_a: tape.Node_Index, y: ^tape.Document, root_b: tape.Node_Index, allocator: runtime.Allocator) -> (same, oom: bool) {
	Compare_Frame :: struct {
		cx, cy: tape.Children,
		ax, ay: tape.Node_Index,
		opened: bool,
	}
	rx, ry := tape.Reader{doc = x}, tape.Reader{doc = y}
	stack, serr := make([dynamic]Compare_Frame, 0, 16, allocator)
	buf_x, bx_err := make([dynamic]u8, 0, 256, allocator)
	buf_y, by_err := make([dynamic]u8, 0, 256, allocator)
	if serr != nil || bx_err != nil || by_err != nil {
		delete(stack)
		delete(buf_x)
		delete(buf_y)
		return false, true
	}
	defer {
		for &fr in stack {
			if fr.opened {
				tape.destroy_children(&fr.cx)
				tape.destroy_children(&fr.cy)
			}
		}
		delete(stack)
		delete(buf_x)
		delete(buf_y)
	}

	compare_scalars :: proc(x: ^tape.Document, ax: tape.Node_Index, y: ^tape.Document, ay: tape.Node_Index, buf_x, buf_y: ^[dynamic]u8) -> bool {
		nx, ny := x.nodes[ax], y.nodes[ay]
		if nx.kind == .Null || ny.kind == .Null {
			return nx.kind == ny.kind
		}
		sx := scalar_string(x, ax, buf_x)
		sy := scalar_string(y, ay, buf_y)
		return sx == sy
	}

	push_pair :: proc(x: ^tape.Document, ax: tape.Node_Index, y: ^tape.Document, ay: tape.Node_Index, rx, ry: tape.Reader, stack: ^[dynamic]Compare_Frame, buf_x, buf_y: ^[dynamic]u8, allocator: runtime.Allocator) -> (match, container, push_oom: bool) {
		kx, ky := x.nodes[ax].kind, y.nodes[ay].kind
		text_k := proc "contextless" (k: tape.Kind) -> tape.Kind {
			return .String if k <= .Plain && k != .Null else k
		}
		if text_k(kx) != text_k(ky) {
			return false, false, false
		}
		if !same_facts(x, tape.facts_of(x, ax), y, tape.facts_of(y, ay)) {
			return false, false, false
		}
		if kx != .Object {
			return compare_scalars(x, ax, y, ay, buf_x, buf_y), false, false
		}
		cx, px, ex := tape.children(rx, ax, allocator)
		cy, py, ey := tape.children(ry, ay, allocator)
		if ex != nil || ey != nil || px != py {
			tape.destroy_children(&cx)
			tape.destroy_children(&cy)
			is_oom := ex == runtime.Allocator_Error.Out_Of_Memory || ey == runtime.Allocator_Error.Out_Of_Memory
			return false, false, is_oom
		}
		if _, aerr := append(stack, Compare_Frame{cx = cx, cy = cy, ax = ax, ay = ay, opened = true}); aerr != nil {
			tape.destroy_children(&cx)
			tape.destroy_children(&cy)
			return false, false, true
		}
		return true, true, false
	}

	ok, cont, push_oom := push_pair(x, root_a, y, root_b, rx, ry, &stack, &buf_x, &buf_y, allocator)
	if push_oom {
		return false, true
	}
	if !ok {
		return false, false
	}
	if !cont {
		return true, false
	}

	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		kx_i, vx, px := tape.next_child(rx, &top.cx, .Group)
		ky_i, vy, py := tape.next_child(ry, &top.cy, .Group)
		if px != py {
			return false, false
		}
		if px != .Found {
			tape.destroy_children(&top.cx)
			tape.destroy_children(&top.cy)
			top.opened = false
			pop(&stack)
			continue
		}
		skx := scalar_string(x, kx_i, &buf_x)
		sky := scalar_string(y, ky_i, &buf_y)
		if skx != sky {
			return false, false
		}
		cok, _, c_oom := push_pair(x, vx, y, vy, rx, ry, &stack, &buf_x, &buf_y, allocator)
		if c_oom {
			return false, true
		}
		if !cok {
			return false, false
		}
	}
	return true, false
}

@(private)
scalar_string :: proc(doc: ^tape.Document, at: tape.Node_Index, scratch: ^[dynamic]u8) -> string {
	n := doc.nodes[at]
	if n.kind == .True {
		return "true"
	}
	if n.kind == .False {
		return "false"
	}
	if n.kind == .Number && .Binary not_in doc.format.caps {
		return string(tape.span_bytes(doc, n.lo, n.n))
	}
	if (n.kind == .String || n.kind == .Plain) && !tape.text_decodes(n) && .Held not_in doc.flags {
		if n.role == .Key {
			if fx := table_key_text(doc.src, n); len(fx) > 0 {
				return fx
			}
		}
		return string(doc.src[n.lo:][:n.n])
	}
	room := max(tape.text_room(doc, at), int(n.n), 64)
	if len(scratch^) < room {
		if resize(scratch, room) != nil {
			return ""
		}
	}
	s, ok := tape.node_text(doc, at, scratch[:])
	return s if ok else ""
}

@(private)
fail_node :: #force_inline proc(w: ^ops_write.Tree, at: tape.Node_Index) {
	if w.err == nil {
		w.err = Refused{at, .No_Spelling}
	}
}

@(private)
begin_line :: #force_inline proc(s: ^Writing, level: int, pretty: bool) {
	if pretty && s.wrote {
		line_indent(s.out, s, level)
	}
	s.wrote = true
}

@(private)
line_indent :: #force_inline proc(out: ^ops_write.Out, s: ^Writing, level: int) #no_bounds_check {
	ops_write.line_indent(out, s.width, s.fill, level)
}

// Writes misc facts of `kinds` and reports whether any non-DOCTYPE comment/instruction was written.
@(private)
write_misc :: proc(s: ^Writing, facts: []tape.Fact, kinds: tape.Facts, level: int, pretty, lead: bool) -> (wrote_non_doctype: bool) {
	first_lead := lead
	for f in facts {
		if f.kind not_in kinds {
			continue
		}
		if f.kind == .Doctype || f.kind == .Instruction || f.kind == .Instruction_Foot {
			if !s.html {
				s.w.dropped += {f.kind}
				continue
			}
			begin_line(s, level, pretty)
			if first_lead && !pretty {
				ops_write.put_byte(s.out, '\n')
				first_lead = false
			}
			ops_write.put(s.out, tape.span_bytes(s.doc, f.lo, f.n))
			s.tail_elem = false
			if f.kind != .Doctype {
				wrote_non_doctype = true
			}
			continue
		}
		if s.html && f.n > 0 {
			begin_line(s, level, pretty)
			if first_lead && !pretty {
				ops_write.put_byte(s.out, '\n')
				first_lead = false
			}
			ops_write.put(s.out, tape.span_bytes(s.doc, f.lo, f.n))
			s.tail_elem = false
			wrote_non_doctype = true
			continue
		}
		body, is_line := ops_write.comment_body(s.doc, f)
		if !holds_comment(string(body)) {
			s.w.dropped += {f.kind}
			continue
		}
		begin_line(s, level, pretty)
		if first_lead && !pretty {
			ops_write.put_byte(s.out, '\n')
			first_lead = false
		}
		ops_write.put(s.out, transmute([]u8)string("<!--"))
		ops_write.put(s.out, body)
		if is_line && len(body) > 0 && body[0] == ' ' && body[len(body) - 1] != ' ' && body[len(body) - 1] != '\t' {
			ops_write.put_byte(s.out, ' ')
		}
		ops_write.put(s.out, transmute([]u8)string("-->"))
		s.tail_elem = false
		wrote_non_doctype = true
	}
	return
}

@(private)
holds_comment :: proc "contextless" (body: string) -> bool {
	has_sub :: proc "contextless" (b, sub: []u8) -> bool {
		if len(sub) > len(b) {
			return false
		}
		for i := 0; i <= len(b) - len(sub); i += 1 {
			if b[i] == sub[0] && string(b[i:i + len(sub)]) == string(sub) {
				return true
			}
		}
		return false
	}
	b := transmute([]u8)body
	if len(b) >= 1 && b[0] == '>' {
		return false
	}
	if len(b) >= 2 && b[0] == '-' && b[1] == '>' {
		return false
	}
	if len(b) >= 3 && string(b[len(b) - 3:]) == "<!-" {
		return false
	}
	if has_sub(b, {'<', '!', '-', '-'}) || has_sub(b, {'-', '-', '>'}) || has_sub(b, {'-', '-', '!', '>'}) {
		return false
	}
	p := raw_data(b)
	end := intrinsics.ptr_offset(p, len(b))
	for i := 0; i < len(b); {
		if b[i] < 0x80 {
			i += 1
			continue
		}
		q, kind := spell.utf8_char(p[i:], end)
		if kind != .None {
			return false
		}
		i = intrinsics.ptr_sub(q, p)
	}
	return true
}

@(private)
holds_text :: proc(w: ^ops_write.Tree, at: tape.Node_Index, html: bool) -> bool {
	return ops_write.holds_text(w, at, html, TEXT_KEY)
}

@(private)
apply_end_text :: proc "contextless" (s: ^Writing, text: string) -> string {
	s.glued = true
	if len(text) > 0 && text[len(text) - 1] == '\n' {
		s.line_end = true
		return text[:len(text) - 1]
	}
	return text
}

@(private)
write_steps :: proc(s: ^Writing, $FACTS, $TABLES: bool) {
	w, out, doc := s.w, s.out, s.doc
	buf: [ops_write.NUMBER_ROOM]u8 = ---
	name_scratch: [64]u8 = ---
	for w.err == nil {
		step := ops_write.tree_next(w, FACTS, TABLES)
		if step.kind == .Done {
			if s.line_end {
				ops_write.put_byte(out, '\n')
				s.line_end = false
			}
			return
		}
		if step.kind == .Close {
			top := pop(&s.stack)
			defer if top.name_owned {
				delete(top.name_str, s.allocator)
			}
			if top.root {
				if s.line_end {
					ops_write.put_byte(out, '\n')
					s.line_end = false
				}
				s.glued = false
				when FACTS {
					if len(step.facts) != 0 {
						_ = write_misc(s, step.facts, {.Comment_Inline, .Comment_Foot, .Instruction_Foot}, 0, false, false)
					}
				}
				continue
			}
			if top.array {
				when FACTS {
					if len(step.facts) != 0 {
						p_frame := s.stack[len(s.stack) - 1]
						s.foot_line = !p_frame.pretty && !p_frame.keeps && !step.first && s.tail_elem
						_ = write_misc(s, step.facts, {.Comment_Foot, .Instruction_Foot}, top.level + 1 if p_frame.closing else 0, p_frame.closing, s.foot_line)
						s.foot_line = false
						_ = write_misc(s, step.facts, {.Comment_Inline}, 0, false, false)
					}
				}
				s.tail_elem = true
				continue
			}
			if !top.void {
				glued := s.glued
				s.foot_line = !top.pretty && !top.keeps && !step.first && s.tail_elem
				when FACTS {
					if len(step.facts) != 0 {
						_ = write_misc(s, step.facts, {.Comment_Foot, .Instruction_Foot}, top.level + 1 if top.closing else 0, top.closing, s.foot_line)
						s.foot_line = false
					}
				}
				if top.closing && !glued {
					begin_line(s, top.level, top.pretty)
				}
				ops_write.put(out, transmute([]u8)string("</"))
				ops_write.put(out, transmute([]u8)top.name_str)
				ops_write.put_byte(out, '>')
			}
			when FACTS {
				if len(step.facts) != 0 {
					_ = write_misc(s, step.facts, {.Comment_Inline}, 0, false, false)
				}
			}
			s.foot_line = false
			s.tail_elem = true
			continue
		}

		parent: Write_Frame
		if len(s.stack) > 0 {
			parent = s.stack[len(s.stack) - 1]
		}
		if len(s.stack) == 0 {
			when FACTS {
				if len(step.facts) != 0 {
					for f in step.facts {
						if f.kind == .Attribute {
							w.dropped += {.Attribute}
						}
					}
					if write_misc(s, step.facts, {.Doctype, .Comment, .Instruction}, 0, s.pretty, false) {
						ops_write.put(out, transmute([]u8)string("\n\n"))
						s.wrote = false
					}
				}
			}
			root_ending := Ending.Chain if (s.pretty && is_document_root(doc, step.node)) else .None
			if _, err := append(&s.stack, Write_Frame{root = true, pretty = s.pretty, level = -1, ending = root_ending}); err != nil {
				w.err = err
			}
			continue
		}
		is_cell := false
		when TABLES {
			is_cell = step.cell
		}
		name_node := step.key
		if name_node == tape.NO_NODE && !is_cell {
			name_node = parent.name
		}
		is_array := step.kind == .Open && w.nodes[step.node].kind == .Array
		if is_array {
			if parent.array || tape.child_count(doc, step.node, w.nodes[step.node]) <= 0 {
				fail_node(w, step.node)
				return
			}
			arr_name_raw: string
			arr_ok: bool
			if is_cell {
				arr_name_raw, arr_ok = ops_write.text_of_token(w, w.cell)
			} else {
				arr_name_raw, arr_ok = ops_write.text_of(w, name_node)
			}
			if !arr_ok {
				return
			}
			arr_name := strings.clone(arr_name_raw, s.allocator)
			if !s.html && !is_html_name(arr_name) {
				delete(arr_name, s.allocator)
				fail_node(w, name_node if name_node != tape.NO_NODE else step.node)
				return
			}
			when FACTS {
				if len(step.facts) != 0 {
					for f in step.facts {
						if f.kind == .Attribute || f.kind == .Doctype {
							w.dropped += {f.kind}
						}
					}
					_ = write_misc(s, step.facts, {.Comment, .Instruction}, parent.level + 1, parent.pretty && !parent.keeps, !step.first && !parent.text && !parent.keeps)
				}
			}
			if _, err := append(&s.stack, Write_Frame{name = name_node, name_str = arr_name, name_owned = true, array = true, pretty = parent.pretty, level = parent.level, in_foreign = parent.in_foreign}); err != nil {
				delete(arr_name, s.allocator)
				w.err = err
			}
			continue
		}

		is_last_in_parent := false
		if !w.in_row && !parent.array {
			if step.kind == .Scalar && w.depth > 0 {
				is_last_in_parent = w.i == w.frames[w.depth - 1].end
			} else if step.kind == .Open && w.depth >= 2 {
				is_last_in_parent = w.frames[w.depth - 1].end == w.frames[w.depth - 2].end
			}
		}

		name_raw: string
		ok: bool
		if is_cell {
			name_raw, ok = ops_write.text_of_token(w, w.cell)
		} else if step.key == tape.NO_NODE && parent.name_str != "" {
			name_raw, ok = parent.name_str, true
		} else {
			name_raw, ok = ops_write.text_of(w, name_node)
		}
		if !ok {
			return
		}
		level := parent.level + 1
		if name_raw == TEXT_KEY {
			if step.kind == .Open {
				fail_node(w, step.node)
				return
			}
			text, tok := scalar_text(w, step.node, &buf)
			if !tok {
				fail_node(w, step.node)
				return
			}
			when FACTS {
				for f in step.facts {
					w.dropped += {f.kind}
				}
			}
			if parent.ending == .Text && is_last_in_parent {
				text = apply_end_text(s, text)
			}
			if !parent.in_foreign && parent.raw {
				ops_write.put(out, transmute([]u8)text)
			} else if !put_escaped(out, text, false, s.ascii) {
				fail_node(w, step.node)
				return
			}
			s.wrote = true
			s.tail_elem = false
			continue
		}

		name: string
		name_owned := false
		if step.kind == .Open {
			name = strings.clone(name_raw, s.allocator)
			name_owned = true
		} else if len(name_raw) <= len(name_scratch) {
			copy(name_scratch[:len(name_raw)], name_raw)
			name = string(name_scratch[:len(name_raw)])
		} else {
			name = strings.clone(name_raw, s.allocator)
			name_owned = true
		}
		defer if name_owned {
			delete(name, s.allocator)
		}

		if !s.html && !is_html_name(name) {
			fail_node(w, name_node if name_node != tape.NO_NODE else step.node)
			return
		}

		when FACTS {
			if len(step.facts) != 0 {
				for f in step.facts {
					if f.kind == .Doctype {
						w.dropped += {.Doctype}
					}
				}
				_ = write_misc(s, step.facts, {.Comment, .Instruction}, level, parent.pretty && !parent.keeps, !step.first && !parent.text && !parent.keeps)
			}
		}

		begin_line(s, level, parent.pretty && !parent.keeps)
		ops_write.put_byte(out, '<')
		ops_write.put(out, transmute([]u8)name)
		when FACTS {
			if len(step.facts) != 0 {
				if !put_attributes(s, step.facts, step.node) {
					fail_node(w, step.node)
					return
				}
			}
		}
		ops_write.put_byte(out, '>')
		s.wrote = true
		s.tail_elem = false

		void := !parent.in_foreign && is_void_name(name)
		if step.kind == .Open {
			if void {
				fail_node(w, step.node)
				return
			}
			has_txt := holds_text(w, step.node, s.html)
			keeps := parent.keeps || keeps_space_name(name)
			child_ending := Ending.None
			if parent.ending == .Chain && is_last_in_parent {
				if name == "html" {
					child_ending = .Chain
				} else if name == "body" {
					child_ending = .Text
				}
			}
			open_name := strings.clone(name_raw, s.allocator)
			frame := Write_Frame {
				name       = name_node,
				name_str   = open_name,
				name_owned = true,
				level      = level,
				pretty     = parent.pretty && !has_txt && !keeps,
				text       = has_txt,
				in_foreign = parent.in_foreign || is_foreign_root(name),
				keeps      = keeps,
				raw        = !parent.in_foreign && is_raw_name(name),
				closing    = parent.pretty && !has_txt && !keeps,
				ending     = child_ending,
			}
			if _, err := append(&s.stack, frame); err != nil {
				delete(open_name, s.allocator)
				w.err = err
				return
			}
			continue
		}

		null := w.nodes[step.node].kind == .Null
		if !null {
			if void {
				fail_node(w, step.node)
				return
			}
			text, tok := scalar_text(w, step.node, &buf)
			if !tok {
				fail_node(w, step.node)
				return
			}
			if parent.ending == .Chain && is_last_in_parent && name == "body" {
				text = apply_end_text(s, text)
			}
			if keeps_space_name(name) && strings.has_prefix(text, "\n") {
				ops_write.put_byte(out, '\n')
			}
			if !parent.in_foreign && is_raw_name(name) {
				ops_write.put(out, transmute([]u8)text)
			} else if !put_escaped(out, text, false, s.ascii) {
				fail_node(w, step.node)
				return
			}
		}
		if !void {
			when FACTS {
				if len(step.facts) != 0 {
					_ = write_misc(s, step.facts, {.Comment_Foot, .Instruction_Foot}, 0, false, false)
				}
			}
			ops_write.put(out, transmute([]u8)string("</"))
			ops_write.put(out, transmute([]u8)name)
			ops_write.put_byte(out, '>')
		} else {
			when FACTS {
				for f in step.facts {
					if f.kind == .Comment_Foot || f.kind == .Instruction_Foot {
						w.dropped += {f.kind}
					}
				}
			}
		}
		when FACTS {
			if len(step.facts) != 0 {
				_ = write_misc(s, step.facts, {.Comment_Inline}, 0, false, false)
			}
		}
		s.tail_elem = true
	}
}

@(private)
put_attributes :: proc(s: ^Writing, facts: []tape.Fact, node: tape.Node_Index) -> bool {
	out, doc := s.out, s.doc
	for f in facts {
		if f.kind != .Attribute {
			continue
		}
		if s.html {
			ops_write.put_byte(out, ' ')
			ops_write.put(out, tape.span_bytes(doc, f.lo, f.n))
			continue
		}
		kt, vt := doc.format.attribute(doc, f)
		nroom := max(tape.text_room(doc, kt), int(kt.n))
		vroom := max(tape.text_room(doc, vt), int(vt.n))
		need := nroom + vroom
		if len(s.attr_buf) < need {
			if aerr := resize(&s.attr_buf, max(need, 256)); aerr != nil {
				s.w.err = aerr
				return false
			}
		}
		aname := decode_token_into(doc, kt, s.attr_buf[:nroom])
		aval := decode_token_into(doc, vt, s.attr_buf[nroom:])
		if !is_attr_name_lower(aname) {
			return false
		}
		ops_write.put_byte(out, ' ')
		ops_write.put(out, transmute([]u8)aname)
		ops_write.put(out, transmute([]u8)string(`="`))
		if !put_escaped(out, aval, true, s.ascii) {
			return false
		}
		ops_write.put_byte(out, '"')
	}
	_ = node
	return true
}

@(private)
decode_token_into :: proc(doc: ^tape.Document, tok: tape.Token, dst: []u8) -> string {
	if !tape.text_decodes(tok) && .Held not_in doc.flags {
		return string(doc.src[tok.lo:][:tok.n])
	}
	s, ok := tape.node_text(doc, tok, dst)
	return s if ok else ""
}

@(private)
scalar_text :: #force_inline proc(w: ^ops_write.Tree, at: tape.Node_Index, buf: ^[ops_write.NUMBER_ROOM]u8) -> (string, bool) {
	#partial switch w.nodes[at].kind {
	case .True:
		return "true", true
	case .False:
		return "false", true
	case .Number:
		return ops_write.number_text(w, at, buf)
	case .String, .Plain:
		return ops_write.text_of(w, at)
	}
	return "", false
}

@(private)
put_escaped :: proc(out: ^ops_write.Out, s: string, attr, ascii: bool) -> bool {
	b := transmute([]u8)s
	run := 0
	for i := 0; i < len(b); {
		for i + 8 <= len(b) && !has_html_special(intrinsics.unaligned_load((^u64)(&b[i]))) {
			i += 8
		}
		if i == len(b) {
			break
		}
		c := b[i]
		if c < 0x80 && c != '&' && c != '<' && c != '>' && c != '"' {
			i += 1
			continue
		}
		if i > run {
			ops_write.put(out, b[run:i])
		}
		r, size := rune(c), 1
		if c >= 0x80 {
			r, size = utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && size <= 1 {
				return false
			}
		}
		switch {
		case c == '&':
			ops_write.put(out, transmute([]u8)string("&amp;"))
		case r == 0xA0:
			ops_write.put(out, transmute([]u8)string("&nbsp;"))
		case c == '"' && attribute_quote(attr):
			ops_write.put(out, transmute([]u8)string("&quot;"))
		case c == '<' && !attr:
			ops_write.put(out, transmute([]u8)string("&lt;"))
		case c == '>' && !attr:
			ops_write.put(out, transmute([]u8)string("&gt;"))
		case c >= 0x80 && ascii:
			digits: [24]u8 = ---
			n := write_u64_dec(digits[:], u64(r))
			ops_write.put(out, transmute([]u8)string("&#"))
			ops_write.put(out, digits[:n])
			ops_write.put_byte(out, ';')
		case:
			ops_write.put(out, b[i : i + size])
		}
		i += size
		run = i
	}
	if run < len(b) {
		ops_write.put(out, b[run:])
	}
	return true
}

@(private = "file")
attribute_quote :: #force_inline proc "contextless" (attr: bool) -> bool {
	return attr
}

@(private)
has_html_special :: #force_inline proc "contextless" (x: u64) -> bool {
	ONES :: u64(0x0101010101010101)
	HIGH :: u64(0x8080808080808080)
	zero :: #force_inline proc "contextless" (v: u64) -> u64 { return (v - ONES) & ~v & HIGH }
	found := zero(x ~ (ONES * '&')) | zero(x ~ (ONES * '<')) | zero(x ~ (ONES * '>')) | zero(x ~ (ONES * '"')) | (x & HIGH)
	return found != 0
}

@(private)
is_html_name :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || s[0] - 'a' >= 26 {
		return false
	}
	for c in transmute([]u8)s {
		if c - 'A' < 26 || is_space(c) || c == '/' || c == '>' || c == 0 || c < 0x20 {
			return false
		}
	}
	return true
}

@(private)
is_attr_name_lower :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in transmute([]u8)s {
		if c - 'A' < 26 || is_space(c) || c == 0 || c == '"' || c == '\'' || c == '>' || c == '/' || c == '=' || c == '<' || c < 0x20 {
			return false
		}
	}
	return true
}

@(private)
is_void_name :: proc "contextless" (name: string) -> bool {
	if len(name) < 2 || len(name) > 8 {
		return false
	}
	switch name[0] {
	case 'a': return name == "area"
	case 'b': return name == "base" || name == "basefont" || name == "bgsound" || name == "br"
	case 'c': return name == "col"
	case 'e': return name == "embed"
	case 'f': return name == "frame"
	case 'h': return name == "hr"
	case 'i': return name == "img" || name == "input"
	case 'k': return name == "keygen"
	case 'l': return name == "link"
	case 'm': return name == "meta"
	case 'p': return name == "param"
	case 's': return name == "source"
	case 't': return name == "track"
	case 'w': return name == "wbr"
	}
	return false
}

@(private)
is_foreign_root :: #force_inline proc "contextless" (name: string) -> bool {
	return (len(name) == 3 && name == "svg") || (len(name) == 4 && name == "math")
}

@(private)
is_raw_name :: proc "contextless" (name: string) -> bool {
	switch name {
	case "style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext":
		return true
	}
	return false
}

@(private = "file")
write_u64_dec :: proc "contextless" (dst: []u8, v: u64) -> int #no_bounds_check {
	if v == 0 {
		dst[0] = '0'
		return 1
	}
	tmp: [24]u8 = ---
	n := 0
	x := v
	for x > 0 {
		tmp[n] = u8('0' + x % 10)
		x /= 10
		n += 1
	}
	for i in 0 ..< n {
		dst[i] = tmp[n - 1 - i]
	}
	return n
}

@(private)
keeps_space_name :: #force_inline proc "contextless" (name: string) -> bool {
	return len(name) >= 3 && (name[0] == 'p' && name == "pre" || name[0] == 'l' && name == "listing" || name[0] == 't' && name == "textarea")
}
