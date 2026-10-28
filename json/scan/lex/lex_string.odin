package lex

import "core:simd"

// The bytes one string's escapes write beyond what they decode to. Raw bytes, wire UTF-8 included, decode
// to themselves, so the decoded length `.Dom` reserves exactly from the arena is the text's length less
// this, and only an escape unit charges it (`escape_step`). A surrogate pair is one escape unit and a lone
// half is refused (`escape_unit`), so every unit's bytes are known where it is read. A short reserve is a
// heap overflow.
// `skip_string_q` keeps no count: the locate route keeps the text and `.Decoded` stays clear, so no
// arena reserve is taken.
Dec_Count :: struct {
	shrink: u64,
}

// The kinds that read a key's escape bit at key time. `object_key` arms the latch for exactly this set and
// `latch_backslash` sets it for exactly this set, or a consumer reads a stale `false`.
KEY_ESC_KINDS :: bit_set[Walk_Kind]{.Demand, .Path, .Nodes, .Shape, .Unique}

// The kinds whose string values carry escape facts (`str_escaped`, `str_first_esc`) to their row.
STR_ESC_KINDS :: bit_set[Walk_Kind]{.Nodes, .Shape}

// Reset a string value's escape facts so the previous string's answer is never inherited. Keys need none:
// `object_key` brackets their parse with `key_esc_live` instead. Escape presence is a property of the
// bytes, so both string leaves latch the same facts.
str_esc_reset :: #force_inline proc(q: ^Query_Ctx, key: bool, $Q: bit_set[Walk_Kind]) {
	when Q & STR_ESC_KINDS != {} {
		if !key {
			q.str_escaped = false
			q.str_first_esc = 0
		}
	}
}

// The backslash at `s.pos`, latched for every consumer: a key's escape bit, and a string's first backslash
// as its offset from `lo` saturating at `FIRST_ESC_SATURATED`, so the clean head is `[lo+1, lo+off)`
// (`first_escape_offset`).
latch_backslash :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, $Q: bit_set[Walk_Kind]) {
	when Q & KEY_ESC_KINDS != {} {
		if q.key_esc_live { q.key_saw_escape = true }
	}
	when Q & STR_ESC_KINDS != {} {
		if !q.str_escaped {
			q.str_first_esc = u16(min(s.pos - lo, u64(FIRST_ESC_SATURATED)))
			q.str_escaped = true
		}
	}
}

// Advance the string span and answer the byte it stopped on, as `span_advance` does. A walk that
// decodes or reads values lands a long span by lane count, while the plain validate walk (`Q == {}`) and the
// bare `.Nodes` walk by probes, which their register allocation is laid out around.
@(private = "file")
span_step :: #force_inline proc(s: ^Scanner, $check: Check_Level, $Q: bit_set[Walk_Kind]) -> int {
	return span_advance(s, check, Q - {.Nodes} != {})
}

// One escape unit, consumed and charged at one site: the decoded value (`escape_decoded`).
escape_step :: #force_inline proc(s: ^Scanner, d: ^Dec_Count, q: ^Query_Ctx, $Q: bit_set[Walk_Kind]) -> Maybe(Error) {
	when .Dom in Q {
		at := s.pos
		cp: u32
		if err := escape_unit(s, &cp, true); err != nil {
			return err
		}
		d.shrink += s.pos - at - escape_decoded(cp)
		return nil
	} else {
		return escape_unit(s, nil, false)
	}
}

// The most units `parse_string_q` takes inline after an escape before rejoining the span.
PROBE_HEAD :: 16

// The strict string leaf: every escape and control byte checked, and the decoded byte count riding along
// with the walk, so no second pass over the string exists.
parse_string_q :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, key: bool, $Q: bit_set[Walk_Kind]) -> Maybe(Error) {
	return string_q(s, q, lo, key, Q, .Values)
}

// String boundaries only. `\"` never ends the string and a backslash escapes exactly one byte, so this
// leaf and stage 1 agree on where every string ends. Escape grammar is unchecked, but wire UTF-8 is
// validated, since encoding is not grammar.
skip_string_q :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, key: bool, $Q: bit_set[Walk_Kind]) -> Maybe(Error) {
	return string_q(s, q, lo, key, Q, .Locate)
}

// The string leaf at `lo` at check level `check`, collecting the facts `Q` asks for. `key` says the token is
// an object member's key: `.Dom` hands no payload to a row for one. Only `.Values` decodes: `.Locate` keeps the
// text, so the row is not `decoded` and nothing is reserved.
@(private = "file")
string_q :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	lo: u64,
	key: bool,
	$Q: bit_set[Walk_Kind],
	$check: Check_Level,
) -> Maybe(Error) {
	dec: Dec_Count
	// Whether a backslash was seen: `.Dom` decides between the zero-copy source slice and an arena decode.
	saw_esc := false
	str_esc_reset(q, key, Q)
	s.pos += 1 // opening quote
	#no_bounds_check {
		when Q - {.Nodes} != {} {
			// A value string that closes in its first 16 bytes is landed by lane count here: value lengths
			// vary, so the span's probe exits mispredict. Keys keep the probes, whose fixed lengths the
			// predictor learns. Any other first stop, a high byte included, is left to the span, which
			// validates it. A clean window is passed.
			if !key && s.pos + 16 <= u64(len(s.src)) {
				v := load16(s.src, s.pos)
				qv: #simd[16]u8 = '"'
				bv: #simd[16]u8 = '\\'
				hit := simd.lanes_eq(v, qv) | simd.lanes_eq(v, bv)
				when check == .Values {
					hit |= simd.lanes_gt(v - 0x20, 0x5f)
				} else {
					hit |= simd.lanes_gt(v, 0x7f)
				}
				if any_lane(hit) {
					k := first_stop_lane(hit)
					if s.src[s.pos + k] == '"' {
						s.pos += k + 1
						emit_dom_string(q, Q, s.src, lo, s.pos, check == .Values, false, s.pos - lo - 2)
						return nil
					}
				} else {
					s.pos += 16
				}
			}
		}
		for {
			// The chain below sees only the quote, the backslash, or a control/high byte.
			at := span_step(s, check, Q)
			if at < 0 {
				return Error{offset = u64(len(s.src)), kind = .Truncated}
			}
			c := u8(at)
			if c == '"' {
				s.pos += 1
				if !key {
					emit_dom_string(q, Q, s.src, lo, s.pos, check == .Values, saw_esc, s.pos - lo - 2 - dec.shrink)
				}
				return nil
			}
			if c == '\\' {
				latch_backslash(s, q, lo, Q)
				when .Dom in Q && check == .Values {
					// The rest of the value decoded as it is checked, where the sink has room for it.
					if !saw_esc && !key {
						vb := q.value_bytes
						from := len(vb^)
						bound := len(s.src) - int(lo)
						if cap(vb^) - from < bound {
							value_bytes_room(vb, bound)
						}
						if cap(vb^) - from >= bound {
							r, n := dom_string_fused(s.src, ([^]u8)(raw_data(vb^))[from:], lo, s.pos)
							if r.kind != Error_Kind(0) {
								return r
							}
							edge_publish(vb, from + n)
							q.dom_pending.str = {u32(from), u32(n)}
							q.dom_pending.decoded = true
							s.pos = r.offset
							return nil
						}
					}
				}
				saw_esc = true
				when check == .Locate {
					if err := skip_escape(s); err != nil {
						return err
					}
					continue
				} else when .Dom in Q {
					// The post-escape run below, with each backslash it meets handed back to this one escape
					// site, so the decoding escape is inlined once.
					escapes: for {
						if err := escape_step(s, &dec, q, Q); err != nil {
							return err
						}
						run := 0
						for _ in 0 ..< PROBE_HEAD {
							if s.pos >= u64(len(s.src)) {
								return Error{offset = u64(len(s.src)), kind = .Truncated}
							}
							d := s.src[s.pos]
							if d == '"' {
								s.pos += 1
								if !key {
									emit_dom_string(q, Q, s.src, lo, s.pos, true, saw_esc, s.pos - lo - 2 - dec.shrink)
								}
								return nil
							} else if d == '\\' {
								continue escapes
							} else if d < 0x20 {
								return Error{offset = s.pos, kind = .Bad_Char}
							} else if d < 0x80 {
								s.pos += 1
								run += 1
								if run == 3 {
									break // long gap: the span below is cheaper
								}
							} else {
								// Wire UTF-8 binds at every level.
								if err := utf8_step_checked(s); err != nil {
									return err
								}
								run += 1
								if run == 3 {
									break
								}
							}
						}
						break
					}
					continue
				} else {
					if err := escape_step(s, &dec, q, Q); err != nil {
						return err
					}
					// Post-escape run: escape-dense strings put the next backslash, a closing quote, or a
					// few clean bytes right after an escape, so take them inline instead of re-entering the
					// span. Three consecutive clean bytes mean a long gap: rejoin the span. Kept separate
					// from the `.Dom` arm above, which restarts `PROBE_HEAD` per escape while this arm spends
					// one budget for the run.
					run := 0
					for _ in 0 ..< PROBE_HEAD {
						if s.pos >= u64(len(s.src)) {
							return Error{offset = u64(len(s.src)), kind = .Truncated}
						}
						d := s.src[s.pos]
						if d == '"' {
							s.pos += 1
							if !key {
								emit_dom_string(q, Q, s.src, lo, s.pos, true, saw_esc, s.pos - lo - 2 - dec.shrink)
							}
							return nil
						} else if d == '\\' {
							if err := escape_step(s, &dec, q, Q); err != nil {
								return err
							}
							run = 0
						} else if d < 0x20 {
							return Error{offset = s.pos, kind = .Bad_Char}
						} else if d < 0x80 {
							s.pos += 1
							run += 1
							if run == 3 {
								break // long gap: the span below is cheaper
							}
						} else {
							// Wire UTF-8 binds at every level.
							if err := utf8_step_checked(s); err != nil {
								return err
							}
							run += 1
							if run == 3 {
								break
							}
						}
					}
					continue
				}
			}
			when check == .Values {
				if c < 0x20 {
					return Error{offset = s.pos, kind = .Bad_Char}
				}
			}
			if c < 0x80 {
				s.pos += 1
				continue
			}
			// Wire UTF-8 binds at every level.
			if err := utf8_step_checked(s); err != nil {
				return err
			}
		}
	}
}
