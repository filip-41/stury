package rules

import "core:strings"

// The longest label of a host name, in its A-label form. A label buffer holds one more code point than that, so a label
// past it is told apart without a second buffer.
@(private)
MAX_LABEL :: 63

@(private)
MAX_NAME :: 253

// RFC 5321 `Mailbox`: a dot string or quoted string of at most 64 bytes, `@`, and a domain or an address literal. An
// internationalized mailbox (RFC 6531) also takes non-ASCII in the local part and an IDN domain.
@(private)
mailbox_valid :: proc(s: string, idn: bool) -> bool {
	idn_byte :: proc(c: u8, idn: bool) -> bool {
		return c >= 0x80 && idn
	}
	local_end := 0
	if strings.has_prefix(s, "\"") {
		i := 1
		for ; i < len(s) && s[i] != '"'; i += 1 {
			if s[i] == '\\' {
				i += 1
			}
			if i >= len(s) || !(s[i] >= 0x20 && s[i] < 0x7F || idn_byte(s[i], idn)) {
				return false
			}
		}
		local_end = i + 1
	} else {
		local_end = strings.index_byte(s, '@')
		if local_end < 0 {
			return false
		}
		previous_dot := true
		for c in transmute([]u8)s[:local_end] {
			atext := c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || strings.contains_rune("!#$%&'*+-/=?^_`{|}~", rune(c)) || idn_byte(c, idn)
			if c == '.' && previous_dot || !atext && c != '.' {
				return false
			}
			previous_dot = c == '.'
		}
		if previous_dot {
			return false
		}
	}
	if local_end > 64 || local_end >= len(s) || s[local_end] != '@' {
		return false
	}
	domain := s[local_end + 1:]
	if strings.has_prefix(domain, "[") && strings.has_suffix(domain, "]") {
		literal := domain[1:len(domain) - 1]
		return ipv4_valid(literal) || len(literal) > 5 && strings.equal_fold(literal[:5], "IPv6:") && ipv6_valid(literal[5:])
	}
	return domain_valid(domain, idn)
}

// A host name (RFC 1123) or, with `idn`, an internationalized domain name: dot separated labels, each an LDH label or
// an A-label that decodes to a valid U-label (RFC 5890), or with `idn` a U-label, under the bidi rule of RFC 5893 when
// any label holds right-to-left text.
@(private)
domain_valid :: proc(s: string, idn: bool) -> bool {
	ok, rtl := domain_pass(s, idn, false)
	if ok && rtl {
		ok, _ = domain_pass(s, idn, true)
	}
	return ok
}

// Judges each label of `s`, under the mapping of UTS 46 when `idn`, else with capitals lowered. `rtl` tells whether one
// of them holds right-to-left text, which a second pass with `bidi` set judges all of them by.
@(private)
domain_pass :: proc(s: string, idn, bidi: bool) -> (ok, rtl: bool) {
	judge :: proc(cps: []rune, bidi: bool, total: ^int, rtl: ^bool) -> bool {
		length, label_rtl, label_ok := label_valid(cps, bidi)
		total^ += length + 1
		rtl^ ||= label_rtl
		return label_ok && total^ <= MAX_NAME
	}
	label: [MAX_LABEL + 1]rune
	n, total := 0, -1
	for r in s {
		out: [MAX_MAPPED]rune
		count := 1
		if idn {
			mapped_ok: bool
			count, mapped_ok = map_code_point(r, &out)
			if !mapped_ok {
				return false, false
			}
		} else if r < 0x80 {
			out[0] = r + 32 if r >= 'A' && r <= 'Z' else r
		} else {
			return false, false
		}
		for m in out[:count] {
			if m == '.' {
				judge(label[:n], bidi, &total, &rtl) or_return
				n = 0
			} else if n == len(label) {
				return false, false
			} else {
				label[n], n = m, n + 1
			}
		}
	}
	return judge(label[:n], bidi, &total, &rtl), rtl
}

// Judges a label of code points: its form, and its length in A-label form.
@(private)
label_valid :: proc(cps: []rune, bidi: bool) -> (length: int, rtl, ok: bool) {
	if len(cps) == 0 {
		return
	}
	plain := true
	for c in cps {
		plain &&= c < 0x80
	}
	u: [MAX_LABEL + 1]rune
	unicode_label := cps
	if plain {
		for c in cps {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return
			}
		}
		length = len(cps)
		if length > MAX_LABEL {
			return
		}
		if length >= 4 && cps[0] == 'x' && cps[1] == 'n' && cps[2] == '-' && cps[3] == '-' {
			body: [MAX_LABEL]u8
			for c, i in cps[4:] {
				body[i] = u8(c)
			}
			decoded, decoded_ok := punycode_decode(string(body[:length - 4]), u[:])
			if !decoded_ok || decoded >= 4 && u[2] == '-' && u[3] == '-' {
				return
			}
			unicode_label = u[:decoded]
			some_unicode := false
			for c in unicode_label {
				some_unicode ||= c >= 0x80
			}
			encoded: [MAX_LABEL]u8
			again, again_ok := punycode_encode(unicode_label, encoded[:])
			if !some_unicode || !again_ok || string(encoded[:again]) != string(body[:length - 4]) {
				return
			}
		}
	} else {
		encoded: [MAX_LABEL]u8
		count, encoded_ok := punycode_encode(cps, encoded[:])
		if !encoded_ok || 4 + count > MAX_LABEL || len(cps) >= 4 && cps[2] == '-' && cps[3] == '-' {
			return
		}
		length = 4 + count
	}
	rtl, ok = ulabel_valid(unicode_label, bidi)
	return
}

// Punycode (RFC 3492) bias adaptation.
@(private)
adapt :: proc(delta, points: int, first: bool) -> (bias: int) {
	d := delta / 700 if first else delta / 2
	d += d / points
	k := 0
	for ; d > 35 * 26 / 2; k += 36 {
		d /= 35
	}
	return k + 36 * d / (d + 38)
}

@(private)
punycode_threshold :: proc(k, bias: int) -> int {
	return 1 if k <= bias else (26 if k >= bias + 26 else k - bias)
}

// Decodes the Punycode `body` of an A-label into `out`, returning the code points it holds.
@(private)
punycode_decode :: proc(body: string, out: []rune) -> (n: int, ok: bool) {
	basic := strings.last_index_byte(body, '-')
	for c in transmute([]u8)body[:max(basic, 0)] {
		if n == len(out) {
			return
		}
		out[n], n = rune(c), n + 1
	}
	i, code, bias := 0, 128, 72
	for at := basic + 1; at < len(body); {
		before, w := i, 1
		for k := 36; ; k += 36 {
			if at >= len(body) {
				return
			}
			c := body[at]
			digit := 0
			switch {
			case c >= 'a' && c <= 'z':
				digit = int(c - 'a')
			case c >= 'A' && c <= 'Z':
				digit = int(c - 'A')
			case c >= '0' && c <= '9':
				digit = int(c - '0') + 26
			case:
				return
			}
			at += 1
			i += digit * w
			t := punycode_threshold(k, bias)
			if digit < t {
				break
			}
			w *= 36 - t
			if i > 1 << 30 || w > 1 << 30 {
				return
			}
		}
		bias = adapt(i - before, n + 1, before == 0)
		code += i / (n + 1)
		i %= n + 1
		if code > 0x10FFFF || n == len(out) {
			return
		}
		copy(out[i + 1:n + 1], out[i:n])
		out[i] = rune(code)
		i, n = i + 1, n + 1
	}
	return n, true
}

// Encodes the code points `cps` to Punycode in `out` and returns its length.
@(private)
punycode_encode :: proc(cps: []rune, out: []u8) -> (n: int, ok: bool) {
	put :: proc(out: []u8, n: ^int, c: u8) -> bool {
		if n^ == len(out) {
			return false
		}
		out[n^] = c
		n^ += 1
		return true
	}
	digit :: proc(d: int) -> u8 {
		return u8('a' + d) if d < 26 else u8('0' + d - 26)
	}
	basic := 0
	for c in cps {
		if c < 0x80 {
			put(out, &n, u8(c)) or_return
			basic += 1
		}
	}
	if basic > 0 {
		put(out, &n, '-') or_return
	}
	code, delta, bias, done := 128, 0, 72, basic
	for done < len(cps) {
		next := max(int)
		for c in cps {
			if int(c) >= code {
				next = min(next, int(c))
			}
		}
		delta += (next - code) * (done + 1)
		code = next
		for c in cps {
			if int(c) < code {
				delta += 1
			} else if int(c) == code {
				q := delta
				for k := 36; ; k += 36 {
					t := punycode_threshold(k, bias)
					if q < t {
						break
					}
					put(out, &n, digit(t + (q - t) % (36 - t))) or_return
					q = (q - t) / (36 - t)
				}
				put(out, &n, digit(q)) or_return
				bias, delta, done = adapt(delta, done + 1, done == basic), 0, done + 1
			}
		}
		delta, code = delta + 1, code + 1
	}
	return n, true
}
