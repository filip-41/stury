package query

import "core:net"
import "core:strings"

// IP address texts: IPv4 in dotted decimal and IPv6 by RFC 4291 section 2.2, with no zone and no brackets, read and
// written by `core:net`. Every `v` below is a string, which the caller checked.

// Whether `s` may go to `core:net` as an address with nothing but its digits: that package reads `a.b.c.d:port` and
// `[a]:port` as an address with a port, an IPv4 address of fewer than four parts, and one with an empty part at its
// end. A leading zero in a part it refuses itself.
@(private)
bare_address :: proc(s: string) -> bool {
	colons := strings.count(s, ":")
	if colons == 1 || strings.contains_any(s, "[]%") {
		return false
	}
	dotted := s[strings.last_index_byte(s, ':') + 1:]
	if colons > 0 && !strings.contains_rune(dotted, '.') {
		return true
	}
	return strings.count(dotted, ".") == 3 && !strings.has_prefix(dotted, ".") && !strings.has_suffix(dotted, ".") &&
		!strings.contains(dotted, "..")
}

@(private)
parse_address :: proc(s: string) -> (a: net.Address, ok: bool) {
	if !bare_address(s) {
		return nil, false
	}
	// `core:net` takes at most six colons before a dotted tail, which a leading `::` and five groups pass. That `::`
	// stands for one zero group there, so the address reads the same with it written `0:`.
	if strings.has_prefix(s, "::") && strings.count(s, ":") == 7 && strings.contains_rune(s, '.') {
		buf: [64]u8
		if len(s) >= len(buf) {
			return nil, false
		}
		buf[0] = '0'
		n := copy(buf[1:], s[1:])
		a = net.parse_address(string(buf[:n + 1]))
		return a, a != nil
	}
	a = net.parse_address(s)
	return a, a != nil
}

@(private, require_results)
address_of :: proc(h: ^Heap, v: Value) -> (a: net.Address, status: Status) {
	ok: bool
	if a, ok = parse_address(text_of(v)); !ok {
		return nil, fail(h, .Parse, .Address, v, detail = "is not an IP address")
	}
	return a, .Ok
}

// Whether string `v` is an IPv4 or IPv6 address, false for any other value.
ip_valid :: proc(v: Value) -> bool {
	if !is_text(v) {
		return false
	}
	_, ok := parse_address(text_of(v))
	return ok
}

// The class of address `v`: "loopback", "private", "link-local", "multicast", "unspecified" (all zero), or "global",
// which is every other address, the remaining reserved ranges not told apart. An IPv4-mapped IPv6 address is classed
// as its IPv4.
@(require_results)
ip_class :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	a := address_of(h, v) or_return
	return text_borrowed(class_of(a)), .Ok
}

@(private)
class_of :: proc(a: net.Address) -> string {
	switch v in a {
	case net.IP4_Address:
		switch {
		case v == net.IP4_Address{}:
			return "unspecified"
		case v[0] == 127:
			return "loopback"
		case v[0] == 10, v[0] == 172 && v[1] & 0xF0 == 16, v[0] == 192 && v[1] == 168:
			return "private"
		case v[0] == 169 && v[1] == 254:
			return "link-local"
		case v[0] & 0xF0 == 224:
			return "multicast"
		}
	case net.IP6_Address:
		if mapped, ok := net.unmap_ip4(v); ok {
			return class_of(mapped)
		}
		b := transmute([16]u8)v
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
	}
	return "global"
}

// The canonical text of address `v`: dotted decimal, or RFC 5952 for IPv6, which is lowercase hex without leading
// zeros, the longest run of two or more zero groups (the first of equals) written `::`, and an IPv4-mapped address
// with its IPv4 part dotted (section 5).
@(require_results)
ip_canonical :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	a := address_of(h, v) or_return
	// The longest text is an IPv6 address of eight four-digit groups.
	buf: [40]u8
	b := strings.builder_from_bytes(buf[:])
	return text_value(h, net.address_to_string_builder(a, &b))
}

// Whether address `v` is in the network `cidr`, `address/length`. An address of the other family is not.
@(require_results)
ip_in_cidr :: proc(h: ^Heap, v, cidr: Value) -> (res: bool, status: Status) {
	a := address_of(h, v) or_return
	text := text_of(cidr) if is_text(cidr) else ""
	network := text[:max(strings.last_index_byte(text, '/'), 0)]
	prefix, ok := net.parse_prefix(text)
	if !ok || !bare_address(network) {
		return false, fail(h, .Parse, .Address, cidr, detail = "is not a CIDR network")
	}
	return net.prefix_contains(prefix, a), .Ok
}
