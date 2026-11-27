package diff

import "base:runtime"
import "stury:lib/core/tape"

// Semantic value classification, exact equality, and canonical hashing over `tape.Document` nodes (including virtual
// grouped arrays for XML `.Group` repeated elements). All traversals use explicit heap stacks (zero native recursion).

@(private)
Class :: enum u8 {
	Null,
	Bool,
	Number,
	String,
	Array,
	Object,
}

// A semantic value on one side of a diff: either a concrete `node`, or a virtual array `group` of 2+ nodes produced by
// repeated sibling keys under `tape.Duplicates.Group` (XML).
@(private)
Val :: struct {
	node:  tape.Node_Index,
	group: []tape.Node_Index,
}

@(private)
val_node :: #force_inline proc "contextless" (at: tape.Node_Index) -> Val {
	return {node = at}
}

@(private)
val_empty :: #force_inline proc "contextless" (v: Val) -> bool {
	return v.node == tape.NO_NODE && len(v.group) == 0
}

@(private)
val_first_node :: #force_inline proc "contextless" (v: Val) -> tape.Node_Index {
	return v.group[0] if len(v.group) > 0 else v.node
}

@(private)
is_grouped :: #force_inline proc "contextless" (doc: ^tape.Document) -> bool {
	return doc.format != nil && doc.format.dups == .Group
}

// Invariant: `at` is a valid index in `doc.nodes`.
@(private = "file")
class_of :: #force_inline proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> Class #no_bounds_check {
	#partial switch doc.nodes[at].kind {
	case .False, .True:
		return .Bool
	case .Number:
		return .Number
	case .String, .Plain, .Bytes:
		return .String
	case .Array:
		return .Array
	case .Object:
		return .Object
	}
	return .Null
}

// Invariant: when `len(v.group) == 0`, `v.node` is a valid index in `doc.nodes`.
@(private)
val_class :: #force_inline proc "contextless" (doc: ^tape.Document, v: Val) -> Class #no_bounds_check {
	if len(v.group) > 0 {
		return .Array
	}
	return class_of(doc, v.node)
}

@(private)
mix64 :: #force_inline proc "contextless" (x: u64) -> u64 {
	x := x
	x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ~ (x >> 27)) * 0x94d049bb133111eb
	return x ~ (x >> 31)
}

@(private)
hash_bytes :: proc "contextless" (s: string) -> u64 {
	h := u64(0xcbf29ce484222325)
	for b in transmute([]u8)s {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	return mix64(h)
}

// Reads the decoded text of scalar node `at` of `doc`, using `buf` when it fits or allocating in `alloc`.
// Invariant: `at` is a valid index in `doc.nodes`.
@(private, require_results)
read_node_text :: #force_inline proc(doc: ^tape.Document, at: tape.Node_Index, buf: []u8, alloc: runtime.Allocator) -> (string, []u8, bool) #no_bounds_check {
	return read_token_text(doc, doc.nodes[at], buf, alloc)
}

// Reads the decoded text of token `t` of `doc` (used for table header keys that are not in `doc.nodes`).
// Invariant: `t`'s span lies within `doc.src` (or `doc.ext.held`).
@(private, require_results)
read_token_text :: proc(doc: ^tape.Document, t: tape.Token, buf: []u8, alloc: runtime.Allocator) -> (text: string, owned: []u8, ok: bool) #no_bounds_check {
	if s, decoded := tape.node_text(doc, t, buf); decoded {
		return s, nil, true
	}
	room := tape.text_room(doc, t)
	if room <= len(buf) {
		return "", nil, false
	}
	tmp, err := make([]u8, room, alloc)
	if err != nil || len(tmp) < room {
		return "", nil, false
	}
	s, decoded := tape.node_text(doc, t, tmp)
	if !decoded {
		delete(tmp, alloc)
		return "", nil, false
	}
	return s, tmp, true
}

// Looks up member `name` of object `obj` on `side`. Under `tape.Duplicates.Group` (XML), a single occurrence returns
// `Val{node = child}`, and 2+ occurrences return `Val{node = tape.NO_NODE, group = items}` allocated in `d.scratch`.
@(private, require_results)
member_val :: proc(d: ^Differ, side: int, obj: tape.Node_Index, name: string) -> (v: Val, found: bool, err: Error) {
	if !is_grouped(d.docs[side]) {
		at, p := tape.member(d.readers[side], obj, name)
		return {node = at}, p == .Found, nil
	}
	c, p := tape.named(d.readers[side], obj, name)
	if p != .Found {
		return {}, false, nil
	}
	_, first, p1 := tape.next_child(d.readers[side], &c, .Group)
	if p1 != .Found {
		return {}, false, nil
	}
	_, second, p2 := tape.next_child(d.readers[side], &c, .Group)
	if p2 != .Found {
		return {node = first}, true, nil
	}
	items := make([dynamic]tape.Node_Index, 0, 4, d.scratch) or_return
	append(&items, first, second) or_return
	for {
		_, vn, pn := tape.next_child(d.readers[side], &c, .Group)
		if pn != .Found {
			break
		}
		append(&items, vn) or_return
	}
	return {node = tape.NO_NODE, group = items[:]}, true, nil
}

// ---- Scalar exact equality

// Invariant: `a` and `b` are valid indices in `d.docs[0].nodes` and `d.docs[1].nodes`.
@(private, require_results)
scalars_equal :: proc(d: ^Differ, a, b: tape.Node_Index) -> bool #no_bounds_check {
	ta, tb := d.docs[0].nodes[a], d.docs[1].nodes[b]
	ca, cb := class_of(d.docs[0], a), class_of(d.docs[1], b)
	if ca != cb {
		return false
	}
	#partial switch ca {
	case .Null:
		return true
	case .Bool:
		return ta.kind == tb.kind
	case .Number:
		return numbers_equal(d, a, b)
	case .String:
		ba, bb: [256]u8 = ---, ---
		sa, oa, oka := read_node_text(d.docs[0], a, ba[:], d.scratch)
		defer if oa != nil {
			delete(oa, d.scratch)
		}
		sb, ob, okb := read_node_text(d.docs[1], b, bb[:], d.scratch)
		defer if ob != nil {
			delete(ob, d.scratch)
		}
		return oka && okb && sa == sb
	}
	return false
}

// ---- Iterative memoized bottom-up hashing (zero native recursion)

@(private = "file")
HASH_SEED_OBJ :: u64(0x5A5A5A5A)
@(private = "file")
HASH_SEED_ARR :: u64(0xA5A5A5A5)

@(private)
Hash_Frame :: struct {
	c:        tape.Children,
	group:    []tape.Node_Index,
	gi:       int,
	acc:      u64,
	key_hash: u64,
	node:     tape.Node_Index, // `tape.NO_NODE` for a virtual XML `.Group` array
	is_obj:   bool,
}

@(private = "file")
nonzero_hash :: #force_inline proc "contextless" (h: u64) -> u64 {
	return h if h != 0 else 1
}

@(private = "file")
fold_hash :: #force_inline proc "contextless" (f: ^Hash_Frame, kh, vh: u64) {
	if f.is_obj {
		f.acc += mix64(kh ~ vh)
	} else {
		f.acc = mix64(f.acc ~ vh)
	}
}

// Invariant: `at` is a valid container index in `doc.nodes`.
@(private = "file")
is_empty_container :: #force_inline proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> bool #no_bounds_check {
	return doc.nodes[at].spelling & (tape.MAX_CHILDREN | tape.CONTAINER_PARTIAL) == 0
}

@(private = "file")
push_hash :: proc(d: ^Differ, side: int, stack: ^[dynamic]Hash_Frame, at: tape.Node_Index) -> bool #no_bounds_check {
	doc := d.docs[side]
	r := d.readers[side]
	ch, p, err := tape.children(r, at, d.scratch)
	if err != nil || p != .Found {
		return false
	}
	is_obj := doc.nodes[at].kind == .Object
	seed := HASH_SEED_OBJ if is_obj else HASH_SEED_ARR
	_, aerr := append(stack, Hash_Frame{node = at, c = ch, acc = seed, is_obj = is_obj})
	if aerr != nil {
		tape.destroy_children(&ch)
		return false
	}
	return true
}

@(private, require_results)
hash_val :: proc(d: ^Differ, side: int, v: Val, base_depth := 0) -> u64 {
	if len(v.group) == 0 {
		return hash_node(d, side, v.node, base_depth)
	}
	if base_depth >= d.opts.max_depth {
		d.too_deep = true
		return 1
	}
	acc := HASH_SEED_ARR
	for elem in v.group {
		vh := hash_node(d, side, elem, base_depth + 1)
		if d.too_deep {
			return 1
		}
		acc = mix64(acc ~ vh)
	}
	return nonzero_hash(mix64(acc ~ u64(len(v.group))))
}

// Invariant: `root` is a valid index in `d.docs[side].nodes` and `d.hashes[side]`; non-reentrant (reuses `d.hash_stack`).
@(private, require_results)
hash_node :: proc(d: ^Differ, side: int, root: tape.Node_Index, base_depth := 0) -> u64 #no_bounds_check {
	hashes := d.hashes[side]
	if h := hashes[root]; h != 0 {
		return h
	}
	doc := d.docs[side]
	r := d.readers[side]
	c0 := class_of(doc, root)
	if c0 != .Array && c0 != .Object {
		h := nonzero_hash(hash_scalar(d, doc, root))
		hashes[root] = h
		return h
	}
	// Empty `{}` / `[]` at `base_depth == max_depth` hashes immediately without triggering `too_deep`.
	if is_empty_container(doc, root) {
		done := nonzero_hash(mix64(HASH_SEED_OBJ if c0 == .Object else HASH_SEED_ARR))
		hashes[root] = done
		return done
	}
	if base_depth >= d.opts.max_depth {
		if n0, p0, e0 := tape.length(r, root, d.scratch); e0 == nil && p0 == .Found && n0 == 0 {
			done := nonzero_hash(mix64(HASH_SEED_OBJ if c0 == .Object else HASH_SEED_ARR))
			hashes[root] = done
			return done
		}
		d.too_deep = true
		return 1
	}

	stack := &d.hash_stack
	defer {
		for &f in stack {
			if f.node != tape.NO_NODE {
				tape.destroy_children(&f.c)
			}
		}
		clear(stack)
	}

	if !push_hash(d, side, stack, root) {
		return 1
	}

	grouped := is_grouped(doc)
	buf: [256]u8 = ---
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		k_node, v_node: tape.Node_Index
		p: tape.Presence
		count: u64
		if f.node == tape.NO_NODE {
			if f.gi < len(f.group) {
				v_node = f.group[f.gi]
				f.gi += 1
				p = .Found
			} else {
				p = .Missing
				count = u64(len(f.group))
			}
		} else {
			dups := tape.Duplicates.First if (f.is_obj && grouped) else tape.Duplicates.Default
			k_node, v_node, p = tape.next_child(r, &f.c, dups)
			count = u64(f.c.place)
		}

		if p != .Found {
			done := nonzero_hash(mix64(f.acc ~ count))
			if f.node != tape.NO_NODE {
				hashes[f.node] = done
				tape.destroy_children(&f.c)
			}
			pop(stack)
			if len(stack) == 0 {
				return done
			}
			parent := &stack[len(stack) - 1]
			fold_hash(parent, parent.key_hash, done)
			continue
		}

		kh: u64
		if f.is_obj {
			ks, owned, ok := read_member_key(d, side, f.c, k_node, buf[:])
			if ok {
				kh = hash_bytes(ks)
				if grouped && !f.c.once {
					mv, found, merr := member_val(d, side, f.node, ks)
					if owned != nil {
						delete(owned, d.scratch)
					}
					if merr != nil || !found {
						return 1
					}
					if len(mv.group) > 0 {
						if base_depth + len(stack) >= d.opts.max_depth {
							d.too_deep = true
							return 1
						}
						f.key_hash = kh
						if _, aerr := append(stack, Hash_Frame{node = tape.NO_NODE, group = mv.group, acc = HASH_SEED_ARR}); aerr != nil {
							return 1
						}
						continue
					}
					v_node = mv.node
				} else if owned != nil {
					delete(owned, d.scratch)
				}
			} else {
				if owned != nil {
					delete(owned, d.scratch)
				}
				kh = 1
			}
		}

		if vh := hashes[v_node]; vh != 0 {
			fold_hash(f, kh, vh)
			continue
		}

		vc := class_of(doc, v_node)
		if vc != .Array && vc != .Object {
			vh := nonzero_hash(hash_scalar(d, doc, v_node))
			hashes[v_node] = vh
			fold_hash(f, kh, vh)
			continue
		}
		if is_empty_container(doc, v_node) {
			vh := nonzero_hash(mix64(HASH_SEED_OBJ if vc == .Object else HASH_SEED_ARR))
			hashes[v_node] = vh
			fold_hash(f, kh, vh)
			continue
		}

		if base_depth + len(stack) >= d.opts.max_depth {
			if nv, pv, ev := tape.length(r, v_node, d.scratch); ev == nil && pv == .Found && nv == 0 {
				vh := nonzero_hash(mix64(HASH_SEED_OBJ if vc == .Object else HASH_SEED_ARR))
				hashes[v_node] = vh
				fold_hash(f, kh, vh)
				continue
			}
			d.too_deep = true
			return 1
		}
		f.key_hash = kh
		if !push_hash(d, side, stack, v_node) {
			return 1
		}
	}
	return hashes[root]
}

// Invariant: `at` is a valid index in `doc.nodes`.
@(private = "file")
hash_scalar :: proc(d: ^Differ, doc: ^tape.Document, at: tape.Node_Index) -> u64 #no_bounds_check {
	t := doc.nodes[at]
	#partial switch t.kind {
	case .Null:
		return mix64(1)
	case .False:
		return mix64(2)
	case .True:
		return mix64(3)
	case .Number:
		return hash_number(d, doc, at)
	case .String, .Plain, .Bytes:
		buf: [256]u8 = ---
		s, owned, ok := read_node_text(doc, at, buf[:], d.scratch)
		defer if owned != nil {
			delete(owned, d.scratch)
		}
		if !ok {
			return 1
		}
		return hash_bytes(s)
	}
	return mix64(1)
}

@(private, require_results)
read_member_key :: proc(d: ^Differ, side: int, c: tape.Children, k_node: tape.Node_Index, buf: []u8) -> (string, []u8, bool) {
	if k_node != tape.NO_NODE {
		return read_node_text(d.docs[side], k_node, buf, d.scratch)
	}
	return read_token_text(d.docs[side], tape.cell_key(d.readers[side], c), buf, d.scratch)
}

// ---- Iterative deep equality (zero native recursion)

@(private)
Eq_Frame :: struct {
	a, b:     tape.Node_Index,
	ca, cb:   tape.Children,
	ga, gb:   []tape.Node_Index,
	gia, gib: int,
	is_obj:   bool,
	has_ca:   bool,
	has_cb:   bool,
}

@(private = "file")
destroy_eq_frame :: #force_inline proc(f: ^Eq_Frame) {
	if f.has_ca {
		tape.destroy_children(&f.ca)
	}
	if f.has_cb {
		tape.destroy_children(&f.cb)
	}
}

@(private = "file")
val_len :: proc(d: ^Differ, side: int, v: Val) -> (int, bool) {
	if len(v.group) > 0 {
		return len(v.group), true
	}
	n, p, err := tape.length(d.readers[side], v.node, d.scratch)
	return n, err == nil && p == .Found
}

// Invariant: `x` and `y` hold valid container nodes in `d.docs[0]` and `d.docs[1]`.
@(private = "file")
open_eq :: proc(d: ^Differ, stack: ^[dynamic]Eq_Frame, x, y: Val, depth: int) -> (equal_so_far, opened: bool) #no_bounds_check {
	na, oka := val_len(d, 0, x)
	nb, okb := val_len(d, 1, y)
	if !oka || !okb || na != nb {
		return false, false
	}
	// Empty `{}` / `[]` are equal even at `depth == max_depth` without marking `too_deep`.
	if na == 0 {
		return true, false
	}
	if depth >= d.opts.max_depth {
		d.too_deep = true
		return false, false
	}
	is_obj := len(x.group) == 0 && d.docs[0].nodes[x.node].kind == .Object
	f := Eq_Frame{a = x.node, b = y.node, ga = x.group, gb = y.group, is_obj = is_obj}
	if len(x.group) == 0 {
		ch_a, p1, e1 := tape.children(d.readers[0], x.node, d.scratch)
		if e1 != nil || p1 != .Found {
			return false, false
		}
		f.ca, f.has_ca = ch_a, true
	}
	if !is_obj && len(y.group) == 0 {
		ch_b, p2, e2 := tape.children(d.readers[1], y.node, d.scratch)
		if e2 != nil || p2 != .Found {
			destroy_eq_frame(&f)
			return false, false
		}
		f.cb, f.has_cb = ch_b, true
	}
	if _, aerr := append(stack, f); aerr != nil {
		destroy_eq_frame(&f)
		return false, false
	}
	return true, true
}

@(private, require_results)
vals_equal :: proc(d: ^Differ, a, b: Val, base_depth := 0) -> bool {
	if d.too_deep {
		return false
	}
	if hash_val(d, 0, a, base_depth) != hash_val(d, 1, b, base_depth) {
		return false
	}
	if d.too_deep {
		return false
	}
	return vals_equal_exact(d, a, b, base_depth)
}

// Invariant: `a` and `b` hold valid nodes in `d.docs[0]` and `d.docs[1]`; non-reentrant (reuses `d.eq_stack`).
@(private, require_results)
vals_equal_exact :: proc(d: ^Differ, a, b: Val, base_depth := 0) -> bool #no_bounds_check {
	ca, cb := val_class(d.docs[0], a), val_class(d.docs[1], b)
	if ca != cb {
		return false
	}
	if ca != .Array && ca != .Object {
		return scalars_equal(d, a.node, b.node)
	}

	stack := &d.eq_stack
	defer {
		for &f in stack {
			destroy_eq_frame(&f)
		}
		clear(stack)
	}

	eq0, opened0 := open_eq(d, stack, a, b, base_depth)
	if !eq0 || !opened0 {
		return eq0
	}

	grouped0 := is_grouped(d.docs[0])
	buf: [256]u8 = ---
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		va, vb: Val
		if !f.is_obj {
			x, y: tape.Node_Index
			px, py: tape.Presence
			if len(f.ga) > 0 {
				if f.gia < len(f.ga) {
					x, px = f.ga[f.gia], .Found
					f.gia += 1
				} else {
					px = .Missing
				}
			} else {
				_, x, px = tape.next_child(d.readers[0], &f.ca)
			}
			if len(f.gb) > 0 {
				if f.gib < len(f.gb) {
					y, py = f.gb[f.gib], .Found
					f.gib += 1
				} else {
					py = .Missing
				}
			} else {
				_, y, py = tape.next_child(d.readers[1], &f.cb)
			}
			if px != .Found || py != .Found {
				if px != py {
					return false
				}
				destroy_eq_frame(f)
				pop(stack)
				continue
			}
			va, vb = val_node(x), val_node(y)
		} else {
			dups := tape.Duplicates.First if grouped0 else tape.Duplicates.Default
			kn, x, px := tape.next_child(d.readers[0], &f.ca, dups)
			if px != .Found {
				destroy_eq_frame(f)
				pop(stack)
				continue
			}
			ks, owned, ok := read_member_key(d, 0, f.ca, kn, buf[:])
			if !ok {
				if owned != nil {
					delete(owned, d.scratch)
				}
				return false
			}
			if grouped0 && !f.ca.once {
				mva, found_a, erra := member_val(d, 0, f.a, ks)
				if erra != nil || !found_a {
					if owned != nil {
						delete(owned, d.scratch)
					}
					return false
				}
				va = mva
			} else {
				va = val_node(x)
			}
			mvb, found_b, errb := member_val(d, 1, f.b, ks)
			if owned != nil {
				delete(owned, d.scratch)
			}
			if errb != nil || !found_b {
				return false
			}
			vb = mvb
		}

		c1, c2 := val_class(d.docs[0], va), val_class(d.docs[1], vb)
		if c1 != c2 {
			return false
		}
		if c1 != .Array && c1 != .Object {
			if !scalars_equal(d, va.node, vb.node) {
				return false
			}
			continue
		}
		if len(va.group) == 0 && len(vb.group) == 0 {
			if ha, hb := d.hashes[0][va.node], d.hashes[1][vb.node]; ha != 0 && hb != 0 && ha != hb {
				return false
			}
		}
		eq, _ := open_eq(d, stack, va, vb, base_depth + len(stack))
		if !eq {
			return false
		}
	}
	return true
}
