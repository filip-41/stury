package json

// Entry-level operations for `insert`, `set` (`upsert`), and `remove`: container scans, entry span resolution,
// separator inference, and JSONC extent placement.

import "base:runtime"
import "core:slice"
import "core:strings"
import core_pkg "../core"
import "scan/walk"
import scan_pkg "scan"

// A JSONC path edit's scan: its entries and their comments are read off the rows.
@(private = "file")
EDIT_QUERIES :: bit_set[Query]{.Path, .Nodes}

// `insert` of the written value `repl`. With `upsert`, a member `at` the object already has has its value
// replaced instead (`set` with `upsert`).
@(private)
insert_at :: proc(src: []byte, p: Path, at: Insert_At, repl: []u8, allocator: runtime.Allocator, dialect: Dialect, upsert := false) -> (out: []byte, err: Maybe(Path_Error)) {
	switch dialect {
	case .Json:
		return insert_in(src, p, at, repl, allocator, .Json, upsert)
	case .Jsonc:
		return insert_in(src, p, at, repl, allocator, .Jsonc, upsert)
	case .Json5: // `edits_read` refuses it before any edit
	}
	return nil, Path_Error{kind = .Bad_Option}
}

// `$dialect` is a compile-time parameter, so the JSON edit compiles without the comment branches.
@(private = "file")
insert_in :: proc(src: []byte, p: Path, at: Insert_At, repl: []u8, allocator: runtime.Allocator, $dialect: Dialect, upsert: bool) -> (out: []byte, err: Maybe(Path_Error)) {
	G :: scan_pkg.GRAMMAR[dialect]
	key := make([dynamic]u8, allocator)
	defer delete(key)
	// Path 0 finds the containers. Under JSON path 1 their entries, which JSONC reads off its rows. The last
	// path is an object's member `at`.
	kids_buf, member_buf: [core_pkg.MAX_PATH_STEPS + 1]Step
	paths := [3]Path{p, extend(kids_buf[:], p.steps, Any{}), {}}
	n_paths := 1 if .Comments in G else 2
	member_q := u32(n_paths)
	if name, is_name := at.(string); is_name {
		if merr := marshal_append(&key, name, {}, nil); merr != .None {
			return nil, Path_Error{kind = .Encode, encode = merr}
		}
		paths[n_paths] = extend(member_buf[:], p.steps, Name(name))
		n_paths += 1
	}
	req: Request(EDIT_QUERIES when .Comments in G else {.Path})
	req.state.route.every_member = true
	defer request_destroy(&req)
	edit_scan(src, &req, paths[:n_paths], dialect, allocator) or_return
	targets, members := found(req.answers[:], 0, allocator), found(req.answers[:], member_q, allocator)
	defer delete(targets)
	defer delete(members)
	when .Comments in G {
		kids := make([dynamic]Path_Answer, allocator)
	} else {
		kids := found(req.answers[:], 1, allocator)
		kc := 0
	}
	defer delete(kids)
	text := make([dynamic]u8, allocator)
	defer delete(text)
	places := make([dynamic]Place, allocator)
	defer delete(places)
	mc := 0
	for c in targets {
		// `set` with `upsert`: the object's member, when it has one, has its value replaced.
		if m := held_by(members[:], &mc, c.lo) if upsert else nil; len(m) > 0 {
			from := len(text)
			append(&text, ..repl)
			append(&places, Place{at = m[0].lo, cut = m[0].hi, from = from, to = len(text)})
			continue
		}
		when .Comments in G {
			own := entries_of(&req.doc, c.node, &kids)
		} else {
			own := held_by(kids[:], &kc, c.lo)
		}
		k := insert_slot(at, c, len(own), members[:], &mc) or_return
		entry_at(&text, &places, src, &req.doc, c, own, k, key[:] if len(key) > 0 else nil, repl, G) or_return
	}
	out, err = places_apply(src, places[:], text[:], allocator)
	when .Comments in G {
		return judged(out, err, allocator, dialect)
	} else {
		return
	}
}

// `remove` of what `p` finds, entry by entry (`entry_lo`, `entry_hi`). A run of removed entries before a
// survivor goes up to the survivor's start. A run at the end takes the separator before it: under JSON from
// the last survivor's end, under JSONC too when no comment sits between them. Otherwise it takes the
// survivor's comma, unless trail comments follow that comma, and then the run's own line break. With no survivor (and under JSONC no
// foot comments) the interior goes. `$dialect` is a compile-time parameter, so the JSON edit compiles without
// the comment branches.
@(private)
remove_in :: proc(src: []byte, p: Path, allocator: runtime.Allocator, $dialect: Dialect) -> (out: []byte, err: Maybe(Path_Error)) {
	G :: scan_pkg.GRAMMAR[dialect]
	// Path 0 finds the values. Under JSON path 1 is every entry of the containers holding them, which JSONC
	// reads off its rows.
	kids_buf: [core_pkg.MAX_PATH_STEPS]Step
	paths := [2]Path{p, extend(kids_buf[:], p.steps[:len(p.steps) - 1], Any{})}
	req: Request(EDIT_QUERIES when .Comments in G else {.Path})
	req.duplicates = .All
	defer request_destroy(&req)
	edit_scan(src, &req, paths[:1 if .Comments in G else 2], dialect, allocator) or_return
	doc := &req.doc
	gone, kids := found(req.answers[:], 0, allocator), found(req.answers[:], 1, allocator)
	defer delete(gone)
	defer delete(kids)
	if len(gone) == 0 {
		return nil, Path_Error{kind = .Not_Found}
	}
	edits := make([dynamic]Edit, allocator)
	defer delete(edits)
	when .Comments not_in G {
		kc := 0
	}
	for i := 0; i < len(gone); {
		// The removed entries of one container, in order.
		owner := gone[i].owner
		j := i + 1
		for j < len(gone) && gone[j].owner == owner {
			j += 1
		}
		run := gone[i:j]
		i = j
		when .Comments in G {
			c := node_at(doc.rows[:], owner)
			own := entries_of(doc, c, &kids)
		} else {
			own := held_by(kids[:], &kc, owner)
		}
		first, last, kept, keyed := cut_interior_runs(&edits, src, doc, own, run, G)
		if !keyed {
			return nil, Path_Error{kind = .Internal}
		}
		if first < 0 {
			continue
		}
		lo, hi, trailing_keyed := trailing_cut(src, doc, owner, own, first, last, kept, G)
		if !trailing_keyed {
			return nil, Path_Error{kind = .Internal}
		}
		append(&edits, Edit{lo = lo, hi = hi})
	}
	when .Comments in G {
		slice.sort_by(edits[:], proc(a, b: Edit) -> bool {
			return a.lo < b.lo
		})
		return judged(edits_apply_checked(src, edits[:], allocator), allocator, dialect)
	} else {
		return edits_apply_checked(src, edits[:], allocator)
	}
}

// Queue the cut of every run of removed entries (`run`, in order) in `own` that a survivor follows. The
// trailing run is left to `trailing_cut`: its `first` and `last` entry indexes, or -1 when `own` ends in a
// survivor, and `kept`, the last survivor's index or -1.
@(private = "file")
cut_interior_runs :: proc(edits: ^[dynamic]Edit, src: []byte, doc: ^Document, own, run: []Path_Answer, $G: scan_pkg.Grammar) -> (first, last, kept: int, keyed: bool) {
	first, last, kept, keyed = -1, -1, -1, true
	g := 0
	for e, x in own {
		for g < len(run) && run[g].lo < e.lo {
			g += 1
		}
		if g < len(run) && run[g].lo == e.lo {
			first = x if first < 0 else first
			last = x
			continue
		}
		if first >= 0 {
			lo, lo_keyed := entry_lo(src, doc, own[first], G)
			hi, hi_keyed := entry_lo(src, doc, e, G)
			if !lo_keyed || !hi_keyed {
				return -1, -1, -1, false
			}
			append(edits, Edit{lo = lo, hi = hi})
			first = -1
		}
		kept = x
	}
	return
}

// The bytes that go for the run at the end of container `owner`, entries `own[first]` to `own[last]`, after
// survivor `own[kept]` (or none): see `remove_in` for what each case takes.
@(private = "file")
trailing_cut :: proc(src: []byte, doc: ^Document, owner: u64, own: []Path_Answer, first, last, kept: int, $G: scan_pkg.Grammar) -> (lo, hi: u64, keyed: bool) {
	lo, keyed = entry_lo(src, doc, own[first], G)
	hi = entry_hi(doc, own[last], G)
	when .Comments in G {
		c := node_at(doc.rows[:], owner)
		comma: u64
		if kept >= 0 {
			comma, _ = comma_after(src, own[kept].hi)
		}
		switch {
		case kept >= 0 && !commented(src[own[kept].hi:lo]): // no comment between the survivor and the run
			lo = own[kept].hi
		case kept >= 0 && extent_hi(doc, own[kept].node) == comma + 1: // the survivor's extent ends at its comma
			lo = comma
		case kept < 0 && !has_place(doc, c, .Foot):
			lo, hi = u64(doc.rows[c].lo) + 1, u64(doc.rows[c].hi) - 1
		case:
			lo, hi = own_lines(doc, lo, hi)
		}
	} else {
		if kept >= 0 {
			lo = own[kept].hi
		} else {
			lo = owner + 1
			for hi < u64(len(src)) && walk.is_space(src[hi]) {
				hi += 1
			}
			when ODIN_DEBUG {
				assert(hi < u64(len(src)) && (src[hi] == '}' || src[hi] == ']'), "trailing_cut: no close bracket after the container's last entry")
			}
		}
	}
	return
}

// The quoted key before an object member's value at `value_lo`, read backwards over strict JSON: blanks,
// `:`, blanks, then the string, whose opening quote is the first `"` behind an even run of backslashes.
// `ok` is false when no key precedes the value, and the edit that asked is refused.
@(private = "file")
key_span :: proc(src: []byte, value_lo: u64) -> (lo, hi: u64, ok: bool) {
	if value_lo > u64(len(src)) {
		return no_key(value_lo)
	}
	i := value_lo
	for i > 0 && walk.is_space(src[i - 1]) {
		i -= 1
	}
	if i == 0 {
		return no_key(value_lo)
	}
	i -= 1 // the colon
	for i > 0 && walk.is_space(src[i - 1]) {
		i -= 1
	}
	hi = i
	if hi < 2 {
		return no_key(value_lo)
	}
	lo = hi - 1
	for lo >= 2 {
		lo -= 1
		if src[lo] != '"' {
			continue
		}
		slashes := u64(0)
		for slashes < lo && src[lo - 1 - slashes] == '\\' {
			slashes += 1
		}
		if slashes % 2 == 0 {
			return lo, hi, true
		}
	}
	return no_key(value_lo)
}

@(private = "file")
no_key :: proc(value_lo: u64) -> (lo, hi: u64, ok: bool) {
	when ODIN_DEBUG {
		assert(false, "key_span: an object member's value is not preceded by its key")
	}
	return value_lo, value_lo, false
}

// Where entry `e` starts: under JSONC its extent (`extent_lo`), else its head (`entry_head`).
@(private = "file")
entry_lo :: proc(src: []byte, doc: ^Document, e: Path_Answer, $G: scan_pkg.Grammar) -> (lo: u64, keyed: bool) {
	when .Comments in G {
		return extent_lo(doc, e.node), true
	} else {
		return entry_head(src, doc, e, G)
	}
}

// Where entry `e`'s own text starts, no comment before it: its key in an object, its value in an array.
// `keyed` is false for a member whose key is not found (`key_span`).
@(private = "file")
entry_head :: proc(src: []byte, doc: ^Document, e: Path_Answer, $G: scan_pkg.Grammar) -> (lo: u64, keyed: bool) {
	when .Comments in G {
		return u64(scan_pkg.entry_lo(doc.rows[e.node])), true
	} else {
		if src[e.owner] == '{' {
			lo, _, keyed = key_span(src, e.lo)
			return
		}
		return e.lo, true
	}
}

// Where entry `e` ends: under JSONC its extent, its comma included (`extent_hi`), else its value.
@(private = "file")
entry_hi :: proc(doc: ^Document, e: Path_Answer, $G: scan_pkg.Grammar) -> u64 {
	when .Comments in G {
		return extent_hi(doc, e.node)
	} else {
		return e.hi
	}
}

// Whether bytes between two entries, which hold blanks, commas and comments only, hold a comment.
@(private = "file")
commented :: proc(gap: []byte) -> bool {
	return slice.contains(gap, '/')
}

@(private = "file")
put_entry :: proc(places: ^[dynamic]Place, at: u64, from, to: int) {
	append(places, Place{at = at, cut = at, from = from, to = to})
}

// The bytes between a member's key and value that a new member copies from `first`, the first member:
// unless a comment sits there, under JSONC, where it is `": "`. Empty for an element.
@(private = "file")
member_between :: proc(src: []byte, doc: ^Document, first: Path_Answer, is_member: bool, $G: scan_pkg.Grammar) -> (between: string, keyed: bool) {
	keyed = true
	if !is_member {
		return
	}
	when .Comments in G {
		between = string(src[doc.rows[first.node].key_hi:first.lo])
		if strings.contains_rune(between, '/') {
			between = ": "
		}
	} else {
		khi: u64
		_, khi, keyed = key_span(src, first.lo)
		between = string(src[khi:first.lo])
	}
	return
}

// The separator a new entry before entry `k` of container `c` copies: after the open bracket for a lone
// entry, else between the two entries around the spot.
@(private = "file")
separator_gap :: proc(src: []byte, doc: ^Document, c: Path_Answer, own: []Path_Answer, k: int, $G: scan_pkg.Grammar) -> (lo, hi: u64, keyed: bool) {
	n := len(own)
	if n < 2 {
		hi, keyed = entry_head(src, doc, own[0], G)
		return c.lo + 1, hi, keyed
	}
	j := clamp(k if k != APPEND else n, 1, n - 1)
	hi, keyed = entry_head(src, doc, own[j], G)
	return own[j - 1].hi, hi, keyed
}

// Under JSONC, whether a comment sits where a new entry before entry `k` of `c` goes: after the last entry
// when `appending`, else between entry `k - 1` (or the open bracket) and entry `k`.
@(private = "file")
commented_at_spot :: proc(src: []byte, doc: ^Document, c: Path_Answer, own: []Path_Answer, k: int, appending: bool, $G: scan_pkg.Grammar) -> bool {
	spot_lo, spot_hi := own[len(own) - 1].hi, c.hi - 1
	if !appending {
		spot_lo = c.lo + 1
		spot_hi, _ = entry_head(src, doc, own[k], G)
		if k > 0 {
			spot_lo = own[k - 1].hi
		}
	}
	return commented(src[spot_lo:spot_hi])
}

// Place a new entry of container `c`, whose entries are `own`, before entry `k` (`APPEND`: after the last).
// `key` is the written name, nil for an element. The entry copies the separator before the entry nearest to
// where it goes, blanks and one comma, or for a lone entry a comma and the blanks after the open bracket.
// Under JSONC a comment in that separator or where the entry goes places it between extents
// (`entry_between_extents`). Without one, JSONC lays the entry out as JSON does. `.Unplaceable` when the
// separator holds anything else.
@(private = "file")
entry_at :: proc(text: ^[dynamic]u8, places: ^[dynamic]Place, src: []byte, doc: ^Document, c: Path_Answer, own: []Path_Answer, k: int, key, value: []u8, $G: scan_pkg.Grammar) -> Maybe(Path_Error) {
	n := len(own)
	from := len(text)
	if n == 0 {
		write_entry(text, key, ":", value)
		put_entry(places, c.hi - 1, from, len(text))
		return nil
	}
	between, between_keyed := member_between(src, doc, own[0], key != nil, G)
	gap_lo, gap_hi, gap_keyed := separator_gap(src, doc, c, own, k, G)
	if !between_keyed || !gap_keyed {
		return Path_Error{kind = .Internal}
	}
	appending := k == APPEND || k == n
	when .Comments in G {
		if commented(src[gap_lo:gap_hi]) || commented_at_spot(src, doc, c, own, k, appending, G) {
			return entry_between_extents(text, places, src, doc, c, own, k, key, between, value)
		}
	}
	gap := src[gap_lo:gap_hi]
	// Whether the entry writes its own comma: a gap between two entries holds theirs.
	comma := n < 2
	commas := 0
	for b in gap {
		if b == ',' && !comma {
			commas += 1
		} else if !walk.is_space(b) {
			return Path_Error{kind = .Unplaceable}
		}
	}
	if commas != (0 if comma else 1) {
		return Path_Error{kind = .Unplaceable}
	}
	if appending {
		if comma {
			append(text, ',')
		}
		append(text, ..gap)
		write_entry(text, key, between, value)
		put_entry(places, own[n - 1].hi, from, len(text))
		return nil
	}
	write_entry(text, key, between, value)
	if comma {
		append(text, ',')
	}
	append(text, ..gap)
	head, keyed := entry_head(src, doc, own[k], G)
	if !keyed {
		return Path_Error{kind = .Internal}
	}
	put_entry(places, head, from, len(text))
	return nil
}

// `entry_at` under JSONC with a comment in the way: the entry goes between two extents, so no comment changes
// owner. It copies the blanks between them and writes a comma before them. An append after an entry with no
// comma adds one at its value's end, and starts a new line after a line comment. `.Unplaceable` when those
// bytes hold more than blanks, `.Bad_Result` when two extents overlap.
@(private = "file")
entry_between_extents :: proc(text: ^[dynamic]u8, places: ^[dynamic]Place, src: []byte, doc: ^Document, c: Path_Answer, own: []Path_Answer, k: int, key: []u8, between: string, value: []u8) -> Maybe(Path_Error) {
	n := len(own)
	from := len(text)
	gap_lo, gap_hi := c.lo + 1, extent_lo(doc, own[0].node)
	if n >= 2 {
		j := clamp(k if k != APPEND else n, 1, n - 1)
		gap_lo, gap_hi = extent_hi(doc, own[j - 1].node), extent_lo(doc, own[j].node)
	}
	if gap_lo > gap_hi {
		return Path_Error{kind = .Bad_Result}
	}
	gap := src[gap_lo:gap_hi]
	for b in gap {
		if !walk.is_space(b) {
			return Path_Error{kind = .Unplaceable}
		}
	}
	if k == APPEND || k == n {
		last := own[n - 1]
		spot := extent_hi(doc, last.node)
		if _, has := comma_after(src, last.hi); !has {
			append(text, ',')
			if spot != last.hi {
				put_entry(places, last.hi, from, len(text))
				from = len(text)
			}
		}
		// A line comment ends the last line, so the entry starts a new one.
		if !slice.contains(gap, '\n') && !slice.contains(gap, '\r') && ends_in_line_comment(doc, last.node, spot) {
			append(text, '\n')
		}
		append(text, ..gap)
		write_entry(text, key, between, value)
		put_entry(places, spot, from, len(text))
		return nil
	}
	write_entry(text, key, between, value)
	append(text, ',')
	append(text, ..gap)
	put_entry(places, extent_lo(doc, own[k].node), from, len(text))
	return nil
}

// Where `insert` puts an entry of container `c`, which has `n` entries: before entry `k`, or `APPEND`. A
// negative index counts from the end as `child`'s does, so `-1` is before the last entry. A name for an
// array, an index for an object, or an index past either end is `.Unplaceable`, a member the object has (in
// `members`, from cursor `mc`) `.Exists`.
@(private = "file")
insert_slot :: proc(at: Insert_At, c: Path_Answer, n: int, members: []Path_Answer, mc: ^int) -> (k: int, err: Maybe(Path_Error)) {
	switch v in at {
	case string:
		if c.kind != .Object {
			return 0, Path_Error{kind = .Unplaceable}
		}
		if len(held_by(members, mc, c.lo)) > 0 {
			return 0, Path_Error{kind = .Exists}
		}
		return APPEND, nil
	case int:
		k = v + n if v < 0 else v
		if c.kind != .Array || (k != APPEND && (k < 0 || k > n)) {
			return 0, Path_Error{kind = .Unplaceable}
		}
		return k, nil
	}
	return
}

// An entry: for a member, `key` and the bytes `between` it and its value, then `value`. For an element
// (`key` nil), `value`.
@(private = "file")
write_entry :: proc(text: ^[dynamic]u8, key: []u8, between: string, value: []u8) {
	if key != nil {
		append(text, ..key)
		append_string(text, between)
	}
	append(text, ..value)
}
