package rules

import "base:runtime"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"

// Layer-3 JSON-model value held by a Description's `enum`, `const`, `default`, or `examples`:
// either a zero-copy `Node_Ref` into a parsed `tape.Document`, or a self-contained value for programmatic
// construction and Odin struct reflection (`lib/schema/model`).

Null :: struct {}

// Exact decimal text of a number (e.g., `Number_Text{"1.0"}`, `Number_Text{"1e100"}`).
Number_Text :: struct {
	text: string,
}

// A node inside a parsed `tape.Document`.
Node_Ref :: struct {
	doc:  ^tape.Document,
	node: tape.Node_Index,
}

// One named member of a programmatic object `Value`.
Member_Value :: struct {
	key:   string,
	value: Value,
}

Value :: union {
	Null,
	bool,
	i64,
	u64,
	f64,
	Number_Text,
	string,
	[]Value,
	[]Member_Value,
	Node_Ref,
}

Value_Kind :: enum u8 {
	Null,
	False,
	True,
	Number,
	String,
	Array,
	Object,
}

// The JSON-model kind of `v`. A `nil` `Value` is `.Null`.
value_kind :: proc "contextless" (v: Value) -> Value_Kind {
	switch x in v {
	case Null:
		return .Null
	case bool:
		return .True if x else .False
	case i64, u64, f64, Number_Text:
		return .Number
	case string:
		return .String
	case []Value:
		return .Array
	case []Member_Value:
		return .Object
	case Node_Ref:
		if x.doc == nil || int(x.node) >= len(x.doc.nodes) {
			return .Null
		}
		#partial switch x.doc.nodes[x.node].kind {
		case .Null:
			return .Null
		case .False:
			return .False
		case .True:
			return .True
		case .Number:
			return .Number
		case .String, .Plain, .Bytes:
			return .String
		case .Array:
			return .Array
		case .Object:
			return .Object
		}
	}
	return .Null
}

@(private)
value_to_tape_kind :: proc "contextless" (k: Value_Kind) -> tape.Kind {
	switch k {
	case .Null:   return .Null
	case .False:  return .False
	case .True:   return .True
	case .Number: return .Number
	case .String: return .String
	case .Array:  return .Array
	case .Object: return .Object
	}
	return .Null
}

// Decoded text of string value `v`, using `buf` when it fits or allocating from `allocator` (`owned = true`).
value_string :: proc(v: Value, buf: []u8, allocator := context.allocator) -> (s: string, owned, ok: bool) {
	#partial switch x in v {
	case string:
		return x, false, true
	case Node_Ref:
		if x.doc == nil || int(x.node) >= len(x.doc.nodes) {
			return "", false, false
		}
		return node_text_alloc(x.doc, x.doc.nodes[x.node], buf, allocator)
	}
	return "", false, false
}

// Exact decimal text of numeric value `v`, using `buf` when it fits or allocating from `allocator` (`owned = true`).
// Returns `ok = false` for non-finite floats (`NaN`, `±Inf`) or unspellable CBOR bignums (>8 KiB).
value_number_text :: proc(v: Value, buf: []u8, allocator := context.allocator) -> (s: string, owned, ok: bool) {
	#partial switch x in v {
	case i64:
		return strconv.write_int(buf, x, 10), false, true
	case u64:
		return strconv.write_uint(buf, x, 10), false, true
	case f64:
		if math.is_nan(x) || math.is_inf(x, 0) {
			return "", false, false
		}
		return strconv.write_float(buf, x, 'g', -1, 64, {}), false, true
	case Number_Text:
		if !valid_decimal_text(x.text) {
			return normalize_decimal_text(x.text, buf, allocator)
		}
		return x.text, false, true
	case Node_Ref:
		if x.doc == nil || int(x.node) >= len(x.doc.nodes) {
			return "", false, false
		}
		t := x.doc.nodes[x.node]
		is_bin := x.doc.format != nil && .Binary in x.doc.format.caps
		if (t.spelling != 0 || is_bin) && x.doc.format != nil && x.doc.format.number != nil {
			if num, nok := tape.node_number(x.doc, x.node); nok {
				switch num.kind {
				case .Int:
					return strconv.write_int(buf, i64(num.bits), 10), false, true
				case .Uint:
					return strconv.write_uint(buf, num.bits, 10), false, true
				case .Float:
					f := transmute(f64)num.bits
					if math.is_nan(f) || math.is_inf(f, 0) {
						return "", false, false
					}
					if is_bin {
						return strconv.write_float(buf, f, 'g', -1, 64, {}), false, true
					}
					raw_s, raw_own, raw_ok := node_text_alloc(x.doc, t, buf, allocator)
					if !raw_ok {
						return strconv.write_float(buf, f, 'g', -1, 64, {}), false, true
					}
					if valid_decimal_text(raw_s) {
						return raw_s, raw_own, true
					}
					ns, nown, nok2 := normalize_decimal_text(raw_s, nil if raw_own else buf, allocator)
					if raw_own {
						delete(raw_s, allocator)
					}
					if nok2 {
						return ns, nown, true
					}
					return "", false, false
				case .Wide:
					// Fall through to exact format decode (or unspellable CBOR bignum if room == 0).
				}
			}
		}
		raw_s, raw_own, raw_ok := node_text_alloc(x.doc, t, buf, allocator)
		if !raw_ok {
			return "", false, false
		}
		if valid_decimal_text(raw_s) {
			return raw_s, raw_own, true
		}
		ns, nown, nok2 := normalize_decimal_text(raw_s, nil if raw_own else buf, allocator)
		if raw_own {
			delete(raw_s, allocator)
		}
		if nok2 {
			return ns, nown, true
		}
		return "", false, false
	}
	return "", false, false
}

// Non-finite float classification (`0` = finite/other, `1` = +Inf, `-1` = -Inf, `2` = NaN)
// or exact CBOR raw bytes for unspellable >8 KiB bignums.
@(private = "file")
number_special :: proc(v: Value) -> (nonfinite: i8, raw_cbor: []u8) {
	#partial switch x in v {
	case f64:
		if math.is_nan(x) {
			return 2, nil
		}
		if math.is_inf(x, 1) {
			return 1, nil
		}
		if math.is_inf(x, -1) {
			return -1, nil
		}
	case Node_Ref:
		if x.doc == nil || int(x.node) >= len(x.doc.nodes) {
			return 0, nil
		}
		t := x.doc.nodes[x.node]
		if x.doc.format != nil && x.doc.format.number != nil {
			if num, nok := tape.node_number(x.doc, x.node); nok && num.kind == .Float {
				f := transmute(f64)num.bits
				if math.is_nan(f) {
					return 2, nil
				}
				if math.is_inf(f, 1) {
					return 1, nil
				}
				if math.is_inf(f, -1) {
					return -1, nil
				}
			}
		}
		if x.doc.format != nil && .Binary in x.doc.format.caps && int(t.lo) + int(t.n) <= len(x.doc.src) {
			return 0, x.doc.src[t.lo:][:t.n]
		}
	}
	return 0, nil
}

// Decodes token `t` of `doc` into `buf` if it fits, else allocates exact-sized string from `allocator`.
@(private)
node_text_alloc :: proc(doc: ^tape.Document, t: tape.Token, buf: []u8, allocator: runtime.Allocator) -> (s: string, owned, ok: bool) {
	if s, ok = tape.node_text(doc, t, buf); ok {
		return s, false, true
	}
	room := tape.text_room(doc, t)
	if room <= 0 {
		// On `.Binary` formats (e.g. CBOR >8 KiB bignums), `room == 0` when `node_text` failed means unspellable!
		if doc.format != nil && .Binary in doc.format.caps {
			return "", false, false
		}
		room = int(t.n)
	}
	if room <= 0 {
		return "", false, false
	}
	mem_buf, err := make([]u8, room, allocator)
	if err != nil {
		return "", false, false
	}
	if s, ok = tape.node_text(doc, t, mem_buf); !ok {
		delete(mem_buf, allocator)
		return "", false, false
	}
	if raw_data(s) == raw_data(mem_buf) && len(s) == len(mem_buf) {
		return s, true, true
	}
	cloned, cerr := strings.clone(s, allocator)
	delete(mem_buf, allocator)
	if cerr != nil {
		return "", false, false
	}
	return cloned, true, true
}

// Canonical FNV-1a / splitmix64 mixing for value hashing.
@(private = "file")
HASH_SEED :: u64(0x9E3779B97F4A7C15)

@(private = "file")
hash_mix :: #force_inline proc "contextless" (h, x: u64) -> u64 {
	v := (h ~ x) * 0xBF58476D1CE4E5B9
	return v ~ (v >> 31)
}

@(private = "file")
hash_bytes :: proc "contextless" (seed: u64, b: []u8) -> u64 {
	h := seed
	for c in b {
		h = (h ~ u64(c)) * 0x100000001B3
	}
	return hash_mix(h, u64(len(b)))
}

@(private = "file")
hash_decimal :: proc "contextless" (d: Decimal) -> u64 {
	if d.head == "" {
		return hash_mix(HASH_SEED, u64(Value_Kind.Number))
	}
	h := hash_mix(HASH_SEED, u64(Value_Kind.Number) | (u64(d.neg) << 8))
	// Hash `head` and `tail` as one contiguous digit stream so `42` and `4.2e1` produce the same hash.
	for c in transmute([]u8)d.head {
		h = (h ~ u64(c)) * 0x100000001B3
	}
	for c in transmute([]u8)d.tail {
		h = (h ~ u64(c)) * 0x100000001B3
	}
	h = hash_mix(h, u64(len(d.head) + len(d.tail)))
	if d.wide == "" {
		h = hash_mix(h, u64(d.point))
		h = hash_mix(h, u64(d.point >> 64))
	} else {
		h = hash_mix(h, u64(d.wide_neg) | 2)
		h = hash_bytes(h, transmute([]u8)d.wide)
		h = hash_mix(h, u64(d.point))
	}
	return h
}

// One collected member of an object value (deduplicated/grouped according to `dups`).
@(private = "file")
Flat_Member :: struct {
	key:       string,
	owned:     bool,
	val:       Value,
	group:     [dynamic]Value, // non-empty when `dups == .Group` combined 2+ values under `key`
}

@(private = "file")
free_members :: proc(list: []Flat_Member, scratch: runtime.Allocator) {
	for &m in list {
		if m.owned {
			delete(m.key, scratch)
		}
		if cap(m.group) > 0 {
			delete(m.group)
		}
	}
	delete(list, scratch)
}

@(private = "file")
add_group_member :: proc(existing: ^Flat_Member, next_val: Value, scratch: runtime.Allocator) -> bool {
	if len(existing.group) == 0 {
		existing.group = make([dynamic]Value, 0, 2, scratch)
		if _, err := append(&existing.group, existing.val); err != nil {
			return false
		}
	}
	if _, err := append(&existing.group, next_val); err != nil {
		return false
	}
	existing.val = existing.group[:]
	return true
}

// Collects the effective members of an object `Value` according to `dups`.
// Under `.Group` (XML), 2+ repeated keys are grouped into a virtual `[]Value` matching `lib/ops/diff/value.odin`.
@(private = "file")
collect_object :: proc(v: Value, dups: tape.Duplicates, scratch: runtime.Allocator) -> ([]Flat_Member, bool) {
	policy := tape.Duplicates.Last if dups == .Default || dups == .Refuse || dups == .All else dups
	out := make([dynamic]Flat_Member, scratch)
	seen := make(map[string]int, scratch)
	defer delete(seen)
	#partial switch x in v {
	case []Member_Value:
		for m in x {
			if idx, dup := seen[m.key]; dup {
				if policy == .Group {
					if !add_group_member(&out[idx], m.value, scratch) {
						free_members(out[:], scratch)
						return nil, false
					}
				} else if policy == .Last {
					out[idx].val = m.value
				}
				continue
			}
			seen[m.key] = len(out)
			if _, err := append(&out, Flat_Member{key = m.key, val = m.value}); err != nil {
				free_members(out[:], scratch)
				return nil, false
			}
		}
	case Node_Ref:
		if x.doc == nil || int(x.node) >= len(x.doc.nodes) {
			return out[:], true
		}
		if dups == .Default && x.doc.format != nil && x.doc.format.dups == .Group {
			policy = .Group
		}
		r := tape.Reader{doc = x.doc}
		it, p, cerr := tape.children(r, x.node, scratch)
		if cerr != nil {
			free_members(out[:], scratch)
			return nil, false
		}
		defer tape.destroy_children(&it)
		if p != .Found {
			return out[:], true
		}
		buf: [128]u8 = ---
		for {
			k, val, cp := tape.next_child(r, &it, policy if policy == .Group else dups)
			if cp != .Found {
				break
			}
			kt: tape.Token
			if k == tape.NO_NODE && it.keys_n != 0 {
				kt = tape.cell_key(r, it)
			} else if k != tape.NO_NODE {
				kt = x.doc.nodes[k]
			} else {
				continue
			}
			key_s, key_owned, ok := node_text_alloc(x.doc, kt, buf[:], scratch)
			if !ok {
				free_members(out[:], scratch)
				return nil, false
			}
			if !key_owned && raw_data(key_s) == raw_data(buf[:]) {
				cloned, aerr := strings.clone(key_s, scratch)
				if aerr != nil {
					free_members(out[:], scratch)
					return nil, false
				}
				key_s, key_owned = cloned, true
			}
			if idx, dup := seen[key_s]; dup {
				if key_owned {
					delete(key_s, scratch)
				}
				if policy == .Group {
					if !add_group_member(&out[idx], Node_Ref{x.doc, val}, scratch) {
						free_members(out[:], scratch)
						return nil, false
					}
				} else if policy == .Last {
					out[idx].val = Node_Ref{x.doc, val}
				}
				continue
			}
			seen[key_s] = len(out)
			if _, err := append(&out, Flat_Member{key = key_s, owned = key_owned, val = Node_Ref{x.doc, val}}); err != nil {
				if key_owned {
					delete(key_s, scratch)
				}
				free_members(out[:], scratch)
				return nil, false
			}
		}
	}
	return out[:], true
}

// Collects direct elements of an array `Value` into `out`. Returns `ok = false` on OOM.
@(private = "file")
collect_array :: proc(v: Value, scratch: runtime.Allocator) -> (elems: []Value, owned: bool, ok: bool) {
	#partial switch x in v {
	case []Value:
		return x, false, true
	case Node_Ref:
		out := make([dynamic]Value, scratch)
		if x.doc == nil || int(x.node) >= len(x.doc.nodes) {
			return out[:], true, true
		}
		r := tape.Reader{doc = x.doc}
		it, p, cerr := tape.children(r, x.node, scratch)
		if cerr != nil {
			delete(out)
			return nil, false, false
		}
		defer tape.destroy_children(&it)
		if p != .Found {
			return out[:], true, true
		}
		for {
			_, val, cp := tape.next_child(r, &it)
			if cp != .Found {
				break
			}
			if _, aerr := append(&out, Node_Ref{x.doc, val}); aerr != nil {
				delete(out)
				return nil, false, false
			}
		}
		return out[:], true, true
	}
	return nil, false, true
}

// Mathematical JSON-Schema hash of `v` (1 == 1.0 == 1e0; object key order ignored).
// Uses an explicit heap stack — zero unbounded native recursion. Returns `.Out_Of_Memory` on allocation failure.
value_hash :: proc(v: Value, dups := tape.Duplicates.Last, scratch := context.allocator) -> (u64, runtime.Allocator_Error) {
	Frame_Kind :: enum u8 {
		Value,
		Array,
		Object,
	}
	Frame :: struct {
		kind:    Frame_Kind,
		val:     Value,
		elems:   []Value,
		owned:   bool,
		members: []Flat_Member,
		idx:     int,
		acc:     u64,
		key_h:   u64,
	}
	stack, serr := make([dynamic]Frame, 0, 16, scratch)
	if serr != nil {
		return 0, .Out_Of_Memory
	}
	defer {
		for &fr in stack {
			if fr.kind == .Array && fr.owned {
				delete(fr.elems, scratch)
			} else if fr.kind == .Object {
				free_members(fr.members, scratch)
			}
		}
		delete(stack)
	}
	if _, aerr := append(&stack, Frame{kind = .Value, val = v}); aerr != nil {
		return 0, .Out_Of_Memory
	}
	result := u64(0)
	has_result := false
	buf: [128]u8 = ---
	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		switch top.kind {
		case .Value:
			cur := top.val
			pop(&stack)
			k := value_kind(cur)
			switch k {
			case .Null, .False, .True:
				result = hash_mix(HASH_SEED, u64(k))
				has_result = true
			case .Number:
				text, owned, ok := value_number_text(cur, buf[:], scratch)
				if ok {
					result = hash_decimal(decimal_of(text))
				} else {
					nf, raw_b := number_special(cur)
					if len(raw_b) > 0 {
						result = hash_bytes(hash_mix(HASH_SEED, u64(Value_Kind.Number) | 0xFE00), raw_b)
					} else {
						result = hash_mix(HASH_SEED, u64(Value_Kind.Number) | (u64(u8(nf)) << 8) | 0xFF0000)
					}
				}
				if owned {
					delete(text, scratch)
				}
				has_result = true
			case .String:
				text, owned, ok := value_string(cur, buf[:], scratch)
				if !ok {
					return 0, .Out_Of_Memory
				}
				result = hash_bytes(hash_mix(HASH_SEED, u64(Value_Kind.String)), transmute([]u8)text)
				if owned {
					delete(text, scratch)
				}
				has_result = true
			case .Array:
				elems, owned, ok := collect_array(cur, scratch)
				if !ok {
					return 0, .Out_Of_Memory
				}
				if _, aerr := append(&stack, Frame{
					kind  = .Array,
					elems = elems,
					owned = owned,
					acc   = hash_mix(HASH_SEED, u64(Value_Kind.Array) | (u64(len(elems)) << 8)),
				}); aerr != nil {
					if owned {
						delete(elems, scratch)
					}
					return 0, .Out_Of_Memory
				}
				has_result = false
			case .Object:
				members, ok := collect_object(cur, dups, scratch)
				if !ok {
					return 0, .Out_Of_Memory
				}
				if _, aerr := append(&stack, Frame{
					kind    = .Object,
					members = members,
					acc     = hash_mix(HASH_SEED, u64(Value_Kind.Object) | (u64(len(members)) << 8)),
				}); aerr != nil {
					free_members(members, scratch)
					return 0, .Out_Of_Memory
				}
				has_result = false
			}
		case .Array:
			if has_result {
				top.acc = hash_mix(top.acc, result)
				has_result = false
			}
			if top.idx < len(top.elems) {
				elem := top.elems[top.idx]
				top.idx += 1
				if _, aerr := append(&stack, Frame{kind = .Value, val = elem}); aerr != nil {
					return 0, .Out_Of_Memory
				}
			} else {
				result = top.acc
				if top.owned {
					delete(top.elems, scratch)
					top.owned = false
				}
				pop(&stack)
				has_result = true
			}
		case .Object:
			if has_result {
				top.acc += hash_mix(top.key_h, result)
				has_result = false
			}
			if top.idx < len(top.members) {
				m := top.members[top.idx]
				top.idx += 1
				top.key_h = hash_bytes(HASH_SEED, transmute([]u8)m.key)
				if _, aerr := append(&stack, Frame{kind = .Value, val = m.val}); aerr != nil {
					return 0, .Out_Of_Memory
				}
			} else {
				result = top.acc
				free_members(top.members, scratch)
				top.members = nil
				pop(&stack)
				has_result = true
			}
		}
	}
	return result, nil
}

// Mathematical JSON-Schema equality of `a` and `b` (1 == 1.0 == 1e0; object key order ignored).
// Uses an explicit heap stack — zero unbounded native recursion, freeing per-iteration buffers explicitly.
value_equal :: proc(a, b: Value, dups := tape.Duplicates.Last, scratch := context.allocator) -> (bool, runtime.Allocator_Error) {
	Pair :: struct {
		a, b:   Value,
		ga, gb: [dynamic]Value, // transferred ownership of `.Group` virtual array backing
	}
	work, werr := make([dynamic]Pair, 0, 16, scratch)
	if werr != nil {
		return false, .Out_Of_Memory
	}
	cur_ga, cur_gb: [dynamic]Value
	defer {
		delete(cur_ga)
		delete(cur_gb)
		for &rem in work {
			delete(rem.ga)
			delete(rem.gb)
		}
		delete(work)
	}
	if _, aerr := append(&work, Pair{a = a, b = b}); aerr != nil {
		return false, .Out_Of_Memory
	}
	buf_a: [128]u8 = ---
	buf_b: [128]u8 = ---
	for len(work) > 0 {
		delete(cur_ga)
		delete(cur_gb)
		cur_ga, cur_gb = nil, nil
		p := pop(&work)
		cur_ga, cur_gb = p.ga, p.gb
		ka, kb := value_kind(p.a), value_kind(p.b)
		if ka != kb {
			return false, nil
		}
		switch ka {
		case .Null, .False, .True:
			continue
		case .Number:
			sa, oa, oka := value_number_text(p.a, buf_a[:], scratch)
			sb, ob, okb := value_number_text(p.b, buf_b[:], scratch)
			eq := false
			if oka && okb {
				eq = decimal_compare(decimal_of(sa), decimal_of(sb)) == 0
			} else if !oka && !okb {
				nfa, rawa := number_special(p.a)
				nfb, rawb := number_special(p.b)
				if nfa != 0 || nfb != 0 {
					eq = nfa == nfb && nfa != 2 // +Inf == +Inf, -Inf == -Inf, NaN != NaN
				} else if len(rawa) > 0 && len(rawb) > 0 {
					eq = slice.equal(rawa, rawb)
				}
			}
			if oa {
				delete(sa, scratch)
			}
			if ob {
				delete(sb, scratch)
			}
			if !eq {
				return false, nil
			}
		case .String:
			sa, oa, oka := value_string(p.a, buf_a[:], scratch)
			sb, ob, okb := value_string(p.b, buf_b[:], scratch)
			eq := oka && okb && sa == sb
			if oa {
				delete(sa, scratch)
			}
			if ob {
				delete(sb, scratch)
			}
			if !oka || !okb {
				return false, .Out_Of_Memory
			}
			if !eq {
				return false, nil
			}
		case .Array:
			ea, oa, oka := collect_array(p.a, scratch)
			if !oka {
				return false, .Out_Of_Memory
			}
			eb, ob, okb := collect_array(p.b, scratch)
			if !okb {
				if oa {
					delete(ea, scratch)
				}
				return false, .Out_Of_Memory
			}
			same_len := len(ea) == len(eb)
			push_err: runtime.Allocator_Error
			if same_len {
				for i := len(ea) - 1; i >= 0; i -= 1 {
					if _, aerr := append(&work, Pair{a = ea[i], b = eb[i]}); aerr != nil {
						push_err = .Out_Of_Memory
						break
					}
				}
			}
			if oa {
				delete(ea, scratch)
			}
			if ob {
				delete(eb, scratch)
			}
			if push_err != nil {
				return false, push_err
			}
			if !same_len {
				return false, nil
			}
		case .Object:
			ma, oka := collect_object(p.a, dups, scratch)
			if !oka {
				return false, .Out_Of_Memory
			}
			mb, okb := collect_object(p.b, dups, scratch)
			if !okb {
				free_members(ma, scratch)
				return false, .Out_Of_Memory
			}
			if len(ma) != len(mb) {
				free_members(ma, scratch)
				free_members(mb, scratch)
				return false, nil
			}
			match_ok := true
			mem_err: runtime.Allocator_Error
			if len(ma) <= 8 {
				for &x in ma {
					found := false
					for &y in mb {
						if x.key == y.key {
							if _, aerr := append(&work, Pair{a = x.val, b = y.val, ga = x.group, gb = y.group}); aerr != nil {
								mem_err = .Out_Of_Memory
							} else {
								x.group = nil
								y.group = nil
							}
							found = true
							break
						}
					}
					if mem_err != nil || !found {
						match_ok = false
						break
					}
				}
			} else {
				by_key, merr := make(map[string]int, len(mb), scratch)
				if merr != nil {
					mem_err = .Out_Of_Memory
				} else {
					for y, idx in mb {
						by_key[y.key] = idx
					}
					for &x in ma {
						idx, found := by_key[x.key]
						if !found {
							match_ok = false
							break
						}
						y := &mb[idx]
						if _, aerr := append(&work, Pair{a = x.val, b = y.val, ga = x.group, gb = y.group}); aerr != nil {
							mem_err = .Out_Of_Memory
							break
						}
						x.group = nil
						y.group = nil
					}
					delete(by_key)
				}
			}
			free_members(ma, scratch)
			free_members(mb, scratch)
			if mem_err != nil {
				return false, mem_err
			}
			if !match_ok {
				return false, nil
			}
		}
	}
	return true, nil
}
