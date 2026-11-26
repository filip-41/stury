package xml

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Builds a long text on the threads of a `tape.Runner`. A seam is the byte past an end tag inside the root, where the
// walk is in the content of the element the tag's parent opened, every open element has given its `Object`, and a new
// text run starts. Each cut of the text guesses the seam after it as the byte past the first `</` and its `>`, which a
// comment, a CDATA section or an instruction may hold. The text between two seams is scanned at once in each part for
// its markup, from the state its seam has when the guess is right: the end tags that close the elements open at its
// seam and the start tags still open at its end. One pass on the calling thread then carries the open elements from
// part to part.
//
// The walk of each part reads from its seam with the frames and namespaces of those open elements, and a part before
// the last pauses where the next part starts. It proves the next part's guess when it pauses there in content with
// the frames the next part starts from, and otherwise the text is built on one thread, as it is when a part's walk is
// cut short by its end, so the first part in text order whose walk faults gives the error the single walk would give.
// A text with a document type declaration, a build under `Budget.steps`, and a part whose walk needs more memory than
// its own block, for frames past `WALK_LEVELS`, namespaces or a tag of many attributes, are built on one thread.

// The bytes of the block each part's walk takes its memory from, as no walk on another thread may call the read's
// allocator.
@(private)
PART_MEMORY :: 16 << 10

// The elements a part's scan holds open at once. A part that opens more is built on one thread.
@(private)
PART_LEVELS :: 256

// A start tag open at a seam: its `<` and its length through its `>`, and in a part's scan whether a child followed it.
@(private)
Part_Open :: struct {
	lo:    u64,
	tag_n: u32,
	child: bool,
}

// What the scan of a part found, and where its seam's open elements lie in the plan's `opens`.
@(private)
Part_Scan :: struct {
	pops:     int, // the end tags that close elements open at its seam
	locals:   int, // the start tags still open at its end, in its block of the plan's `locals`
	deepest:  int, // the most elements it opens at once
	starts:   int,
	texts:    int, // the text runs that may be `#text` members
	facts:    int, // its attributes, comments and instructions
	ok:       bool, // it ends at the byte past an end tag and holds no document type declaration
	opens_at: int,
	opens_n:  int,
}

@(private)
Part_Plan :: struct {
	src:    []u8,
	seams:  []int,
	scans:  []Part_Scan,
	locals: []Part_Open, // `PART_LEVELS` for each part
	opens:  [dynamic]Part_Open,
	kinds:  [dynamic]tape.Kind,
	memory: []u8, // `PART_MEMORY` for each part
	limit:  u64,
}

@(private)
build_parallel :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	doc, err, built := build_parts(src, S, opts, caller)
	if built {
		return doc, err
	}
	one := opts
	one.runner = nil
	if build.read_lax(one) {
		return build_as(src, S, true, one, caller)
	}
	return build_as(src, S, false, one, caller)
}

// Builds `src` in parts and returns its document and error, or `built` false for a text built on one thread.
@(private)
build_parts :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error, built: bool) {
	if opts.budget.steps != 0 {
		return {}, nil, false
	}
	want := build.chunk_count(opts.runner, len(src))
	if want < 2 || prolog_doctype(src) {
		return {}, nil, false
	}
	m: hook.Memory_Budget
	allocator := build.read_allocator(&m, opts, caller)
	plan := Part_Plan {
		src   = src,
		limit = build.read_depth(opts),
		opens = make([dynamic]Part_Open, allocator),
		kinds = make([dynamic]tape.Kind, allocator),
	}
	seams, serr := make([]int, want + 1, allocator)
	if serr != nil {
		return {}, nil, false
	}
	plan.seams = seams
	defer {
		delete(seams, allocator)
		delete(plan.scans, allocator)
		delete(plan.locals, allocator)
		delete(plan.memory, allocator)
		delete(plan.opens)
		delete(plan.kinds)
	}
	merr: runtime.Allocator_Error
	plan.seams[want] = len(src)
	guess :: proc(arg: rawptr, k: int) {
		j := (^Part_Plan)(arg)
		j.seams[k] = 0 if k == 0 else seam_after(j.src, len(j.src) * k / (len(j.seams) - 1))
	}
	tape.fan_each(opts.runner, want, guess, &plan)
	// A guess past the next cut's leaves one part for both.
	n := 1
	for k in 1 ..= want {
		if plan.seams[k] > plan.seams[n - 1] && (k == want || plan.seams[k] < len(src)) {
			plan.seams[n] = plan.seams[k]
			n += 1
		}
	}
	parts_n := n - 1
	if parts_n < 2 || plan.seams[parts_n] != len(src) {
		return {}, nil, false
	}
	plan.seams = plan.seams[:n]
	if plan.scans, merr = make([]Part_Scan, parts_n, allocator); merr != nil {
		return {}, nil, false
	}
	if plan.locals, merr = non_zero_make([]Part_Open, parts_n * PART_LEVELS, allocator); merr != nil {
		return {}, nil, false
	}
	scan :: proc(arg: rawptr, k: int) {
		j := (^Part_Plan)(arg)
		j.scans[k] = part_scan(j.src, j.seams[k], j.seams[k + 1], k == len(j.scans) - 1, j.locals[k * PART_LEVELS:][:PART_LEVELS])
	}
	tape.fan_each(opts.runner, parts_n, scan, &plan)
	parts := make([]build.Part, parts_n, allocator)
	defer delete(parts, allocator)
	if raw_data(parts) == nil || !plan_opens(&plan, parts) {
		return {}, nil, false
	}
	if plan.memory, merr = non_zero_make([]u8, parts_n * PART_MEMORY, allocator); merr != nil {
		return {}, nil, false
	}
	walk :: proc(src: []u8, parts: []build.Part, k: int, s: ^build.Segment, opts: Options, data: rawptr) {
		walk_part(src, parts, k, s, opts, (^Part_Plan)(data))
	}
	finish :: proc(doc: ^tape.Document, segs: []build.Segment, opts: Options, data: rawptr) -> tape.Error {
		build.segments_dups(doc, segs, opts.dups, &RULES, opts.runner) or_return
		return keep_scopes(doc, true)
	}
	return build.parts_build(src, &FORMATS[S], &RULES, parts, opts, 0, allocator, caller, walk, finish, &plan)
}

// The seam after byte `from` of `src` when `from` lies in content: the byte past the first `</` and the `>` after it,
// or the text's end for none.
@(private)
seam_after :: proc "contextless" (src: []u8, from: int) -> int #no_bounds_check {
	i := from
	for i < len(src) {
		k := kernel.index_byte(src[i:], '<')
		if k < 0 {
			break
		}
		i += k + 1
		if i < len(src) && src[i] == '/' {
			gt := kernel.index_byte(src[i:], '>')
			if gt < 0 {
				break
			}
			return i + gt + 1
		}
	}
	return len(src)
}

// Scans the markup of `src` from seam `lo` to seam `hi`, keeping the start tags still open at `hi` in `locals`, in
// blocks of 64 bytes whose masks of `<`, `>`, quotes and white space step from one markup byte to the next. A
// comment, an instruction or a CDATA section is read past by its close. A part before the `last` must end at the byte
// past an end tag. Bytes up to U+0020 count as white space, which only a text the walk refuses holds otherwise.
@(private)
part_scan :: proc "contextless" (src: []u8, lo, hi: int, last: bool, locals: []Part_Open) -> (s: Part_Scan) #no_bounds_check {
	Mode :: enum u8 {
		Text,
		Tag,
		Quote, // in an attribute value of a start tag, which `quote` ends
		End, // in an end tag
	}
	text := src[:hi]
	mode := Mode.Text
	quote: u8
	tag, past := 0, -1 // the start tag being read, and the byte past the last end tag
	// The run since the last tag holds a character other than white space, so a tag after it may end a text member.
	chars := false
	base, pos := lo, uint(0)
	blocks: for base < hi {
		b := kernel.load_block(text, base)
		m := kernel.pack_n([4]kernel.Block{kernel.eq(b, '<'), kernel.eq(b, '>'), kernel.eq(b, '"'), kernel.eq(b, '\'')})
		lt, gt, dq, sq, other := m[0], m[1], m[2], m[3], ~kernel.pack(kernel.below(b, 0x21))
		for pos < 64 {
			above := max(u64) << pos
			x: u64
			switch mode {
			case .Text:
				x = lt & above
			case .Tag:
				x = (gt | dq | sq) & above
			case .Quote:
				x = (dq if quote == '"' else sq) & above
			case .End:
				x = gt & above
			}
			if x == 0 {
				chars ||= mode == .Text && other & above != 0
				break
			}
			t := uint(intrinsics.count_trailing_zeros(x))
			at := base + int(t)
			pos = t + 1
			switch mode {
			case .Text:
				chars ||= other & above & ~(max(u64) << t) != 0
				if at + 1 >= hi {
					return
				}
				switch text[at + 1] {
				case '/':
					mode, pos = .End, t + 2
				case '?', '!':
					past, closed := markup_end(raw_data(text)[at:], raw_data(text)[hi:])
					if !closed {
						return
					}
					// A CDATA section is a character of the text, and a comment or an instruction a fact.
					if text[at + 2] == '[' {
						chars = true
					} else {
						s.facts += 1
					}
					base, pos = intrinsics.ptr_sub(past, raw_data(text)), 0
					continue blocks
				case:
					mode, tag = .Tag, at
				}
			case .Tag:
				if text[at] != '>' {
					mode, quote = .Quote, text[at]
					s.facts += 1
					continue
				}
				mode = .Text
				s.starts += 1
				s.texts += int(chars)
				chars = false
				if s.locals > 0 {
					locals[s.locals - 1].child = true
				}
				if text[at - 1] != '/' {
					if s.locals == len(locals) {
						return
					}
					locals[s.locals] = {lo = u64(tag), tag_n = u32(at + 1 - tag)}
					s.locals += 1
					s.deepest = max(s.deepest, s.locals)
				}
			case .Quote:
				mode = .Tag
			case .End:
				mode, past = .Text, at + 1
				// An element open at the seam has a child, and one opened in the part has one when a start tag said so.
				if s.locals > 0 {
					s.locals -= 1
					s.texts += int(chars && locals[s.locals].child)
				} else {
					s.pops += 1
					s.texts += int(chars)
				}
				chars = false
			}
		}
		base += 64
		pos -= 64 if pos >= 64 else pos
	}
	s.ok = last || mode == .Text && past == hi
	return
}

// Carries the open elements of the plan's scans from part to part and plans `parts` from them. False when a scan
// failed, a part closes more elements than its seam has open, or a seam lies outside the root.
@(private)
plan_opens :: proc(plan: ^Part_Plan, parts: []build.Part) -> bool {
	stack := make([dynamic]Part_Open, plan.opens.allocator)
	defer delete(stack)
	for &s, k in plan.scans {
		if !s.ok {
			return false
		}
		s.opens_at, s.opens_n = len(plan.opens), len(stack)
		if _, err := append(&plan.opens, ..stack[:]); err != nil {
			return false
		}
		kinds_at := len(plan.kinds)
		if k > 0 {
			if err := resize(&plan.kinds, kinds_at + 1 + len(stack)); err != nil {
				return false
			}
			for &kind in plan.kinds[kinds_at:] {
				kind = .Object
			}
		}
		parts[k] = {
			from     = plan.seams[k],
			to       = plan.seams[k + 1],
			opens_at = kinds_at,
			opens_n  = len(plan.kinds) - kinds_at,
			levels   = 2 + len(stack) + s.deepest,
			comments = s.facts + 4,
			nodes    = 2 * (s.starts + s.texts) + 4,
		}
		if k == len(plan.scans) - 1 {
			break
		}
		if s.pops > len(stack) {
			return false
		}
		resize(&stack, len(stack) - s.pops)
		if _, err := append(&stack, ..plan.locals[k * PART_LEVELS:][:s.locals]); err != nil || len(stack) == 0 {
			return false
		}
	}
	build.parts_opens(parts, plan.kinds[:])
	return true
}

// Walks part `k` of `parts` into segment `s`, from its seam's open elements, and settles the part's error: a part
// before the last proves the next part's seam or is astray.
@(private)
walk_part :: proc(src: []u8, parts: []build.Part, k: int, s: ^build.Segment, opts: Options, plan: ^Part_Plan) {
	p := &parts[k]
	last := k == len(parts) - 1
	arena: mem.Arena
	mem.arena_init(&arena, plan.memory[k * PART_MEMORY:][:PART_MEMORY])
	ctx := context
	ctx.allocator = mem.arena_allocator(&arena)
	frames: [WALK_LEVELS]Frame = ---
	pause := Pause {
		end   = raw_data(src)[p.to:],
		more  = true,
		units = {at = u64(p.to), whole = u64(p.to)},
	}
	w: Walk(build.Builder, true)
	walk_init(&w, opts, plan.limit, max(u64), raw_data(frames[:]))
	walk_bind(&w, raw_data(src), &s.b, &s.regs, &ctx)
	w.pause, w.allocator = nil if last else &pause, ctx.allocator
	w.depth = hook.held_depth(&s.b, &s.regs, min(w.limit, WALK_LEVELS))
	text, end := src[:p.to], raw_data(src)[p.to:]
	r: u64
	if k == 0 {
		r = prolog(&w, text, 0, s.regs.a, s.regs.b, s.regs.c, build.builder_hook_facts)
	} else {
		sc := plan.scans[k]
		d := u64(sc.opens_n)
		if !seam_frames(&w, plan.opens[sc.opens_at:][:sc.opens_n], u64(p.from)) {
			p.astray = true
			return
		}
		r = st_content(raw_data(src)[p.from:], end, d, &w, s.regs.a, s.regs.b, s.regs.c, build.builder_hook_facts)
	}
	if !last && u8(r) == hook.WALK_MORE {
		next := plan.scans[k + 1]
		p.close, p.astray = u64(p.to), !seam_proved(&w, &pause, plan.opens[next.opens_at:][:next.opens_n], u64(p.to))
		return
	}
	p.close, p.err, _ = hook.walk_error(hook.Walk_Result(r), &RULES)
	if !last {
		// A part cut short by its end, or that ended its walk, misread the text, or faults where the single walk reads on.
		f, is_fault := p.err.(tape.Fault)
		p.astray = p.err == nil || is_fault && f.kind == .Truncated
	}
}

// Sets the frames of walk `w` for the elements `opens` open at seam `at`, each with its `Object` given and a child
// ended, and declares their namespaces. False for a tag no walk reads so, which a walk of a part before refuses.
@(private)
seam_frames :: proc "contextless" (w: ^Walk($H, $LAX), opens: []Part_Open, at: u64) -> bool #no_bounds_check {
	for o, i in opens {
		tag := w.base[o.lo:]
		gt := tag[o.tag_n - 1:]
		q, nf := name_end(tag[1:], gt)
		if nf != .None {
			return false
		}
		w.stack[i] = Frame {
			tag     = tag,
			text_lo = o.lo + u64(o.tag_n),
			tag_n   = o.tag_n,
			name_n  = u16(intrinsics.ptr_sub(q, tag[1:])),
			flags   = {.Object, .Prev},
		}
		for q < gt {
			q = kernel.skip_ws(q, gt)
			if q >= gt || q[0] == '>' || q[0] == '/' {
				break
			}
			name := q
			q, nf = name_end(q, gt)
			if nf != .None {
				return false
			}
			n := intrinsics.ptr_sub(q, name)
			q = kernel.skip_ws(q, gt)
			if q >= gt || q[0] != '=' {
				return false
			}
			q = kernel.skip_ws(q[1:], gt)
			if q >= gt || q[0] != '"' && q[0] != '\'' {
				return false
			}
			k := kernel.index_byte(q[1:][:intrinsics.ptr_sub(gt, q[1:])], q[0])
			if k < 0 {
				return false
			}
			if declares_ns(name, n) {
				if rule, no_memory := declare(w, name, n, q[1:][:k], u64(i) + 1); rule != .None || no_memory {
					return false
				}
			}
			q = q[k + 2:]
		}
	}
	if len(opens) > 0 {
		w.stack[len(opens) - 1].text_lo = at
	}
	return true
}

// Whether walk `w`, paused as `pause` says, stands at seam `at` in the state the walk of the part from it starts in:
// in content, with the elements `opens` open as `seam_frames` sets them.
@(private)
seam_proved :: proc "contextless" (w: ^Walk($H, $LAX), pause: ^Pause, opens: []Part_Open, at: u64) -> bool {
	if pause.place != .Content || pause.at != at || pause.depth != u64(len(opens)) || len(opens) == 0 {
		return false
	}
	for o, i in opens {
		f := w.stack[i]
		if f.tag != w.base[o.lo:] || f.tag_n != o.tag_n || f.flags != {.Object, .Prev} {
			return false
		}
	}
	return w.stack[len(opens) - 1].text_lo == at
}
