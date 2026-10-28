package core

// The scalar reads of a row document: a value's string, key, number and boolean. A plain row is read here, inline;
// a flagged one through the document's spelling (`Row_Spelling`), into its cache. The `get_*` readers' `ok` is
// false for a value of another kind or `NO_NODE`; `get_int` and `get_float` also answer false for a value that does
// not fit, and `get_string`/`get_key` when a flagged value's decode could not be allocated.

import "base:intrinsics"

// `true` or `false` for a boolean `n`.
@(require_results)
get_bool :: #force_inline proc(doc: ^Document, n: Node) -> (v: bool, ok: bool) {
	k := kind(doc, n) or_return
	return k == .True, k == .True || k == .False
}

// The integer number `n` writes, when it fits `i64`. `-0` is 0, as `unmarshal` reads it into an integer. `ok` is
// also false for an integer past `max(i64)` and for a fraction or exponent notation (`get_number`).
@(require_results)
get_int :: #force_inline proc(doc: ^Document, n: Node) -> (v: i64, ok: bool) {
	if !dom_has(doc.rows[:], n) || doc.rows[n].kind != .Number {
		return 0, false
	}
	r := doc.rows[n]
	known: bool
	if v, ok, known = int_token(doc.src, u64(r.lo), u64(r.hi), r.first_esc); known {
		return v, ok
	}
	return int_uncounted(doc.src, u64(r.lo), u64(r.hi), r.first_esc, doc.spelling)
}

// The binary64 value of number `n`, correctly rounded. `ok` is also false for a number with no binary64
// value (`1e400`); `get_number` tells how the value relates to the authored one.
@(require_results)
get_float :: proc(doc: ^Document, n: Node) -> (v: f64, ok: bool) {
	num, is_number := get_number(doc, n)
	return num.value, is_number && num.exactness != .None
}

// The binary64 projection of number `n` and its `exactness` against the authored value.
//
//	- `ok` is false only where `n` is no number, so one past binary64's range (`1e400`) is `Number{0, .None}`
//	  (`value` +0, `.None`) with `ok` true, where `get_float` answers false.
//	- Decoded from the number's text at each call: a document keeps no number's value, so a reader that
//	  wants one many times keeps it itself.
//	- Inlined, so the decoding the caller does not read is dropped (`get_float` asks only whether there is a
//	  value).
@(require_results)
get_number :: #force_inline proc(doc: ^Document, n: Node) -> (v: Number, ok: bool) {
	if !dom_has(doc.rows[:], n) || doc.rows[n].kind != .Number {
		return {}, false
	}
	r := doc.rows[n]
	return number_token(doc.src, u64(r.lo), u64(r.hi), r.first_esc, doc.spelling), true
}

// The decoded text of string `n`, valid until the document is destroyed.
//
//	- A plain string is a slice of `doc.src`. A flagged one is what the build decoded (`.Decoded`) or, on a
//	  scanned document (`Document`), decoded by the spelling into its cache on the first read and kept.
//	- `ok` is false for a value that is not a string, and when a flagged string's decode could not be allocated.
@(require_results)
get_string :: #force_inline proc(doc: ^Document, n: Node) -> (s: string, ok: bool) #no_bounds_check {
	if dom_has(doc.rows[:], n) {
		r := &doc.rows[n]
		lo, hi := u64(r.lo), u64(r.hi)
		// The text is borrowed from `src`, the slices below in range once `hi` is. A quoted string is tested
		// first and alone: an arithmetic quote width costs every read.
		if r.kind == .String && .Str_Escaped not_in r.flags && hi <= u64(len(doc.src)) {
			if .Bare not_in r.flags {
				if hi >= lo + 2 {
					return string(doc.src[lo + 1:hi - 1]), true
				}
			} else if hi >= lo {
				return string(doc.src[lo:hi]), true
			}
		}
	}
	return get_string_flagged(doc, n)
}

// Runs `get_string` for every value but a plain string.
@(private = "file")
get_string_flagged :: #force_no_inline proc(doc: ^Document, n: Node) -> (s: string, ok: bool) {
	if !dom_has(doc.rows[:], n) || doc.rows[n].kind != .String || .Str_Escaped not_in doc.rows[n].flags {
		return "", false
	}
	r := doc.rows[n]
	if .Decoded in r.flags {
		return string(doc.values[r.payload.str.off:][:r.payload.str.len]), true
	}
	if doc.cache != nil {
		if s, ok = doc.cache.strings[n]; ok {
			return
		}
	}
	if doc.decoded {
		return "", false
	}
	b: []u8
	b, ok = spelled_text(doc, u64(r.lo), u64(r.hi), u64(r.first_esc))
	if ok {
		// A string the map cannot hold is decoded again on the next call.
		doc.cache.strings[n] = string(b)
	}
	return string(b), ok
}

// The decoded key of member `n`, valid until the document is destroyed. A plain key is a slice of `doc.src`. A
// flagged one is what the build decoded or, on a scanned document (`Document`), decoded by the spelling into
// its cache on the first read and kept. `ok` is false when `n` is not an object's member, and when a flagged key's
// decode could not be allocated.
@(require_results)
get_key :: #force_inline proc(doc: ^Document, n: Node) -> (s: string, ok: bool) #no_bounds_check {
	if !dom_has(doc.rows[:], n) || doc.rows[n].key_lo == NO_KEY {
		return "", false
	}
	r := &doc.rows[n]
	if .Key_Escaped not_in r.flags {
		lo, hi := u64(r.key_lo), u64(r.key_hi)
		if hi <= u64(len(doc.src)) {
			if .Key_Bare not_in r.flags {
				if hi >= lo + 2 {
					return string(doc.src[lo + 1:hi - 1]), true
				}
			} else if hi >= lo {
				return string(doc.src[lo:hi]), true
			}
		}
		return "", false
	}
	return get_key_flagged(doc, n)
}

// Runs `get_key` for a flagged key, which is kept.
@(private = "file")
get_key_flagged :: #force_no_inline proc(doc: ^Document, n: Node) -> (s: string, ok: bool) {
	if doc.decoded {
		return key_text(doc, n)
	}
	if doc.cache != nil {
		if s, ok = doc.cache.keys[n]; ok {
			return
		}
	}
	return decode_key(doc, n)
}

// The key text the build of decoded document `doc` decoded for member `n`, found by binary search.
@(private = "file")
key_text :: proc(doc: ^Document, n: Node) -> (s: string, ok: bool) {
	lo, hi := 0, len(doc.key_texts)
	for lo < hi {
		mid := (lo + hi) / 2
		if doc.key_texts[mid].node < n {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == len(doc.key_texts) || doc.key_texts[lo].node != n {
		return "", false
	}
	t := doc.key_texts[lo].str
	return string(doc.values[t.off:][:t.len]), true
}

// Decode the flagged key of member `n` into the cache and keep it; `ok` is false when the decode could not
// allocate. A key the map cannot hold is decoded again on the next read.
@(private = "file")
decode_key :: proc(doc: ^Document, n: Node) -> (s: string, ok: bool) {
	r := doc.rows[n]
	b: []u8
	b, ok = spelled_text(doc, u64(r.key_lo), u64(r.key_hi), 0)
	if ok {
		doc.cache.keys[n] = string(b)
	}
	return string(b), ok
}

// The text of flagged token `src[lo:hi]`, decoded by the document's spelling into its cache's arena, which grows at
// each call: the caller keeps what it decoded.
@(private)
spelled_text :: proc(doc: ^Document, lo, hi, first_esc: u64) -> (s: []u8, ok: bool) {
	if doc.spelling == nil {
		return nil, false
	}
	c := row_cache(doc)
	if c == nil {
		return nil, false
	}
	return doc.spelling.decode(doc.src, lo, hi, first_esc, &c.arena)
}

// Whether the key of row `r` decodes to `want`: a plain key compared as written, inline, a flagged one by the
// spelling, decoding nothing.
row_key_equals :: #force_inline proc(doc: ^Document, r: ^Row, want: string) -> bool #no_bounds_check {
	lo, hi := u64(r.key_lo), u64(r.key_hi)
	if .Key_Escaped not_in r.flags {
		q := u64(.Key_Bare not_in r.flags)
		return hi >= lo + 2 * q && hi - lo - 2 * q == u64(len(want)) && spelled_equals(doc.src[lo + q:hi - q], want)
	}
	return doc.spelling != nil && doc.spelling.key_equals(doc.src, lo, hi, want)
}

// Two equal-length byte strings compared without a call. Below 8 bytes a word load could leave either string,
// so the bytes are compared one at a time. From 8 to 16 bytes two overlapping words cover both strings, and
// neither load leaves them.
spelled_equals :: #force_inline proc(got: []byte, want: string) -> bool {
	n := len(want)
	#no_bounds_check {
		if n < 8 {
			for i in 0 ..< n {
				if got[i] != want[i] {
					return false
				}
			}
			return true
		}
		if n > 16 {
			return string(got) == want
		}
		g, w := raw_data(got), raw_data(want)
		return intrinsics.unaligned_load((^u64)(g)) == intrinsics.unaligned_load((^u64)(w)) &&
			intrinsics.unaligned_load((^u64)(g[n - 8:])) == intrinsics.unaligned_load((^u64)(w[n - 8:]))
	}
}
