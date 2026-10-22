package jq

// The builtins that take values and give one value: strings and containers. Sorting and grouping live in `sort.odin`.
// Numbers and dates live in `math_time.odin`.

import "base:intrinsics"
import "core:math"
import "core:simd"
import "core:strings"
import "core:unicode/utf8"

fn_length :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	switch kind(v) {
	case .Null:
		return num(0), .Go
	case .False, .True:
		return nil, fail(ip, "boolean (%s) has no length", brief(v))
	case .Number:
		// jq's jv_number_abs: a literal without its sign, a negative zero's (`-0.0`) too, else fabs. Either is a new
		// number, not the input (`1 | path(length)` fails).
		n, _ := number_of(v)
		switch {
		case len(n.lit) == 0:
			return num(abs(n.f)), .Go
		case n.lit[0] == '-':
			return Number{f = abs(n.f), lit = n.lit[1:]}, .Go
		}
		return Number{f = n.f, lit = strings.clone(n.lit)}, .Go
	case .String:
		s, _ := string_of(v)
		return num(f64(owned_codepoints(ip, s))), .Go
	case .Array, .Object:
	}
	return num(f64(length_of(v))), .Go
}

// The codepoints of `s`: its bytes but the continuation ones (10xxxxxx), 16 at a time. Strings here are valid
// UTF-8 (input is repaired on the way in).
codepoints :: proc(s: string) -> int {
	cont, i := 0, 0
	for i + 16 <= len(s) {
		acc: #simd[16]u8
		for end := min(i + 255 * 16, len(s)); i + 16 <= end; i += 16 {
			v := intrinsics.unaligned_load((^#simd[16]u8)(raw_data(s)[i:]))
			acc -= simd.lanes_eq(simd.bit_and(v, 0xC0), 0x80)
		}
		for lane in simd.to_array(acc) {
			cont += int(lane)
		}
	}
	for b in transmute([]u8)s[i:] {
		cont += int(b & 0xC0 == 0x80)
	}
	return len(s) - cont
}

fn_utf8bytelength :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	s, ok := string_of(v)
	if !ok {
		return nil, fail(ip, "%s (%s) only strings have UTF-8 byte length", type_name(v), brief(v))
	}
	return num(f64(len(s))), .Go
}

fn_keys :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	if kind(v) == .Object {
		a := new_array(length_of(v))
		for k in sorted_keys(v) {
			append(&a.items, k)
		}
		return a, .Go
	}
	return fn_keys_unsorted(ip, name, v, args)
}

fn_keys_unsorted :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	#partial switch kind(v) {
	case .Object:
		a := new_array(length_of(v))
		it := iterate(v)
		for k in next_member(&it) {
			append(&a.items, k)
		}
		return a, .Go
	case .Array:
		a := new_array(length_of(v))
		for i in 0 ..< length_of(v) {
			append(&a.items, num(f64(i)))
		}
		return a, .Go
	}
	return nil, fail(ip, "%s (%s) has no keys", type_name(v), brief(v))
}

fn_has :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	k := args[0]
	switch {
	case kind(v) == .Object && kind(k) == .String:
		s, _ := string_of(k)
		_, has := object_get(v, s)
		return has, .Go
	case kind(v) == .Array && kind(k) == .Number:
		n, _ := number_of(k)
		return n.f >= 0 && n.f < f64(length_of(v)), .Go
	case kind(v) == .Null:
		return false, .Go // jq 1.8 has no key in null, of any kind
	}
	return nil, fail(ip, "Cannot check whether %s has a %s key", type_name(v), type_name(k))
}

fn_contains :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	if kind(v) != kind(args[0]) { // jq's kinds: true and false are two
		return nil, fail(ip, "%s (%s) and %s (%s) cannot have their containment checked", type_name(v), brief(v), type_name(args[0]), brief(args[0]))
	}
	too_deep = false
	r := contains(v, args[0])
	if too_deep {
		return nil, fail(ip, "Containment check too deep")
	}
	return r, .Go
}

// Whether `a` contains `b`. Past MAX_DEPTH it sets `too_deep`.
contains :: proc(a, b: Value, depth := 0) -> bool {
	if depth > MAX_DEPTH {
		too_deep = true
		return false
	}
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Object && kb == .Object:
		it := iterate(b)
		for k, bv in next_member(&it) {
			av, has := object_get(a, k)
			if !has || !contains(av, bv, depth + 1) {
				return false
			}
		}
		return true
	case ka == .Array && kb == .Array:
		return contains_elements(elements(a), elements(b), depth)
	case ka == .String && kb == .String:
		x, _ := string_of(a)
		y, _ := string_of(b)
		return strings.contains(x, y)
	}
	return compare(a, b, depth) == 0
}

// Whether each of `b` is contained in some element of `a` of its kind. Past a few dozen comparisons the scalars of
// `a` are indexed once, so a wide array of scalars costs a lookup per element of `b` and not a scan of `a`. A string
// that is only a substring, and an array or object, still scan `a`: a ceiling, since substring containment cannot be
// hashed.
contains_elements :: proc(a, b: []Value, depth: int) -> bool {
	ix: Scalar_Index
	indexed := worth_indexing(len(a), len(b)) && depth < MAX_DEPTH
	if indexed {
		ix = index_scalars(a)
	}
	outer: for bv in b {
		kb := kind(bv)
		if indexed {
			found, scalar := index_has(&ix, bv)
			if found {
				continue outer
			}
			if scalar && kb != .String {
				return false
			}
		}
		for av in a {
			if kind(av) == kb && contains(av, bv, depth + 1) {
				continue outer
			}
		}
		return false
	}
	return true
}

fn_tonumber :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	#partial switch kind(v) {
	case .Number:
		return v, .Go
	case .String:
		s, _ := string_of(v)
		if strings.index_byte(s, 0) < 0 {
			if n, ok := read_number(s); ok {
				return n, .Go
			}
		}
	}
	return nil, fail(ip, "%s (%s) cannot be parsed as a number", type_name(v), brief(v))
}

fn_fromjson :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	s, ok := string_of(v)
	if !ok {
		return nil, fail(ip, "%s (%s) only strings can be parsed", type_name(v), brief(v))
	}
	parsed, msg := read_json(s)
	if msg != "" {
		return nil, fail(ip, "%s", msg)
	}
	return parsed, .Go
}

fn_ascii_downcase :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return flip_ascii_case(ip, v, 'A')
}

fn_ascii_upcase :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return flip_ascii_case(ip, v, 'a')
}

@(private = "file")
flip_ascii_case :: proc(ip: ^Interp, v: Value, from: byte) -> (Value, Signal) {
	s, ok := string_of(v)
	if !ok {
		return nil, fail(ip, "explode input must be a string") // jq's are `explode | ... | implode`
	}
	// The letters of the case being changed, flipped by their 0x20 bit as they are copied, in a loop
	// without branches, which vectorizes.
	b := make([]byte, len(s))
	#no_bounds_check for c, i in transmute([]byte)s {
		b[i] = c ~ (u8(c - from < 26) << 5)
	}
	return string(b), .Go
}

fn_explode :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	s, ok := string_of(v)
	if !ok {
		return nil, fail(ip, "explode input must be a string")
	}
	a := new_array(len(s))
	for r in s {
		append(&a.items, num(f64(r)))
	}
	return a, .Go
}

fn_implode :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	if kind(v) != .Array {
		return nil, fail(ip, "implode input must be an array")
	}
	b := strings.builder_make()
	it := iterate(v)
	for _, m in next_member(&it) {
		n, ok := number_of(m)
		if !ok || math.is_nan(n.f) {
			return nil, fail(ip, "%s (%s) can't be imploded, unicode codepoint needs to be numeric", type_name(m), brief(m))
		}
		r := rune(n.f)
		if n.f < 0 || n.f > 0x10ffff || (r >= 0xd800 && r < 0xe000) {
			r = utf8.RUNE_ERROR
		}
		strings.write_rune(&b, r)
	}
	return strings.to_string(b), .Go
}

fn_startswith :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return affix(ip, v, args[0], start = true, trim = false)
}

fn_endswith :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return affix(ip, v, args[0], start = false, trim = false)
}

fn_ltrimstr :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return affix(ip, v, args[0], start = true, trim = true)
}

fn_rtrimstr :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return affix(ip, v, args[0], start = false, trim = true)
}

// startswith and endswith (the affix at the `start` or not), and ltrimstr and rtrimstr, which jq writes
// with them (`trim`): the input without the affix it has, or else the very input.
@(private = "file")
affix :: #force_inline proc(ip: ^Interp, v, of: Value, start, trim: bool) -> (Value, Signal) {
	s, sok := string_of(v)
	t, tok := string_of(of)
	if !sok || !tok {
		return nil, fail(ip, "%s() requires string inputs", "startswith" if start else "endswith")
	}
	has := strings.has_prefix(s, t) if start else strings.has_suffix(s, t)
	switch {
	case !trim:
		return has, .Go
	case has && start:
		return s[len(t):], .Go
	case has && len(t) > 0:
		return s[:len(s) - len(t)], .Go
	}
	return v, .Go
}

fn_trim :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return trimmed(ip, v, left = true, right = true)
}

fn_ltrim :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return trimmed(ip, v, left = true, right = false)
}

fn_rtrim :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return trimmed(ip, v, left = false, right = true)
}

// The Unicode White_Space property, which is what jq trims: not U+200B, U+200E, U+200F or U+FEFF.
@(private = "file")
is_trimmed :: proc(r: rune) -> bool {
	switch r {
	case '\t' ..= '\r', ' ', 0x85, 0xa0, 0x1680, 0x2000 ..= 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000:
		return true
	}
	return false
}

@(private = "file")
trimmed :: #force_inline proc(ip: ^Interp, v: Value, left, right: bool) -> (Value, Signal) {
	whole, ok := string_of(v)
	if !ok {
		return nil, fail(ip, "trim input must be a string")
	}
	s := whole
	if left {
		s = strings.trim_left_proc(s, is_trimmed)
	}
	if right {
		s = strings.trim_right_proc(s, is_trimmed)
	}
	if len(s) == len(whole) {
		return v, .Go // jq's trims return their very input when there is nothing to trim
	}
	return s, .Go
}

fn_split :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	s, sok := string_of(v)
	sep, tok := string_of(args[0])
	if !sok || !tok {
		return nil, fail(ip, "split input and separator must be strings")
	}
	return split_string(s, sep), .Go
}

// jq's `reduce .[] as $i (null; (if . == null then "" else . + $x end) + ($i | if type == "boolean" or
// type == "number" then tostring else . // "" end)) // ""`, its errors included, with the string built
// in place while the operands are strings.
fn_join :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	k := kind(v)
	if k != .Array && k != .Object {
		return nil, fail(ip, "Cannot iterate over %s (%s)", type_name(v), brief(v))
	}
	sep, sep_is_str := string_of(args[0])
	b := strings.builder_make()
	acc: Value // the result so far once it is not a string, nil while it is (in `b`)
	first := true
	it := iterate(v)
	for _, m in next_member(&it) {
		item: Value
		#partial switch kind(m) {
		case .False, .True, .Number:
			item = to_json(m)
		case .Null:
			item = ""
		case:
			item = m
		}
		left: Value = ""
		if !first {
			if acc == nil && sep_is_str {
				strings.write_string(&b, sep)
			} else {
				sig: Signal
				if left, sig = binary_op(ip, .Add, acc if acc != nil else Value(strings.to_string(b)), args[0]); sig != .Go {
					return nil, sig
				}
				acc = left
			}
		}
		first = false
		text, item_is_str := item.(string)
		if acc == nil && item_is_str {
			strings.write_string(&b, text)
			continue
		}
		sig: Signal
		if acc == nil {
			left = strings.to_string(b)
		}
		if acc, sig = binary_op(ip, .Add, left if acc == nil else acc, item); sig != .Go {
			return nil, sig
		}
	}
	if acc == nil {
		return strings.to_string(b), .Go
	}
	return acc if truthy(acc) else Value(""), .Go
}

// jq's `[.[length - 1 - range(0; length)]]`: an array reversed, and for anything else with a length
// nothing when it is 0, else the error of indexing it with that length less one.
fn_reverse :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	if kind(v) == .Array {
		items := elements(v)
		a := new_array(len(items))
		#reverse for x in items {
			append(&a.items, x)
		}
		return a, .Go
	}
	n, sig := fn_length(ip, name, v, nil)
	if sig != .Go {
		return nil, sig
	}
	if l, _ := number_of(n); l.f == 0 {
		return new_array(), .Go
	} else {
		return index_value(ip, v, num(l.f - 1))
	}
}

// jq's `if $x < 0 then error(...) else _flatten($x) end`: a depth of any type that orders below 0
// fails, and one that is not a number fails as `$x - 1` does at the first array it would flatten.
fn_flatten :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	depth: Value = num(1e18)
	if len(args) > 0 {
		depth = args[0]
		if compare(depth, num(0)) < 0 {
			return nil, fail(ip, "flatten depth must not be negative")
		}
	}
	k := kind(v)
	if k != .Array && k != .Object {
		return nil, fail(ip, "Cannot iterate over %s (%s)", type_name(v), brief(v))
	}
	a := new_array()
	return a, flatten_into(ip, a, v, depth)
}

@(private = "file")
flatten_into :: proc(ip: ^Interp, a: ^Array, v: Value, depth: Value) -> Signal {
	it := iterate(v)
	for _, m in next_member(&it) {
		if kind(m) != .Array || compare(depth, num(0), eq = true) == 0 {
			append(&a.items, m)
			continue
		}
		less, sig := binary_op(ip, .Sub, depth, num(1))
		if sig == .Go {
			sig = flatten_into(ip, a, m, less)
		}
		if sig != .Go {
			return sig
		}
	}
	return .Go
}

fn_indices :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	i := args[0]
	switch {
	case kind(v) == .Array && kind(i) != .Array:
		wrap := new_array(1)
		append(&wrap.items, i)
		return index_value(ip, v, wrap)
	case kind(v) == .String && kind(i) == .String:
		return fn_strindices(ip, name, v, args)
	}
	return index_value(ip, v, i)
}

// `_strindices`: where `t` starts in the string, in codepoints, overlaps included.
fn_strindices :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	s, sok := string_of(v)
	if !sok {
		return nil, fail(ip, "%s (%s) cannot be searched, as it is not a string", type_name(v), brief(v))
	}
	t, tok := string_of(args[0])
	if !tok {
		return nil, fail(ip, "%s (%s) is not a string", type_name(args[0]), brief(args[0]))
	}
	a := new_array()
	if len(t) > 0 {
		runes, from := 0, 0 // the codepoints before s[from:]
		for at := 0; ; at += 1 {
			k := strings.index(s[at:], t)
			if k < 0 {
				break
			}
			at += k
			runes += codepoints(s[from:at])
			from = at
			append(&a.items, num(f64(runes)))
		}
	}
	return a, .Go
}

fn_add :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	k := kind(v)
	if k != .Array && k != .Object {
		return nil, fail(ip, "Cannot iterate over %s (%s)", type_name(v), brief(v))
	}
	owned: Owned
	acc: Value
	it := iterate(v)
	for _, m in next_member(&it) {
		sig: Signal
		if acc, sig = add(ip, acc, m, &owned); sig != .Go {
			return nil, sig
		}
	}
	return acc, .Go
}

fn_to_entries :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	k := kind(v)
	if k != .Object && k != .Array {
		return nil, fail(ip, "%s (%s) has no keys", type_name(v), brief(v))
	}
	a := new_array(length_of(v))
	it := iterate(v)
	i := 0
	for key, m in next_member(&it) {
		e := new_object()
		object_put(e, "key", key if k == .Object else num(f64(i)))
		object_put(e, "value", m)
		append(&a.items, e)
		i += 1
	}
	return a, .Go
}
