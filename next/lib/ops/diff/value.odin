package diff

import "base:runtime"
import "core:math"
import "core:strconv"
import "stury:lib/base/spell"
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

@(private)
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
hash_bytes :: proc "contextless" (s: string) -> u64 #no_bounds_check {
	h := u64(0xcbf29ce484222325)
	for b in transmute([]u8)s {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	return mix64(h)
}

// Reads the decoded text of scalar node `at` of `doc`, using `buf` when it fits or allocating in `alloc`.
@(private)
read_node_text :: #force_inline proc(doc: ^tape.Document, at: tape.Node_Index, buf: []u8, alloc: runtime.Allocator) -> (string, []u8, bool) #no_bounds_check {
	return read_token_text(doc, doc.nodes[at], buf, alloc)
}

// Reads the decoded text of token `t` of `doc` (used for table header keys that are not in `doc.nodes`).
@(private)
read_token_text :: proc(doc: ^tape.Document, t: tape.Token, buf: []u8, alloc: runtime.Allocator) -> (text: string, owned: []u8, ok: bool) #no_bounds_check {
	if (t.kind == .String || t.kind == .Plain) && !tape.text_decodes(t) && .Held not_in doc.flags {
		return string(doc.src[t.lo:][:t.n]), nil, true
	}
	room := tape.text_room(doc, t)
	if room == 0 {
		return string(tape.span_bytes(doc, t.lo, t.n)), nil, true
	}
	if room <= len(buf) {
		s, decoded := tape.node_text(doc, t, buf[:room])
		return s, nil, decoded
	}
	tmp, err := make([]u8, room, alloc)
	if err != nil {
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
@(private)
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
	items := make([dynamic]tape.Node_Index, 0, 4, d.scratch)
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

// ---- Exact mathematical number comparison and canonical hashing

@(private = "file")
TWO_63 :: f64(1 << 63)
@(private = "file")
TWO_64 :: f64(1 << 64)
@(private = "file")
HASH_MOD :: u64((1 << 61) - 1)

@(private = "file")
mod_hash_p :: #force_inline proc "contextless" (v: u128) -> u64 {
	r := (v & u128(HASH_MOD)) + (v >> 61)
	r = (r & u128(HASH_MOD)) + (r >> 61)
	return 0 if u64(r) == HASH_MOD else u64(r)
}

@(private = "file")
hash_wide_int :: #force_inline proc "contextless" (neg: bool, rem: u64) -> u64 {
	return mix64(rem ~ (0x5555555555555555 if neg else 0xAAAAAAAAAAAAAAAA))
}

@(private = "file")
Num_Kind :: enum u8 {
	Int,
	Uint,
	Float,
	Wide_Int,
	Raw_Bytes, // unspellable binary number past format's decode limit (compared by exact raw bytes)
}

@(private = "file")
Num_Val :: struct {
	kind: Num_Kind,
	i:    i64,
	u:    u64,
	f:    f64,
	dec:  string,
}

@(private = "file")
wide_double :: proc "contextless" (text: []u8) -> f64 {
	neg := len(text) > 0 && text[0] == '-'
	big_order := true
	for c, i in text {
		if c | 0x20 == 'e' {
			big_order = i + 1 >= len(text) || text[i + 1] != '-'
			break
		}
	}
	f := math.inf_f64(1) if big_order else 0
	return -f if neg else f
}

@(private = "file")
is_plain_int_dec :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	i := 0
	if s[0] == '-' {
		i = 1
	}
	if i >= len(s) {
		return false
	}
	for c in transmute([]u8)s[i:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

@(private = "file")
float_num :: #force_inline proc "contextless" (f: f64) -> Num_Val {
	if f == math.trunc(f) && !math.is_inf(f) {
		if f >= -TWO_63 && f < TWO_63 {
			return {kind = .Int, i = i64(f)}
		}
		if f >= TWO_63 && f < TWO_64 {
			return {kind = .Uint, u = u64(f)}
		}
	}
	return {kind = .Float, f = f}
}

// Extracts canonical mathematical representation of a number node. When decoding a binary `.Wide` number requires heap
// space beyond `buf`, `owned` holds the temporary buffer for the caller to free in `alloc`.
@(private = "file")
node_num :: proc(doc: ^tape.Document, at: tape.Node_Index, buf: []u8, alloc: runtime.Allocator) -> (val: Num_Val, owned: []u8) #no_bounds_check {
	n, _ := tape.node_number(doc, at)
	is_binary := doc.format != nil && .Binary in doc.format.caps
	switch n.kind {
	case .Int:
		return {kind = .Int, i = i64(n.bits)}, nil
	case .Uint:
		if n.bits <= u64(max(i64)) {
			return {kind = .Int, i = i64(n.bits)}, nil
		}
		return {kind = .Uint, u = n.bits}, nil
	case .Float:
		if !is_binary {
			form, _ := tape.number_form(doc, at)
			if form.frac_digits == 0 && !form.exponent && !form.point && form.kind == 0 {
				t := doc.nodes[at]
				return {kind = .Wide_Int, dec = string(tape.span_bytes(doc, t.lo, t.n))}, nil
			}
		}
		return float_num(transmute(f64)n.bits), nil
	case .Wide:
		t := doc.nodes[at]
		if is_binary {
			room := tape.text_room(doc, at)
			if room == 0 {
				return {kind = .Raw_Bytes, dec = string(tape.span_bytes(doc, t.lo, t.n))}, nil
			}
			s: string
			decoded: bool
			if room <= len(buf) {
				s, decoded = tape.node_text(doc, at, buf[:room])
			} else {
				tmp, aerr := make([]u8, room, alloc)
				if aerr == nil {
					s, decoded = tape.node_text(doc, at, tmp)
					if decoded {
						owned = tmp
					} else {
						delete(tmp, alloc)
					}
				}
			}
			if !decoded {
				return {kind = .Raw_Bytes, dec = string(tape.span_bytes(doc, t.lo, t.n))}, nil
			}
			if is_plain_int_dec(s) {
				return {kind = .Wide_Int, dec = s}, owned
			}
			sn, valid := spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
			defer if owned != nil {
				delete(owned, alloc)
				owned = nil
			}
			if valid {
				switch sn.kind {
				case .Int:
					return {kind = .Int, i = i64(sn.bits)}, nil
				case .Uint:
					if sn.bits <= u64(max(i64)) {
						return {kind = .Int, i = i64(sn.bits)}, nil
					}
					return {kind = .Uint, u = sn.bits}, nil
				case .Float:
					return float_num(transmute(f64)sn.bits), nil
				case .Wide:
				}
			}
			return {kind = .Float, f = wide_double(transmute([]u8)s)}, nil
		}
		form, _ := tape.number_form(doc, at)
		raw := tape.span_bytes(doc, t.lo, t.n)
		if form.frac_digits == 0 && !form.exponent && !form.point && form.kind == 0 {
			return {kind = .Wide_Int, dec = string(raw)}, nil
		}
		return {kind = .Float, f = wide_double(raw)}, nil
	}
	return {kind = .Int, i = 0}, nil
}

@(private = "file")
decimal_parts :: proc "contextless" (s: string) -> (neg: bool, digits: string) {
	t := s
	if len(t) > 0 && t[0] == '-' {
		neg = true
		t = t[1:]
	}
	for len(t) > 1 && t[0] == '0' {
		t = t[1:]
	}
	if t == "0" {
		neg = false
	}
	return neg, t
}

@(private = "file")
decimal_equal :: proc "contextless" (a, b: string) -> bool {
	an, ad := decimal_parts(a)
	bn, bd := decimal_parts(b)
	return an == bn && ad == bd
}

@(private = "file")
numbers_equal :: proc(d: ^Differ, a, b: tape.Node_Index) -> bool {
	ba, bb: [256]u8
	va, oa := node_num(d.docs[0], a, ba[:], d.scratch)
	defer if oa != nil {
		delete(oa, d.scratch)
	}
	vb, ob := node_num(d.docs[1], b, bb[:], d.scratch)
	defer if ob != nil {
		delete(ob, d.scratch)
	}
	if va.kind == .Float && math.is_nan(va.f) || vb.kind == .Float && math.is_nan(vb.f) {
		return false
	}
	if va.kind == vb.kind {
		switch va.kind {
		case .Int:
			return va.i == vb.i
		case .Uint:
			return va.u == vb.u
		case .Float:
			return va.f == vb.f
		case .Wide_Int:
			return decimal_equal(va.dec, vb.dec)
		case .Raw_Bytes:
			return va.dec == vb.dec
		}
	}
	// Cross-kind equality: `.Wide_Int` vs `.Float` (exact large integer float), `.Uint`, or `.Int`.
	if va.kind == .Wide_Int && vb.kind == .Float {
		return wide_int_equals_float(va.dec, vb.f)
	}
	if vb.kind == .Wide_Int && va.kind == .Float {
		return wide_int_equals_float(vb.dec, va.f)
	}
	if va.kind == .Wide_Int && vb.kind == .Uint {
		buf: [24]u8
		return decimal_equal(va.dec, strconv.write_uint(buf[:], vb.u, 10))
	}
	if vb.kind == .Wide_Int && va.kind == .Uint {
		buf: [24]u8
		return decimal_equal(vb.dec, strconv.write_uint(buf[:], va.u, 10))
	}
	if va.kind == .Wide_Int && vb.kind == .Int {
		buf: [24]u8
		return decimal_equal(va.dec, strconv.write_int(buf[:], vb.i, 10))
	}
	if vb.kind == .Wide_Int && va.kind == .Int {
		buf: [24]u8
		return decimal_equal(vb.dec, strconv.write_int(buf[:], va.i, 10))
	}
	return false
}

@(private = "file")
wide_int_equals_float :: proc(dec: string, f: f64) -> bool {
	if math.is_nan(f) || math.is_inf(f) || f != math.trunc(f) {
		return false
	}
	if abs(f) < TWO_63 {
		return false
	}
	buf: [320]u8
	fd := strconv.write_float(buf[:], f, 'f', 0, 64, {})
	return decimal_equal(dec, fd)
}

@(private = "file")
hash_number :: proc(d: ^Differ, doc: ^tape.Document, at: tape.Node_Index) -> u64 {
	buf: [256]u8
	v, owned := node_num(doc, at, buf[:], d.scratch)
	defer if owned != nil {
		delete(owned, d.scratch)
	}
	switch v.kind {
	case .Int:
		return mix64(u64(v.i))
	case .Uint:
		return hash_wide_int(false, mod_hash_p(u128(v.u)))
	case .Wide_Int:
		neg, digits := decimal_parts(v.dec)
		acc: u64
		for c in transmute([]u8)digits {
			acc = mod_hash_p(u128(acc) * 10 + u128(c - '0'))
		}
		return hash_wide_int(neg, acc)
	case .Raw_Bytes:
		return hash_bytes(v.dec)
	case .Float:
		f := v.f
		if f == 0 {
			return mix64(0)
		}
		if f == math.trunc(f) && !math.is_inf(f) {
			bits := transmute(u64)abs(f)
			m := (u64(1) << 52) | (bits & ((u64(1) << 52) - 1))
			exp := int((bits >> 52) & 0x7FF) - 1023 - 52
			rem := mod_hash_p(u128(m))
			if exp > 0 {
				// Multiply by 2^exp mod (2^61 - 1): 2^61 == 1 mod (2^61 - 1).
				shift := uint(exp % 61)
				rem = mod_hash_p(u128(rem) << shift)
			}
			return hash_wide_int(f < 0, rem)
		}
		return mix64(transmute(u64)f)
	}
	return 1
}

// ---- Scalar exact equality

@(private)
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
		ba, bb: [256]u8
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

@(private = "file")
Hash_Frame :: struct {
	node:     tape.Node_Index, // `tape.NO_NODE` for a virtual XML `.Group` array
	c:        tape.Children,
	group:    []tape.Node_Index,
	gi:       int,
	acc:      u64,
	is_obj:   bool,
	key_hash: u64,
}

@(private)
hash_val :: proc(d: ^Differ, side: int, v: Val, base_depth := 0) -> u64 #no_bounds_check {
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
	done := mix64(acc ~ u64(len(v.group)))
	return done if done != 0 else 1
}

@(private)
hash_node :: proc(d: ^Differ, side: int, root: tape.Node_Index, base_depth := 0) -> u64 #no_bounds_check {
	hashes := d.hashes[side]
	if h := hashes[root]; h != 0 {
		return h
	}
	doc := d.docs[side]
	r := d.readers[side]
	c0 := class_of(doc, root)
	if c0 != .Array && c0 != .Object {
		h := hash_scalar(d, doc, root)
		hashes[root] = h if h != 0 else 1
		return hashes[root]
	}
	// Empty `{}` / `[]` at `base_depth == max_depth` hashes immediately without triggering `too_deep`.
	if n0, p0, e0 := tape.length(r, root, d.scratch); e0 == nil && p0 == .Found && n0 == 0 {
		seed := HASH_SEED_OBJ if c0 == .Object else HASH_SEED_ARR
		done := mix64(seed)
		hashes[root] = done if done != 0 else 1
		return hashes[root]
	}
	if base_depth >= d.opts.max_depth {
		d.too_deep = true
		return 1
	}

	stack := make([dynamic]Hash_Frame, 0, 16, d.scratch)
	defer {
		for &f in stack {
			if f.node != tape.NO_NODE {
				tape.destroy_children(&f.c)
			}
		}
		delete(stack)
	}

	push_hash :: proc(d: ^Differ, side: int, stack: ^[dynamic]Hash_Frame, at: tape.Node_Index) -> bool {
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

	if !push_hash(d, side, &stack, root) {
		return 1
	}

	grouped := is_grouped(doc)
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
			done := mix64(f.acc ~ count)
			if done == 0 {
				done = 1
			}
			if f.node != tape.NO_NODE {
				hashes[f.node] = done
				tape.destroy_children(&f.c)
			}
			pop(&stack)
			if len(stack) == 0 {
				return done
			}
			parent := &stack[len(stack) - 1]
			if parent.is_obj {
				parent.acc += mix64(parent.key_hash ~ done)
			} else {
				parent.acc = mix64(parent.acc ~ done)
			}
			continue
		}

		kh: u64
		if f.is_obj {
			buf: [256]u8
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
						if _, aerr := append(&stack, Hash_Frame{node = tape.NO_NODE, group = mv.group, acc = HASH_SEED_ARR}); aerr != nil {
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
			if f.is_obj {
				f.acc += mix64(kh ~ vh)
			} else {
				f.acc = mix64(f.acc ~ vh)
			}
			continue
		}

		vc := class_of(doc, v_node)
		if vc != .Array && vc != .Object {
			vh := hash_scalar(d, doc, v_node)
			if vh == 0 {
				vh = 1
			}
			hashes[v_node] = vh
			if f.is_obj {
				f.acc += mix64(kh ~ vh)
			} else {
				f.acc = mix64(f.acc ~ vh)
			}
			continue
		}
		if nv, pv, ev := tape.length(r, v_node, d.scratch); ev == nil && pv == .Found && nv == 0 {
			seed := HASH_SEED_OBJ if vc == .Object else HASH_SEED_ARR
			vh := mix64(seed)
			if vh == 0 {
				vh = 1
			}
			hashes[v_node] = vh
			if f.is_obj {
				f.acc += mix64(kh ~ vh)
			} else {
				f.acc = mix64(f.acc ~ vh)
			}
			continue
		}

		if base_depth + len(stack) >= d.opts.max_depth {
			d.too_deep = true
			return 1
		}
		f.key_hash = kh
		if !push_hash(d, side, &stack, v_node) {
			return 1
		}
	}
	return hashes[root]
}

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
		buf: [256]u8
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

@(private)
read_member_key :: proc(d: ^Differ, side: int, c: tape.Children, k_node: tape.Node_Index, buf: []u8) -> (string, []u8, bool) {
	if k_node != tape.NO_NODE {
		return read_node_text(d.docs[side], k_node, buf, d.scratch)
	}
	return read_token_text(d.docs[side], tape.cell_key(d.readers[side], c), buf, d.scratch)
}

// ---- Iterative deep equality (zero native recursion)

@(private = "file")
Eq_Frame :: struct {
	a, b:     tape.Node_Index,
	ca, cb:   tape.Children,
	ga, gb:   []tape.Node_Index,
	gia, gib: int,
	is_obj:   bool,
	has_ca:   bool,
	has_cb:   bool,
}

@(private)
nodes_equal :: #force_inline proc(d: ^Differ, a, b: tape.Node_Index, base_depth := 0) -> bool {
	return vals_equal(d, val_node(a), val_node(b), base_depth)
}

@(private)
nodes_equal_exact :: #force_inline proc(d: ^Differ, a, b: tape.Node_Index, base_depth := 0) -> bool {
	return vals_equal_exact(d, val_node(a), val_node(b), base_depth)
}

@(private)
vals_equal :: proc(d: ^Differ, a, b: Val, base_depth := 0) -> bool #no_bounds_check {
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

@(private)
vals_equal_exact :: proc(d: ^Differ, a, b: Val, base_depth := 0) -> bool #no_bounds_check {
	ca, cb := val_class(d.docs[0], a), val_class(d.docs[1], b)
	if ca != cb {
		return false
	}
	if ca != .Array && ca != .Object {
		return scalars_equal(d, a.node, b.node)
	}

	stack := make([dynamic]Eq_Frame, 0, 16, d.scratch)
	defer {
		for &f in stack {
			if f.has_ca {
				tape.destroy_children(&f.ca)
			}
			if f.has_cb {
				tape.destroy_children(&f.cb)
			}
		}
		delete(stack)
	}

	val_len :: proc(d: ^Differ, side: int, v: Val) -> (int, bool) {
		if len(v.group) > 0 {
			return len(v.group), true
		}
		n, p, err := tape.length(d.readers[side], v.node, d.scratch)
		return n, err == nil && p == .Found
	}

	open_eq :: proc(d: ^Differ, stack: ^[dynamic]Eq_Frame, x, y: Val, depth: int) -> (equal_so_far, opened: bool) {
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
				if f.has_ca {
					tape.destroy_children(&f.ca)
				}
				return false, false
			}
			f.cb, f.has_cb = ch_b, true
		}
		if _, aerr := append(stack, f); aerr != nil {
			if f.has_ca {
				tape.destroy_children(&f.ca)
			}
			if f.has_cb {
				tape.destroy_children(&f.cb)
			}
			return false, false
		}
		return true, true
	}

	eq0, opened0 := open_eq(d, &stack, a, b, base_depth)
	if !eq0 || !opened0 {
		return eq0
	}

	grouped0 := is_grouped(d.docs[0])
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
				if f.has_ca {
					tape.destroy_children(&f.ca)
				}
				if f.has_cb {
					tape.destroy_children(&f.cb)
				}
				pop(&stack)
				continue
			}
			va, vb = val_node(x), val_node(y)
		} else {
			dups := tape.Duplicates.First if grouped0 else tape.Duplicates.Default
			kn, x, px := tape.next_child(d.readers[0], &f.ca, dups)
			if px != .Found {
				tape.destroy_children(&f.ca)
				pop(&stack)
				continue
			}
			buf: [256]u8
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
		eq, _ := open_eq(d, &stack, va, vb, base_depth + len(stack))
		if !eq {
			return false
		}
	}
	return true
}
