package msgpack

import "stury:lib/core/tape"

// Streaming piece-by-piece decoder of MessagePack scalar text: tolerated UTF-8 replacement (`U+FFFD`),
// binary keys in base64, integer keys in decimal digits, and Timestamp (`ext -1`) payloads in RFC 3339.

@(private)
Text_Mode :: enum u8 {
	Bytes,
	Lax,
	Base64,
	Digits,
	Timestamp,
}

@(private)
Text_Run :: struct {
	src:      []u8,
	pos, end: u64,
	mode:     Text_Mode,
	scratch:  [TIMESTAMP_TEXT_ROOM]u8,
	given:    bool,
}

// Initializes a streaming text reader for token `t` of `src`.
@(private)
text_run :: proc "contextless" (src: []u8, t: tape.Token) -> (r: Text_Run) {
	r.src = src
	if t.kind == .Number {
		r.mode = .Digits
		digits := integer_text(src[t.lo:t.lo + u64(t.n)], r.scratch[:24])
		r.pos = u64(uintptr(raw_data(digits)) - uintptr(&r.scratch[0]))
		r.end = r.pos + u64(len(digits))
		return
	}
	if t.spelling & STR_TIMESTAMP != 0 {
		r.mode = .Timestamp
		ts, _ := timestamp_text(src[t.lo:t.lo + u64(t.n)], r.scratch[:])
		r.pos = 0
		r.end = u64(len(ts))
		return
	}
	r.pos, r.end = t.lo, t.lo + u64(t.n)
	if t.kind == .Bytes && t.role == .Key {
		r.mode = .Base64
	} else if t.spelling & tape.SPELLING_LAX != 0 {
		r.mode = .Lax
	}
	return
}

// Returns the next decoded byte chunk from `r`, or false when exhausted.
@(private)
text_next :: proc "contextless" (r: ^Text_Run) -> ([]u8, bool) #no_bounds_check {
	switch r.mode {
	case .Digits, .Timestamp:
		if r.given {
			return nil, false
		}
		r.given = true
		return r.scratch[r.pos:r.end], true
	case .Base64:
		if r.pos >= r.end {
			return nil, false
		}
		group: [3]u8
		k := 0
		for k < 3 && r.pos < r.end {
			group[k] = r.src[r.pos]
			r.pos += 1
			k += 1
		}
		return tape.base64_encode_group(group, k, r.scratch[:]), true
	case .Bytes:
		if r.pos >= r.end {
			return nil, false
		}
		piece := r.src[r.pos:r.end]
		r.pos = r.end
		return piece, true
	case .Lax:
		if r.pos >= r.end {
			return nil, false
		}
		return tape.lax_utf8_piece(r.src, &r.pos, r.end, r.scratch[:]), true
	}
	return nil, false
}

// Decodes scalar node `t` into `buf`.
@(private)
text_decoded :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, _: ^tape.Format_Ext) -> (string, bool) {
	if t.kind == .Number {
		return number_text(src, t, buf)
	}
	if t.spelling & STR_TIMESTAMP != 0 {
		return timestamp_text(src[t.lo:t.lo + u64(t.n)], buf)
	}
	r := text_run(src, t)
	return tape.stream_text_decoded(&r, buf, text_next)
}

// Buffer size guaranteed to hold `text_decoded` of scalar `t`.
@(private)
decode_room :: proc "contextless" (src: []u8, t: tape.Node, _: ^tape.Format_Ext) -> int {
	switch {
	case t.kind == .Number:
		return number_room(src, t)
	case t.kind == .Bytes && t.role == .Key:
		return int(min((u64(t.n) + 2) / 3 * 4, u64(max(int))))
	case t.spelling & STR_TIMESTAMP != 0:
		return TIMESTAMP_TEXT_ROOM
	case t.spelling & tape.SPELLING_LAX != 0:
		return int(min(3 * u64(t.n), u64(max(int))))
	}
	return int(min(u64(t.n), u64(max(int))))
}

// Compares the decoded text of scalar `t` of `src` and scalar `o` of `other`.
@(private)
same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	return tape.stream_same_text(src, t, other, o, text_run, text_next)
}

// Computes `tape.text_hash` of the decoded text of key `t` in `src`.
@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	return tape.stream_key_hash(src, t, text_run, text_next)
}
