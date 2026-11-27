package rules

import "core:strings"
import "core:unicode/utf8"

@(private) MAX_LABEL :: 63
@(private) MAX_NAME  :: 253

@(private)
mailbox_valid :: proc(s: string, idn: bool) -> bool {
	if idn {
		if !utf8.valid_string(s) { return false }
		for r in s { if r >= 0x80 && r <= 0x9F { return false } }
	}
	local_end := 0
	if strings.has_prefix(s, "\"") {
		i := 1
		for ; i < len(s) && s[i] != '"'; i += 1 {
			if s[i] == '\\' { i += 1 }
			if i >= len(s) || !(s[i] >= 0x20 && s[i] < 0x7F || idn && s[i] >= 0x80) { return false }
		}
		local_end = i + 1
	} else {
		if local_end = strings.index_byte(s, '@'); local_end < 0 { return false }
		prev_dot := true
		for c in transmute([]u8)s[:local_end] {
			atext := c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || strings.contains_rune("!#$%&'*+-/=?^_`{|}~", rune(c)) || idn && c >= 0x80
			if c == '.' && prev_dot || !atext && c != '.' { return false }
			prev_dot = c == '.'
		}
		if prev_dot { return false }
	}
	if local_end > 64 || local_end >= len(s) || s[local_end] != '@' { return false }
	domain := s[local_end + 1:]
	if strings.has_prefix(domain, "[") && strings.has_suffix(domain, "]") {
		lit := domain[1:len(domain) - 1]
		return ipv4_valid(lit) || len(lit) > 5 && strings.equal_fold(lit[:5], "IPv6:") && ipv6_valid(lit[5:])
	}
	return domain_valid(domain, idn)
}

@(private)
domain_valid :: proc(s: string, idn: bool) -> bool {
	ok, rtl := domain_pass(s, idn, false)
	if ok && rtl { ok, _ = domain_pass(s, idn, true) }
	return ok
}

@(private)
domain_pass :: proc(s: string, idn, bidi: bool) -> (ok, rtl: bool) {
	judge :: proc(cps: []rune, idn, bidi: bool, total: ^int, rtl: ^bool) -> bool {
		length, label_rtl, label_ok := label_valid(cps, idn, bidi)
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
			if count, mapped_ok = map_code_point(r, &out); !mapped_ok { return false, false }
		} else if r < 0x80 {
			out[0] = r + 32 if r >= 'A' && r <= 'Z' else r
		} else {
			return false, false
		}
		for m in out[:count] {
			if m == '.' {
				judge(label[:n], idn, bidi, &total, &rtl) or_return
				n = 0
			} else if n == len(label) {
				return false, false
			} else {
				label[n], n = m, n + 1
			}
		}
	}
	return judge(label[:n], idn, bidi, &total, &rtl), rtl
}

@(private)
label_valid :: proc(cps: []rune, idn, bidi: bool) -> (length: int, rtl, ok: bool) {
	if len(cps) == 0 { return }
	plain := true
	for c in cps { plain &&= c < 0x80 }
	u: [MAX_LABEL + 1]rune
	unicode_label := cps
	if plain {
		for c in cps { if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') { return } }
		if length = len(cps); length > MAX_LABEL { return }
		if length >= 4 && cps[0] == 'x' && cps[1] == 'n' && cps[2] == '-' && cps[3] == '-' {
			body: [MAX_LABEL]u8
			for c, i in cps[4:] { body[i] = u8(c) }
			decoded, decoded_ok := punycode_decode(string(body[:length - 4]), u[:])
			if !decoded_ok || decoded >= 4 && u[2] == '-' && u[3] == '-' { return }
			unicode_label = u[:decoded]
			some_unicode := false
			for c in unicode_label { some_unicode ||= c >= 0x80 }
			encoded: [MAX_LABEL]u8
			again, again_ok := punycode_encode(unicode_label, encoded[:])
			if !some_unicode || !again_ok || string(encoded[:again]) != string(body[:length - 4]) { return }
		} else if idn && length >= 4 && cps[2] == '-' && cps[3] == '-' {
			return
		}
	} else {
		encoded: [MAX_LABEL]u8
		count, encoded_ok := punycode_encode(cps, encoded[:])
		if !encoded_ok || 4 + count > MAX_LABEL || len(cps) >= 4 && cps[2] == '-' && cps[3] == '-' { return }
		length = 4 + count
	}
	rtl, ok = ulabel_valid(unicode_label, bidi)
	return
}

@(private)
adapt :: proc "contextless" (delta, points: int, first: bool) -> (bias: int) {
	d := delta / 700 if first else delta / 2
	d += d / points
	k := 0
	for ; d > 35 * 26 / 2; k += 36 { d /= 35 }
	return k + 36 * d / (d + 38)
}

@(private)
punycode_threshold :: proc "contextless" (k, bias: int) -> int {
	return 1 if k <= bias else (26 if k >= bias + 26 else k - bias)
}

@(private)
punycode_decode :: proc(body: string, out: []rune) -> (n: int, ok: bool) {
	basic := strings.last_index_byte(body, '-')
	for c in transmute([]u8)body[:max(basic, 0)] {
		if n == len(out) { return }
		out[n], n = rune(c), n + 1
	}
	i, code, bias := 0, 128, 72
	for at := basic + 1; at < len(body); {
		before, w := i, 1
		for k := 36; ; k += 36 {
			if at >= len(body) { return }
			c, digit := body[at], 0
			switch {
			case c >= 'a' && c <= 'z': digit = int(c - 'a')
			case c >= 'A' && c <= 'Z': digit = int(c - 'A')
			case c >= '0' && c <= '9': digit = int(c - '0') + 26
			case: return
			}
			at += 1
			LIMIT :: 1 << 30
			if digit > (LIMIT - i) / w { return }
			i += digit * w
			t := punycode_threshold(k, bias)
			if digit < t { break }
			if w > LIMIT / (36 - t) { return }
			w *= 36 - t
		}
		bias = adapt(i - before, n + 1, before == 0)
		code += i / (n + 1)
		i %= n + 1
		if code > 0x10FFFF || n == len(out) { return }
		copy(out[i + 1:n + 1], out[i:n])
		out[i] = rune(code)
		i, n = i + 1, n + 1
	}
	return n, true
}

@(private)
punycode_encode :: proc "contextless" (cps: []rune, out: []u8) -> (n: int, ok: bool) {
	put :: proc "contextless" (out: []u8, n: ^int, c: u8) -> bool {
		if n^ == len(out) { return false }
		out[n^] = c; n^ += 1; return true
	}
	digit :: proc "contextless" (d: int) -> u8 { return u8('a' + d) if d < 26 else u8('0' + d - 26) }
	basic := 0
	for c in cps { if c < 0x80 { put(out, &n, u8(c)) or_return; basic += 1 } }
	if basic > 0 { put(out, &n, '-') or_return }
	code, delta, bias, done := 128, 0, 72, basic
	for done < len(cps) {
		next := max(int)
		for c in cps { if int(c) >= code { next = min(next, int(c)) } }
		delta += (next - code) * (done + 1)
		code = next
		for c in cps {
			if int(c) < code {
				delta += 1
			} else if int(c) == code {
				q := delta
				for k := 36; ; k += 36 {
					t := punycode_threshold(k, bias)
					if q < t { break }
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
