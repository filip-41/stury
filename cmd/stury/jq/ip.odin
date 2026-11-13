package jq

// Builtins beyond jq on IP address text: IPv4 in dotted decimal and IPv6 by RFC 4291 section 2.2 (no zone, no brackets).

import "core:fmt"
import "core:strings"

@(private = "file")
Address :: struct {
	bytes: [16]byte, // an IPv4 address in the first four
	v4:    bool,
}

@(private = "file")
parse_address :: proc(s: string) -> (a: Address, ok: bool) {
	if strings.index_byte(s, ':') < 0 {
		a.v4 = true
		ok = parse_dotted(s, a.bytes[:4])
		return a, ok
	}
	left, double, right := strings.partition(s, "::")
	if double != "" && strings.contains(right, "::") {
		return {}, false
	}
	groups: [8]u16
	count := 0
	// The groups of one side of the `::`, or of the whole address; the last may be a dotted IPv4 address.
	read_side :: proc(side: string, groups: ^[8]u16, count: ^int, last_side: bool) -> bool {
		if side == "" {
			return true
		}
		rest := side
		for part in strings.split_iterator(&rest, ":") {
			dotted := rest == "" && last_side && strings.contains_rune(part, '.')
			room := 2 if dotted else 1
			if count^ + room > 8 {
				return false
			}
			if dotted {
				tail: [4]byte
				if !parse_dotted(part, tail[:]) {
					return false
				}
				groups[count^], groups[count^ + 1] = u16(tail[0]) << 8 | u16(tail[1]), u16(tail[2]) << 8 | u16(tail[3])
				count^ += 2
				continue
			}
			if len(part) < 1 || len(part) > 4 {
				return false
			}
			g := 0
			for c in transmute([]byte)part {
				d := hex_value(c)
				if d > 15 {
					return false
				}
				g = g << 4 | int(d)
			}
			groups[count^] = u16(g)
			count^ += 1
		}
		return true
	}
	if double == "" {
		if !read_side(left, &groups, &count, true) || count != 8 {
			return {}, false
		}
	} else {
		head: [8]u16
		tail: [8]u16
		heads, tails := 0, 0
		if !read_side(left, &head, &heads, false) || !read_side(right, &tail, &tails, true) || heads + tails > 7 {
			return {}, false
		}
		copy(groups[:heads], head[:heads])
		copy(groups[8 - tails:], tail[:tails])
	}
	for g, i in groups {
		a.bytes[i * 2], a.bytes[i * 2 + 1] = byte(g >> 8), byte(g)
	}
	return a, true
}

@(private = "file")
hex_value :: proc(c: byte) -> byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	}
	return 0xFF
}

// Four decimal octets without leading zeros, which some readers take as octal.
@(private = "file")
parse_dotted :: proc(s: string, out: []byte) -> bool {
	rest := s
	n := 0
	for part in strings.split_iterator(&rest, ".") {
		v := 0
		if n >= 4 || len(part) < 1 || len(part) > 3 || len(part) > 1 && part[0] == '0' {
			return false
		}
		for c in transmute([]byte)part {
			if c < '0' || c > '9' {
				return false
			}
			v = v * 10 + int(c - '0')
		}
		if v > 255 {
			return false
		}
		out[n] = byte(v)
		n += 1
	}
	return n == 4
}

@(private = "file")
address_of :: proc(ip: ^Interp, name: string, v: Value) -> (Address, Signal) {
	s, is_str := string_of(v)
	if !is_str {
		return {}, fail(ip, "%s (%s) cannot be read as an IP address, only a string", type_name(v), brief(ip, v))
	}
	a, ok := parse_address(s)
	if !ok {
		return {}, fail(ip, "string (%s) is not an IP address", brief(ip, s))
	}
	return a, .Go
}

// ip_valid: whether the input is a string that is an IPv4 or IPv6 address.
fn_ip_valid :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	s, is_str := string_of(v)
	if !is_str {
		return false, .Go
	}
	_, ok := parse_address(s)
	return ok, .Go
}

// ip_class and ip_canonical.
fn_ip_text :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	a := address_of(ip, name, v) or_return
	if name == "ip_class" {
		return address_class(a), .Go
	}
	if a.v4 {
		return fmt.aprintf("%d.%d.%d.%d", a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3]), .Go
	}
	return canonical_v6(a.bytes), .Go
}

// The class of an address: loopback, private, link-local, multicast, unspecified (all zero), or global, which is every
// other address: the remaining reserved ranges are not told apart. An IPv4-mapped IPv6 address is classed as its IPv4.
@(private = "file")
address_class :: proc(a: Address) -> string {
	b := a.bytes
	if !a.v4 {
		mapped := b[10] == 0xFF && b[11] == 0xFF
		for c in b[:10] {
			mapped &&= c == 0
		}
		if mapped {
			return address_class({bytes = {0 = b[12], 1 = b[13], 2 = b[14], 3 = b[15]}, v4 = true})
		}
		zeros := true
		for c in b[:15] {
			zeros &&= c == 0
		}
		switch {
		case zeros && b[15] == 0:
			return "unspecified"
		case zeros && b[15] == 1:
			return "loopback"
		case b[0] == 0xFF:
			return "multicast"
		case b[0] & 0xFE == 0xFC:
			return "private"
		case b[0] == 0xFE && b[1] & 0xC0 == 0x80:
			return "link-local"
		}
		return "global"
	}
	switch {
	case b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 0:
		return "unspecified"
	case b[0] == 127:
		return "loopback"
	case b[0] == 10, b[0] == 172 && b[1] & 0xF0 == 16, b[0] == 192 && b[1] == 168:
		return "private"
	case b[0] == 169 && b[1] == 254:
		return "link-local"
	case b[0] & 0xF0 == 224:
		return "multicast"
	}
	return "global"
}

// RFC 5952: lowercase hex without leading zeros, the longest run of two or more zero groups (the first of equals)
// written `::`, and an IPv4-mapped address with its IPv4 part dotted (section 5).
@(private = "file")
canonical_v6 :: proc(b: [16]byte) -> string {
	groups: [8]u16
	for i in 0 ..< 8 {
		groups[i] = u16(b[i * 2]) << 8 | u16(b[i * 2 + 1])
	}
	best_at, best_len := -1, 1
	for i := 0; i < 8; {
		run := 0
		for i + run < 8 && groups[i + run] == 0 {
			run += 1
		}
		if run > best_len {
			best_at, best_len = i, run
		}
		i += max(run, 1)
	}
	mapped := best_at == 0 && best_len == 5 && groups[5] == 0xFFFF
	out := strings.builder_make()
	after_gap := true
	for i := 0; i < 8; i += 1 {
		if i == best_at {
			strings.write_string(&out, "::")
			i += best_len - 1
			after_gap = true
			continue
		}
		if !after_gap {
			strings.write_byte(&out, ':')
		}
		after_gap = false
		if mapped && i == 6 {
			fmt.sbprintf(&out, "%d.%d.%d.%d", b[12], b[13], b[14], b[15])
			break
		}
		fmt.sbprintf(&out, "%x", groups[i])
	}
	return strings.to_string(out)
}

// ip_in_cidr(cidr): whether the input address is in the network `address/length`. An address of the other family is not.
fn_ip_in_cidr :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	a := address_of(ip, name, v) or_return
	cidr, _ := string_of(args[0])
	network_text, _, length_text := strings.partition(cidr, "/")
	network, network_ok := parse_address(network_text)
	length := 0
	length_ok := length_text != "" && len(length_text) <= 3
	for c in transmute([]byte)length_text {
		length = length * 10 + int(c - '0')
		length_ok &&= c >= '0' && c <= '9'
	}
	if !network_ok || !length_ok || length > (32 if network.v4 else 128) {
		return nil, fail(ip, "%s (%s) is not a CIDR network", type_name(args[0]), brief(ip, args[0]))
	}
	if a.v4 != network.v4 {
		return false, .Go
	}
	for i in 0 ..< length / 8 {
		if a.bytes[i] != network.bytes[i] {
			return false, .Go
		}
	}
	if rest := length % 8; rest > 0 {
		mask := byte(0xFF << uint(8 - rest))
		return a.bytes[length / 8] & mask == network.bytes[length / 8] & mask, .Go
	}
	return true, .Go
}
