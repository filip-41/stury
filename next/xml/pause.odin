package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A walk that stops between two markup constructs and goes on later from the same state: in the next window of a text
// in pieces, or at the next member of the root under `.Members`. The walk keeps its frames, namespaces and DTD, and
// pauses only in content, before a child of the root, or past the root, where no token is half given. A walk with no
// `pause` never pauses, and only a `LAX` walk reads it.

// Where a paused walk goes on.
@(private)
Place :: enum u8 {
	Prolog, // at the text's first byte
	Content, // in the content of the element with `depth` open elements, at `at`
	Member, // at the start tag at `at` of a child of the root, which the walk of its record reads
	Epilog, // past the root's end tag, at `at`
}

@(private)
Pause :: struct {
	// Set by the caller. A text in pieces pauses at a unit `units` does not find whole before `end`, the window's end,
	// while `more` says bytes follow it.
	end:     [^]u8,
	more:    bool,
	// The walk pauses before each child of the root, past the text before it, and in the content of an element with
	// fewer than `floor` open elements.
	members: bool,
	floor:   u64,
	units:   Units,
	// Set by the walk where it paused.
	place:   Place,
	at:      u64,
	depth:   u64,
}

// Pauses walk `w` at `p` with `d` open elements and the hook's registers `hs`, to go on at `place`.
@(private, cold)
paused :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), hs: hook.Regs, place: Place, p: [^]u8, d: u64) -> u64 {
	w.pause.place, w.pause.at, w.pause.depth = place, at(w, p), d
	w.regs^ = hs
	return fault_at(at(w, p), tape.Fault_Kind(hook.WALK_MORE))
}

// Whether walk `w` pauses at `p` in the content of the element with `d` open elements: a member under `.Members` ended,
// or the window does not hold the unit at `p` whole. A walk inside a replacement text reads to its literal's end, which
// no window cuts.
@(private)
pause_due :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), p, end: [^]u8, d: u64) -> bool {
	pc := w.pause
	return d < pc.floor || end == pc.end && pc.more && at(w, p) >= pc.units.whole
}

// Pauses walk `w` at `p` as `pause_due` says, after framing the window on, which may show the unit at `p` whole.
@(private, cold)
pause_content :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), p, end: [^]u8, d: u64, hs: hook.Regs) -> (result: u64, stop: bool) {
	pc := w.pause
	if d >= pc.floor {
		units_frame(&pc.units, w.base, at(w, end))
		if at(w, p) < pc.units.whole {
			return 0, false
		}
	}
	return paused(w, hs, .Content, p, d), true
}

// Gives the text before the root's child at `q` as the root's `#text` member, opening the root's `Object` first, and
// pauses before the child's start tag, which the walk of its record reads.
@(private, cold)
pause_member :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), q: [^]u8, hs: hook.Regs) -> u64 {
	hs := hs
	if r, done := open_content(w, on, &hs, &w.frames[0], 1, q); done {
		return r
	}
	return paused(w, hs, .Member, q, 1)
}

// `p` is at the start tag of a child of the root with `d` open elements, the root of a member's record. Reads it as
// `st_start` does, with no token for its name, which is the record's key, and nothing given of the root.
@(private, enable_target_feature = STATE_FEATURES)
st_member :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	hs := hook.Regs{s0, s1, s2}
	q, nf, colon := name_end_colon(p[1:], end)
	if nf != .None {
		return name_fault(w, hs, q, end, nf, .Name)
	}
	name_n := intrinsics.ptr_sub(q, p[1:])
	if name_n > int(max(u16)) {
		return fault(w, hs, p, .Too_Wide)
	}
	if d >= w.depth {
		if kind := deepen(w, &hs, p); kind != .None {
			return fault(w, hs, p, kind)
		}
	}
	w.frames[d] = Frame{tag = p, name_n = u16(name_n)}
	w.nattr = 0
	w.tag_ns = colon
	return #must_tail st_attributes(q, end, d + 1, w, hs.a, hs.b, hs.c, on)
}

// Gives walk `w`, kept past the call that reads it, what that call lends it: the text's base, the frames and the hook
// with its registers, and the context its allocator is called in. The call takes them back before it returns.
@(private)
walk_bind :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), base: [^]u8, frames: [^]Frame, h: ^H, regs: ^hook.Regs, ctx: ^runtime.Context) {
	w.base, w.frames, w.hooks, w.regs, w.ctx = base, frames, h, regs, ctx
}

// Goes on with walk `w` over `src`, which ends at `end` past the place it paused at, for the hook from registers `hs`.
@(private)
resume :: proc "contextless" (w: ^Walk($H, $LAX), src: []u8, end: [^]u8, hs: hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	pc := w.pause
	p := w.base[pc.at:]
	switch pc.place {
	case .Prolog:
		return prolog(w, src, 0, hs.a, hs.b, hs.c, on)
	case .Content:
		return st_content(p, end, pc.depth, w, hs.a, hs.b, hs.c, on)
	case .Member:
		return st_member(p, end, pc.depth, w, hs.a, hs.b, hs.c, on)
	case .Epilog:
		return st_epilog(p, end, pc.depth, w, hs.a, hs.b, hs.c, on)
	}
	return 0
}

// The units of a window of markup that the window holds whole. A unit is a run of character data and the markup
// construct after it: a start or end tag to its `>` outside quotes, a comment, an instruction, a CDATA section, or the
// document type declaration with its internal subset. A comment or instruction is whole only once the unit after the
// run of them is, as the walk reads such a run with the byte past it. The framing goes on from window to window where
// it stopped, so it reads each byte once, and the walk reads a unit only once it is whole, so it gives no token twice.
// A construct the framing takes for longer than the walk reads only holds its window back.
@(private)
Units :: struct {
	at:     u64, // the next byte to frame
	whole:  u64, // one past the last unit the window holds whole
	state:  Unit_State,
	quote:  u8, // in a tag or the document type declaration, the quote a literal opened, 0 outside one, and in `Bang` the opener's third byte
	n:      u8, // the bytes of an opener or a closer matched
	rooted: bool, // a start tag ended, so the prolog is whole
}

@(private)
Unit_State :: enum u8 {
	Text,
	Open, // past a `<`
	Bang, // past `<!`, `n` bytes of `<!--`, `<![CDATA[` or `<!DOCTYPE` matched
	Tag,
	End_Tag,
	Comment, // `n` the `-` just before
	Pi, // `n` 1 past a `?`
	Declaration, // an instruction at the text's start, read as the walk reads the XML declaration: `quote` as in `Tag`, `n` as in `Pi`
	Cdata, // `n` the `]` just before
	Doctype,
	Subset,
	Subset_Open, // past a `<` in the internal subset, `n` bytes of `<!--` or `<?` matched
	Subset_Comment,
	Subset_Pi,
}

// Frames the units of `base` from `u.at` up to `to`.
@(private)
units_frame :: proc "contextless" (u: ^Units, base: [^]u8, to: u64) #no_bounds_check {
	i := u.at
	for i < to {
		b := base[i]
		switch u.state {
		case .Text:
			k := kernel.index_byte(base[i:to], '<')
			if k < 0 {
				i = to
				continue
			}
			i += u64(k) + 1
			u.state = .Open
			continue
		case .Open:
			switch b {
			case '/':
				u.state = .End_Tag
			case '!':
				u.state, u.n = .Bang, 2
			case '?':
				u.state, u.n = .Pi, 0
				// The walk reads the literals of an XML declaration to their closing quote, past a `?>` they hold.
				if i == 1 || i == 4 && base[0] == 0xef {
					u.state, u.quote = .Declaration, 0
				}
			case:
				u.state, u.quote = .Tag, 0
				continue
			}
		case .Bang:
			if u.n == 2 {
				if b != '-' && b != '[' && b != 'D' {
					// No construct opens so, and the walk refuses it at its `<`.
					unit_end(u, i, false)
					continue
				}
				u.quote = b
			}
			word := "<!--" if u.quote == '-' else "<![CDATA[" if u.quote == '[' else "<!DOCTYPE"
			if b != word[u.n] {
				unit_end(u, i, false)
				continue
			}
			u.n += 1
			if int(u.n) == len(word) {
				u.state = .Comment if u.quote == '-' else .Cdata if u.quote == '[' else .Doctype
				u.quote, u.n = 0, 0
			}
		case .Tag:
			if u.quote != 0 {
				if b == u.quote {
					u.quote = 0
				}
			} else if b == '"' || b == '\'' {
				u.quote = b
			} else if b == '>' {
				u.rooted = true
				unit_end(u, i + 1, false)
			}
		case .End_Tag:
			if b == '>' {
				unit_end(u, i + 1, false)
			}
		case .Comment, .Subset_Comment:
			if b == '>' && u.n >= 2 {
				if u.state == .Comment {
					unit_end(u, i + 1, true)
				} else {
					u.state = .Subset
				}
			} else {
				u.n = min(u.n + 1, 2) if b == '-' else 0
			}
		case .Pi, .Subset_Pi:
			if b == '>' && u.n == 1 {
				if u.state == .Pi {
					unit_end(u, i + 1, true)
				} else {
					u.state = .Subset
				}
			} else {
				u.n = 1 if b == '?' else 0
			}
		case .Declaration:
			if u.quote != 0 {
				if b == u.quote {
					u.quote = 0
				}
			} else if b == '"' || b == '\'' {
				u.quote = b
			} else if b == '>' && u.n == 1 {
				unit_end(u, i + 1, true)
			}
			u.n = 1 if b == '?' else 0
		case .Cdata:
			if b == '>' && u.n >= 2 {
				unit_end(u, i + 1, false)
			} else {
				u.n = min(u.n + 1, 2) if b == ']' else 0
			}
		case .Doctype, .Subset:
			if u.quote != 0 {
				if b == u.quote {
					u.quote = 0
				}
			} else if b == '"' || b == '\'' {
				u.quote = b
			} else if u.state == .Doctype {
				if b == '[' {
					u.state = .Subset
				} else if b == '>' {
					unit_end(u, i + 1, false)
				}
			} else if b == ']' {
				u.state = .Doctype
			} else if b == '<' {
				u.state, u.n = .Subset_Open, 1
			}
		case .Subset_Open:
			switch {
			case u.n == 1 && b == '?':
				u.state, u.n = .Subset_Pi, 0
			case u.n == 1 && b == '!', u.n >= 2 && b == '-':
				u.n += 1
				if u.n == 4 {
					u.state, u.n = .Subset_Comment, 0
				}
			case:
				u.state = .Subset
				continue
			}
		}
		i += 1
	}
	u.at = i
}

// Ends the unit whose construct ends before `at`. A comment or instruction (`misc`) leaves `whole` to the unit after it.
@(private)
unit_end :: #force_inline proc "contextless" (u: ^Units, at: u64, misc: bool) {
	if !misc {
		u.whole = at
	}
	u.state = .Text
}
