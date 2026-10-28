package walk

// Fact emission. Every proc below is comptime-specialized on `Q`, so a walk
// built for `{}` contains none of them. A refused append is recorded by
// `note_oom`, and the walk keeps going to reach the document result.

// A row's per-token facts, its payload and its decode state. Passed by value
// into the `#force_inline` `emit_node`, which only copies it into the row.
Node_Facts :: struct {
	// The row's flags, the decode state included on a `.Dom` scan.
	flags: Row_Flags,
	// A string's escape latch, or a number's digit counts (`Row.first_esc`).
	first_esc: u16,
	// The value's payload, or nothing. A container's is a zero member count, which only
	// its close (`dom_container_close`) sets. Handed over by the string leaf through
	// `Query_Ctx.dom_pending`.
	payload: Row_Payload,
	// Whether a payload was produced. False is the claim, not a default: a
	// locating walk and a failed arena reserve land here, and `get_string`
	// reads the false as "decode the span".
	decoded: bool,
}

emit_node :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	lo, hi: u64,
	subtree_size: u32,
	kind: Kind,
	facts: Node_Facts,
) {
	when .Nodes in Q {

	// The key latched by `object_key` belongs to the next row written, which on
	// a preorder tape is the member's value itself.
	key_lo, key_hi := q.node_key_lo, q.node_key_hi
	flags := facts.flags
	if key_lo != NO_KEY_LATCH && q.node_key_escaped {
		flags |= {.Key_Escaped}
		// .Dom: the key is decoded for this row where its leaf checked it, so the leaves keep their shape.
		when .Dom in Q {
			if q.walk_judged {
				emit_dom_key(q, q.path_src, key_lo, key_hi, int(key_hi - key_lo))
			}
		}
	}
	// `request_fault` refuses a `.Nodes` source past `MAX_ROW_SOURCE`, so the
	// u32 casts cannot truncate, and `NO_KEY_LATCH` narrows to `NO_KEY`.
	row := Row{
		lo =           u32(lo),
		hi =           u32(hi),
		key_lo =       u32(key_lo),
		key_hi =       u32(key_hi),
		subtree_size = subtree_size,
		kind =         kind,
		flags =        flags,
		first_esc =    facts.first_esc,
		payload =      facts.payload,
	}
	if facts.decoded {
		row.flags |= {.Decoded}
	}
	edge_push(&q.nodes_edge, row, .Nodes)

	if key_lo != NO_KEY_LATCH {
		// Consumed: the next row is inside this value or another member.
		q.node_key_lo = NO_KEY_LATCH
		q.node_key_hi = NO_KEY_LATCH
		q.node_key_escaped = false
	}
	}
}

// .Dom: the checked escaped key token `src[lo:hi]` decoded onto the sink's value bytes by the format's decoder
// and kept for the row about to be written, the member's value. `bound` is at least its decoded length. The
// key store sits in the sink beside `value_bytes`, so the walk state carries no pointer to it: a larger
// `Query_Ctx` slows every walk.
@(private = "file")
emit_dom_key :: #force_no_inline proc(q: ^Query_Ctx, src: []byte, lo, hi: u64, bound: int) {
	at, ok := value_bytes_reserve(q.value_bytes, bound, len(src) - int(lo))
	if !ok {
		note_oom(q, .Dom)
		return
	}
	n := q.hooks.dom_unescape_into(q.value_bytes[at:], src, lo, hi, 0)
	edge_publish(q.value_bytes, at + n)
	sink := container_of(q.value_bytes, Scan_Query_Sink, "value_bytes")
	if !row_append(&sink.key_texts, Key_Text{node = Node(q.nodes_edge.len), str = {u32(at), u32(n)}}) {
		note_oom(q, .Dom)
	}
}

emit_literal :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	lo: u64,
	$Q: bit_set[Walk_Kind],
) {
	// `lo` is the walk's dispatch byte for this literal, which `peek` proved is in `src`.
	#no_bounds_check {
		c := s.src[lo]
		kind := Kind.Null
		if c == 't' {
			kind = .True
		} else if c == 'f' {
			kind = .False
		}
		emit_scalar(q, Q, lo, s.pos, kind)
	}
}

// A container's `.Nodes` row at its open, in preorder (a fused `[` past the run's first has
// `dom_run_open`). The row is stored twice:
//
//   at open    hi = 0, cnt = 0, subtree_size = the row's own index
//   at close   hi = one past `]`, cnt = the frame's `members`,
//              subtree_size = len(rows) - index (`dom_container_close`)
//
// The member key needs no depth check: `object_key` latched it just before this
// row is written, and no descendant exists yet to latch over it.
dom_container_open :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	fr: ^Open_Frame,
	lo: u64,
) {

	when .Nodes in Q {
		// The row's own index is the cursor's length before the push.
		at := u32(q.nodes_edge.len)
		f := Node_Facts{}
		when .Dom in Q {
			// A container has nothing to decode.
			f.decoded = true
		}
		// `hi` and `subtree_size` are the two words the close site owns.
		emit_node(
			q,
			Q,
			lo,
			0,
			at,
			fr.is_obj ? Kind.Object : Kind.Array,
			f,
		)
		// `edge_push` drops a row it has no room for, so a close that patched `at`
		// would write into a row it does not own. The shortfall is already recorded.
		fr.row = u32(q.nodes_edge.len) > at ? at : NO_ROW
	}

}

// `dom_container_open` for a fused `[` past the run's first. The run's first `[` took the member key, so
// these rows carry none. The row count is `n`, a walk local the caller writes back to `q.nodes_edge.len`
// after the run: kept in memory, every row's count would be a load of the previous row's store, a chain
// that bounds a deep run.
dom_run_open :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	fr: ^Open_Frame,
	lo: u64,
	n: ^int,
) {
	when .Nodes in Q {
		at := n^
		row := Row{
			lo =           u32(lo),
			key_lo =       NO_KEY,
			key_hi =       NO_KEY,
			subtree_size = u32(at),
			kind =         .Array,
		}
		when .Dom in Q {
			row.flags = {.Decoded}
		}
		e := &q.nodes_edge
		if at < e.cap {
			e.base[at] = row
			n^ = at + 1
		} else {
			e.len = at
			edge_push(e, row, .Nodes)
			n^ = e.len
		}
		fr.row = n^ > at ? u32(at) : NO_ROW
	}
}

// The close-time patch: three stores into a row the open already published.
// `fr.row` is an index, never an address: `edge_push` may have reallocated the
// array in between. The skip is `len(rows) - fr.row`, which stays right when a
// refused append dropped rows.
dom_container_close :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	fr: ^Open_Frame,
	hi: u64,
	members: u64,
) {

	when .Nodes in Q {
		if fr.row != NO_ROW {
			// Through the cursor's base, which `edge_push` re-points on growth.
			r := &q.nodes_edge.base[int(fr.row)]
			r.hi = u32(hi)
			// Rows written since the open, this one included.
			r.subtree_size = u32(q.nodes_edge.len) - fr.row
			r.cnt = u32(members)
		}
	}

}

// .Nodes: one row per scalar token, appended at the token's close.
emit_scalar :: #force_inline proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind], lo, hi: u64, kind: Kind) {
	when .Nodes in Q {
		facts := Node_Facts{}
		if kind == .String {
			// Latched by the string leaf, which returns immediately before this call.
			if q.str_escaped {
				facts.flags |= {.Str_Escaped}
				facts.first_esc = q.str_first_esc
			}
			when .Dom in Q {
				// The payload handoff from `emit_dom_string`, which ran inside the leaf.
				facts.payload.str = q.dom_pending.str
				facts.decoded = q.dom_pending.decoded
				// Cleared so a later scalar cannot read this string's bytes.
				q.dom_pending.str = {}
				q.dom_pending.decoded = false
			}
		}
		when .Dom in Q {
			// `true`/`false`/`null` carry `.Decoded` with no payload: the bit means
			// only "the walk validated this token". Not for `.String`: its `.Decoded`
			// is the leaf's own answer and is false wherever the unescape did not
			// run (e.g. a refused `value_bytes_reserve`), and `get_string` trusts it,
			// so setting it there would return a slice that still holds backslashes.
			if kind == .True || kind == .False || kind == .Null {
				facts.decoded = true
			}
		}

		emit_node(q, Q, lo, hi, 1, kind, facts)
	}
}

// .Dom: one decoded string value's payload, called from the string leaf.
// `decoded` is false on a locating route (.Structural): nothing was unescaped, so
// the row leaves `.Decoded` clear. `escaped` says a backslash was seen. `dec_len` is
// the decoded byte length, which makes the reserve exact.
emit_dom_string :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	src: []byte,
	lo, hi: u64,
	decoded, escaped: bool,
	dec_len: u64,
) {
	when .Dom in Q {
		if !decoded || !escaped {
			// No payload: escape-free text is the source text, `src[lo + 1:hi - 1]`, and a locating route
			// claims nothing was decoded.
			q.dom_pending.str = {}
			q.dom_pending.decoded = decoded
			return
		}
		// Escaped: decode onto the end of the sink's value bytes. The rest of `src` bounds what the scan
		// can still decode.
		at, ok := value_bytes_reserve(q.value_bytes, int(dec_len), len(src) - int(lo))
		if ok {
			slot := q.value_bytes[at:]
			// `.Dom` implies `.Nodes` (json/request_scan.odin's `WALK`), so
			// `str_first_esc` is live: the offset of this token's first
			// backslash, a lower bound once saturated at
			// `FIRST_ESC_SATURATED`. The decoder reads `[lo+1, lo+off)` as a
			// clean head, so its bulk copy never reaches the backslash.
			esc_off: u64
			when .Nodes in Q {
				esc_off = u64(q.str_first_esc)
			}
			n := q.hooks.dom_unescape_into(slot, src, lo, hi, esc_off)
			// The decoder's stores are unchecked (`#no_bounds_check`), so a count
			// that disagrees with the reserve would write into the next slot.
			// Checked in every build. Under `-disable-assert` the `slot[:n]`
			// bounds check below fires on the same condition.
			assert(u64(n) == dec_len, "dom: the decoded length is not the reserved length")
			// `request_fault` bounds the source by `MAX_ROW_SOURCE`, and the decoded bytes by the source.
			q.dom_pending.str = {u32(at), u32(len(slot[:n]))}
			q.dom_pending.decoded = true
		} else {
			// The row is still written with no payload. The shortfall reaches
			// the caller through `qerr` and the reader falls back to the span.
			note_oom(q, .Dom)
			q.dom_pending.str = {}
			q.dom_pending.decoded = false
		}
	}
}

// .Nodes, numbers only: a row with no payload, `.Dom` too (`Row_Payload`). `digits` is the token's
// `number_digits_pack`, zero where the walk counted none.
emit_number :: #force_inline proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind], lo, hi: u64, digits: u16) {
	when .Nodes in Q {
		emit_node(q, Q, lo, hi, 1, .Number, Node_Facts{first_esc = digits})
	}
}
