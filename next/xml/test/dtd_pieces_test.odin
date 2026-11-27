package xml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

// Piece reads with an internal DTD subset (`<!DOCTYPE ... [...]>`) release consumed bytes past the DTD subset instead
// of pinning `Pieces.keep` at `subset_lo` for the rest of the stream, while preserving entity expansion, defaulted
// attributes, and markup entities across `validate`, `find`, and `scan`.
@(test)
piece_reads_release_bytes_after_internal_dtd_subset :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Build a ~40 KiB body of sibling elements so window growth past the DTD subset is unmistakable.
	body_b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 1000 {
		fmt.sbprintf(&body_b, "<item id=\"%d\">payload-bytes-%04d</item>", i, i)
	}
	body := strings.to_string(body_b)

	Case :: struct {
		name:      string,
		src:       string,
		find_path: []tape.Step,
		want_find: string,
	}
	path_tail := [?]tape.Step{tape.Name("r"), tape.Name("tail")}
	path_b := [?]tape.Step{tape.Name("r"), tape.Name("tail"), tape.Name("b")}

	cases := [?]Case{
		{
			name      = "plain entity",
			src       = strings.concatenate({`<!DOCTYPE r [<!ENTITY g "hello&amp;world"><!ENTITY unused "&unused;">]><r>`, body, `<tail>&g;</tail></r>`}, context.temp_allocator),
			find_path = path_tail[:],
			want_find = "hello&world",
		},
		{
			name      = "entity and default attr",
			src       = strings.concatenate({`<!DOCTYPE r [<!ENTITY g "ok"><!ATTLIST tail a CDATA "def">]><r>`, body, `<tail>&g;</tail></r>`}, context.temp_allocator),
			find_path = path_tail[:],
			want_find = "ok",
		},
		{
			name      = "markup entity",
			src       = strings.concatenate({`<!DOCTYPE r [<!ENTITY m "<b>in</b>">]><r>`, body, `<tail>&m;</tail></r>`}, context.temp_allocator),
			find_path = path_b[:],
			want_find = "in",
		},
		{
			name      = "default xmlns attr",
			src       = strings.concatenate({`<!DOCTYPE r [<!ENTITY g "ns"><!ATTLIST tail xmlns CDATA "urn:t">]><r>`, body, `<tail>&g;</tail></r>`}, context.temp_allocator),
			find_path = path_tail[:],
			want_find = "ns",
		},
	}

	STEP :: 512
	MAX_WINDOW :: 4096

	// Copy each window into an isolated heap slice so ASan catches any out-of-bounds read before `p.from`.
	copy_win :: proc(raw: []u8, lo, hi: u64) -> []u8 {
		buf := make([]u8, hi - lo)
		copy(buf, raw[lo:hi])
		return buf
	}

	for c in cases {
		raw := transmute([]u8)c.src
		subset_end := u64(strings.index(c.src, "]>") + 2)
		testing.expect(t, subset_end > 0 && subset_end < 512)

		// 1. Validate in pieces: window stays bounded and `p.keep` advances well past `subset_end`.
		{
			p := tape.Pieces{allocator = context.allocator}
			defer tape.destroy(&p)
			max_win := u64(0)
			max_keep := u64(0)
			for hi := STEP; ; hi = min(hi + STEP, len(raw)) {
				p.from = p.keep
				p.last = hi == len(raw)
				win := copy_win(raw, p.keep, u64(hi))
				max_win = max(max_win, u64(len(win)))
				err := xml.validate(win, .Xml, {pieces = &p})
				delete(win)
				testing.expectf(t, err == nil, "%s validate: %v", c.name, err)
				max_keep = max(max_keep, p.keep)
				if err != nil || !p.more {
					break
				}
			}
			testing.expectf(t, max_keep > subset_end + 16_000, "%s validate: keep did not advance past DTD (%d <= %d)", c.name, max_keep, subset_end)
			testing.expectf(t, max_win <= MAX_WINDOW, "%s validate: window grew to %d bytes (limit %d)", c.name, max_win, MAX_WINDOW)
		}

		// 2. Find in pieces: bounded window AND matches whole-text find result.
		{
			whole_ans, werr := xml.find(raw, c.find_path)
			testing.expectf(t, werr == nil, "%s whole find: %v", c.name, werr)

			p := tape.Pieces{allocator = context.allocator}
			defer tape.destroy(&p)
			max_win := u64(0)
			max_keep := u64(0)
			ans: tape.Span_Answer
			ferr: tape.Error
			for hi := STEP; ; hi = min(hi + STEP, len(raw)) {
				p.from = p.keep
				p.last = hi == len(raw)
				win := copy_win(raw, p.keep, u64(hi))
				max_win = max(max_win, u64(len(win)))
				ans, ferr = xml.find(win, c.find_path, opts = {pieces = &p})
				delete(win)
				max_keep = max(max_keep, p.keep)
				if ferr != nil || !p.more {
					break
				}
			}
			testing.expectf(t, ferr == nil, "%s piece find: %v", c.name, ferr)
			testing.expect_value(t, ans.outcome, whole_ans.outcome)
			testing.expect_value(t, ans.lo, whole_ans.lo)
			testing.expect_value(t, ans.hi, whole_ans.hi)
			testing.expectf(t, max_keep > subset_end + 16_000, "%s find: keep did not advance past DTD (%d)", c.name, max_keep)
			testing.expectf(t, max_win <= MAX_WINDOW, "%s find: window grew to %d bytes", c.name, max_win)
		}

		// 3. Scan in pieces: bounded window AND entity-expanded value agrees with whole-text scan.
		{
			d, derr := tape.demand_of({c.find_path})
			defer tape.destroy(&d)
			testing.expect_value(t, derr, nil)

			whole_doc, werr := xml.scan(raw, &d)
			defer tape.destroy(&whole_doc)
			testing.expectf(t, werr == nil, "%s whole scan: %v", c.name, werr)

			p := tape.Pieces{allocator = context.allocator}
			defer tape.destroy(&p)
			max_win := u64(0)
			max_keep := u64(0)
			piece_doc: tape.Document
			serr: tape.Error
			for hi := STEP; ; hi = min(hi + STEP, len(raw)) {
				p.from = p.keep
				p.last = hi == len(raw)
				win := copy_win(raw, p.keep, u64(hi))
				max_win = max(max_win, u64(len(win)))
				piece_doc, serr = xml.scan(win, &d, opts = {pieces = &p})
				delete(win)
				max_keep = max(max_keep, p.keep)
				if serr != nil || !p.more {
					break
				}
			}
			defer tape.destroy(&piece_doc)
			testing.expectf(t, serr == nil, "%s piece scan: %v", c.name, serr)
			testing.expect_value(t, testkit.render_doc(&piece_doc), testkit.render_doc(&whole_doc))

			// Verify decoded text expands the entity to `want_find`.
			node, presence, ok := tape.answer(reader(&piece_doc), 0, 0)
			testing.expect(t, ok)
			testing.expect_value(t, presence, tape.Presence.Found)
			if ok {
				testing.expect_value(t, testkit.scalar_text(&piece_doc, node), c.want_find)
			}
			testing.expectf(t, max_keep > subset_end + 16_000, "%s scan: keep did not advance past DTD (%d)", c.name, max_keep)
			testing.expectf(t, max_win <= MAX_WINDOW, "%s scan: window grew to %d bytes", c.name, max_win)
		}
	}
}

// A malformed DTD entity literal that closes an outer element (`<!ENTITY bad "hello</tail>">`) must fail cleanly with
// `.Bad_Char` (entity boundary) across `validate`, `build`, `find`, and `scan` — both whole-text and in pieces after
// the window has slid past the internal subset (no OOB `ptr_at` or negative span `.Too_Wide`).
@(test)
dtd_entity_closing_outer_element_faults_cleanly :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	short_src := `<!DOCTYPE tail [<!ENTITY bad "hello</tail>">]><tail>&bad;</tail>`
	pad_b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 100 {
		fmt.sbprintf(&pad_b, "<item>%04d</item>", i)
	}
	padded_src := strings.concatenate({`<!DOCTYPE r [<!ENTITY bad "hello</tail>">]><r>`, strings.to_string(pad_b), `<tail>&bad;</tail></r>`}, context.temp_allocator)

	path_tail := [?]tape.Step{tape.Name("tail")}
	path_nested := [?]tape.Step{tape.Name("r"), tape.Name("tail")}

	copy_win :: proc(raw: []u8, lo, hi: u64) -> []u8 {
		buf := make([]u8, hi - lo)
		copy(buf, raw[lo:hi])
		return buf
	}
	expect_entity_fault :: proc(t: ^testing.T, label: string, err: tape.Error, want_at: u64) {
		f, is_f := err.(tape.Fault)
		testing.expectf(t, is_f && f.kind == .Bad_Char && f.at == want_at, "%s: expected Bad_Char at %d, got %v", label, want_at, err)
	}

	Case :: struct {
		name: string,
		src:  string,
		path: []tape.Step,
	}
	for c in ([?]Case{{"short", short_src, path_tail[:]}, {"padded", padded_src, path_nested[:]}}) {
		raw := transmute([]u8)c.src
		want_at := u64(strings.index(c.src, "&bad;"))

		// Whole-text reads.
		expect_entity_fault(t, fmt.tprintf("%s whole validate", c.name), xml.validate(raw), want_at)
		doc, berr := xml.build(raw)
		tape.destroy(&doc)
		expect_entity_fault(t, fmt.tprintf("%s whole build", c.name), berr, want_at)
		_, ferr := xml.find(raw, c.path)
		expect_entity_fault(t, fmt.tprintf("%s whole find", c.name), ferr, want_at)
		d, derr := tape.demand_of({c.path})
		defer tape.destroy(&d)
		testing.expect_value(t, derr, nil)
		sdoc, serr := xml.scan(raw, &d)
		tape.destroy(&sdoc)
		expect_entity_fault(t, fmt.tprintf("%s whole scan", c.name), serr, want_at)

		// Piece reads with isolated window copies (step 64 so window slides well past the DTD subset on `padded`).
		STEP :: 64
		{
			p := tape.Pieces{allocator = context.allocator}
			defer tape.destroy(&p)
			err: tape.Error
			for hi := min(STEP, len(raw)); ; hi = min(hi + STEP, len(raw)) {
				p.from = p.keep
				p.last = hi == len(raw)
				win := copy_win(raw, p.keep, u64(hi))
				err = xml.validate(win, .Xml, {pieces = &p})
				delete(win)
				if err != nil || !p.more {
					break
				}
			}
			expect_entity_fault(t, fmt.tprintf("%s pieces validate", c.name), err, want_at)
		}
		{
			p := tape.Pieces{allocator = context.allocator}
			defer tape.destroy(&p)
			pdoc: tape.Document
			err: tape.Error
			for hi := min(STEP, len(raw)); ; hi = min(hi + STEP, len(raw)) {
				p.from = p.keep
				p.last = hi == len(raw)
				win := copy_win(raw, p.keep, u64(hi))
				pdoc, err = xml.build(win, .Xml, {pieces = &p})
				delete(win)
				if err != nil || !p.more {
					break
				}
			}
			tape.destroy(&pdoc)
			expect_entity_fault(t, fmt.tprintf("%s pieces build", c.name), err, want_at)
		}
		{
			p := tape.Pieces{allocator = context.allocator}
			defer tape.destroy(&p)
			err: tape.Error
			for hi := min(STEP, len(raw)); ; hi = min(hi + STEP, len(raw)) {
				p.from = p.keep
				p.last = hi == len(raw)
				win := copy_win(raw, p.keep, u64(hi))
				_, err = xml.find(win, c.path, opts = {pieces = &p})
				delete(win)
				if err != nil || !p.more {
					break
				}
			}
			expect_entity_fault(t, fmt.tprintf("%s pieces find", c.name), err, want_at)
		}
		{
			p := tape.Pieces{allocator = context.allocator}
			defer tape.destroy(&p)
			pdoc: tape.Document
			err: tape.Error
			for hi := min(STEP, len(raw)); ; hi = min(hi + STEP, len(raw)) {
				p.from = p.keep
				p.last = hi == len(raw)
				win := copy_win(raw, p.keep, u64(hi))
				pdoc, err = xml.scan(win, &d, opts = {pieces = &p})
				delete(win)
				if err != nil || !p.more {
					break
				}
			}
			tape.destroy(&pdoc)
			expect_entity_fault(t, fmt.tprintf("%s pieces scan", c.name), err, want_at)
		}
	}
}
