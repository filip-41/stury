package jq

import "stury:lib/query"

// stury's builtins beyond jq on texts: digests, codes, identifiers, URLs, query strings, logfmt, number formats, IP
// addresses and JSON Pointers, each name bound to an engine operation with jq's words for a wrong kind.

// Raises the words `parts` joined.
@(private)
raise_joined :: proc(m: ^Machine, parts: ..string) -> query.Status {
	out := make([dynamic]u8, m.h.allocator)
	defer delete(out)
	for p in parts {
		append(&out, p)
	}
	return raise_owned_text(m, string(out[:]))
}

// sha1, sha256, sha512, md5 and crc32.
@(private)
v_digest :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_joined(m, b.name, " input must be a string")
	}
	s := query.text_of(x)
	switch b.name {
	case "sha1":
		return query.digest_hex(m.h, s, .Sha1)
	case "sha256":
		return query.digest_hex(m.h, s, .Sha256)
	case "sha512":
		return query.digest_hex(m.h, s, .Sha512)
	case "md5":
		return query.digest_hex(m.h, s, .Md5)
	}
	return query.int_value(i64(query.crc32(s))), .Ok
}

// hmac_sha256(key) and hmac_sha512(key).
@(private)
v_hmac :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_joined(m, b.name, " input must be a string")
	}
	if !query.is_text(args[0]) {
		return query.NULL, raise_joined(m, b.name, " key must be a string")
	}
	return query.hmac_hex(m.h, query.text_of(x), query.text_of(args[0]), .Sha256 if b.name == "hmac_sha256" else .Sha512)
}

// hex_encode, hex_decode, base64url_encode and base64url_decode.
@(private)
v_text_code :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_joined(m, b.name, " input must be a string")
	}
	s := query.text_of(x)
	switch b.name {
	case "hex_encode":
		return query.encode_hex(m.h, s)
	case "base64url_encode":
		return query.encode_base(m.h, s, .Base64_Url, false)
	case "hex_decode":
		v, ok := query.decode_hex(m.h, s) or_return
		if !ok {
			return query.NULL, cannot_decode(m, x, "is not valid hex data")
		}
		return v, .Ok
	}
	v, fault := query.decode_base(m.h, s, .Base64_Url) or_return
	if fault != .None {
		return query.NULL, cannot_decode(m, x, base_fault_text(fault, "base64"))
	}
	return v, .Ok
}

// uuid_v4 and uuid_v7, from the hooks' random bytes and time.
@(private)
v_uuid :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	v7 := b.name == "uuid_v7"
	hooks := m.hooks
	if hooks == nil || hooks.random == nil || v7 && hooks.now == nil {
		return query.NULL, raise_joined(m, b.name, "/0 not implemented on this platform")
	}
	bytes: [16]u8
	hooks.random(hooks.data, bytes[:])
	if v7 {
		return query.uuid_text(m.h, bytes, i64(hooks.now(hooks.data) * 1000))
	}
	return query.uuid_text(m.h, bytes)
}

// parse_url, parse_query_string and parse_logfmt.
@(private)
v_parse_text :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		out := make([dynamic]u8, m.h.allocator)
		defer delete(out)
		typed(m.h, &out, x)
		append(&out, " cannot be parsed by ")
		append(&out, b.name)
		append(&out, ", only a string")
		return query.NULL, raise_owned_text(m, string(out[:]))
	}
	switch b.name {
	case "parse_url":
		return query.parse_url(m.h, x)
	case "parse_query_string":
		return query.parse_query_string(m.h, x)
	}
	return query.parse_logfmt(m.h, x)
}

// numfmt(spec).
@(private)
v_numfmt :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if query.type_of(x) != .Number {
		return query.NULL, raise_typed(m, x, " number required")
	}
	return query.number_format(m.h, x, args[0])
}

// ip_valid, ip_class, ip_canonical and ip_in_cidr(cidr).
@(private)
v_address :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if b.name == "ip_valid" {
		return query.bool_value(query.ip_valid(x)), .Ok
	}
	if !query.is_text(x) {
		return query.NULL, raise_typed(m, x, " cannot be read as an IP address, only a string")
	}
	switch b.name {
	case "ip_class":
		return query.ip_class(m.h, x)
	case "ip_canonical":
		return query.ip_canonical(m.h, x)
	}
	in_network := query.ip_in_cidr(m.h, x, args[0]) or_return
	return query.bool_value(in_network), .Ok
}

// _pointer_tokens(ptr), the tokens of `json_pointer`, and _pointer_index, a token as the index it names or null.
@(private)
v_pointer :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if b.name == "_pointer_tokens" {
		return query.pointer_tokens(m.h, args[0])
	}
	if i, ok := query.pointer_index(query.text_of(x)); ok {
		return query.int_value(i), .Ok
	}
	return query.NULL, .Ok
}
