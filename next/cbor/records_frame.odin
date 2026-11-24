package cbor

// The framing of the items of a sequence read in pieces, a head at a time, so that no byte of an item is read twice
// before its end is known.

// The framing of an item of a text in pieces across windows: `open` once begun, read up to `seen`, in the `d` frames of
// `frames` whose innermost is `top`, with the bytes of a head the last window cut in `head[:head_n]`, and `ended` once
// the heads say where it ends. `need` is where the item ends at least, as the counts of its containers say, and
// `stuck` is set at a byte that leaves its end unknown.
@(private)
Item_Frame :: struct {
	open, stuck, ended: bool,
	head_n:      u8,
	head:        [9]u8,
	d, top:      u64,
	seen, need:  u64,
	frames:      [ITEM_LEVELS]u64,
}

// The levels `Item_Frame` holds. An item nesting deeper is walked once the last window holds it.
@(private)
ITEM_LEVELS :: 64

// `record_frame` under `.Concatenated` in a text in pieces. An item is walked once a window holds its end, or once the
// window holds a byte that leaves its end unknown and every count before it, where the walk judges the count against
// the bytes left, or once the last window holds what the text has of it. Until then the batch ends, and its framing
// goes on in the next window where this one stopped, reading the heads only, each byte once.
@(private)
record_frame_window :: proc "contextless" (r: ^Records) -> (lo, cut: u64, ok: bool) {
	n := u64(len(r.src))
	more := !r.opts.pieces.last
	f := &r.item
	if !f.open {
		if r.pos >= n {
			if !more {
				r.at = .Done
			}
			return
		}
		f.open, f.stuck, f.ended, f.head_n, f.d, f.top, f.seen, f.need = true, false, false, 0, 0, 0, r.pos, 0
	}
	if !f.stuck && !item_frame(r, n) && more {
		return
	}
	if f.stuck && more && f.need > n {
		return
	}
	f.open = false
	return r.pos, n, true
}

// Reads the heads of the item `r.item` frames on from where it stopped, up to `n`. True at the item's end, or with
// `stuck` set at a byte that leaves its end unknown, false at `n` short of either, with `ended` once the heads say
// where the item ends.
@(private)
item_frame :: proc "contextless" (r: ^Records, n: u64) -> bool #no_bounds_check {
	f := &r.item
	src := r.src
	// An item whose last string runs past the window ends where the string does.
	for !f.ended && f.seen < n {
		// The head, read from the window or from the bytes of it the last window held.
		b := f.head[0] if f.head_n > 0 else src[f.seen]
		ai := b & 31
		hl := max(u64(HEAD_LEN[ai]), 1)
		have := u64(f.head_n)
		if f.seen + hl - have > n {
			copy(f.head[have:], src[f.seen:n])
			f.head_n = u8(have + n - f.seen)
			f.seen = n
			return false
		}
		at := f.seen - have
		head: []u8
		if have > 0 {
			copy(f.head[have:hl], src[f.seen:f.seen + hl - have])
			head = f.head[:hl]
			f.head_n = 0
		} else {
			head = src[at:at + hl]
		}
		f.seen = at + hl
		arg: u64
		if ai <= 27 {
			arg, _, _ = read_head(head, 0, ai)
		}
		if f.top & FLAG_CHUNKS != 0 && b != 0xff && (b >> 5 != u8(f.top >> 56) & 7 || ai > 27) {
			f.stuck = true
			return true
		}
		switch CLASS[b] {
		case .Int, .False, .True, .Null, .Simple, .Simple_8, .Float:
		case .Bytes, .Text:
			f.seen = max(u64) if arg > max(u64) - f.seen else f.seen + arg
		case .Array, .Map:
			pair := u64(b >> 5) & 1
			if !item_push(f, frame_of(min(arg, COUNT_MASK >> 2), pair)) {
				return true
			}
			f.need = max(f.need, max(u64) if arg > max(u64) >> 2 else at + hl + arg << pair)
			if arg != 0 {
				continue
			}
		case .Indefinite_Container:
			if !item_push(f, indefinite_frame(u64(b >> 5) & 1)) {
				return true
			}
			continue
		case .Tag:
			if !item_push(f, FLAG_TAG | 1) {
				return true
			}
			continue
		case .Indefinite_String:
			if !item_push(f, FLAG_CHUNKS | FLAG_TAG | FLAG_INDEF | INDEF_COUNT | u64(b >> 5) << 56) {
				return true
			}
			continue
		case .Break:
			if break_refused(f.top) {
				f.stuck = true
				return true
			}
			f.top = f.top & ~COUNT_MASK | 1
		case .Reserved:
			f.stuck = true
			return true
		}
		for f.d > 0 {
			f.top -= 1
			if f.top & COUNT_MASK != 0 {
				break
			}
			f.d -= 1
			f.top = f.frames[f.d]
		}
		if f.d == 0 {
			f.ended = true
			break
		}
	}
	return f.ended && f.seen <= n
}

// Opens a frame of `frame` in `f`, or false with `stuck` set and the item's end past the last window when `f` holds no
// more levels.
@(private)
item_push :: #force_inline proc "contextless" (f: ^Item_Frame, frame: u64) -> bool {
	if f.d == ITEM_LEVELS {
		f.stuck, f.need = true, max(u64)
		return false
	}
	f.frames[f.d] = f.top
	f.d += 1
	f.top = frame
	return true
}
