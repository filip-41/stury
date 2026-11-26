package yaml

import "base:runtime"
import "core:io"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// YAML 1.2 writer: writes any `tape.Document` (native YAML or foreign JSON/TOML/CBOR/DSV/XML) as block YAML when
// indented (`opts.indent > 0 || opts.tab`, always using space indentation since YAML forbids tab indentation) or
// compact flow YAML when `opts.indent == 0 && !opts.tab`. Preserves comments, tags, anchors, aliases, directives,
// explicit markers, scalar/collection styles, folded/literal blocks, hex/octal integers, `.inf`/`.nan`, and `!!binary`.

Write_Options :: write.Options
Write_Error :: write.Error
Token_Kind :: write.Token_Kind
Record_Framing :: write.Record_Framing
Refused :: write.Refused
Refusal :: write.Refusal

@(private)
HELD :: FACTS

// Writes value `opts.node` of `doc` as YAML of `spec` into a caller-owned buffer from `allocator`.
write :: proc(doc: ^tape.Document, spec := Spec.Yaml_1_2, opts := Write_Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Write_Error) {
	return write.to_buffer(doc, u8(spec), opts, allocator, write_out)
}

// `write` into `sink` through a `write.SINK_BYTES` buffer from `allocator`.
write_to :: proc(sink: io.Writer, doc: ^tape.Document, spec := Spec.Yaml_1_2, opts := Write_Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Write_Error) {
	return write.to_sink(sink, doc, u8(spec), opts, allocator, write_out)
}

@(private)
write_dialect :: #force_inline proc "contextless" (opts: Write_Options) -> tape.Yaml_Dialect {
	y, _ := opts.format.(tape.Yaml_Options)
	return y.dialect
}

@(private)
write_check :: proc "contextless" (spec: u8, opts: Write_Options) -> Write_Error {
	if spec > u8(max(Spec)) {
		return tape.Bad_Option{"spec"}
	}
	if opts.format != nil {
		if y, ok := opts.format.(tape.Yaml_Options); !ok || y.dialect > max(tape.Yaml_Dialect) {
			return tape.Bad_Option{"format"}
		}
	}
	if opts.grow_header || len(opts.header) > 0 {
		return tape.Bad_Option{"header" if len(opts.header) > 0 else "options"}
	}
	if opts.framing != .None {
		return tape.Bad_Option{"framing"}
	}
	return nil
}

@(private)
Member :: struct {
	key, value: tape.Node_Index,
	name:       string,
}

@(private)
Properties :: struct {
	tag, anchor, alias: string,
	spelled:            bool,
}

@(private)
Context :: enum u8 {
	Root,
	Key,
	Dash,
}

@(private)
Members :: struct {
	Direct: struct {
		c:      tape.Children,
		scalar: bool,
	},
	Sorted: struct {
		lo, hi, at: int,
	},
	direct: bool,
}

@(private)
Put_Open :: struct {
	members:     Members,
	elements:    tape.Children,
	node:        tape.Node_Index,
	ind:         int,
	object:      bool,
	flow:        bool,
	first:       bool,
	compact:     bool,
	tail:        bool,
	elem_scalar: bool,
}

@(private)
Layout :: struct {
	w:         write.Tree,
	out:       ^write.Out,
	opts:      Write_Options,
	dialect:   tape.Yaml_Dialect,
	pretty:    bool,
	step:      int,
	own:       bool,
	whole:     bool,
	commented: bool,
	styled:    bool,
	tagged:    bool,
	sort:      bool,
	skipped:      tape.Facts,
	members:      [dynamic]Member,
	defined:      map[string]struct{},
	inline_opens: [64]Put_Open,
	open_n:       int,
	extra_opens:  [dynamic]Put_Open,
}

@(private)
write_out :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	if e := write_check(spec, opts); e != nil {
		return {}, e
	}
	l := Layout {
		out     = out,
		opts    = opts,
		dialect = write_dialect(opts),
		pretty  = !write.compact(opts),
		step    = int(opts.indent) if opts.indent > 0 else 2,
		sort    = opts.sort_keys,
	}
	l.whole = .Held not_in doc.flags
	l.own = doc.format == &FORMATS[.Yaml_1_2] || doc.format == &FORMATS[.Yaml_Merge]
	if e := write.tree_start(&l.w, doc, opts, HELD, allocator); e != nil {
		return {}, e
	}
	l.members.allocator = allocator
	l.defined.allocator = allocator
	l.extra_opens.allocator = allocator
	defer {
		release_members(&l, 0)
		delete(l.members)
		delete(l.defined)
		for l.open_n > 0 {
			o := pop_open(&l)
			close_open(&o)
		}
		delete(l.extra_opens)
	}
	l.commented = doc.present != {}
	l.styled = .Style in doc.present
	l.tagged = !l.own && .Tag in doc.present

	put_root(&l, opts.node)
	l.w.fact = len(l.w.facts)
	dropped := write.tree_end(&l.w) + l.skipped
	if l.w.err == nil {
		l.w.err = out.err
	}
	if l.w.err != nil {
		return {}, l.w.err
	}
	return dropped, nil
}

@(private)
release_members :: proc(l: ^Layout, lo: int) {
	for m in l.members[lo:] {
		if len(m.name) > 0 {
			delete(m.name, l.members.allocator)
		}
	}
	resize(&l.members, lo)
}

@(private)
close_open :: #force_inline proc(o: ^Put_Open) {
	if o.object && o.members.direct && !o.members.Direct.scalar {
		tape.destroy_children(&o.members.Direct.c)
	} else if !o.object && !o.elem_scalar {
		tape.destroy_children(&o.elements)
	}
}

@(private)
refuse :: proc(l: ^Layout, at: tape.Node_Index, why := write.Refusal.No_Spelling) -> bool {
	if l.w.err == nil {
		l.w.err = write.Refused{at, why}
	}
	return false
}

@(private)
put_root :: proc(l: ^Layout, node: tape.Node_Index) -> bool {
	if len(l.w.doc.nodes) == 0 {
		return true
	}
	pr := props_of(l, node) or_return
	before := l.out.cursor
	put_comments(l, node, .Comment, 0)
	wrote_comment := l.out.cursor != before
	directives := l.own && node == tape.ROOT && put_directives(l)
	if !l.own && .Directive in l.w.doc.present && node == tape.ROOT {
		l.skipped += {.Directive}
	}
	n := l.w.nodes[node]
	k := n.kind
	if k >= .Array && n.spelling & tape.CONTAINER_PARTIAL != 0 {
		return refuse(l, node, .Partial)
	}
	non_empty := (k == .Object || k == .Array) && container_non_empty(l, node, n)
	block := non_empty && l.pretty && !kept_flow(l, node)
	if block && wrote_comment && !directives {
		write.put_byte(l.out, '\n')
	}
	if directives || (block && (pr.tag != "" || pr.anchor != "")) {
		if !directives {
			put_str(l.out, "---")
		}
		put_node(l, node, .Key, 0) or_return
	} else {
		put_node(l, node, .Root, 0) or_return
	}
	if l.own && node == tape.ROOT && ends_explicitly(l) {
		put_str(l.out, "...\n" if l.pretty else "\n...")
	}
	return true
}

@(private)
container_non_empty :: #force_inline proc(l: ^Layout, node: tape.Node_Index, n: tape.Node) -> bool {
	if l.whole {
		return n.n > 1
	}
	return tape.child_count(l.w.doc, node, n) > 0
}

@(private)
put_directives :: proc(l: ^Layout) -> bool {
	start := false
	for f in tape.facts_of(l.w.doc, tape.ROOT) {
		if f.kind != .Directive {
			continue
		}
		body := string(tape.span_bytes(l.w.doc, f.lo, f.n))
		if len(body) > 0 && body[0] == '%' {
			put_str(l.out, body)
			write.put_byte(l.out, '\n')
		}
		start ||= len(body) > 0 && body[0] != '.'
	}
	if start {
		put_str(l.out, "---")
	}
	return start
}

@(private)
ends_explicitly :: proc(l: ^Layout) -> bool {
	for f in tape.facts_of(l.w.doc, tape.ROOT) {
		if f.kind == .Directive {
			body := tape.span_bytes(l.w.doc, f.lo, f.n)
			if len(body) > 0 && body[0] == '.' {
				return true
			}
		}
	}
	return false
}

@(private)
props_of :: #force_inline proc(l: ^Layout, node: tape.Node_Index) -> (pr: Properties, ok: bool) {
	if !l.tagged && !(l.own && l.commented) && !(!l.own && .Tag in l.w.doc.present) {
		return {}, true
	}
	return props_read(l, node)
}

@(private)
props_read :: proc(l: ^Layout, node: tape.Node_Index) -> (pr: Properties, ok: bool) {
	doc := l.w.doc
	if !l.own && (.Tag in doc.present) {
		if doc.format.fact_name != nil {
			if name, has := doc.format.fact_name(doc, node, .Tag); has {
				if l.w.nodes[node].kind == .String || l.w.nodes[node].kind == .Plain {
					s, tok := write.text_of(&l.w, node)
					if !tok {
						return {}, false
					}
					if dt := timestamp_tag(s, name); dt != "" {
						pr.tag = dt
						pr.spelled = true
						return pr, true
					}
				}
				if len(name) > 0 && name[0] == '!' {
					pr.tag = name
					return pr, true
				}
				l.skipped += {.Tag}
				return pr, true
			}
		}
		for f in tape.facts_of(doc, node) {
			if f.kind != .Tag {
				continue
			}
			span := tape.span_bytes(doc, f.lo, f.n)
			if len(span) > 0 && span[0] == '!' && .Binary not_in doc.format.caps {
				pr.tag = string(span)
			} else {
				l.skipped += {.Tag}
			}
			break
		}
		return pr, true
	}
	if !l.own {
		return pr, true
	}
	for f in tape.facts_of(doc, node) {
		#partial switch f.kind {
		case .Tag:
			if pr.tag == "" {
				pr.tag = string(tape.span_bytes(doc, f.lo, f.n))
			}
		case .Anchor:
			if pr.anchor == "" {
				body := tape.span_bytes(doc, f.lo, f.n)
				pr.anchor = string(body[1:]) if len(body) > 0 && body[0] == '&' else string(body)
			}
		case .Alias:
			if pr.alias == "" {
				body := tape.span_bytes(doc, f.lo, f.n)
				pr.alias = string(body[1:]) if len(body) > 0 && body[0] == '*' else string(body)
			}
		}
	}
	return pr, true
}

@(private)
timestamp_tag :: proc(text, name: string) -> string {
	switch name {
	case "datetime", "date-time", "offset-date-time":
		return "!!timestamp" if timestamp_kind(text) == .Datetime else ""
	case "date-local", "local-date", "date":
		return "!!timestamp" if timestamp_kind(text) == .Local_Date else ""
	case "datetime-local", "local-date-time", "local-datetime":
		return "!!timestamp" if timestamp_kind(text) == .Local_Datetime else ""
	}
	return ""
}

@(private)
node_kind :: #force_inline proc(l: ^Layout, node: tape.Node_Index) -> tape.Kind {
	return l.w.nodes[node].kind
}

@(private)
put_token :: proc(l: ^Layout, space: ^bool, text: string) {
	if space^ {
		write.put_byte(l.out, ' ')
	}
	put_str(l.out, text)
	space^ = true
}

@(private)
put_props :: proc(l: ^Layout, space: ^bool, pr: Properties) -> bool {
	if pr.tag != "" {
		put_token(l, space, pr.tag)
	}
	if pr.anchor != "" {
		put_token(l, space, "&")
		put_str(l.out, pr.anchor)
		if _, err := map_insert(&l.defined, pr.anchor, struct{}{}); err != nil {
			l.w.err = err
			return false
		}
	}
	return true
}

@(private)
open_top :: #force_inline proc "contextless" (l: ^Layout) -> ^Put_Open #no_bounds_check {
	if l.open_n <= len(l.inline_opens) {
		return &l.inline_opens[l.open_n - 1]
	}
	return &l.extra_opens[l.open_n - len(l.inline_opens) - 1]
}

@(private)
pop_open :: #force_inline proc(l: ^Layout) -> Put_Open #no_bounds_check {
	l.open_n -= 1
	if l.open_n < len(l.inline_opens) {
		return l.inline_opens[l.open_n]
	}
	return pop(&l.extra_opens)
}

@(private)
push_open_ptr :: #force_inline proc(l: ^Layout) -> (o: ^Put_Open, ok: bool) #no_bounds_check {
	if l.open_n < len(l.inline_opens) {
		o = &l.inline_opens[l.open_n]
		l.open_n += 1
		return o, true
	}
	if _, err := append(&l.extra_opens, Put_Open{}); err != nil {
		l.w.err = err
		return nil, false
	}
	l.open_n += 1
	return &l.extra_opens[l.open_n - len(l.inline_opens) - 1], true
}

@(private)
put_node :: proc(l: ^Layout, node: tape.Node_Index, ctx: Context, ind: int) -> bool {
	put_node_start(l, node, ctx, ind) or_return
	for l.open_n > 0 && l.w.err == nil {
		if open_top(l).flow {
			put_flow_next(l) or_return
		} else {
			put_block_next(l) or_return
		}
	}
	return l.w.err == nil
}

@(private)
put_node_start :: proc(l: ^Layout, node: tape.Node_Index, ctx: Context, ind: int) -> bool {
	pr := props_of(l, node) or_return
	space := ctx != .Root
	if pr.alias != "" && !l.sort && (pr.alias in l.defined) {
		put_token(l, &space, "*")
		put_str(l.out, pr.alias)
		put_inline_comment(l, node)
		put_line_end(l)
		return true
	}
	n := l.w.nodes[node]
	k := n.kind
	#partial switch k {
	case .Object, .Array:
		if n.spelling & tape.CONTAINER_PARTIAL != 0 {
			return refuse(l, node, .Partial)
		}
		if l.pretty {
			non_empty := container_non_empty(l, node, n)
			if non_empty && !kept_flow(l, node) {
				return put_block_open(l, node, pr, ctx, ind)
			}
			put_props(l, &space, pr) or_return
			if space {
				write.put_byte(l.out, ' ')
			}
			if l.commented && !non_empty && has_fact(l, node, .Comment_Foot) {
				put_empty_foot(l, node, k == .Object, ind)
				return true
			}
		} else {
			put_props(l, &space, pr) or_return
			if space {
				write.put_byte(l.out, ' ')
			}
		}
		return put_flow_open(l, node, true)
	case .Null:
		if l.dialect == .Core && ctx != .Root && l.own && pr.tag == "" && pr.anchor == "" && n.n == 0 && style_of(n.spelling) == .Plain {
			put_inline_comment(l, node)
			put_line_end(l)
			return true
		}
	}
	put_props(l, &space, pr) or_return
	if space {
		write.put_byte(l.out, ' ')
	}
	ended := put_leaf(l, node, k, false, false, ind, pr.tag != "") or_return
	if ended {
		return true
	}
	if ctx == .Root {
		put_flow_inline(l, node)
	}
	put_inline_comment(l, node)
	put_line_end(l)
	return true
}

@(private)
put_line_end :: #force_inline proc(l: ^Layout) {
	if l.pretty {
		write.put_byte(l.out, '\n')
	}
}

@(private)
put_block_open :: proc(l: ^Layout, node: tape.Node_Index, pr: Properties, ctx: Context, ind: int) -> bool {
	space := ctx != .Root
	compact := ctx == .Dash && pr.tag == "" && pr.anchor == "" && !has_fact(l, node, .Comment_Inline) && !first_headed(l, node)
	if compact {
		write.put_byte(l.out, ' ')
	} else {
		put_props(l, &space, pr) or_return
		put_inline_comment(l, node)
		if ctx != .Root {
			write.put_byte(l.out, '\n')
		}
	}
	o, pok := push_open_ptr(l)
	if !pok {
		return false
	}
	o^ = {node = node, ind = ind, first = true, compact = compact}
	if l.w.nodes[node].kind == .Object {
		o.object = true
		m, mok := members_of(l, node)
		if !mok {
			o.object = false
			o.elem_scalar = true
			l.open_n -= 1
			return false
		}
		o.members = m
	} else if write.plain_members(&l.w, node) {
		o.elem_scalar = true
		o.elements = {container = node, next = node + 1}
	} else {
		elems, ok := write.children_as_written(&l.w, node)
		if !ok {
			o.elem_scalar = true
			l.open_n -= 1
			return false
		}
		o.elements = elems
	}
	return true
}

@(private)
put_block_next :: proc(l: ^Layout) -> bool {
	o := open_top(l)
	ind := o.ind
	if o.object {
		m, more := members_next(l, o)
		if !more {
			return put_block_close(l)
		}
		if !(o.first && o.compact) {
			put_comments(l, m.value, .Comment, ind)
			put_run(l.out, ind, ' ')
		}
		o.first = false
		explicit := put_key(l, m.key, false) or_return
		if explicit {
			write.put_byte(l.out, '\n')
			put_run(l.out, ind, ' ')
		}
		write.put_byte(l.out, ':')
		return put_node_start(l, m.value, .Key, ind + l.step)
	}
	element: tape.Node_Index
	if o.elem_scalar {
		end := o.node + tape.Node_Index(l.w.nodes[o.node].n)
		if o.elements.next >= end {
			return put_block_close(l)
		}
		element = o.elements.next
		o.elements.next = tape.node_after(l.w.doc, element)
	} else {
		_, elem, p := tape.next_child(l.w.reader, &o.elements, .Group)
		if p != .Found {
			return put_block_close(l)
		}
		element = elem
	}
	if !(o.first && o.compact) {
		put_comments(l, element, .Comment, ind)
		put_run(l.out, ind, ' ')
	}
	o.first = false
	write.put_byte(l.out, '-')
	return put_node_start(l, element, .Dash, ind + 2)
}

@(private)
put_block_close :: proc(l: ^Layout) -> bool {
	o := pop_open(l)
	put_comments(l, o.node, .Comment_Foot, o.ind)
	close_open(&o)
	return true
}

@(private)
first_headed :: proc(l: ^Layout, node: tape.Node_Index) -> bool {
	if !l.commented {
		return false
	}
	if l.w.nodes[node].kind == .Object {
		c, ok := write.children_as_written(&l.w, node)
		if !ok {
			return false
		}
		defer tape.destroy_children(&c)
		_, first, p := tape.next_child(l.w.reader, &c, .Group)
		return p == .Found && has_fact(l, first, .Comment)
	}
	return node + 1 < tape.Node_Index(len(l.w.doc.nodes)) && has_fact(l, node + 1, .Comment)
}

@(private)
has_fact :: proc(l: ^Layout, node: tape.Node_Index, kind: tape.Fact_Kind) -> bool {
	if !l.commented {
		return false
	}
	for f in tape.facts_of(l.w.doc, node) {
		if f.kind == kind {
			return true
		}
	}
	return false
}

@(private)
plain_direct_body :: #force_inline proc(l: ^Layout, node: tape.Node_Index, flow: bool) -> (span: []u8, ok: bool) #no_bounds_check {
	if !l.own {
		return nil, false
	}
	n := l.w.nodes[node]
	if n.kind != .String || style_of(n.spelling) != .Plain || (n.spelling & tape.SPELLING_DECODE != 0) || n.n == 0 {
		return nil, false
	}
	ascii := (n.spelling & tape.SPELLING_ASCII) != 0
	if l.opts.ascii && !ascii {
		return nil, false
	}
	s := tape.span_bytes(l.w.doc, n.lo, n.n)
	if s[0] == ' ' || s[len(s) - 1] == ' ' {
		return nil, false
	}
	if l.dialect != .Failsafe && RESOLVABLE_LEAD[s[0]] && classify(s) != .Text {
		return nil, false
	}
	if len(s) >= 3 && (s[0] == '-' && s[1] == '-' && s[2] == '-' || s[0] == '.' && s[1] == '.' && s[2] == '.') {
		return nil, false
	}
	for b, i in s {
		if b == '\t' || b == '#' || (flow && (b == ',' || b == '[' || b == ']' || b == '{' || b == '}')) {
			return nil, false
		}
		if b == ':' && (i + 1 == len(s) || s[i + 1] == ' ' || (flow && is_flow_indicator(s[i + 1]))) {
			return nil, false
		}
		if !ascii && (b == 0xc2 || b == 0xe2 || b == 0xef) {
			return nil, false
		}
	}
	return s, true
}

@(private)
put_single_quoted_fast :: #force_inline proc(out: ^write.Out, body: string) #no_bounds_check {
	if len(body) + 2 <= write.ROOM_MAX {
		p := write.room(out, len(body) + 2)
		p[0] = '\''
		copy(p[1:1 + len(body)], body)
		p[1 + len(body)] = '\''
		out.cursor += len(body) + 2
		return
	}
	write.put_byte(out, '\'')
	put_str(out, body)
	write.put_byte(out, '\'')
}

@(private)
put_key :: proc(l: ^Layout, key: tape.Node_Index, flow: bool) -> (explicit, ok: bool) {
	n := l.w.nodes[key]
	if n.kind > .Plain {
		return false, refuse(l, key, .No_Spelling)
	}
	if l.dialect == .Failsafe && n.kind != .String && n.kind != .Plain {
		return false, refuse(l, key, .No_Spelling)
	}
	if l.dialect == .Json && n.kind == .Number {
		if nv, is_num := tape.node_number(l.w.doc, key); is_num && nv.kind == .Float {
			f := transmute(f64)nv.bits
			if math.is_nan(f) || math.is_inf(f) {
				return false, refuse(l, key, .No_Spelling)
			}
		}
	}
	if n.kind == .Bytes {
		has_tag := l.own && has_fact(l, key, .Tag)
		if l.commented && l.own {
			for f in tape.facts_of(l.w.doc, key) {
				if f.kind != .Style && f.kind != .Tag {
					l.skipped += {f.kind}
				}
			}
		}
		encoded: string
		bok: bool
		if l.own {
			// YAML `.Bytes` keys decode via `decode_binary_to(..., normalize = true)` directly to whitespace-stripped base64.
			encoded, bok = write.text_of(&l.w, key)
		} else {
			encoded, bok = write.bytes_base64(&l.w, key)
		}
		if !bok {
			return false, false
		}
		defer if !l.own {
			delete(encoded, l.w.allocator)
		}
		tag_str := "!!binary"
		if has_tag {
			for f in tape.facts_of(l.w.doc, key) {
				if f.kind == .Tag {
					tag_str = string(tape.span_bytes(l.w.doc, f.lo, f.n))
					break
				}
			}
		}
		explicit = len(tag_str) + 1 + max(len(encoded), 2) > KEY_MAX
		if explicit {
			put_str(l.out, "? ")
		}
		put_str(l.out, tag_str)
		write.put_byte(l.out, ' ')
		put_scalar(l.out, encoded, .Plain if len(encoded) > 0 else .Double, false)
		return explicit, true
	}
	has_tag := false
	if l.commented && l.own {
		for f in tape.facts_of(l.w.doc, key) {
			if f.kind == .Tag {
				has_tag = true
			}
			if f.kind != .Style {
				l.skipped += {f.kind}
			}
		}
	}
	if !l.sort && !has_tag && n.n <= KEY_MAX {
		if span, fast := plain_direct_body(l, key, flow); fast {
			write.put(l.out, span)
			return false, true
		}
		if body, whole := single_quoted_body(l, key); whole && len(body) + 2 <= KEY_MAX {
			put_single_quoted_fast(l.out, body)
			return false, true
		}
	}
	text, tok := write.text_of(&l.w, key)
	if !tok {
		return false, false
	}
	explicit = len(text) > KEY_MAX
	if explicit {
		put_str(l.out, "? ")
	}
	keeps: Maybe(Style)
	if l.own && !l.opts.sort_keys {
		if has_tag {
			if n.kind == .String && style_of(n.spelling) != .Plain {
				keeps = style_of(n.spelling)
			}
		} else if n.kind == .Number {
			nk := Number_Spelling(n.spelling & tape.NUMBER_KIND)
			if number_is_quoted(nk) {
				keeps = style_of(n.spelling)
			} else {
				keeps = .Plain
			}
		} else if n.kind == .String && style_of(n.spelling) == .Plain {
			if l.dialect == .Failsafe || classify(transmute([]u8)text) == .Text {
				keeps = .Plain
			}
		} else {
			keeps = style_of(n.spelling)
		}
	}
	if !l.own && l.styled {
		if name, has := tape.fact_name(l.w.doc, key, .Style); has {
			keeps, _ = style_kept_name(name)
		}
	}
	shape, valid := shape_of(text, Place{flow = flow, key = true, ascii = l.opts.ascii, keeps = keeps})
	if !valid {
		return false, refuse(l, key, .No_Spelling)
	}
	if shape == .Plain && explicit {
		shape = .Single
	}
	put_scalar(l.out, text, shape, l.opts.ascii)
	return explicit, true
}

@(private)
kept_flow :: proc(l: ^Layout, node: tape.Node_Index) -> bool {
	if l.own {
		return is_flow(l.w.doc, l.w.nodes[node])
	}
	if l.styled {
		if style, has := tape.fact_name(l.w.doc, node, .Style); has && style == "flow" {
			return !holds_inner_fact(l.w.doc, node)
		}
	}
	return false
}

@(private)
holds_inner_fact :: proc(doc: ^tape.Document, node: tape.Node_Index) -> bool {
	if len(doc.facts) == 0 {
		return false
	}
	end := tape.node_after(doc, node)
	for f in doc.facts {
		if f.node > node && f.node < end && (f.kind == .Comment || f.kind == .Comment_Inline || f.kind == .Comment_Foot) {
			return true
		}
	}
	return false
}

@(private)
kept_style :: proc(l: ^Layout, node: tape.Node_Index) -> (keeps: Maybe(Style), folded: bool) {
	if l.own {
		t := l.w.nodes[node]
		st := style_of(t.spelling)
		if st == .Block {
			span := tape.span_bytes(l.w.doc, t.lo, t.n)
			return .Block, len(span) > 0 && span[0] == '>'
		}
		return st, false
	}
	if l.styled {
		if name, has := tape.fact_name(l.w.doc, node, .Style); has {
			return style_kept_name(name)
		}
	}
	return nil, false
}

@(private)
style_kept_name :: proc "contextless" (name: string) -> (Maybe(Style), bool) {
	switch name {
	case "single":
		return .Single, false
	case "double":
		return .Double, false
	case "literal", "multiline":
		return .Block, false
	case "folded":
		return .Block, true
	}
	return nil, false
}

@(private)
put_leaf :: proc(l: ^Layout, node: tape.Node_Index, k: tape.Kind, flow, key: bool, ind: int, tagged: bool) -> (ended: bool, ok: bool) {
	#partial switch k {
	case .String, .Plain:
		if k == .String {
			if span, fast := plain_direct_body(l, node, flow); fast {
				write.put(l.out, span)
				return false, true
			}
			if body, whole := single_quoted_body(l, node); whole {
				put_single_quoted_fast(l.out, body)
				return false, true
			}
		}
		text, tok := write.text_of(&l.w, node)
		if !tok {
			return false, false
		}
		keeps, folded := kept_style(l, node)
		place := Place{flow = flow, key = key, block = l.pretty && !flow && !key, ascii = l.opts.ascii, keeps = keeps, folded = folded, tagged = tagged}
		shape, valid := shape_of(text, place)
		if !valid {
			return false, refuse(l, node, .No_Spelling)
		}
		if shape == .Literal || shape == .Folded {
			put_block(l.out, text, shape, ind if ind > 0 else l.step)
			return true, true
		}
		put_scalar(l.out, text, shape, l.opts.ascii)
	case .Number:
		if l.dialect == .Failsafe {
			return false, refuse(l, node, .No_Spelling)
		}
		return false, put_number(l, node, flow, ind, tagged)
	case .True:
		if l.dialect == .Failsafe {
			return false, refuse(l, node, .No_Spelling)
		}
		put_str(l.out, own_word(l, node, "true"))
	case .False:
		if l.dialect == .Failsafe {
			return false, refuse(l, node, .No_Spelling)
		}
		put_str(l.out, own_word(l, node, "false"))
	case .Null:
		if l.dialect == .Failsafe {
			return false, refuse(l, node, .No_Spelling)
		}
		put_str(l.out, own_word(l, node, "null"))
	case .Bytes:
		if l.dialect == .Failsafe {
			return false, refuse(l, node, .No_Spelling)
		}
		encoded, bok := write.bytes_base64(&l.w, node)
		if !bok {
			return false, false
		}
		defer delete(encoded, l.w.allocator)
		if !tagged {
			put_str(l.out, "!!binary ")
		}
		put_scalar(l.out, encoded, .Plain if len(encoded) > 0 else .Double, false)
	case:
		return false, refuse(l, node, .No_Spelling)
	}
	return false, true
}

@(private)
put_number :: proc(l: ^Layout, at: tape.Node_Index, flow: bool, ind: int, tagged: bool) -> bool {
	doc := l.w.doc
	n := l.w.nodes[at]
	if l.own {
		nk := Number_Spelling(n.spelling & tape.NUMBER_KIND)
		if (l.dialect == .Core || nk == .Plain) && !number_is_quoted(nk) && !number_is_block(nk) && n.spelling & tape.SPELLING_DECODE == 0 {
			span := tape.span_bytes(doc, n.lo, n.n)
			if len(span) > 0 {
				write.put(l.out, span)
				return true
			}
		}
		if tagged && (l.dialect == .Core || nk == .Plain) {
			text, tok := write.text_of(&l.w, at)
			if !tok {
				return false
			}
			keeps: Maybe(Style)
			if number_is_quoted(nk) {
				keeps = style_of(n.spelling)
			} else if number_is_block(nk) {
				keeps = .Block
			}
			shape, valid := shape_of(text, Place{flow = flow, block = l.pretty && !flow, ascii = l.opts.ascii, keeps = keeps, tagged = true})
			if valid {
				if shape == .Literal || shape == .Folded {
					put_block(l.out, text, shape, ind if ind > 0 else l.step)
				} else {
					put_scalar(l.out, text, shape, l.opts.ascii)
				}
				return true
			}
		}
	}
	buf: [write.NUMBER_ROOM]u8 = ---
	nv, _ := tape.node_number(doc, at)
	if nv.kind == .Float {
		f := transmute(f64)nv.bits
		if math.is_nan(f) {
			if l.dialect == .Json {
				return refuse(l, at, .No_Spelling)
			}
			put_str(l.out, ".nan")
			return true
		}
		if math.is_inf(f) {
			if l.dialect == .Json {
				return refuse(l, at, .No_Spelling)
			}
			put_str(l.out, "-.inf" if f < 0 else ".inf")
			return true
		}
	}
	style := ""
	if l.styled {
		if st, has := tape.fact_name(doc, at, .Style); has {
			style = st
		}
	}
	if l.dialect == .Core && (style == "hex" || style == "octal") && (nv.kind == .Uint || nv.kind == .Int && i64(nv.bits) >= 0) {
		put_str(l.out, "0x" if style == "hex" else "0o")
		base := 16 if style == "hex" else 8
		put_str(l.out, strconv.write_bits(buf[:], nv.bits, base, false, 64, "0123456789abcdef", {}))
		return true
	}
	s, ok := write.number_text(&l.w, at, &buf)
	if !ok {
		return refuse(l, at, .No_Spelling)
	}
	put_str(l.out, s)
	if style == "float" && !strings.contains_any(s, ".eE") {
		put_str(l.out, ".0")
	}
	return true
}

@(private)
single_quoted_body :: #force_inline proc(l: ^Layout, node: tape.Node_Index) -> (text: string, whole: bool) {
	if !l.own || l.opts.ascii {
		return "", false
	}
	n := l.w.nodes[node]
	if n.kind != .String || style_of(n.spelling) != .Single || n.spelling & tape.SPELLING_DECODE != 0 {
		return "", false
	}
	if n.spelling & tape.SPELLING_ASCII != 0 {
		return string(tape.span_bytes(l.w.doc, n.lo, n.n)), true
	}
	return "", false
}

@(private)
own_word :: proc(l: ^Layout, node: tape.Node_Index, word: string) -> string {
	if l.own && l.dialect == .Core {
		n := l.w.nodes[node]
		if style_of(n.spelling) == .Plain && n.spelling & tape.SPELLING_DECODE == 0 {
			if span := tape.span_bytes(l.w.doc, n.lo, n.n); len(span) > 0 {
				return string(span)
			}
		}
	}
	return word
}

@(private)
put_empty_foot :: proc(l: ^Layout, node: tape.Node_Index, object: bool, ind: int) {
	put_str(l.out, "{\n" if object else "[\n")
	put_comments(l, node, .Comment_Foot, ind)
	put_run(l.out, ind, ' ')
	write.put_byte(l.out, '}' if object else ']')
	put_inline_comment(l, node)
	put_line_end(l)
}

@(private)
put_flow_open :: proc(l: ^Layout, node: tape.Node_Index, tail: bool) -> bool {
	if l.w.nodes[node].spelling & tape.CONTAINER_PARTIAL != 0 {
		return refuse(l, node, .Partial)
	}
	o, pok := push_open_ptr(l)
	if !pok {
		return false
	}
	o^ = {node = node, flow = true, first = true, tail = tail}
	if l.w.nodes[node].kind == .Object {
		write.put_byte(l.out, '{')
		o.object = true
		m, mok := members_of(l, node)
		if !mok {
			o.object = false
			o.elem_scalar = true
			l.open_n -= 1
			return false
		}
		o.members = m
	} else {
		write.put_byte(l.out, '[')
		if write.plain_members(&l.w, node) {
			o.elem_scalar = true
			o.elements = {container = node, next = node + 1}
		} else {
			elems, ok := write.children_as_written(&l.w, node)
			if !ok {
				o.elem_scalar = true
				l.open_n -= 1
				return false
			}
			o.elements = elems
		}
	}
	return true
}

@(private)
put_flow_next :: proc(l: ^Layout) -> bool {
	o := open_top(l)
	if o.object {
		m, more := members_next(l, o)
		if !more {
			put_flow_comments(l, o.node, .Comment_Foot)
			write.put_byte(l.out, '}')
			return put_flow_close(l)
		}
		if !o.first {
			put_str(l.out, ", ")
		}
		o.first = false
		put_flow_comments(l, m.value, .Comment)
		explicit := put_key(l, m.key, true) or_return
		put_str(l.out, " : " if explicit else ": ")
		return put_flow_start(l, m.value)
	}
	element: tape.Node_Index
	if o.elem_scalar {
		end := o.node + tape.Node_Index(l.w.nodes[o.node].n)
		if o.elements.next >= end {
			put_flow_comments(l, o.node, .Comment_Foot)
			write.put_byte(l.out, ']')
			return put_flow_close(l)
		}
		element = o.elements.next
		o.elements.next = tape.node_after(l.w.doc, element)
	} else {
		_, elem, p := tape.next_child(l.w.reader, &o.elements, .Group)
		if p != .Found {
			put_flow_comments(l, o.node, .Comment_Foot)
			write.put_byte(l.out, ']')
			return put_flow_close(l)
		}
		element = elem
	}
	if !o.first {
		put_str(l.out, ", ")
	}
	o.first = false
	put_flow_comments(l, element, .Comment)
	return put_flow_start(l, element)
}

@(private)
put_flow_close :: proc(l: ^Layout) -> bool {
	o := pop_open(l)
	if !o.tail {
		put_flow_inline(l, o.node)
	} else {
		put_inline_comment(l, o.node)
		put_line_end(l)
	}
	close_open(&o)
	return true
}

@(private)
put_flow_start :: proc(l: ^Layout, node: tape.Node_Index) -> bool {
	pr := props_of(l, node) or_return
	space := false
	if pr.alias != "" && !l.sort && (pr.alias in l.defined) {
		write.put_byte(l.out, '*')
		put_str(l.out, pr.alias)
		return true
	}
	k := node_kind(l, node)
	put_props(l, &space, pr) or_return
	if space {
		write.put_byte(l.out, ' ')
	}
	if k == .Object || k == .Array {
		return put_flow_open(l, node, false)
	}
	put_leaf(l, node, k, true, false, 0, pr.tag != "") or_return
	put_flow_inline(l, node)
	return true
}

@(private)
members_of :: proc(l: ^Layout, node: tape.Node_Index) -> (m: Members, ok: bool) {
	if !l.sort {
		if write.plain_members(&l.w, node) {
			return Members{direct = true, Direct = {c = {container = node, next = node + 1}, scalar = true}}, true
		}
		c, cok := write.children_as_written(&l.w, node)
		if !cok {
			return {}, false
		}
		return Members{direct = true, Direct = {c = c}}, true
	}
	c, cok := write.children_as_written(&l.w, node)
	if !cok {
		return {}, false
	}
	defer tape.destroy_children(&c)
	lo := len(l.members)
	for {
		key, val, p := tape.next_child(l.w.reader, &c, .Group)
		if p != .Found {
			break
		}
		name: string
		if key == tape.NO_NODE && c.keys_n != 0 {
			// Table row cell without a key node is unsupported as a sorted node index key; refuse cleanly if encountered.
			release_members(l, lo)
			return {}, refuse(l, node, .No_Spelling)
		}
		if l.w.nodes[key].kind > .Plain {
			release_members(l, lo)
			return {}, refuse(l, key, .No_Spelling)
		}
		raw_name, tok := write.text_of(&l.w, key)
		if !tok {
			release_members(l, lo)
			return {}, false
		}
		var_name, err := strings.clone(raw_name, l.members.allocator)
		if err != nil {
			l.w.err = err
			release_members(l, lo)
			return {}, false
		}
		name = var_name
		if _, aerr := append(&l.members, Member{key = key, value = val, name = name}); aerr != nil {
			delete(name, l.members.allocator)
			l.w.err = aerr
			release_members(l, lo)
			return {}, false
		}
	}
	hi := len(l.members)
	slice.stable_sort_by(l.members[lo:hi], proc(a, b: Member) -> bool {
		return a.name < b.name
	})
	return Members{direct = false, Sorted = {lo = lo, hi = hi, at = lo}}, true
}

@(private)
members_next :: proc(l: ^Layout, o: ^Put_Open) -> (m: Member, ok: bool) {
	mem := &o.members
	if mem.direct {
		if mem.Direct.scalar {
			end := o.node + tape.Node_Index(l.w.nodes[o.node].n)
			k := mem.Direct.c.next
			if k >= end {
				return {}, false
			}
			val := tape.node_after(l.w.doc, k)
			mem.Direct.c.next = tape.node_after(l.w.doc, val)
			return {key = k, value = val}, true
		}
		key, val, p := tape.next_child(l.w.reader, &mem.Direct.c, .Group)
		if p != .Found {
			return {}, false
		}
		if key == tape.NO_NODE {
			// Tabular cell key: unsupported directly; refuse cleanly if no node.
			_ = refuse(l, val, .No_Spelling)
			return {}, false
		}
		return {key = key, value = val}, true
	}
	if mem.Sorted.at >= mem.Sorted.hi {
		release_members(l, mem.Sorted.lo)
		return {}, false
	}
	item := l.members[mem.Sorted.at]
	mem.Sorted.at += 1
	return item, true
}

@(private)
comment_valid :: proc "contextless" (body: []u8) -> bool #no_bounds_check {
	high: u8 = 0
	for c in body {
		high |= c
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' || c == 0x7f {
			return false
		}
	}
	return high < 0x80 || utf8.valid_string(string(body))
}

@(private)
put_comments :: proc(l: ^Layout, node: tape.Node_Index, kind: tape.Fact_Kind, ind: int) {
	if !l.commented {
		return
	}
	for f in tape.facts_of(l.w.doc, node) {
		if f.kind != kind {
			continue
		}
		body, _ := write.comment_body(l.w.doc, f)
		if !comment_valid(body) {
			l.skipped += {kind}
			continue
		}
		rest := string(body)
		if len(rest) == 0 {
			put_run(l.out, ind, ' ')
			put_str(l.out, "#\n")
			continue
		}
		for line in strings.split_lines_iterator(&rest) {
			put_run(l.out, ind, ' ')
			write.put_byte(l.out, '#')
			put_str(l.out, line)
			write.put_byte(l.out, '\n')
		}
	}
}

@(private)
put_inline_comment :: proc(l: ^Layout, node: tape.Node_Index) -> bool {
	if !l.commented || !l.pretty {
		return false
	}
	return emit_inline_comments(l, node)
}

@(private)
emit_inline_comments :: proc(l: ^Layout, node: tape.Node_Index) -> bool {
	wrote := false
	for f in tape.facts_of(l.w.doc, node) {
		if f.kind != .Comment_Inline {
			continue
		}
		body, _ := write.comment_body(l.w.doc, f)
		if !comment_valid(body) {
			l.skipped += {.Comment_Inline}
			continue
		}
		put_str(l.out, " #" if !wrote else " ")
		for c in body {
			write.put_byte(l.out, ' ' if c == '\n' || c == '\r' else c)
		}
		wrote = true
	}
	return wrote
}

@(private)
put_flow_comments :: proc(l: ^Layout, node: tape.Node_Index, kind: tape.Fact_Kind) {
	if !l.commented || l.pretty || !has_fact(l, node, kind) {
		return
	}
	if l.out.cursor > 0 && l.out.buf[l.out.cursor - 1] == ' ' {
		l.out.cursor -= 1
	}
	if l.out.cursor > 0 && l.out.buf[l.out.cursor - 1] != '\n' {
		write.put_byte(l.out, '\n')
	}
	put_comments(l, node, kind, 0)
}

@(private)
put_flow_inline :: proc(l: ^Layout, node: tape.Node_Index) {
	if !l.commented || l.pretty {
		return
	}
	if emit_inline_comments(l, node) {
		write.put_byte(l.out, '\n')
	}
}
