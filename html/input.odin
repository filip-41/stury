package html

import core "../core"

// The encoding sniffing of the standard's section 13.2.3: a byte order mark, else a `meta` that the prescan finds in
// the first 1024 bytes, else the first `meta` the tree inserts that names one. The tree reads UTF-8, so a text in
// another encoding faults where it names it, unless every byte of the text reads as UTF-8 reads it, as an ASCII text
// does in an encoding that extends ASCII.

// The bytes the prescan reads.
@(private)
PRESCAN_BYTES :: 1024

// Where a document's characters start, past a UTF-8 byte order mark, the encoding the mark or the prescan names and
// whether one does, or the fault at the mark or the label of an encoding that reads the text otherwise than UTF-8.
@(private)
sniff :: proc "contextless" (src: []u8) -> (from: u64, enc: Encoding, found: bool, fault: Maybe(core.Fault)) {
	at: u64
	enc, at, from, found = sniffed(src)
	if found && !reads_as_utf8(src[from:], enc) {
		return 0, enc, found, core.Fault{at = at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Encoding)}
	}
	return
}

// The encoding a byte order mark or the prescan names, where the mark or the label starts, and where the characters
// start.
@(private)
sniffed :: proc "contextless" (src: []u8) -> (enc: Encoding, at, from: u64, found: bool) {
	switch {
	case len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF:
		return .Utf_8, 0, 3, true
	case len(src) >= 2 && src[0] == 0xFE && src[1] == 0xFF:
		return .Utf_16be, 0, 2, true
	case len(src) >= 2 && src[0] == 0xFF && src[1] == 0xFE:
		return .Utf_16le, 0, 2, true
	}
	enc, at, found = prescan(src[:min(len(src), PRESCAN_BYTES)])
	return
}

// A `meta` start tag the tree reads while the encoding is tentative, no mark or prescan having named one, changes the
// encoding to the one it names. Sets `t.misread`, with `t.at` at the label, when that encoding reads the text otherwise
// than UTF-8.
@(private)
meta_changes_encoding :: proc(t: ^Html_Tree, attrs: []Attribute) {
	enc, at, found := meta_encoding(t, attrs)
	if !found {
		return
	}
	t.tentative = false
	t.encoding = meta_named(enc)
	if !reads_as_utf8(t.src, t.encoding) {
		t.misread = true
		t.at = at
	}
}

// The encoding a `meta` element's attributes name: its `charset`, else its `content` when its `http-equiv` is
// `content-type`. Returns where the label starts, the value's start when the value holds a character reference.
@(private)
meta_encoding :: proc(t: ^Html_Tree, attrs: []Attribute) -> (enc: Encoding, at: u64, found: bool) {
	label_at :: proc(a: ^Attribute, i: u64) -> u64 {
		return a.value.lo + i if a.value.flags & ~{.Missing} == {} else a.value.lo
	}
	if a := attribute_of(t, attrs, "charset"); a != nil {
		v := transmute([]u8)decoded(t, a.value, 0)
		if e, i, ok := encoding_of(v, 0, len(v)); ok {
			return e, label_at(a, i), true
		}
	}
	if _, pragma := attr_value_is(t, attrs, "http-equiv", "content-type"); pragma {
		if a := attribute_of(t, attrs, "content"); a != nil {
			v := transmute([]u8)decoded(t, a.value, 0)
			if e, i, ok := content_charset(v, 0, len(v)); ok {
				return e, label_at(a, i), true
			}
		}
	}
	return
}

// The encoding a `meta` naming `enc` sets: UTF-8 for UTF-16, which no `meta` can name, and windows-1252 for
// x-user-defined.
@(private)
meta_named :: proc "contextless" (enc: Encoding) -> Encoding {
	#partial switch enc {
	case .Utf_16be, .Utf_16le:
		return .Utf_8
	case .X_User_Defined:
		return .Windows_1252
	}
	return enc
}

// Whether `enc` reads every byte of `src` as UTF-8 does.
@(private)
reads_as_utf8 :: proc "contextless" (src: []u8, enc: Encoding) -> bool {
	#partial switch enc {
	case .Utf_8:
		return true
	case .Replacement, .Utf_16be, .Utf_16le:
		return false
	case .Iso_2022_Jp:
		// Its escape sequences and shifts are ASCII bytes.
		for b in src {
			if b >= 0x80 || b == 0x0E || b == 0x0F || b == 0x1B {
				return false
			}
		}
		return true
	}
	for b in src {
		if b >= 0x80 {
			return false
		}
	}
	return true
}

// The prescan: the encoding the first `meta` naming one names, and where its label starts.
@(private)
prescan :: proc "contextless" (b: []u8) -> (enc: Encoding, at: u64, found: bool) {
	n := len(b)
	for i := 0; i < n; i += 1 {
		if b[i] != '<' {
			continue
		}
		switch {
		case has_at(b, i, "<!--"):
			// The `>` of the first `-->` from the comment's own `--`, so `<!-->` is a comment.
			j := i + 2
			for j + 2 < n && !(b[j] == '-' && b[j + 1] == '-' && b[j + 2] == '>') {
				j += 1
			}
			if j + 2 >= n {
				return
			}
			i = j + 2
		case i + 5 < n && fold_equal(raw_data(b)[i:], transmute([]u8)string("<meta")) && (is_space(b[i + 5]) || b[i + 5] == '/'):
			i += 5
			e, a, ok, ended := meta(b, &i)
			if ended {
				return
			}
			if ok {
				return e, a, true
			}
		case i + 1 < n && (is_alpha(b[i + 1]) || b[i + 1] == '/' && i + 2 < n && is_alpha(b[i + 2])):
			for i < n && !is_space(b[i]) && b[i] != '>' {
				i += 1
			}
			for {
				_, more, ended := get_attribute(b, &i)
				if ended {
					return
				}
				if !more {
					break
				}
			}
		case i + 1 < n && (b[i + 1] == '!' || b[i + 1] == '/' || b[i + 1] == '?'):
			i += 1
			for i < n && b[i] != '>' {
				i += 1
			}
			if i >= n {
				return
			}
		}
	}
	return
}

// An attribute the prescan reads: its name and value, ASCII case folded when compared, as byte ranges.
@(private)
Prescan_Attribute :: struct {
	name_lo, name_hi, value_lo, value_hi: int,
}

// The attributes of a `meta` whose name `i` is past, up to its `>`. Returns the encoding they name with the pragma
// they need, where its label starts, whether they name one, and whether the bytes ran out first.
@(private)
meta :: proc "contextless" (b: []u8, i: ^int) -> (enc: Encoding, at: u64, ok, ended: bool) {
	Pragma :: enum u8 {
		Unknown,
		Needed,
		Not_Needed,
	}
	Seen :: enum u8 {
		Http_Equiv,
		Content,
		Charset,
	}
	seen: bit_set[Seen; u8]
	got_pragma := false
	need := Pragma.Unknown
	charset_set, charset_ok := false, false
	for {
		attr, more, out := get_attribute(b, i)
		if out {
			return {}, 0, false, true
		}
		if !more {
			break
		}
		name := b[attr.name_lo:attr.name_hi]
		value := b[attr.value_lo:attr.value_hi]
		switch {
		case ascii_fold_equal(string(name), "http-equiv"):
			if .Http_Equiv not_in seen {
				seen += {.Http_Equiv}
				got_pragma ||= ascii_fold_equal(string(value), "content-type")
			}
		case ascii_fold_equal(string(name), "content"):
			if .Content not_in seen {
				seen += {.Content}
				if !charset_set {
					if e, a, found := content_charset(b, attr.value_lo, attr.value_hi); found {
						enc, at = e, a
						charset_set, charset_ok = true, true
						need = .Needed
					}
				}
			}
		case ascii_fold_equal(string(name), "charset"):
			if .Charset not_in seen {
				seen += {.Charset}
				e, a, found := encoding_of(b, attr.value_lo, attr.value_hi)
				enc, at = e, a
				charset_set, charset_ok = true, found
				need = .Not_Needed
			}
		}
	}
	if need == .Unknown || need == .Needed && !got_pragma || !charset_ok {
		return {}, 0, false, false
	}
	return meta_named(enc), at, true, false
}

// The prescan's "get an attribute" from `i`. Returns the attribute, whether there was one before a `>`, and whether
// the bytes ran out first. `i` is left at the byte after the attribute.
@(private)
get_attribute :: proc "contextless" (b: []u8, i: ^int) -> (attr: Prescan_Attribute, ok, ended: bool) {
	n := len(b)
	p := i^
	defer i^ = p
	for p < n && (is_space(b[p]) || b[p] == '/') {
		p += 1
	}
	if p >= n {
		return {}, false, true
	}
	if b[p] == '>' {
		return {}, false, false
	}
	attr.name_lo = p
	for {
		if p >= n {
			return {}, false, true
		}
		c := b[p]
		if c == '=' && p > attr.name_lo {
			attr.name_hi = p
			p += 1
			break
		}
		if is_space(c) {
			attr.name_hi = p
			for p < n && is_space(b[p]) {
				p += 1
			}
			if p >= n {
				return {}, false, true
			}
			if b[p] != '=' {
				attr.value_lo, attr.value_hi = p, p
				return attr, true, false
			}
			p += 1
			break
		}
		if c == '/' || c == '>' {
			attr.name_hi = p
			attr.value_lo, attr.value_hi = p, p
			return attr, true, false
		}
		p += 1
	}
	for p < n && is_space(b[p]) {
		p += 1
	}
	if p >= n {
		return {}, false, true
	}
	switch q := b[p]; q {
	case '"', '\'':
		p += 1
		attr.value_lo = p
		for p < n && b[p] != q {
			p += 1
		}
		if p >= n {
			return {}, false, true
		}
		attr.value_hi = p
		p += 1
		return attr, true, false
	case '>':
		attr.value_lo, attr.value_hi = p, p
		return attr, true, false
	}
	attr.value_lo = p
	for p < n && !is_space(b[p]) && b[p] != '>' {
		p += 1
	}
	if p >= n {
		return {}, false, true
	}
	attr.value_hi = p
	return attr, true, false
}

// The encoding a `content` attribute's value `b[lo:hi]` names after `charset=`.
@(private)
content_charset :: proc "contextless" (b: []u8, lo, hi: int) -> (enc: Encoding, at: u64, ok: bool) {
	p := lo
	for {
		for p + 7 <= hi && !fold_equal(raw_data(b)[p:], transmute([]u8)string("charset")) {
			p += 1
		}
		if p + 7 > hi {
			return
		}
		p += 7
		for p < hi && is_space(b[p]) {
			p += 1
		}
		if p < hi && b[p] == '=' {
			break
		}
	}
	p += 1
	for p < hi && is_space(b[p]) {
		p += 1
	}
	if p >= hi {
		return
	}
	if q := b[p]; q == '"' || q == '\'' {
		for e := p + 1; e < hi; e += 1 {
			if b[e] == q {
				return encoding_of(b, p + 1, e)
			}
		}
		return
	}
	e := p
	for e < hi && !is_space(b[e]) && b[e] != ';' {
		e += 1
	}
	return encoding_of(b, p, e)
}

// The encoding label `b[lo:hi]` names, ASCII whitespace trimmed and case folded, and where the label starts.
@(private)
encoding_of :: proc "contextless" (b: []u8, lo, hi: int) -> (enc: Encoding, at: u64, ok: bool) {
	lo, hi := lo, hi
	for lo < hi && is_space(b[lo]) {
		lo += 1
	}
	for hi > lo && is_space(b[hi - 1]) {
		hi -= 1
	}
	label := b[lo:hi]
	l, r := 0, len(ENCODING_LABELS)
	for l < r {
		m := (l + r) / 2
		c := compare_label(label, ENCODING_LABELS[m].label)
		if c == 0 {
			return ENCODING_LABELS[m].encoding, u64(lo), true
		}
		if c < 0 {
			r = m
		} else {
			l = m + 1
		}
	}
	return {}, u64(lo), false
}

// Orders `s`, ASCII lowered, against lowercase `label`.
@(private)
compare_label :: proc "contextless" (s: []u8, label: string) -> int {
	for i in 0 ..< min(len(s), len(label)) {
		c := s[i] | 0x20 if 'A' <= s[i] && s[i] <= 'Z' else s[i]
		if c != label[i] {
			return -1 if c < label[i] else 1
		}
	}
	return len(s) - len(label)
}

@(private)
has_at :: #force_inline proc "contextless" (b: []u8, i: int, s: string) -> bool {
	return i + len(s) <= len(b) && string(b[i:][:len(s)]) == s
}

// ASCII whitespace as the prescan reads it: tab, line feed, form feed, carriage return and space.
@(private)
is_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return CLASS[c] & C_WS != 0
}

@(private)
is_alpha :: #force_inline proc "contextless" (c: u8) -> bool {
	return CLASS[c] & C_ALPHA != 0
}
