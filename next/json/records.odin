package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of a text read in one walk, whose gap table goes on from each record to the next, so that a record is
// read with the gaps the records before it taught. Each record is judged as a read of its bytes alone judges them, in
// place in the text.

// The records of a text of a JSON spec, which `records_open` makes and each call of `records_validate`,
// `records_find` or `records_scan` reads in batches, as `tape.Records` says.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	// What the walk learned, kept from record to record. A walk of any spec and hook is laid out as this one, or as its
	// front when it has no `LAX`.
	walk:          Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS),
	// In a text in pieces, the first byte of the window the gaps were last checked against, and where the framing
	// stopped at the last window's end: `open` once the record at `pos` has begun, its line end looked for up to `seen`.
	window:        u64,
	seen:          u64,
	open:          bool,
	entered:       bool, // the framing opened the container whose children are the records, and has not passed its close
	begun:         bool, // in a text in pieces, the byte order mark was judged
	nav:           Path_Nav,
	frame:         Piece_Frame,
}

// Where the framing around the records is: on the way down `path` to the container whose children are the records, or
// once the path or the records ended, on the way through what follows to the text's end.
@(private)
Path_Nav :: struct {
	open:    u32, // the containers of `path` open
	passed:  u32, // the children of the deepest one passed
	stage:   Nav_Stage,
	leaving: bool, // no child is taken any more
	// Where the step the framing is in started, and the steps of `Budget.steps` the walk had left there, which a text
	// in pieces judges a fault from.
	from:    u64,
	left:    u64,
}

// The step the framing takes next in the deepest open container, `open` containers deep: the value of the child it
// takes opened as a container, a child's key read under a `Name` step, a child's value passed, or the comma or close
// after a value. At depth 0 the value is the root, and what follows it is the text's tail.
@(private)
Nav_Stage :: enum u8 {
	Open,
	Child,
	Pass,
	Sep,
}

// The framing of a text in pieces under `.Elements` and `.Members` from window to window, which reads each byte once:
// the bytes before `seen` are framed, `depth` containers are open there, and `inside` says what the framing is
// inside of. `ahead` is set once it found the stop the framing's next step reads to, a byte of kind `kind`.
@(private)
Piece_Frame :: struct {
	seen:   u64,
	depth:  u64,
	gap:    u64, // the first byte of the comment the framing is in
	inside: Frame_In,
	quote:  u8,
	ahead:  bool,
	kind:   Frame_Stop,
}

@(private)
Frame_In :: enum u8 {
	Code,
	String,
	Escape,
	Slash, // past a `/` that may open a comment
	Line,
	Line_E2, // in a line comment past the first byte, or the first two, of U+2028 or U+2029
	Line_E280,
	Block,
	Block_Star,
}

@(private)
Frame_Stop :: enum u8 {
	Comma,
	Colon,
	Open,
	Close,
}

#assert(size_of(Walk(.Json5, build.Scanner, false, build.SCANNER_CAPS)) <= size_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS)))
#assert(offset_of(Walk(.Json5, build.Scanner, false, build.SCANNER_CAPS), gaps) == offset_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS), gaps))

// A record's walk reads at most this far past its line, so a value that runs on past its line is refused after a
// bounded read, while every block the walk reads within the line has its bytes ahead.
@(private)
RECORD_AHEAD :: 256

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. Under `.Elements` and
// `.Members` the records are those of the container `path` reaches, the root for none, as `tape.Records` says: the
// framing passes the members and elements before it, judging each, and those after it, and a text with no such
// container holds no records and ends them with the verdict `validate` gives for it. The budget's limits hold for each
// record, but `Budget.steps` under `.Elements` and `.Members`, which counts the containers of the whole text. The
// framing `.Concatenated`, which JSON has no reading of, options of another format family and a `path` the framing does
// not take end the records with `tape.Bad_Option` before any is read. A text in pieces opens with its first window, as
// `tape.Records` says. Under `.Elements` and `.Members` a window holds each value the framing passes whole, as it
// holds a record.
records_open :: proc(src: []u8, framing := tape.Framing.Lines, spec := Spec.Json, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("json: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.pos, r.path = src, framing, spec, opts, u64(spell.bom_length(src)), path
	if opts.pieces != nil {
		// The byte order mark is judged once the first record is framed, when the window may hold it.
		r.src, r.pos = tape.piece_src(src, opts.pieces.from), 0
	}
	if framing == .Concatenated {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	}
	if e := build.records_path_refused(framing, path); e != nil {
		r.err, r.at = e, .Done
	}
	if e := tape.options_refused(&FORMATS[spec], opts); e != nil {
		r.err, r.at = e, .Done
	}
	walk_init(&r.walk, src, nil, (^hook.No_Hooks)(nil), nil, {}, nil, build.read_depth(opts), opts.tolerate, opts.budget.steps)
	return
}

// Reads the next records of `r` into `out` and judges each, as `validate` judges its bytes alone. Returns how many it
// filled, and fewer than `len(out)` once the records have ended, when `err` says why, nil at the text's end. Only a
// record nesting past `WALK_LEVELS` allocates, for its open levels. Needs `READ_STACK` bytes of stack and faults on a
// thread with less.
@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Json:
		if lax {
			return records_validate_as(r, out, .Json, true, allocator)
		}
		return records_validate_as(r, out, .Json, false, allocator)
	case .Jsonc:
		if lax {
			return records_validate_as(r, out, .Jsonc, true, allocator)
		}
		return records_validate_as(r, out, .Jsonc, false, allocator)
	case .Json5:
		if lax {
			return records_validate_as(r, out, .Json5, true, allocator)
		}
		return records_validate_as(r, out, .Json5, false, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the first value `path` reaches in it into the same place of
// `answers`, as `find` reads its bytes alone, with every offset from the text's first byte. Returns how many it filled,
// at most the shorter of the two slices, and fewer once the records have ended. Under `.Elements` and `.Members` the
// walk reads each value to its end whatever `read.stop_early` says, as the next starts there. Allocates as `find` does.
// Needs `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Json:
		if lax {
			return records_find_as(r, path, out, answers, .Json, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Json, false, read, allocator)
	case .Jsonc:
		if lax {
			return records_find_as(r, path, out, answers, .Jsonc, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Jsonc, false, read, allocator)
	case .Json5:
		if lax {
			return records_find_as(r, path, out, answers, .Json5, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Json5, false, read, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the document of its nodes the paths of `demand` reach into the
// same place of `docs`, as `scan` reads its bytes alone. Returns how many it filled, at most the shorter of the two
// slices, and fewer once the records have ended. Each document's nodes point into the text, and the documents are in the
// records' block, valid until the next call or `tape.destroy_records`, as `tape.Record_Block` says, so the memory the
// records hold is bounded by the slices a call is given. Under `.Elements` and `.Members` the walk
// reads each value to its end whatever `read.stop_early` says, as the next starts there. Needs `READ_STACK` bytes of
// stack and faults on a thread with less.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Json:
		if lax {
			return records_scan_as(r, demand, out, docs, .Json, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Json, false, read, allocator)
	case .Jsonc:
		if lax {
			return records_scan_as(r, demand, out, docs, .Jsonc, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Jsonc, false, read, allocator)
	case .Json5:
		if lax {
			return records_scan_as(r, demand, out, docs, .Json5, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Json5, false, read, allocator)
	}
	return
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, hook.No_Hooks)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, build.Finder)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, build.finder_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, tape.number_respell, rewalk, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, build.Scanner)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, build.scanner_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, rewalk, node_bound, frame, walk)
}

// `record_frame` of the records `r` of a JSON spec, in the walk for hook `H`.
@(private)
record_frame_of :: #force_inline proc(r: ^tape.Records, $S: Spec, $LAX: bool, $H: typeid) -> (lo, cut: u64, ok: bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	j := container_of(r, Records, "records")
	return record_frame(j, (^Walk(S, H, LAX, C))(&j.walk))
}

// Walks the record from `lo` to `cut` for hook `h`, first in the walk of the whole text, or with `alone` as a text of
// its bytes alone.
@(private)
record_walked :: #force_inline proc(r: ^Records, $S: Spec, $LAX: bool, lo, cut: u64, alone: bool, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	w := (^Walk(S, H, LAX, C))(&r.walk)
	if alone {
		walked.res, walked.ok = record_alone(r, w, lo, cut, h, regs, allocator, ctx, on), true
	} else {
		walked.res, walked.hi, walked.again, walked.ok = record_first(r, w, lo, cut, h, regs, allocator, ctx, on)
	}
	walked.tolerated = w.tolerated
	return
}

// The next record's first byte, and under `.Lines` its line's end less a CR, under `.Elements` and `.Members` the text's
// end. Under `.Members` the key is read into `r.key` and the first byte is the value's. False once the records have
// ended, or in a text in pieces once the window holds no more. A fault in the text around the records' container's
// elements or members ends them with the fault `validate` gives for the text.
@(private)
record_frame :: proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C)) -> (lo, cut: u64, ok: bool) {
	if r.at == .Done {
		return
	}
	n := u64(len(r.src))
	when LAX {
		if r.opts.pieces != nil {
			if r.framing == .Lines {
				return record_frame_window(r, w)
			}
			if !piece_begin(r, (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w)) {
				return
			}
		}
	}
	if r.framing == .Lines {
		base := raw_data(r.src)
		lo = u64(intrinsics.ptr_sub(kernel.skip_ws(base[r.pos:], base[n:]), base))
		if lo == n {
			r.at = .Done
			return
		}
		cut = n
		if i := kernel.index_byte(r.src[lo:], '\n'); i >= 0 {
			cut = lo + u64(i)
		}
		r.pos = min(cut + 1, n)
		if r.src[cut - 1] == '\r' {
			cut -= 1
		}
		return lo, cut, true
	}
	for !r.entered {
		switch path_frame(r, (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w)) {
		case .Entered:
		case .Wait:
			return
		case .Ended:
			r.at = .Done
			return
		case .Fault:
			frame_refuse(r, nil)
			return
		}
	}
	when LAX {
		if r.opts.pieces != nil && !record_framed(r, S) {
			return
		}
	}
	r.nav.from = r.pos
	when LAX {
		r.nav.left = w.steps[0]
	}
	at, next := element_next(r, w)
	switch next {
	case .Element:
		if r.framing == .Members {
			if at = record_key(r, w, at); at == 0 {
				frame_refuse(r, nil)
				return
			}
		}
		return at, n, true
	case .End:
		// What follows the records' container is framed as what follows a value passed in the container holding it.
		r.entered, r.frame.ahead = false, false
		r.nav = {open = u32(len(r.path)), passed = 1, stage = .Sep, leaving = true}
		return record_frame(r, w)
	case .Fault:
		frame_refuse(r, nil)
	}
	return
}

// Takes the framing's next steps around the records, as `Path_Nav` says, until it opens the records' container or the
// text ends: down `r.path`, taking at each container the first member of the key or the element of the place its step
// names, and once the path takes no more, through each value to the text's end. Each value passed is judged alone, as
// the walk of the whole text judges it. A container the path names that the text lacks leaves the records with none,
// and the text judged to its end. In a text in pieces a step whose bytes the window lacks waits for the next window.
@(private)
path_frame :: proc(r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS)) -> Nav_Result #no_bounds_check {
	base := raw_data(r.src)
	end := base[len(r.src):]
	nv := &r.nav
	for {
		k := u64(nv.open)
		nv.from = r.pos
		when LAX {
			nv.left = w.steps[0]
		}
		object := nav_object(r, k)
		switch nv.stage {
		case .Open:
			if !framed(r, k, false, true, S) {
				return .Wait
			}
			q := element_gap(base[r.pos:], end, S)
			if q == nil || q == end {
				return .Fault
			}
			if k > 0 && (q[0] == ']' || q[0] == '}') {
				if !nav_close(r, q, base, object, S) {
					return .Fault
				}
				continue
			}
			takes_object := nav_object(r, k + 1)
			if q[0] != ('{' if takes_object else '[') {
				nv.leaving, nv.stage = true, .Pass
				continue
			}
			if k + 1 > build.read_depth(r.opts) {
				return .Fault
			}
			when LAX {
				w.steps[0] -= 1
				if w.steps[0] == 0 {
					return .Fault
				}
			}
			r.frame.ahead = false
			r.pos = u64(intrinsics.ptr_sub(q, base)) + 1
			nv.open, nv.passed = nv.open + 1, 0
			if k == u64(len(r.path)) {
				r.entered, r.at = true, .Open
				return .Entered
			}
			nv.stage = .Child
		case .Child:
			if !object {
				nv.stage = .Pass
				if !nv.leaving && i64(nv.passed) == i64(r.path[k - 1].(tape.Index)) {
					nv.stage = .Open
				}
				continue
			}
			if !framed(r, k, true, false, S) {
				return .Wait
			}
			q := element_gap(base[r.pos:], end, S)
			if q == nil || q == end {
				return .Fault
			}
			if q[0] == ']' || q[0] == '}' {
				if !nav_close(r, q, base, object, S) {
					return .Fault
				}
				continue
			}
			at := member_colon(r, w, u64(intrinsics.ptr_sub(q, base)))
			if at == 0 {
				return .Fault
			}
			r.frame.ahead, r.pos = false, at
			nv.stage = .Pass
			if !nv.leaving && tape.key_names(&FORMATS[S], r.src, r.key, string(r.path[k - 1].(tape.Name))) {
				nv.stage = .Open
			}
			r.key = {}
		case .Pass:
			if r.frame.ahead && r.frame.kind == .Open {
				// The value is a container, which the framing goes on into.
				r.frame.ahead = false
			}
			if !framed(r, k, false, false, S) {
				return .Wait
			}
			q := element_gap(base[r.pos:], end, S)
			if q == nil || q == end {
				return .Fault
			}
			if k > 0 && !object && (q[0] == ']' || q[0] == '}') {
				if !nav_close(r, q, base, object, S) {
					return .Fault
				}
				continue
			}
			hi, passed := path_pass(r, w, u64(intrinsics.ptr_sub(q, base)), k)
			if !passed {
				return .Fault
			}
			r.pos, nv.passed, nv.stage = hi, nv.passed + 1, .Sep
		case .Sep:
			if k == 0 {
				return nav_tail(r, S)
			}
			if !framed(r, k, false, false, S) {
				return .Wait
			}
			q := element_gap(base[r.pos:], end, S)
			if q == nil || q == end {
				return .Fault
			}
			if q[0] != ',' {
				if !nav_close(r, q, base, object, S) {
					return .Fault
				}
				continue
			}
			r.frame.ahead, r.pos, nv.stage = false, u64(intrinsics.ptr_sub(q, base)) + 1, .Child
		}
	}
}

@(private)
Nav_Result :: enum u8 {
	Entered, // the records' container is open
	Wait,
	Ended,
	Fault,
}

// Whether the container `k` levels deep is an object: one a `Name` step takes a member of, or past the path the
// records' container under `.Members`.
@(private)
nav_object :: #force_inline proc "contextless" (r: ^Records, k: u64) -> bool {
	if k == 0 {
		return false
	}
	if k <= u64(len(r.path)) {
		_, object := r.path[k - 1].(tape.Name)
		return object
	}
	return r.framing == .Members
}

// Closes the deepest open container at its close bracket at `q`, where a child or a comma may end it, after which the
// framing passes what follows it in the container holding it. `.Fault` for a bracket of the other kind, and in JSON for
// a close past a comma.
@(private)
nav_close :: proc "contextless" (r: ^Records, q, base: [^]u8, object: bool, $S: Spec) -> bool {
	nv := &r.nav
	if q[0] != ('}' if object else ']') || object && nv.stage == .Open || S == .Json && nv.stage != .Sep && nv.passed > 0 {
		return false
	}
	r.frame.ahead, r.pos = false, u64(intrinsics.ptr_sub(q, base)) + 1
	nv.open, nv.passed, nv.stage, nv.leaving = nv.open - 1, 1, .Sep, true
	return true
}

// Frames the text's tail past its root: white space and comments to its end. In a text in pieces whose window is not
// the last, the tail up to the window's end, or to the comment the window's end cuts, is judged and dropped.
@(private)
nav_tail :: proc "contextless" (r: ^Records, $S: Spec) -> Nav_Result {
	base := raw_data(r.src)
	n := u64(len(r.src))
	if p := r.opts.pieces; p != nil && !p.last {
		upto := n
		if !frame_stop(r, 0, false, true, S) && r.frame.inside != .Code && r.frame.inside != .String && r.frame.inside != .Escape {
			upto = r.frame.gap
		}
		if element_gap(base[r.pos:], base[upto:], S) != base[upto:] {
			return .Fault
		}
		r.pos = upto
		return .Wait
	}
	return .Ended if element_gap(base[r.pos:], base[n:], S) == base[n:] else .Fault
}

// Judges the value at `lo` alone, inside `depth` containers, as the walk of the whole text judges it, and returns where
// it ends. False for a fault.
@(private)
path_pass :: proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo, depth: u64) -> (hi: u64, ok: bool) {
	plain := (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w)
	none: hook.No_Hooks
	regs: hook.Regs
	ctx := context
	res := record_walk(r, plain, lo, raw_data(r.src)[len(r.src):], build.read_depth(r.opts) - depth, &none, &regs, context.allocator, &ctx, false, hook.no_hook)
	if u8(res) != 0 {
		return 0, false
	}
	return u64(res) >> 16, true
}

// In a text in pieces under `.Elements` and `.Members`, readies the framing for the window: the walk's gap table drops
// what the last window held, and the byte order mark is judged once the window holds enough of it. False while it
// does not.
@(private)
piece_begin :: proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS)) -> bool {
	p := r.opts.pieces
	if p.from != r.window {
		gaps_drop(&w.gaps, p.from)
		r.window = p.from
	}
	if !r.begun {
		if !p.last && piece_bom_open(r.src) {
			return false
		}
		r.pos = u64(spell.bom_length(r.src))
		r.frame.seen, r.begun, r.at = r.pos, true, .Open
	}
	return true
}

// Whether the window holds the next record of a text in pieces with what follows it up to the comma or close after it.
// The stop the last record's framing found is past its comma, unless it is the close, which the records end at.
@(private)
record_framed :: proc "contextless" (r: ^Records, $S: Spec) -> bool {
	if r.at == .After && r.frame.ahead {
		if r.frame.kind == .Close {
			return true
		}
		r.frame.ahead = false
	}
	return framed(r, u64(len(r.path)) + 1, false, false, S)
}

// Whether the window of a text in pieces holds the bytes the framing's next step reads, up to the next stop at most
// `level` containers deep: a comma, with `colon` a colon, with `open` an open bracket, or a close. Always for a whole
// text and for the last window.
@(private)
framed :: #force_inline proc "contextless" (r: ^Records, level: u64, colon, open: bool, $S: Spec) -> bool {
	p := r.opts.pieces
	return p == nil || r.frame.ahead || frame_stop(r, level, colon, open, S) || p.last
}

// Frames the bytes from `r.frame.seen` to the next stop at most `level` containers deep, as `framed` names them. True
// with `r.frame.ahead` set and `seen` past it, false at the window's end, where the framing goes on in the next window.
@(private)
frame_stop :: proc "contextless" (r: ^Records, level: u64, colon, open: bool, $S: Spec) -> bool #no_bounds_check {
	f := &r.frame
	n := u64(len(r.src))
	for i := f.seen; i < n; i += 1 {
		c := r.src[i]
		switch f.inside {
		case .Code:
			stop := Frame_Stop.Comma
			switch c {
			case '"':
				f.inside, f.quote = .String, c
				continue
			case '\'':
				when S == .Json5 {
					f.inside, f.quote = .String, c
				}
				continue
			case '/':
				when S != .Json {
					f.inside, f.gap = .Slash, i
				}
				continue
			case '[', '{':
				f.depth += 1
				if !open || f.depth > level + 1 {
					continue
				}
				stop = .Open
			case ']', '}':
				d := f.depth
				f.depth = max(d, 1) - 1
				if d > level {
					continue
				}
				stop = .Close
			case ',':
				if f.depth > level {
					continue
				}
			case ':':
				if !colon || f.depth > level {
					continue
				}
				stop = .Colon
			case:
				continue
			}
			f.seen, f.ahead, f.kind = i + 1, true, stop
			return true
		case .String:
			if c == '\\' {
				f.inside = .Escape
			} else if c == f.quote {
				f.inside = .Code
			}
		case .Escape:
			f.inside = .String
		case .Slash:
			switch c {
			case '/':
				f.inside = .Line
			case '*':
				f.inside = .Block
			case:
				f.inside = .Code
				i -= 1
			}
		case .Line:
			if c == '\n' || c == '\r' {
				f.inside = .Code
			} else if S == .Json5 && c == 0xE2 {
				f.inside = .Line_E2
			}
		case .Line_E2:
			f.inside = .Line_E280 if c == 0x80 else .Line
			if c != 0x80 {
				i -= 1
			}
		case .Line_E280:
			f.inside = .Code if c == 0xA8 || c == 0xA9 else .Line
			if c != 0xA8 && c != 0xA9 {
				i -= 1
			}
		case .Block:
			if c == '*' {
				f.inside = .Block_Star
			}
		case .Block_Star:
			f.inside = .Code if c == '/' else .Block if c != '*' else .Block_Star
		}
	}
	f.seen = n
	return false
}

// Ends the records with the error `validate` gives for the text, or `err` when it gives none. In a text in pieces,
// whose bytes before the window are gone, it is the error `validate` gives for a text of the bytes from where the
// framing's step started, behind brackets and placeholder members that open the containers around them as they are
// open there, with the steps of `Budget.steps` the walk had left.
@(private, cold)
frame_refuse :: proc(r: ^Records, err: tape.Error) {
	if r.opts.pieces == nil {
		records_refuse(r, err)
		return
	}
	nv := &r.nav
	k := u64(nv.open)
	text := make([dynamic]u8)
	defer delete(text)
	for j in 1 ..= k {
		object := nav_object(r, j)
		append(&text, '{' if object else '[')
		if j < k && object {
			append(&text, `"":`)
		}
	}
	object := nav_object(r, k)
	// A placeholder value ends at a space, so that no byte after it reads as part of it.
	member := `"":0 ` if object else "0 "
	if r.entered {
		if r.at == .After {
			append(&text, member)
		}
	} else {
		switch nv.stage {
		case .Open, .Pass:
			if k > 0 && object {
				append(&text, `"":`)
			} else if k > 0 && nv.passed > 0 {
				append(&text, "0,")
			}
		case .Child:
			if nv.passed > 0 {
				append(&text, member)
				append(&text, ",")
			}
		case .Sep:
			append(&text, member)
		}
	}
	by := i64(nv.from) - i64(len(text))
	append(&text, ..r.src[nv.from:])
	opts := r.opts
	opts.pieces = nil
	if opts.budget.steps != 0 && nv.left != max(u64) {
		// The walk starts with one step past the budget, and each bracket before the bytes takes one.
		opts.budget.steps = nv.left - 1 + k
	}
	r.err, r.at = validate(text[:], r.spec, opts), .Done
	#partial switch &e in r.err {
	case tape.Fault:
		e.at = u64(i64(e.at) + by)
	case tape.Exceeded:
		if e.kind != .Memory {
			e.at = u64(i64(e.at) + by)
		}
	case nil:
		r.err = err
	}
}

// `record_frame` under `.Lines` in a text in pieces: a record whose line end the window does not hold ends the batch,
// and its framing goes on in the next window where this one stopped. The record's walk reads up to its window's end, at
// most `RECORD_AHEAD` bytes past its line, where a walk of the whole text reads that far, which judges the record alike,
// as a walk that reads past the line walks the record again alone.
@(private)
record_frame_window :: proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C)) -> (lo, cut: u64, ok: bool) {
	p := r.opts.pieces
	n := u64(len(r.src))
	more := !p.last
	if p.from != r.window {
		gaps_drop(&w.gaps, p.from)
		r.window = p.from
	}
	if r.at == .Start {
		if more && piece_bom_open(r.src) {
			return
		}
		r.pos, r.at = u64(spell.bom_length(r.src)), .Open
	}
	if !r.open {
		base := raw_data(r.src)
		r.pos = u64(intrinsics.ptr_sub(kernel.skip_ws(base[r.pos:], base[n:]), base))
		if r.pos == n {
			if !more {
				r.at = .Done
			}
			return
		}
		r.open, r.seen = true, r.pos
	}
	cut = n
	if i := kernel.index_byte(r.src[r.seen:], '\n'); i >= 0 {
		cut = r.seen + u64(i)
	} else if more {
		r.seen = n
		return
	}
	lo = r.pos
	r.open, r.pos = false, min(cut + 1, n)
	if r.src[cut - 1] == '\r' {
		cut -= 1
	}
	return lo, cut, true
}

@(private)
Element_Next :: enum u8 {
	Element,
	End,
	Fault,
}

// Where the next element of the records' container starts, or under `.Members` its next member's key, past the open
// bracket or the comma before it, or whether the container ends there, leaving `r.pos` past its close, or holds
// something else.
@(private)
element_next :: proc "contextless" (r: ^Records, w: ^Walk($S, $H, $LAX, $C)) -> (at: u64, next: Element_Next) #no_bounds_check {
	base := raw_data(r.src)
	end := base[len(r.src):]
	close := u8('}') if r.framing == .Members else ']'
	q := element_gap(base[r.pos:], end, S)
	if q == nil || q == end {
		return 0, .Fault
	}
	if r.at == .After && q[0] != close {
		if q[0] != ',' {
			return 0, .Fault
		}
		if q = element_gap(q[1:], end, S); q == nil || q == end {
			return 0, .Fault
		}
		if S == .Json && q[0] == close {
			return 0, .Fault
		}
	}
	if q[0] == close {
		r.pos = u64(intrinsics.ptr_sub(q, base)) + 1
		return 0, .End
	}
	return u64(intrinsics.ptr_sub(q, base)), .Element
}

// The first byte past the white space and comments from `p`, nil at a comment that does not end.
@(private)
element_gap :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> [^]u8 {
	when S == .Json {
		return kernel.skip_ws(p, end)
	} else {
		q, _, kind := comment_run(p, end, false, S)
		return q if kind == .None else nil
	}
}

// Ends the records with the error `validate` gives for the text, or `err` when it gives none.
@(private, cold)
records_refuse :: proc(r: ^Records, err: tape.Error) {
	r.err = validate(r.src, r.spec, r.opts)
	if r.err == nil {
		r.err = err
	}
	r.at = .Done
}

// Walks the record that `record_frame` framed from `lo` to `cut` for hook `h` from registers `regs`, and returns the
// walk's result, the record's end, and under `.Lines` whether the record must be walked again alone, which the walk
// in the whole text reads as no walk of its line would. False once the records have ended, as under `.Elements` a
// fault in an element ends them.
@(private)
record_first :: #force_inline proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo, cut: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (res: hook.Walk_Result, hi: u64, alone, ok: bool) {
	base := raw_data(r.src)
	n := u64(len(r.src))
	if r.framing == .Lines {
		res = record_walk(r, w, lo, base[min(n, cut + RECORD_AHEAD):], build.read_depth(r.opts), h, regs, allocator, ctx, false, on)
		return res, cut, !line_read(r.src, res, cut), true
	}
	when LAX {
		left := w.steps[0]
	}
	depth := build.read_depth(r.opts) - 1 - u64(len(r.path))
	res = record_walk(r, w, lo, base[n:], depth, h, regs, allocator, ctx, false, on)
	if u8(res) == hook.WALK_STOPPED {
		// The hook refused the value, which leaves the walk short of its end, so a walk with no hook finds it.
		// The refusal is the record's error, as it is for a line.
		when LAX {
			w.steps[0] = left
		}
		plain := (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w)
		none: hook.No_Hooks
		none_regs: hook.Regs
		end := record_walk(r, plain, lo, base[n:], depth, &none, &none_regs, allocator, ctx, false, hook.no_hook)
		if u8(end) != 0 {
			_, err, _ := hook.walk_error(end, &RULES)
			frame_refuse(r, err)
			return
		}
		hi = u64(end) >> 16
		r.pos, r.at = hi, .After
		return res, hi, false, true
	}
	if u8(res) != 0 {
		_, err, _ := hook.walk_error(res, &RULES)
		frame_refuse(r, err)
		return
	}
	hi = u64(res) >> 16
	r.pos, r.at = hi, .After
	return res, hi, false, true
}

// The hook of the walk that reads a member's key, which keeps the key and stops the walk.
@(private)
Member_Key :: struct {
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
	key:      tape.Token,
}

#assert(size_of(Walk(.Json5, Member_Key, true, hook.NO_HOOKS_CAPS)) == size_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS)))
#assert(offset_of(Walk(.Json5, Member_Key, true, hook.NO_HOOKS_CAPS), gaps) == offset_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS), gaps))

@(private)
member_key_hook :: proc "contextless" (h: ^Member_Key, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.key = t
	return s, .Stop
}

// The level of the root object, as the walk's states name a container: its depth and its kind bit.
@(private)
MEMBER_LEVEL :: u64(1 << 1 | 1)

// Reads the key of the member at `at` into `r.key` with the walk's own key states, and returns where its value starts,
// past the colon and the gaps around it, or 0 when the key, the colon or the text fails.
@(private)
record_key :: proc "contextless" (r: ^Records, w: ^Walk($S, $H, $LAX, $C), at: u64) -> u64 {
	base := raw_data(r.src)
	end := base[len(r.src):]
	colon := member_colon(r, w, at)
	if colon == 0 {
		return 0
	}
	q := element_gap(base[colon:], end, S)
	if q == nil || q == end {
		return 0
	}
	return u64(intrinsics.ptr_sub(q, base))
}

// Reads the key of the member at `at` into `r.key`, as `record_key` does, and returns the offset past its colon, or 0
// when the key, the colon or the text fails.
@(private)
member_colon :: proc "contextless" (r: ^Records, w: ^Walk($S, $H, $LAX, $C), at: u64) -> u64 {
	base := raw_data(r.src)
	end := base[len(r.src):]
	h: Member_Key
	regs: hook.Regs
	res := key_walk(r, (^Walk(S, Member_Key, LAX, hook.NO_HOOKS_CAPS))(w), at, &h, &regs)
	if u8(res) != hook.WALK_STOPPED {
		return 0
	}
	q := element_gap(base[u64(res) >> 16:], end, S)
	if q == nil || q == end || q[0] != ':' {
		return 0
	}
	r.key = h.key
	return u64(intrinsics.ptr_sub(q, base)) + 1
}

// Walks the key of the member at `at` for hook `h`, which stops on it, and returns the walk's result.
@(private)
key_walk :: proc "contextless" (r: ^Records, w: ^Walk($S, Member_Key, $LAX, $C), at: u64, h: ^Member_Key, regs: ^hook.Regs) -> hook.Walk_Result {
	stack: [2]u32
	when LAX {
		left := w.steps[0]
	}
	walk_start(w, r.src, raw_data(stack[:]), h, regs, {}, nil, build.read_depth(r.opts), r.opts.tolerate, r.opts.budget.steps)
	when LAX {
		w.piece[0] = nil
		w.steps[0] = left
	}
	w.depth = min(w.limit, WALK_LEVELS)
	res := enter_member(raw_data(r.src)[at:], raw_data(r.src)[len(r.src):], MEMBER_LEVEL, INDENT_START, w, regs^, GAP_OFF, member_key_hook)
	w.hooks, w.regs, w.ctx, w.stack, w.allocator = nil, nil, nil, nil, {}
	return res
}

// Walks the record from `lo` to `cut` as a text of those bytes alone, and returns the walk's result.
@(private, cold)
record_alone :: #force_no_inline proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo, cut: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	return record_walk(r, w, lo, raw_data(r.src)[cut:], build.read_depth(r.opts), h, regs, allocator, ctx, true, on)
}

// Whether the walk in the whole text with result `res` read the record that ends at `cut` as a walk of its bytes alone
// reads them: its value ended, or the hook stopped the walk, within them, and only white space follows the value.
@(private)
line_read :: #force_inline proc "contextless" (src: []u8, res: hook.Walk_Result, cut: u64) -> bool #no_bounds_check {
	hi := u64(res) >> 16
	if hi > cut {
		return false
	}
	switch u8(res) {
	case 0:
		for c in src[hi:cut] {
			if c != ' ' && c != '\t' && c != '\r' {
				return false
			}
		}
		return true
	case hook.WALK_STOPPED:
		return true
	}
	return false
}

// Walks the value at `lo` to `end` for hook `h` from registers `regs`, in the walk of `r` with its gap table, within
// `limit` levels. With `TAIL` what follows the value up to `end` is judged as a text's tail.
@(private)
record_walk :: #force_inline proc "contextless" (r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo: u64, end: [^]u8, limit: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $TAIL: bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	stack: [WALK_LEVELS]u32 = ---
	when LAX {
		left := w.steps[0]
	}
	walk_start(w, r.src, raw_data(stack[:]), h, regs, allocator, ctx, limit, r.opts.tolerate, r.opts.budget.steps)
	when LAX {
		w.piece[0] = nil
		if r.framing != .Lines {
			w.steps[0] = left
		}
	}
	w.depth = hook.held_depth(h, regs, min(w.limit, WALK_LEVELS))
	when .Walk in C {
		h.walk = w
	}
	res := enter(raw_data(r.src)[lo:], end, INDENT_START, w, regs^, GAP_START, on)
	when TAIL {
		res = walk_tail(w, res, end, on)
	}
	when .Walk in C {
		h.walk = nil
	}
	when LAX {
		if u8(res) == hook.WALK_STOPPED && w.steps[0] == 0 {
			res = hook.walk_result(u64(res) >> 16, hook.WALK_STEPS)
		}
	}
	if w.owned {
		hook.levels_free(w)
	}
	// The records keep the walk past the call, and none of the caller's frame.
	w.hooks, w.regs, w.ctx, w.stack, w.allocator = nil, nil, nil, nil, {}
	return res
}
