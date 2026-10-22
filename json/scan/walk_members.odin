package scan

import "base:intrinsics"
import c "../../core"
import index "index"
import lex "lex"

// Members of an object the walk can take without its generic dispatch. A
// member whose key no demand wants is taken whole: key, colon, the value
// skipped, then a comma. A member whose key a demand wants is latched the way
// `object_key` latches it, and the walk reads its value.
//
// A key, its colon and a string or scalar value are taken only when their
// tokens, and the token after them, are in the classified region, so the
// region's facts cover all of them and the reader never refills. A container
// is skipped the way the walk would skip it. Anything else, down to a byte
// that would fault, is left for the generic walk at the point it would have
// read it from, so every fault keeps its kind and offset.
//
// Only a demand-only query set asks nothing of a member but its key, so only
// it runs here, and only in a walk that skips what no query reads. Inside an
// answer checked whole every value is checked, so the walk takes those members
// itself. A reading told to stop stops at the next value's end, which is the
// walk's to find.
//
// A gated demand (`.Gate`) runs here too: a member of a gated depth is read into only when its key passes
// the gate, and is otherwise taken whole.
MEMBER_RUN_KINDS :: bit_set[Walk_Kind]{.Demand}

// Where `take_members` left the walk, and where `demand_skip_walk_pays` stands.
@(private = "file")
Member_Place :: enum u8 {
	Key, // on a member's key, for the walk to read
	Value, // on a member's value, its key latched if a demand wants it
	After, // past a member's value, on the comma or close after it
}

// Takes members from the key at `s.pos`, which the object's open or a comma
// just introduced, in the object whose frame is `sp` and which opened at
// `owner_lo`. `room` is the depth a skipped container may still nest.
take_members :: #force_inline proc(
	s: ^Scanner,
	cur: ^Index_Cursor($F),
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	sp: u64,
	owner_lo: u64,
	pend: ^Demand_Pend,
	room: int,
	stopped: ^bool,
) -> Member_Place {
	#assert(Q - {.Gate} == MEMBER_RUN_KINDS)
	if stopped != nil && stopped^ {
		return .Key
	}
	src := s.src
	// A region with a backslash may hold an escaped key, which only the
	// generic key compare decodes. A region failing a wire check holds a
	// string a leaf must check.
	if !cur.ix.chunk_wire_ok || cur.ix.chunk_bs {
		return .Key
	}
	// Whether a demand reads members of this object, and whether one reads
	// into its containers: both hold for every member.
	keyed := sp == q.demand.depth && len(q.demand.keys) > 0
	reaches := c.demand_reaches_into(q, Q, sp)
	when .Gate in Q {
		// A skipping walk takes whole every member a shut gate guards, so `keyed` needs no gate test.
		// The gate is shut at every key (`Demand_Gate.open`), so `reaches` is false at a gated depth and
		// a member that passes is handed to the walk below.
		gated := c.demand_gated_at(q, sp)
	}
	// Every `continue` below follows a skipped member, so a member past the first iteration means one was
	// skipped, and the walk keeps no count. Only the exits that return right after a skip say so themselves.
	start := cur.p
	key := start
	skipped := false
	defer q.skipped ||= skipped || key != start
	#no_bounds_check for {
		key = cur.p
		if key != int(s.pos) || src[key] != '"' {
			return .Key
		}
		// A run of scalar members the key filter rules out: a member's four tokens (key, colon, value, comma)
		// and the next key are five positions of the region, the first four read as one word.
		when .Gate in Q {
			run_ok := !gated
		} else {
			run_ok := true
		}
		if run_ok {
			rd := cur.r
			buf := raw_data(cur.ix.buf[:])
			at := key
			for rd.i + 4 <= rd.n {
				w := intrinsics.unaligned_load((^u64)(&buf[rd.i]))
				colon := rd.lo + int(w & 0xffff)
				val := rd.lo + int((w >> 16) & 0xffff)
				sep := rd.lo + int((w >> 32) & 0xffff)
				if src[at] != '"' || src[colon] != ':' || lex.VCLASS[src[val]] < VC_STRING || src[sep] != ',' {
					break
				}
				if keyed && c.demand_first_byte_wanted(q, src[at + 1]) && c.demand_head_may_match(q, src, u64(at)) {
					break
				}
				at = rd.lo + int(w >> 48)
				rd.i += 4
			}
			if at != key {
				cur.r = rd
				cur.p = at
				s.pos = u64(at)
				continue
			}
		}
		r := cur.r
		if !index.next_is_buffered(&r) {
			return .Key
		}
		colon := index.next(cur.ix, &r)
		if src[colon] != ':' || !index.next_is_buffered(&r) {
			return .Key
		}
		v := index.next(cur.ix, &r)
		// The key has no escape, as the region holds no backslash, so the first-byte and head tests are
		// `demand_key_filtered`.
		if keyed && c.demand_first_byte_wanted(q, src[key + 1]) {
			if c.demand_head_may_match(q, src, u64(key)) &&
			   c.demand_key_at_depth(q, Q, u64(key), u64(token_end(src, colon)), u64(v), sp, owner_lo, pend, false, false) {
				cur.p = v
				cur.r = r
				s.pos = u64(v)
				return .Value
			}
		}
		vc := lex.VCLASS[src[v]]
		if vc >= VC_STRING {
			if !index.next_is_buffered(&r) {
				return .Key
			}
			sep := index.next(cur.ix, &r)
			when .Gate in Q {
				// Nothing below a scalar is read, but a repeat of the gate's name must still see this
				// occurrence. Checked only once the member is taken, so the walk never meets its key again.
				if gated {
					_ = c.demand_gate_passes(q, u64(key), u64(token_end(src, colon)), false, sp, owner_lo)
				}
			}
			if src[sep] == ',' && index.next_is_buffered(&r) {
				cur.p = index.next(cur.ix, &r)
				cur.r = r
				s.pos = u64(cur.p)
				continue
			}
			cur.p = sep
			cur.r = r
			s.pos = u64(token_end(src, sep))
			skipped = true
			return .After
		}
		if vc == VC_NONE {
			return .Key
		}
		// The key and colon are taken. The container is the walk's to descend
		// into when a demand reaches its members, or to read when the skip
		// finds it has no end.
		cur.p = v
		cur.r = r
		s.pos = u64(v)
		when .Gate in Q {
			if gated && c.demand_gate_passes(q, u64(key), u64(token_end(src, colon)), false, sp, owner_lo) {
				c.demand_gate_open(q, sp)
				return .Value
			}
		}
		if reaches || !cursor_skip_value(s, cur, vc, room) {
			return .Value
		}
		// The skip may have left the region, and the next key is checked by the
		// facts of the one it is in.
		if !cur.ix.chunk_wire_ok || cur.ix.chunk_bs || cur.p < 0 || src[cur.p] != ',' || !index.next_is_buffered(&cur.r) {
			skipped = true
			return .After
		}
		cur.p = index.next(cur.ix, &cur.r)
		s.pos = u64(cur.p)
	}
}

// How many records `demand_skip_walk_pays` reads before it trusts them for the rest.
@(private = "file")
HEAD_RECORDS :: 4
// Records whose bytes are at least this many eighths whitespace keep the skipping walk, whose index cursor
// jumps the whitespace.
@(private = "file")
HEAD_WS_EIGHTHS :: 1

// Whether the skipping walk pays on the demand's first records: they hold a value it would leave unvisited
// (a member no key wants, or a scalar or array where a record should be), or enough whitespace for its index
// cursor to jump. Otherwise a reading that cannot stop either is the complete walk with an index and a
// per-value test on top, so `dispatch_walk_cursor` takes the complete one. The probe reads at most
// HEAD_RECORDS records within the first sixteenth of the item. The answer only picks a walk, never a result:
// a head it cannot read, or one holding no whole record, keeps the skipping walk.
demand_skip_walk_pays :: #force_no_inline proc(q: ^Query_Ctx, src: []u8, root: int, max_depth: u64) -> bool {
	depth := int(q.demand.depth)
	// `objects` holds one bit per open container.
	if depth > 63 {
		return true
	}
	// A record may run to a sixteenth of the item, but once a thirty-second is read the records seen decide.
	p := Scanner{src = src[:root + (len(src) - root) >> 4], pos = u64(root)}
	enough := root + (len(src) - root) >> 5
	sp, records := 0, 0
	objects: u64
	// Whitespace between the tokens read, which the index cursor jumps and the byte cursor steps through.
	ws: u64
	at := Member_Place.Value
	for {
		was := p.pos
		b := lex.skip_peek(&p)
		ws += p.pos - was
		if b < 0 {
			return records == 0
		}
		switch at {
		case .Key:
			if b != '"' {
				return true
			}
			lo := int(p.pos)
			end := lex.value_end(p.src, lo, VC_STRING, 0)
			if end < 0 {
				return records == 0
			}
			// Compared by text: an escaped key may be treated as unwanted, which only keeps the skipping walk.
			if sp == depth {
				pend: Demand_Pend
				filtered := c.demand_key_filtered(q, u64(lo), u64(end), false)
				if !c.demand_key_at_depth(q, MEMBER_RUN_KINDS, u64(lo), u64(end), 0, u64(sp), 0, &pend, false, filtered) {
					return true
				}
			}
			p.pos = u64(end)
			if lex.skip_peek(&p) != ':' {
				return records == 0
			}
			p.pos += 1
			at = .Value
		case .Value:
			vc := lex.VCLASS[b]
			if sp == depth {
				end := lex.value_end(p.src, int(p.pos), vc, int(max_depth) - sp)
				if end < 0 {
					return records == 0
				}
				p.pos = u64(end)
				at = .After
				continue
			}
			// Above the records' depth only containers are read into, and only objects are records.
			if vc == VC_NONE || vc >= VC_STRING || (sp + 1 == depth && vc == VC_ARRAY) || u64(sp) >= max_depth {
				return true
			}
			objects = objects & ~(u64(1) << uint(sp)) | u64(vc == VC_OBJECT) << uint(sp)
			sp += 1
			p.pos += 1
			closer := int(b) + 2 // `{` + 2 is `}`, `[` + 2 is `]`
			if lex.skip_peek(&p) == closer {
				at = .After
			} else {
				at = .Key if vc == VC_OBJECT else .Value
			}
		case .After:
			is_obj := objects & (u64(1) << uint(sp - 1)) != 0
			if b == ',' {
				p.pos += 1
				at = .Key if is_obj else .Value
				continue
			}
			if b != ('}' if is_obj else ']') {
				return true
			}
			p.pos += 1
			sp -= 1
			if sp == depth - 1 {
				records += 1
				if records == HEAD_RECORDS || int(p.pos) >= enough {
					return ws * 8 >= (p.pos - u64(root)) * HEAD_WS_EIGHTHS
				}
			}
			if sp == 0 {
				return records == 0
			}
		}
	}
}

// How many root members `path_skip_walk_pays` reads before it trusts them for the rest.
@(private = "file")
HEAD_MEMBERS :: 64

// Whether a path's skipping walk pays on the item's head: the root holds a container, which the walk may
// leave unvisited, or enough whitespace for its index cursor to jump. Otherwise every value it would skip
// is a scalar, which its index cursor passes slower than the byte walk reads it, so
// `dispatch_walk_cursor` takes the byte walk. The probe reads at most HEAD_MEMBERS root members within the
// first sixteenth of the item. The answer only picks a walk: a head it cannot read keeps the skipping walk.
path_skip_walk_pays :: #force_no_inline proc(src: []u8, root: int) -> bool {
	p := Scanner{src = src[:root + (len(src) - root) >> 4], pos = u64(root)}
	enough := root + (len(src) - root) >> 5
	ws: u64
	was := p.pos
	b := lex.skip_peek(&p)
	ws += p.pos - was
	if b != '{' && b != '[' {
		return true
	}
	is_obj := b == '{'
	closer := b + 2 // `{` + 2 is `}`, `[` + 2 is `]`
	p.pos += 1
	members := 0
	head: for members < HEAD_MEMBERS && int(p.pos) < enough {
		was = p.pos
		b = lex.skip_peek(&p)
		ws += p.pos - was
		if b == closer && members == 0 {
			break
		}
		if is_obj {
			if b != '"' {
				return true
			}
			end := lex.value_end(p.src, int(p.pos), VC_STRING, 0)
			if end < 0 {
				break
			}
			p.pos = u64(end)
			was = p.pos
			if lex.skip_peek(&p) != ':' {
				return true
			}
			ws += p.pos - was
			p.pos += 1
			was = p.pos
			b = lex.skip_peek(&p)
			ws += p.pos - was
		}
		if b < 0 {
			break
		}
		vc := lex.VCLASS[b]
		if vc != VC_STRING && vc != VC_LITERAL && vc != VC_NUMBER {
			return true
		}
		end := lex.value_end(p.src, int(p.pos), vc, 0)
		if end < 0 {
			break
		}
		p.pos = u64(end)
		members += 1
		was = p.pos
		b = lex.skip_peek(&p)
		ws += p.pos - was
		switch b {
		case ',':
			p.pos += 1
		case closer, -1:
			break head
		case:
			return true
		}
	}
	return members == 0 || ws * 8 >= (p.pos - u64(root)) * HEAD_WS_EIGHTHS
}
