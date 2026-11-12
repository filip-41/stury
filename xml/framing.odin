package xml

import "base:intrinsics"
import spell "../core/spell"
import core "../core"

// What stands around the root element: the XML declaration, comments, processing instructions, the document type
// declaration, and after the root the comments and instructions that end the text.

// Reads the prolog of the document in `src` from `lo`, gives the `Doctype`, the prolog's comments and instructions, and
// the document's `Object`, then reads the root element and the epilog. Returns the walk's result.
@(private)
prolog :: proc "contextless" (w: ^Walk($H), src: []u8, lo: u64, s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	p := raw_data(src)
	end := p[len(src):]
	q := p[core.text_start(src, lo):]
	if q < end && (q[0] == 0xfe || q[0] == 0xff || q[0] == 0 || q[0] == '<' && intrinsics.ptr_sub(end, q) >= 2 && q[1] == 0) {
		return fault(w, hs, q, .Bad_Char, .Encoding)
	}
	standalone := false
	if declares(q, end) {
		next, kind, detail, alone := declaration(q, end)
		if kind != .None {
			return fault(w, hs, next, kind, detail)
		}
		q, standalone = next, alone
	}
	result: u64
	ok: bool
	q, result, ok = prolog_misc(w, on, &hs, q, end)
	if !ok {
		return result
	}
	if intrinsics.ptr_sub(end, q) >= 9 && string(q[:9]) == "<!DOCTYPE" {
		r, at_, kind, detail := doctype(w, src, q, end, standalone)
		if kind != .None {
			return fault(w, hs, at_, kind, detail)
		}
		w.tag_dtd = w.dtd != nil && .Defaults in w.dtd.head.flags
		if x := emit(w, on, &hs, .Plain, .Doctype, at(w, q), intrinsics.ptr_sub(r, q)); x != .Next {
			return refused(w, hs, x, r)
		}
		q, result, ok = prolog_misc(w, on, &hs, r, end)
		if !ok {
			return result
		}
	}
	if q >= end {
		return fault(w, hs, end, .Truncated)
	}
	if q[0] != '<' {
		return fault(w, hs, q, .Bad_Char, .Prolog)
	}
	if intrinsics.ptr_sub(end, q) < 2 {
		return fault(w, hs, end, .Truncated)
	}
	if q[1] == '/' || q[1] == '!' || q[1] == '?' {
		return fault(w, hs, q, .Bad_Char, .Doctype if intrinsics.ptr_sub(end, q) >= 9 && string(q[:9]) == "<!DOCTYPE" else .Prolog)
	}
	if x := emit(w, on, &hs, .Object, .Value, at(w, q), 0, 0, max(u64)); x != .Next {
		return refused(w, hs, x, q)
	}
	return st_start(q, end, 0, w, hs.a, hs.b, hs.c, on)
}

// Whether the text at `q` opens with an XML declaration: `<?xml` and then a byte that does not continue the target.
@(private)
declares :: #force_inline proc "contextless" (q, end: [^]u8) -> bool #no_bounds_check {
	room := intrinsics.ptr_sub(end, q)
	return room >= 5 && string(q[:5]) == "<?xml" && (room == 5 || is_ws(q[5]) || q[5] == '?')
}

// Reads the run of comments and instructions before the root element or after the document type declaration, and
// gives them as comments of the document. Returns where it ends, or the walk's result as `fault`.
@(private)
prolog_misc :: proc "contextless" (w: ^Walk($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, p, end: [^]u8) -> (q: [^]u8, result: u64, ok: bool) {
	r: Run
	q, r = misc_run(w, p, end)
	if r.kind != .None {
		return q, run_fault(w, hs^, r), false
	}
	if x, at_ := give_misc(w, on, hs, p, q, end, false, .Comment); x != .Next {
		return q, refused(w, hs^, x, at_), false
	}
	return q, 0, true
}

// Reads the run of comments and instructions after the root element, which ends the text. A comment on the line
// where the root ends is its inline comment, and the rest are comments of the document's end. `p` is one past the
// root's end tag. A state of its own, so the check of an open entity stays out of `st_closed`.
@(private, enable_target_feature = STATE_FEATURES)
st_epilog :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	if w.dtd != nil && w.dtd.depth > 0 {
		return fault(w, hs, w.dtd.stack[w.dtd.depth - 1].at, .Bad_Char, .Entity_Boundary)
	}
	q, r := misc_run(w, p, end)
	if r.kind != .None {
		return run_fault(w, hs, r)
	}
	if x, at_ := give_misc(w, on, &hs, p, q, end, true, .Comment_Foot); x != .Next {
		return refused(w, hs, x, at_)
	}
	if q < end {
		return fault(w, hs, q, .Bad_Char, .Junk_After_Root)
	}
	if x := emit(w, on, &hs, .End, .Value, at(w, end), 0); x != .Next {
		return refused(w, hs, x, end)
	}
	w.regs^ = hs
	return core.fault_at(at(w, end), .None)
}

// Reads whitespace, comments and processing instructions from `p`, judging each. Returns where they end: the first byte
// that begins none, or the text's end. The fault is in the `Run`.
@(private)
misc_run :: proc "contextless" (w: ^Walk($H), p, end: [^]u8) -> (q: [^]u8, r: Run) #no_bounds_check {
	q = p
	for {
		q = skip_ws(q, end)
		room := intrinsics.ptr_sub(end, q)
		if room < 2 || q[0] != '<' {
			return q, {}
		}
		switch q[1] {
		case '!':
			if room < 4 {
				if prefix_of(q, room, "<!--") {
					return q, Run{q = end, kind = .Truncated}
				}
				return q, {}
			}
			if q[2] != '-' || q[3] != '-' {
				return q, {}
			}
			c := run(w, q[4:], end, .Comment, 0)
			if c.kind != .None {
				return q, c
			}
			q = c.q[3:]
		case '?':
			next, c := instruction(w, q, end)
			if c.kind != .None {
				return q, c
			}
			q = next
		case:
			return q, {}
		}
	}
}

// Reads the processing instruction at `q`, where `q[0:2]` is `<?`. Returns one past its `?>`.
@(private)
instruction :: proc "contextless" (w: ^Walk($H), q, end: [^]u8) -> (next: [^]u8, r: Run) #no_bounds_check {
	t, nf := name_end(q[2:], end)
	switch nf {
	case .Truncated:
		return q, Run{q = end, kind = .Truncated}
	case .Not_Name:
		return q, Run{q = q[2:], kind = .Bad_Char, detail = .Instruction}
	case .Bad_Utf8:
		return q, Run{q = t, kind = .Bad_Char, detail = .Invalid_Utf8}
	case .None:
	}
	if intrinsics.ptr_sub(t, q[2:]) == 3 && q[2] | 0x20 == 'x' && q[3] | 0x20 == 'm' && q[4] | 0x20 == 'l' {
		return q, Run{q = q[2:], kind = .Bad_Char, detail = .Reserved_Target}
	}
	if has_colon(q[2:], intrinsics.ptr_sub(t, q[2:])) {
		return q, Run{q = q[2:], kind = .Bad_Char, detail = .Qualified_Name}
	}
	if t >= end {
		return q, Run{q = end, kind = .Truncated}
	}
	if t[0] == '?' {
		if intrinsics.ptr_sub(end, t) < 2 {
			return q, Run{q = end, kind = .Truncated}
		}
		if t[1] != '>' {
			return q, Run{q = t, kind = .Bad_Char, detail = .Instruction}
		}
		return t[2:], {}
	}
	if !is_ws(t[0]) {
		return q, Run{q = t, kind = .Bad_Char, detail = .Instruction}
	}
	d := run(w, t, end, .Pi, 0)
	if d.kind != .None {
		return q, d
	}
	return d.q[2:], {}
}

// Gives the comments and instructions in the run from `p` to `q`, which `misc_run` has read whole. With `inline`, a
// comment on the run's first line is a `Comment_Inline`, and the others get role `rest`. Returns the refusal of
// `emit` and the byte it stopped at.
@(private)
give_misc :: proc "contextless" (w: ^Walk($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, p, q, end: [^]u8, inline: bool, rest: core.Role) -> (Emitted, [^]u8) {
	when H == core.No_Hooks {
		return .Next, p
	} else {
		x := p
		next_line := !inline
		for x < q {
			if x[0] != '<' {
				next_line ||= x[0] == '\n' || x[0] == '\r'
				x = x[1:]
				continue
			}
			e: [^]u8
			role: core.Role
			spelling: u16
			if x[1] == '!' {
				e = run(w, x[4:], q, .Comment, 0).q[3:]
				role = rest if next_line else .Comment_Inline
				spelling = core.comment_spelling(4, 3)
			} else {
				e, _ = instruction(w, x, q)
				role = .Instruction
				spelling = core.comment_spelling(2, 2)
			}
			if r := emit(w, on, hs, .Plain, role, at(w, x), intrinsics.ptr_sub(e, x), spelling); r != .Next {
				return r, e
			}
			if !next_line {
				for c := x; c < e; c = c[1:] {
					if c[0] == '\n' || c[0] == '\r' {
						next_line = true
						break
					}
				}
			}
			x = e
		}
		return .Next, p
	}
}

// Reads the XML declaration at `q`, where the text starts with `<?xml` and a byte that does not continue the target.
// Returns one past its `?>`, or the byte the fault names, and whether it says the document is standalone.
@(private)
declaration :: proc "contextless" (q, end: [^]u8) -> (next: [^]u8, kind: core.Fault_Kind, detail: Detail, standalone: bool) {
	p := q[5:]
	version, after, ok := pseudo_attribute(p, end, "version")
	if !ok {
		if after >= end {
			return end, .Truncated, .None, false
		}
		return after, .Bad_Char, .Declaration, false
	}
	if len(version) < 3 || version[:2] != "1." {
		return p, .Bad_Char, .Declaration, false
	}
	for i in 2 ..< len(version) {
		if version[i] - '0' > 9 {
			return p, .Bad_Char, .Declaration, false
		}
	}
	p = after
	if encoding, after_encoding, found := pseudo_attribute(p, end, "encoding"); found {
		if len(encoding) == 0 || !(encoding[0] | 0x20 >= 'a' && encoding[0] | 0x20 <= 'z') {
			return p, .Bad_Char, .Declaration, false
		}
		for i in 0 ..< len(encoding) {
			c := encoding[i]
			if !(c | 0x20 >= 'a' && c | 0x20 <= 'z' || c - '0' <= 9 || c == '.' || c == '_' || c == '-') {
				return p, .Bad_Char, .Declaration, false
			}
		}
		if !utf8_label(encoding) {
			return p, .Bad_Char, .Encoding, false
		}
		p = after_encoding
	}
	if value, after_standalone, found := pseudo_attribute(p, end, "standalone"); found {
		if value != "yes" && value != "no" {
			return p, .Bad_Char, .Declaration, false
		}
		p, standalone = after_standalone, value == "yes"
	}
	p = skip_ws(p, end)
	if intrinsics.ptr_sub(end, p) < 2 {
		return end, .Truncated, .None, false
	}
	if p[0] != '?' || p[1] != '>' {
		return p, .Bad_Char, .Declaration, false
	}
	return p[2:], .None, .None, standalone
}

@(private)
utf8_label :: proc "contextless" (label: string) -> bool {
	if len(label) != 5 {
		return false
	}
	return label[0] | 0x20 == 'u' && label[1] | 0x20 == 't' && label[2] | 0x20 == 'f' && label[3] == '-' && label[4] == '8'
}

// Reads whitespace, the name `name`, `=` and a quoted value at `p`, for the XML declaration. Returns the value and one
// past the closing quote, or with `ok` false the byte it stopped at.
@(private)
pseudo_attribute :: proc "contextless" (p, end: [^]u8, name: string) -> (value: string, next: [^]u8, ok: bool) #no_bounds_check {
	s := skip_ws(p, end)
	if s == p || intrinsics.ptr_sub(end, s) < len(name) || string(s[:len(name)]) != name {
		return "", p if s == p else s, false
	}
	q := skip_ws(s[len(name):], end)
	if q >= end || q[0] != '=' {
		return "", q, false
	}
	q = skip_ws(q[1:], end)
	if q >= end || q[0] != '"' && q[0] != '\'' {
		return "", q, false
	}
	e := q[1:]
	for e < end && e[0] != q[0] {
		e = e[1:]
	}
	if e >= end {
		return "", end, false
	}
	return string(q[1:][:intrinsics.ptr_sub(e, q[1:])]), e[1:], true
}

// Reads the document type declaration at `q`, where the text starts with `<!DOCTYPE`, and its internal subset into
// the walk's DTD, which a declaration with an external identifier or a subset has. Returns one past its `>`, or the
// byte the fault names.
@(private)
doctype :: proc "contextless" (w: ^Walk($H), src: []u8, q, end: [^]u8, standalone: bool) -> (next, at_: [^]u8, kind: core.Fault_Kind, detail: Detail) #no_bounds_check {
	p := q[9:]
	s := skip_ws(p, end)
	if s >= end {
		return q, end, .Truncated, .None
	}
	if s == p {
		return q, p, .Bad_Char, .Doctype
	}
	n, nf := name_end(s, end)
	switch nf {
	case .Truncated:
		return q, end, .Truncated, .None
	case .Not_Name:
		return q, s, .Bad_Char, .Doctype
	case .Bad_Utf8:
		return q, n, .Bad_Char, .Invalid_Utf8
	case .None:
	}
	p = skip_ws(n, end)
	if p >= end {
		return q, end, .Truncated, .None
	}
	external := false
	public: []u8
	room := intrinsics.ptr_sub(end, p)
	for word in ([]string{"SYSTEM", "PUBLIC"}) {
		if room >= len(word) && string(p[:len(word)]) == word {
			if p == n {
				return q, p, .Bad_Char, .Doctype
			}
			external = true
			is_public := word == "PUBLIC"
			p = p[len(word):]
			passes := 2 if is_public else 1
			for pass in 0 ..< passes {
				l := skip_ws(p, end)
				if l >= end {
					return q, end, .Truncated, .None
				}
				if l == p {
					return q, p, .Bad_Char, .Doctype
				}
				e, k, bad_at := literal(l, end, is_public && pass == 0)
				if k != .None {
					return q, bad_at, k, .Doctype if k == .Bad_Char else .None
				}
				if is_public && pass == 0 {
					public = l[1:][:intrinsics.ptr_sub(e, l) - 2]
				}
				p = e
			}
			break
		}
	}
	p = skip_ws(p, end)
	if p >= end {
		return q, end, .Truncated, .None
	}
	if p[0] != '>' && p[0] != '[' {
		return q, p, .Bad_Char, .Doctype
	}
	if !external && p[0] == '>' {
		return p[1:], nil, .None, .None
	}
	d := dtd_make(src, w.opts)
	if d == nil {
		return q, p, .No_Memory, .None
	}
	w.dtd = d
	if !external {
		d.built.flags += {.Complete}
	}
	if standalone {
		d.built.flags += {.Standalone}
	}
	for id in HTML_PUBLIC_IDS {
		if string(public) == id {
			d.built.flags += {.Html}
		}
	}
	if p[0] == '[' {
		d.built.subset_lo = u64(intrinsics.ptr_sub(p[1:], raw_data(src)))
		rw := Walk(core.No_Hooks) {
			base = w.base,
			tier = w.tier,
			dtd  = d,
		}
		close, f := declarations(d, &rw, p[1:], end, true, false, 0)
		if f.kind != .None {
			return q, f.at if f.at != nil else p, f.kind, f.detail
		}
		d.built.subset_hi = u64(intrinsics.ptr_sub(close, raw_data(src)))
		p = skip_ws(close[1:], end)
		if p >= end {
			return q, end, .Truncated, .None
		}
		if p[0] != '>' {
			return q, p, .Bad_Char, .Doctype
		}
	}
	if !dtd_seal(d) {
		return q, p, .No_Memory, .None
	}
	return p[1:], nil, .None, .None
}

// Reads the quoted literal at `p` of an external identifier. A public identifier takes only `PubidChar`, a system
// identifier any `Char`. Returns one past the closing quote.
@(private)
literal :: proc "contextless" (p, end: [^]u8, pubid: bool) -> (next: [^]u8, kind: core.Fault_Kind, at_: [^]u8) #no_bounds_check {
	quote := p[0]
	if quote != '"' && quote != '\'' {
		return p, .Bad_Char, p
	}
	q := p[1:]
	for q < end {
		c := q[0]
		if c == quote {
			return q[1:], .None, nil
		}
		if c >= 0x80 {
			r, k := spell.utf8_char(q, end)
			if k == .Truncated {
				return end, .Truncated, end
			}
			if k != .None || pubid || c == 0xef && non_char(q, end) {
				return q, .Bad_Char, q
			}
			q = r
			continue
		}
		if pubid {
			if !(c == ' ' || c == '\r' || c == '\n' || c | 0x20 >= 'a' && c | 0x20 <= 'z' || c - '0' <= 9 || c == '-' || c == '\'' || c == '(' || c == ')' || c == '+' || c == ',' || c == '.' || c == '/' || c == ':' || c == '=' || c == '?' || c == ';' || c == '!' || c == '*' || c == '#' || c == '@' || c == '$' || c == '_' || c == '%') {
				return q, .Bad_Char, q
			}
		} else if c < 0x20 && c != '\t' && c != '\n' && c != '\r' {
			return q, .Bad_Char, q
		}
		q = q[1:]
	}
	return end, .Truncated, end
}

// Whether the first `n` bytes at `p` are the first `n` bytes of `word`, where `n` is at most `len(word)`.
@(private)
prefix_of :: #force_inline proc "contextless" (p: [^]u8, n: int, word: string) -> bool #no_bounds_check {
	for i in 0 ..< n {
		if p[i] != word[i] {
			return false
		}
	}
	return true
}
