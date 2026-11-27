// Explicit-stack schema inference from `tape.Document`s or `rules.Value`s into `rules.Description`.
// Zero native stack recursion (handles 10,000+ level nesting in 1 MiB stack),
// zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package schema

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

@(private) MAX_NAMES :: 64

@(private) Key_Form :: enum u8 { Integer, Uuid }

@(private)
Summary :: struct {
	kinds:                rules.Kinds,
	numbers, strings:     u64,
	arrays, objects:      u64,
	low, high:            string,
	ranged, unranged:     bool,
	min_chars, max_chars: u64,
	min_items, max_items: u64,
	items:                ^Summary,
	members:              [dynamic]Member_Seen,
	values:               ^Summary,
	collapsed:            bool,
	forms:                bit_set[Key_Form],
	hint:                 int,
}

@(private)
Member_Seen :: struct {
	name:       string,
	count:      u64,
	at:         ^Summary,
	last:       u64,
	last_node:  rules.Markup_Node,
	collected:  bool,
	attributed: bool,
	markup:     rules.Markup_Node,
	ordinal:    u64,
}

Inferred :: struct {
	root:        ^Summary,
	ranges:      bool,
	rows:        bool,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
	allocator:   runtime.Allocator,
	failed:      bool,
	seq:         u64,
	trash:       Summary,
}

inferred_destroy :: proc(inf: ^Inferred) {
	if inf == nil { return }
	if inf.arena_ready { mem.dynamic_arena_destroy(&inf.arena) }
	inf^ = {}
}

infer_document :: proc(inf: ^Inferred, doc: ^tape.Document, at := tape.ROOT, allocator := context.allocator) -> runtime.Allocator_Error {
	if doc == nil || len(doc.nodes) == 0 || int(at) >= len(doc.nodes) { return .None }
	return infer_value(inf, rules.Node_Ref{doc, at}, allocator)
}

@(private = "file")
inf_push :: proc(inf: ^Inferred, arr: ^[dynamic]$T, val: T) -> bool {
	if _, err := append(arr, val); err != nil { inf.failed = true; return false }
	return true
}

infer_value :: proc(inf: ^Inferred, v: rules.Value, allocator := context.allocator) -> runtime.Allocator_Error {
	if !inf_ensure(inf, allocator) { return .Out_Of_Memory }
	a := mem.dynamic_arena_allocator(&inf.arena)

	Work :: struct { p: ^Summary, v: rules.Value }
	stack, serr := make([dynamic]Work, 0, 64, inf.allocator)
	child_buf, cberr := make([dynamic]Work, 0, 64, inf.allocator)
	defer { delete(stack); delete(child_buf) }
	if serr != nil || cberr != nil { inf.failed = true; return .Out_Of_Memory }

	append(&stack, Work{p = inf.root, v = v})
	text_buf: [512]u8 = ---

	for len(stack) > 0 && !inf.failed {
		w := pop(&stack)
		p, cur := w.p, w.v

		if ref, is_ref := cur.(rules.Node_Ref); is_ref && ref.doc != nil && int(ref.node) < len(ref.doc.nodes) {
			doc := ref.doc
			node := doc.nodes[ref.node]
			is_markup := doc.format != nil && .Attribute in doc.format.facts
			if is_markup && node.kind != .Array {
				has_attr := false
				for f in tape.facts_of(doc, ref.node) { if f.kind == .Attribute { has_attr = true; break } }
				if has_attr || node.kind == .Object {
					infer_object_node(inf, a, p, ref, true, &child_buf, &stack, text_buf[:])
					continue
				}
			}
			#partial switch node.kind {
			case .Array:  infer_array_node(inf, a, p, ref, &child_buf, &stack)
			case .Object: infer_object_node(inf, a, p, ref, false, &child_buf, &stack, text_buf[:])
			case:         infer_leaf(inf, a, p, cur, text_buf[:])
			}
			continue
		}

		switch rules.value_kind(cur) {
		case .Array:
			p.kinds += {.Array}
			p.arrays += 1
			elems := cur.([]rules.Value) or_else nil
			n := u64(len(elems))
			p.min_items = n if p.arrays == 1 else min(p.min_items, n)
			p.max_items = max(p.max_items, n)
			if len(elems) > 0 {
				it_sum := inf_child(inf, a, &p.items)
				for i := len(elems) - 1; i >= 0; i -= 1 { if !inf_push(inf, &stack, Work{it_sum, elems[i]}) { break } }
			}
		case .Object:
			p.kinds += {.Object}
			p.objects += 1
			members := cur.([]rules.Member_Value) or_else nil
			clear(&child_buf)
			for m, idx in members {
				dup := false
				for j in idx + 1 ..< len(members) { if members[j].key == m.key { dup = true; break } }
				if !dup {
					if !inf_push(inf, &child_buf, Work{inf_member(inf, a, p, m.key, false, .Any), m.value}) { break }
				}
			}
			for i := len(child_buf) - 1; i >= 0; i -= 1 { if !inf_push(inf, &stack, child_buf[i]) { break } }
		case .Null, .False, .True, .Number, .String:
			infer_leaf(inf, a, p, cur, text_buf[:])
		}
	}
	return .Out_Of_Memory if inf.failed else .None
}

infer_merge :: proc(dst, src: ^Inferred, allocator := context.allocator) -> runtime.Allocator_Error {
	if src == nil || src.root == nil { return .None }
	if src.failed || !inf_ensure(dst, allocator) { return .Out_Of_Memory }
	dst.rows ||= src.rows
	a := mem.dynamic_arena_allocator(&dst.arena)
	stack, serr := make([dynamic]Join_Pair, 0, 32, dst.allocator)
	if serr != nil { dst.failed = true; return .Out_Of_Memory }
	defer delete(stack)
	if inf_push(dst, &stack, Join_Pair{dst.root, src.root, dst.seq}) {
		join_drain(dst, a, &stack)
	}
	dst.seq += src.seq
	return .Out_Of_Memory if dst.failed else .None
}

@(require_results)
inferred :: proc(inf: ^Inferred, allocator := context.allocator) -> (rules.Description, runtime.Allocator_Error) {
	d := rules.Description {
		nodes     = make([dynamic]rules.Node, allocator),
		arrays    = make([dynamic]rules.Array, allocator),
		objects   = make([dynamic]rules.Object, allocator),
		texts     = make([dynamic]string, allocator),
		anchors   = make([dynamic]rules.Anchor, allocator),
		names     = make(map[rules.Node_Index]string, allocator),
		bases     = make([dynamic]rules.Base, allocator),
		allocator = allocator,
	}
	ok := false
	defer if !ok { rules.description_destroy(&d) }

	empty_root := Summary{kinds = rules.EVERY_KIND}
	root := inf.root if (inf != nil && inf.root != nil) else &empty_root
	rows_root: Summary
	if inf != nil && inf.rows {
		rows_root = Summary{kinds = {.Array}, arrays = 1, items = root}
		root = &rows_root
	}

	Task :: struct { idx: rules.Node_Index, p: ^Summary, markup: rules.Markup_Node }
	stack, serr := make([dynamic]Task, 0, 64, allocator)
	if serr != nil { return {}, .Out_Of_Memory }
	defer delete(stack)

	root_idx, aerr := alloc_desc_node(&d)
	if aerr != nil { return {}, .Out_Of_Memory }
	d.root = root_idx
	if _, perr := append(&stack, Task{idx = root_idx, p = root}); perr != nil { return {}, .Out_Of_Memory }

	inf_arena_alloc := mem.dynamic_arena_allocator(&inf.arena) if (inf != nil && inf.arena_ready) else runtime.Allocator{}
	want_ranges := inf != nil && inf.ranges

	for len(stack) > 0 {
		t := pop(&stack)
		p := t.p
		kinds := p.kinds if p.kinds != {} else rules.EVERY_KIND
		if .Number in kinds { kinds -= {.Integer} }
		d.nodes[t.idx].kinds = kinds
		if want_ranges {
			rl, rok := ranges_of(&d, p)
			if !rok { return {}, .Out_Of_Memory }
			d.nodes[t.idx].rules = rl
		}
		if t.markup != .Any { d.nodes[t.idx].rules.markup = t.markup }
		if p.arrays > 0 {
			a := rules.Array{items = rules.NONE}
			if p.items != nil {
				child_idx, cerr := alloc_desc_node(&d)
				if cerr != nil { return {}, .Out_Of_Memory }
				a.items = child_idx
				if _, perr := append(&stack, Task{idx = child_idx, p = p.items}); perr != nil { return {}, .Out_Of_Memory }
			}
			d.nodes[t.idx].array = i32(len(d.arrays))
			if _, aerr2 := append(&d.arrays, a); aerr2 != nil { return {}, .Out_Of_Memory }
		}
		if p.objects > 0 {
			o := rules.Object{additional = rules.NONE, keys = rules.NONE}
			if !p.collapsed && len(p.members) > 0 && p.forms != {} && inf != nil {
				collapse_iterative(inf, inf_arena_alloc, p)
				if inf.failed { return {}, .Out_Of_Memory }
			}
			if p.collapsed {
				if p.values != nil {
					val_idx, verr := alloc_desc_node(&d)
					if verr != nil { return {}, .Out_Of_Memory }
					o.additional = val_idx
					if _, perr := append(&stack, Task{idx = val_idx, p = p.values}); perr != nil { return {}, .Out_Of_Memory }
				}
			} else if len(p.members) > 0 {
				slice.sort_by(p.members[:], proc(x, y: Member_Seen) -> bool { return x.ordinal < y.ordinal })
				list, lerr := make([]rules.Member, len(p.members), allocator)
				child_tasks, cterr := make([]Task, len(p.members), allocator)
				defer delete(child_tasks, allocator)
				if lerr != nil || cterr != nil { delete(list, allocator); return {}, .Out_Of_Memory }
				for m, k in p.members {
					at_idx, nerr := alloc_desc_node(&d)
					if nerr != nil { delete(list, allocator); return {}, .Out_Of_Memory }
					member_node, child_markup := at_idx, m.markup
					if m.collected {
						wrapped, werr := make_collected_node(&d, at_idx, m.attributed)
						if werr != nil { delete(list, allocator); return {}, .Out_Of_Memory }
						d.nodes[wrapped].rules.markup = m.markup
						member_node, child_markup = wrapped, .Any
					}
					name_copy, ncerr := desc_keep_text(&d, m.name)
					if ncerr != nil { delete(list, allocator); return {}, .Out_Of_Memory }
					list[k] = {name = name_copy, node = member_node, required = m.count == p.objects}
					child_tasks[k] = Task{idx = at_idx, p = m.at, markup = child_markup}
				}
				for k := len(child_tasks) - 1; k >= 0; k -= 1 {
					if _, perr := append(&stack, child_tasks[k]); perr != nil { delete(list, allocator); return {}, .Out_Of_Memory }
				}
				o.members = list
			}
			d.nodes[t.idx].object = i32(len(d.objects))
			if _, oerr := append(&d.objects, o); oerr != nil { delete(o.members, allocator); return {}, .Out_Of_Memory }
		}
	}

	if inf != nil && inf.rows && len(d.nodes) > 0 { d.nodes[0].rules.min_items, d.nodes[0].rules.max_items = 0, nil }
	ok = true
	return d, .None
}

@(private = "file")
inf_ensure :: proc(inf: ^Inferred, allocator: runtime.Allocator) -> bool {
	if inf == nil { return false }
	if inf.root != nil { return !inf.failed }
	inf.allocator = allocator
	mem.dynamic_arena_init(&inf.arena, allocator, allocator)
	inf.arena_ready = true
	inf.root = inf_fresh(inf, mem.dynamic_arena_allocator(&inf.arena))
	return !inf.failed
}

@(private = "file")
inf_fresh :: proc(inf: ^Inferred, a: runtime.Allocator) -> ^Summary {
	p, err := new(Summary, a)
	if err != nil { inf.failed = true; return &inf.trash }
	p.forms = {.Integer, .Uuid}
	p.members.allocator = a
	return p
}

@(private = "file")
inf_child :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^^Summary) -> ^Summary {
	if p^ == nil { p^ = inf_fresh(inf, a) }
	return p^
}

@(private = "file")
infer_array_node :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^Summary, ref: rules.Node_Ref, child_buf, stack: ^[dynamic]$W) {
	p.kinds += {.Array}
	p.arrays += 1
	rd := tape.Reader{doc = ref.doc}
	it, pres, err := tape.children(rd, ref.node, inf.allocator)
	if err != nil { inf.failed = true; return }
	defer tape.destroy_children(&it)
	clear(child_buf)
	if pres == .Found {
		for {
			_, ch, cp := tape.next_child(rd, &it)
			if cp != .Found { break }
			if !inf_push(inf, child_buf, W{p = inf_child(inf, a, &p.items), v = rules.Node_Ref{ref.doc, ch}}) { return }
		}
	}
	n := u64(len(child_buf))
	p.min_items = n if p.arrays == 1 else min(p.min_items, n)
	p.max_items = max(p.max_items, n)
	for i := len(child_buf) - 1; i >= 0; i -= 1 { if !inf_push(inf, stack, child_buf[i]) { return } }
}

@(private = "file")
decode_token_text :: proc(doc: ^tape.Document, tok: tape.Token, text_buf: []u8, allocator: runtime.Allocator) -> (string, bool, bool) {
	if s, ok := tape.node_text(doc, tok, text_buf); ok { return s, false, true }
	s, ok := doc_token_string(doc, tok, allocator)
	return s, ok, ok
}

@(private = "file")
infer_object_node :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^Summary, ref: rules.Node_Ref, is_markup: bool, child_buf, stack: ^[dynamic]$W, text_buf: []u8) {
	p.kinds += {.Object}
	p.objects += 1
	doc := ref.doc
	if is_markup && doc.format != nil && doc.format.attribute != nil {
		for f in tape.facts_of(doc, ref.node) {
			if f.kind != .Attribute { continue }
			name_tok, val_tok := doc.format.attribute(doc, f)
			nm, nm_owned, nm_ok := decode_token_text(doc, name_tok, text_buf, inf.allocator)
			if !nm_ok { inf.failed = true; return }
			at := inf_member(inf, a, p, nm, true, .Attribute)
			if nm_owned { delete(nm, inf.allocator) }
			at.kinds += {.String}
			at.strings += 1
			if inf.ranges {
				vs, vs_owned, vs_ok := decode_token_text(doc, val_tok, text_buf, inf.allocator)
				if !vs_ok { inf.failed = true; return }
				chars := u64(kernel.count_chars(transmute([]u8)vs))
				if vs_owned { delete(vs, inf.allocator) }
				at.min_chars = chars if at.strings == 1 else min(at.min_chars, chars)
				at.max_chars = max(at.max_chars, chars)
			}
		}
		if node := doc.nodes[ref.node]; node.kind != .Object {
			if node.kind != .Null && node.n != 0 {
				infer_leaf(inf, a, inf_member(inf, a, p, tape.TEXT_KEY, true, .Text), ref, text_buf)
			}
			return
		}
	}
	rd := tape.Reader{doc = doc}
	it, pres, err := tape.children(rd, ref.node, inf.allocator)
	if err != nil { inf.failed = true; return }
	defer tape.destroy_children(&it)
	clear(child_buf)
	if pres == .Found {
		dups := tape.Duplicates.Group if is_markup else .Last
		for {
			k_idx, v_idx, cp := tape.next_child(rd, &it, dups)
			if cp != .Found { break }
			kt: tape.Token
			if k_idx == tape.NO_NODE && it.keys_n != 0 {
				kt = tape.cell_key(rd, it)
			} else if k_idx != tape.NO_NODE && int(k_idx) < len(doc.nodes) {
				kt = doc.nodes[k_idx]
			} else { inf.failed = true; return }
			key_s, key_owned, key_ok := decode_token_text(doc, kt, text_buf, inf.allocator)
			if !key_ok { inf.failed = true; return }
			m_sum := inf_member(inf, a, p, key_s, is_markup, .Any)
			if key_owned { delete(key_s, inf.allocator) }
			if !inf_push(inf, child_buf, W{p = m_sum, v = rules.Node_Ref{doc, v_idx}}) { return }
		}
	}
	for i := len(child_buf) - 1; i >= 0; i -= 1 { if !inf_push(inf, stack, child_buf[i]) { return } }
}

@(private = "file")
infer_leaf :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^Summary, v: rules.Value, text_buf: []u8) {
	if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil && int(ref.node) < len(ref.doc.nodes) && ref.doc.nodes[ref.node].kind == .Bytes {
		p.kinds += {.String}
		return
	}
	#partial switch rules.value_kind(v) {
	case .Null:        p.kinds += {.Null}
	case .True, .False: p.kinds += {.Bool}
	case .Number:      infer_number(inf, a, p, v, text_buf)
	case .String:
		p.kinds += {.String}
		p.strings += 1
		if inf.ranges {
			s, owned, ok := rules.value_string(v, text_buf, inf.allocator)
			if !ok { inf.failed = true; return }
			chars := u64(kernel.count_chars(transmute([]u8)s))
			p.min_chars = chars if p.strings == 1 else min(p.min_chars, chars)
			p.max_chars = max(p.max_chars, chars)
			if owned { delete(s, inf.allocator) }
		}
	}
}

@(private = "file")
infer_number :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^Summary, v: rules.Value, text_buf: []u8) {
	txt, owned, ok := rules.value_number_text(v, text_buf, inf.allocator)
	defer if owned { delete(txt, inf.allocator) }
	whole := false
	if ok {
		whole = rules.integral(rules.decimal_of(txt))
	} else {
		p.unranged = true
		if f, is_f := v.(f64); is_f { whole = f == math.trunc(f) && !math.is_inf(f, 0) && !math.is_nan(f) }
	}
	p.kinds += {.Integer if whole else .Number}
	p.numbers += 1
	if inf.ranges && ok && !p.unranged { widen_range(inf, a, p, txt, txt) }
}

@(private = "file")
widen_range :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^Summary, low, high: string) {
	if !p.ranged || rules.decimal_compare(rules.decimal_of(low), rules.decimal_of(p.low)) < 0 {
		cp, err := strings.clone(low, a)
		if err != nil { inf.failed = true; return }
		p.low = cp
	}
	if !p.ranged || rules.decimal_compare(rules.decimal_of(high), rules.decimal_of(p.high)) > 0 {
		cp, err := strings.clone(high, a)
		if err != nil { inf.failed = true; return }
		p.high = cp
	}
	p.ranged = true
}

@(private = "file")
inf_member :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^Summary, name: string, is_markup: bool, node: rules.Markup_Node) -> ^Summary {
	if p.collapsed { return inf_child(inf, a, &p.values) }
	p.forms &= forms_of(name)
	found := -1
	for k in 0 ..< len(p.members) {
		if i := (p.hint + k) % len(p.members); p.members[i].name == name { found = i; break }
	}
	if found < 0 {
		if len(p.members) == MAX_NAMES {
			collapse_iterative(inf, a, p)
			return inf_child(inf, a, &p.values)
		}
		text, cerr := strings.clone(name, a)
		if cerr != nil { inf.failed = true; return &inf.trash }
		if !inf_push(inf, &p.members, Member_Seen{name = text, at = inf_fresh(inf, a), markup = node, ordinal = inf.seq}) { return &inf.trash }
		inf.seq += 1
		found = len(p.members) - 1
	}
	m := &p.members[found]
	p.hint = (found + 1) % len(p.members)
	m.attributed ||= node == .Attribute
	if m.last != p.objects {
		m.count, m.last = m.count + 1, p.objects
	} else if node == .Any && m.last_node == .Any {
		m.collected ||= is_markup
	}
	if m.markup != node { m.markup = .Any }
	m.last_node = node
	return m.at
}

@(private = "file")
forms_of :: proc "contextless" (name: string) -> (forms: bit_set[Key_Form]) {
	digits := name[1:] if len(name) > 0 && name[0] == '-' else name
	if len(digits) > 0 {
		all_d := true
		for c in transmute([]u8)digits { if c < '0' || c > '9' { all_d = false; break } }
		if all_d { forms += {.Integer} }
	}
	if len(name) == 36 && name[8] == '-' && name[13] == '-' && name[18] == '-' && name[23] == '-' {
		uuid := true
		for c, i in transmute([]u8)name {
			uuid &&= i == 8 || i == 13 || i == 18 || i == 23 || '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F'
		}
		if uuid { forms += {.Uuid} }
	}
	return
}

@(private = "file")
Join_Pair :: struct { dst, src: ^Summary, offset: u64 }

@(private = "file")
collapse_into_stack :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^Summary, stack: ^[dynamic]Join_Pair) -> bool {
	all := inf_child(inf, a, &p.values)
	old := p.members
	p.members, p.collapsed = nil, true
	for om in old { if !inf_push(inf, stack, Join_Pair{all, om.at, 0}) { return false } }
	return true
}

@(private = "file")
collapse_iterative :: proc(inf: ^Inferred, a: runtime.Allocator, p: ^Summary) {
	stack, serr := make([dynamic]Join_Pair, 0, len(p.members), inf.allocator)
	if serr != nil { inf.failed = true; return }
	defer delete(stack)
	if collapse_into_stack(inf, a, p, &stack) { join_drain(inf, a, &stack) }
}

@(private = "file")
join_drain :: proc(inf: ^Inferred, a: runtime.Allocator, stack: ^[dynamic]Join_Pair) {
	for len(stack) > 0 && !inf.failed {
		pair := pop(stack)
		dst, src, offset := pair.dst, pair.src, pair.offset
		if dst == nil || src == nil { continue }
		dst.kinds += src.kinds
		dst.numbers += src.numbers
		dst.unranged ||= src.unranged
		if src.ranged && !dst.unranged { widen_range(inf, a, dst, src.low, src.high) }
		if src.strings > 0 {
			dst.min_chars = src.min_chars if dst.strings == 0 else min(dst.min_chars, src.min_chars)
			dst.max_chars = max(dst.max_chars, src.max_chars)
			dst.strings += src.strings
		}
		if src.arrays > 0 {
			dst.min_items = src.min_items if dst.arrays == 0 else min(dst.min_items, src.min_items)
			dst.max_items = max(dst.max_items, src.max_items)
			dst.arrays += src.arrays
		}
		if src.items != nil && !inf_push(inf, stack, Join_Pair{inf_child(inf, a, &dst.items), src.items, offset}) { return }
		dst.objects += src.objects
		dst.forms &= src.forms
		if src.collapsed && !dst.collapsed && !collapse_into_stack(inf, a, dst, stack) { return }
		if src.values != nil && !inf_push(inf, stack, Join_Pair{inf_child(inf, a, &dst.values), src.values, offset}) { return }
		for m in src.members {
			if dst.collapsed {
				if !inf_push(inf, stack, Join_Pair{inf_child(inf, a, &dst.values), m.at, offset}) { return }
				continue
			}
			at := -1
			for x, i in dst.members { if x.name == m.name { at = i; break } }
			if at < 0 {
				if len(dst.members) == MAX_NAMES {
					if !collapse_into_stack(inf, a, dst, stack) || !inf_push(inf, stack, Join_Pair{dst.values, m.at, offset}) { return }
					continue
				}
				nm, nerr := strings.clone(m.name, a)
				if nerr != nil { inf.failed = true; return }
				if !inf_push(inf, &dst.members, Member_Seen{name = nm, at = inf_fresh(inf, a), markup = m.markup, ordinal = m.ordinal + offset}) { return }
				at = len(dst.members) - 1
			}
			x := &dst.members[at]
			x.count += m.count
			x.collected ||= m.collected
			x.attributed ||= m.attributed
			x.ordinal = min(x.ordinal, m.ordinal + offset)
			if x.markup != m.markup { x.markup = .Any }
			if !inf_push(inf, stack, Join_Pair{x.at, m.at, offset}) { return }
		}
	}
}

@(private = "file")
alloc_desc_node :: proc(d: ^rules.Description) -> (rules.Node_Index, runtime.Allocator_Error) {
	idx := rules.Node_Index(len(d.nodes))
	_, err := append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
	return idx, err
}

@(private = "file")
desc_keep_text :: proc(d: ^rules.Description, s: string) -> (res: string, err: runtime.Allocator_Error) {
	t := strings.clone(s, d.allocator) or_return
	if _, aerr := append(&d.texts, t); aerr != nil { delete(t, d.allocator); return "", aerr }
	return t, nil
}

@(private = "file")
make_collected_node :: proc(d: ^rules.Description, item: rules.Node_Index, alone: bool) -> (res: rules.Node_Index, err: runtime.Allocator_Error) {
	at := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Array}, array = i32(len(d.arrays)), object = -1}) or_return
	append(&d.arrays, rules.Array{items = item}) or_return
	if !alone { return at, nil }
	arms := make([]rules.Node_Index, 2, d.allocator) or_return
	arms[0], arms[1] = item, at
	wrapper := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, any_of = arms}) or_return
	return wrapper, nil
}

@(private = "file")
ranges_of :: proc(d: ^rules.Description, p: ^Summary) -> (r: rules.Rules, ok: bool) {
	if p.ranged && !p.unranged {
		lo, e1 := desc_keep_text(d, p.low)
		hi, e2 := desc_keep_text(d, p.high)
		if e1 != nil || e2 != nil { return {}, false }
		r.minimum, r.maximum = lo, hi
	}
	if p.strings > 0 { r.min_length, r.max_length = p.min_chars, p.max_chars }
	if p.arrays > 0 { r.min_items, r.max_items = p.min_items, p.max_items }
	return r, true
}
