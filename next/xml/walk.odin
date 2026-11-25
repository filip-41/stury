package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// XML's walk: each grammar state is a procedure that tail-calls the next with `#must_tail`. A state reads the first
// byte of its construct and branches on it. Runs of characters (text.odin), names (name.odin) and the prolog and
// epilog (framing.odin) are read by leaf procedures.

// The kernel tier the states are built for, the lowest: `V2` on x86-64, `Base` elsewhere.
@(private)
STATE_TIER :: kernel.Tier(0)

@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// Stack headroom probed on each XML read entry (frames: 512 * 24 B = 12 KiB, plus builder/scanner stack frames).
READ_STACK :: 48 * 1024

// Open elements a read keeps in its frame. A deeper text moves them to memory from the read's allocator, so a
// `validate` within this depth allocates nothing past what a DTD or a namespace declaration needs.
@(private)
WALK_LEVELS :: 512

// The most frames a walk holds, whose bytes an `int` counts.
@(private)
MAX_LEVELS :: u64(max(int) / size_of(Frame))

// An open element. `tag` is its start tag's `<`, and its name follows it. `text_lo` is where the text run that has not
// been given yet starts: past the start tag, or past the child that last closed.
@(private)
Frame :: struct {
	tag:     [^]u8,
	text_lo: u64,
	tag_n:   u32,
	name_n:  u16,
	flags:   Frame_Flags,
}

@(private)
Frame_Flag :: enum u8 {
	Object, // the element's `Object` token is given: it has a child element
	Seen, // the run holds a character that is no markup whitespace, so it is text
	Decode, // the run holds a reference, CDATA, a comment, a processing instruction or a CR
	Prev, // a child element or text member ended before this point
	Held, // a comment or instruction stands before the first child, and the next child or the end tag gives its role
	Chars, // the run holds a character, white space included, so its text is not empty
	Dtd, // the run refers to an entity the DTD declares, which its decode reads the DTD for
}

@(private)
Frame_Flags :: bit_set[Frame_Flag; u16]

#assert(size_of(Frame) == 24)

// The attribute names of a tag that `attr_repeats` compares without a table.
@(private)
ATTR_SLOTS :: 16

@(private)
Name_Ref :: struct {
	p: [^]u8,
	n: u64,
}

// The allocator a walk takes memory from past its frame, the read's or a decode's, and the context its calls run in,
// the default context for a nil `ctx`. An allocator with no procedure refuses every block.
@(private)
Grab :: struct {
	allocator: runtime.Allocator,
	ctx:       ^runtime.Context,
}

// `size` bytes from `g`, zeroed when `zero`, nil when memory is refused.
@(private, cold)
grab :: proc "contextless" (g: Grab, size: int, zero := false) -> rawptr {
	context = g.ctx^ if g.ctx != nil else runtime.default_context()
	if g.allocator.procedure == nil {
		return nil
	}
	b: []u8
	err: runtime.Allocator_Error
	if zero {
		b, err = runtime.mem_alloc(size, 16, g.allocator)
	} else {
		b, err = runtime.mem_alloc_non_zeroed(size, 16, g.allocator)
	}
	return raw_data(b) if err == nil else nil
}

// The block `p` of `old` bytes from `g` moved to one of `size`, nil when memory is refused, which leaves `p` as it was.
@(private, cold)
regrab :: proc "contextless" (g: Grab, p: rawptr, old, size: int) -> rawptr {
	context = g.ctx^ if g.ctx != nil else runtime.default_context()
	if g.allocator.procedure == nil {
		return nil
	}
	b, err := runtime.non_zero_mem_resize(p, old, size, 16, g.allocator)
	return raw_data(b) if err == nil else nil
}

// Frees the block `p` of `size` bytes from `g`. A nil `p` or a `size` of 0 is no block, as `grab` gives none.
@(private, cold)
ungrab :: proc "contextless" (g: Grab, p: rawptr, size: int) {
	if p == nil || size == 0 {
		return
	}
	context = g.ctx^ if g.ctx != nil else runtime.default_context()
	runtime.mem_free_with_size(p, size, g.allocator)
}

// The state a walk carries besides its registers. A walk with `LAX` counts `Budget.steps`, which one without never
// does. `stack[i]` is the frame of the element with `i` open elements around it, and `depth` frames are held, so no
// frame is read before it is written. Its levels are those `hook.deepen` grows.
@(private)
Walk :: struct($H: typeid, $LAX: bool) {
	base:       [^]u8,
	hooks:      ^H,
	stack:      [^]Frame,
	regs:       ^hook.Regs, // the hook's registers where the walk ended
	// With `LAX`, where a walk that goes on later pauses (pieces and member records), nil for a walk that never does.
	pause:      ^Pause,
	// The address one past the hook's room for nodes, for a hook with `.Rooms`.
	rooms:      uintptr,
	depth:      u64, // frames `stack` and the hook hold
	room:       u64, // frames `stack` holds
	limit:      u64, // `Budget.depth`
	opened:     u64, // the hook's open containers when the walk started
	// With `.Skips`, the open count of the element whose `Object` a `Skip` hid, 0 for none. While it is set no token
	// reaches the hook. The document's is the most a `u64` holds, as is any after `Rest`.
	mute:       u64,
	// With `.Skips`, the hook skipped the member whose key it was given last, so the walk gives the facts before its
	// value and not the value.
	skip_value: bool,
	// With `.Skips`, the element `mute` names is the value of a member skipped at its key, so its `End` is not given.
	mute_end:   bool,
	// With `.Keeps`, the open count of the element whose `Object` the hook keeps through its inner hook, 0 for none.
	keep:       u64,
	// One more than the containers the walk may still open within `Budget.steps`, 0 once it opened one past it.
	steps:      u64,
	// The names of the tag being read, in `names` up to `ATTR_SLOTS` and then in the `table` out of line.
	names:      [ATTR_SLOTS]Name_Ref,
	table:      [^]Name_Ref,
	table_cap:  u64, // the names `table` has room for
	nattr:      u64,
	// The namespace declarations in scope: `ns[:ns_len]` in open order, from the walk's allocator and freed with it.
	ns:         [^]Ns_Entry,
	ns_len:     u32,
	ns_cap:     u32,
	// The DTD the text declares, nil for none, and the run `st_halt` acts on.
	dtd:        ^Dtd,
	halt:       Run,
	expansion:  u64, // `Budget.expansion`
	allocator:  runtime.Allocator, // what `stack` grows in past the frame's levels
	ctx:        ^runtime.Context, // the caller's, for the calls of `allocator`
	tier:       kernel.Tier,
	// Whether the tag being read has a name with a colon or a declaration, so its names are judged at its end.
	tag_ns:     bool,
	// Whether the DTD declares attribute defaults, so each tag is checked for them at its end.
	tag_dtd:    bool,
	// Whether the DTD declares an attribute of a type other than `CDATA`, so each attribute's reader reads the DTD.
	attr_dtd:   bool,
	owned:      bool, // `stack` is the allocator's
	unread:     bool, // `.Unread_Entity` is tolerated
	infer:      bool, // `Xml_Options.infer`
	keep_stubs: bool, // the keep is `Keep_Stubs`
	tolerated:  bool, // the walk read a reference to an entity whose text is not read
	// The walk reads the prolog only, to the DTD, as the decode of a node of no document does.
	dtd_only:   bool,
}


// The result of walking the document of `src` from `lo` for hook `h` from its registers `regs`, within `limit` element levels and
// the count `steps` of containers, with the walk's frames in `allocator` past its own, called in context `ctx`, and
// whether it read a reference to an entity whose text is not read. A hook with `.Walk` is given the walk. Its offset is
// where the text ends, unless the walk stopped or faulted.
@(private)
walk_document :: #force_inline proc "contextless" (src: []u8, lo: u64, $LAX: bool, opts: tape.Options, limit, steps: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (hook.Walk_Result, bool) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	// `= ---` leaves the array unwritten. Every frame is written before it is read.
	stack: [WALK_LEVELS]Frame = ---
	w: Walk(H, LAX)
	walk_init(&w, opts, limit, steps, raw_data(stack[:]))
	walk_bind(&w, raw_data(src), h, regs, ctx)
	w.opened, w.allocator = regs.c, allocator
	w.depth = hook.held_depth(h, regs, min(w.limit, WALK_LEVELS))
	when .Walk in C {
		h.walk = &w
	}
	r := prolog(&w, src, lo, regs.a, regs.b, regs.c, on)
	when .Walk in C {
		h.walk = nil
	}
	return hook.steps_result(hook.Walk_Result(walk_end(&w, r)), w.steps), w.tolerated
}

// Readies walk `w` for a text read under `opts`, to `limit` levels and with `steps` as `steps_of` counts them, its
// levels in `stack` while its frame holds them. The calls that read the text bind it.
@(private)
walk_init :: proc "contextless" (w: ^Walk($H, $LAX), opts: tape.Options, limit, steps: u64, stack: [^]Frame = nil) {
	x, _ := opts.format.(tape.Xml_Options)
	w^ = {
		stack     = stack,
		room      = WALK_LEVELS,
		limit     = min(limit, MAX_LEVELS),
		steps     = steps,
		expansion = opts.budget.expansion,
		tier      = kernel.tier(),
		unread    = .Unread_Entity in opts.tolerate,
		infer     = x.infer,
	}
}

// Gives walk `w`, kept past the call that reads it, what that call lends it: the text's base, the hook with its
// registers, and the context its allocator is called in. The call takes them back before it returns.
@(private)
walk_bind :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), base: [^]u8, h: ^H, regs: ^hook.Regs, ctx: ^runtime.Context) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	w.base, w.hooks, w.regs, w.ctx = base, h, regs, ctx
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
}

// Frees what walk `w` holds and returns its result `r`, the fault of a reference whose replacement text the text ends
// inside for a text that ends there.
@(private)
walk_end :: proc "contextless" (w: ^Walk($H, $LAX), r: u64) -> u64 {
	r := r
	if w.dtd != nil {
		w.tolerated = w.dtd.took
		r = dtd_end(w, r)
	}
	if w.owned {
		hook.levels_free(w)
	}
	table_free(w)
	if w.ns != nil {
		ns_release(w, w.ns[:w.ns_len])
		ungrab(walk_grab(w), w.ns, int(w.ns_cap) * size_of(Ns_Entry))
	}
	return r
}

// The allocator walk `w` takes memory from past its frame.
@(private)
walk_grab :: #force_inline proc "contextless" (w: ^Walk($H, $LAX)) -> Grab {
	return {w.allocator, w.ctx}
}

// Frees the table of a tag's attribute names, nil for none.
@(private, cold)
table_free :: proc "contextless" (w: ^Walk($H, $LAX)) {
	ungrab(walk_grab(w), w.table, int(w.table_cap) * size_of(Name_Ref))
	w.table, w.table_cap = nil, 0
}

// The open count of the document's `Object`. A `Rest` mutes the walk for the most a `u64` holds, which no `End` ends.
@(private)
DOCUMENT :: max(u64) - 1

// What `emit` reports: the walk goes on, the hook stopped it, or the token is wider than `Token.n` holds.
@(private)
Emitted :: enum u8 {
	Next,
	Stop,
	Wide,
}

// Gives the hook the token of `n` bytes at `lo`, growing the hook's room first for a node it has no place for. The
// walk takes a step of `Budget.steps` per container and stops at the first past it. `open` is the open count of the
// element whose `Object` this is, which a `Skip` or a keep of it lasts to, and `DOCUMENT` for the document's.
@(private)
emit :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, kind: tape.Kind, role: tape.Role, lo: u64, n: int, spelling: u16 = 0, open: u64 = 0) -> Emitted {
	when LAX {
		if kind == .Object {
			w.steps -= 1
			if w.steps == 0 {
				return .Stop
			}
		}
	}
	when H == hook.No_Hooks {
		return .Next
	} else {
		C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
		when .Skips in C {
			if w.mute != 0 {
				return .Next
			}
			if w.skip_value && role == .Value && kind != .End {
				w.skip_value = false
				if kind == .Object {
					w.mute, w.mute_end = open, true
				}
				return .Next
			}
		}
		if u64(n) > u64(max(u32)) {
			return .Wide
		}
		t := tape.Token{lo, u32(n), kind, role, spelling}
		when .Keeps in C {
			if w.keep != 0 {
				return emit_kept(w, hs, t)
			}
		}
		when .Rooms in C {
			if kind != .End && role <= .Key && uintptr(hs.a) == w.rooms && !grow_room(w, hs, lo) {
				return .Stop
			}
		}
		a: hook.Action
		hs^, a = on(w.hooks, hs^, t)
		if a == .Next {
			return .Next
		}
		// A hook that passes members at their keys does so at most keys, so the skip stays in line.
		when .Skips in C {
			if role == .Key && a == .Skip {
				w.skip_value = true
				return .Next
			}
		}
		return answered(w, hs, a, t, open)
	}
}

// Answers the action `a` other than `Next` the hook gave token `t`: a stop, or for the `Object` of the element with
// `open` open elements a skip, the rest of the text with no hook, or a keep through the inner hook, which is given `t`.
@(private, cold)
answered :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), hs: ^hook.Regs, a: hook.Action, t: tape.Token, open: u64) -> Emitted {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	when .Skips in C {
		if open != 0 {
			#partial switch a {
			case .Skip:
				w.mute = open
				return .Next
			case .Rest:
				w.mute = max(u64)
				return .Next
			case .Keep, .Keep_Stubs:
				when .Keeps in C {
					w.keep, w.keep_stubs = open, a == .Keep_Stubs
					// The inner hook's room is read anew for each token, as the inner and the outer hook grow theirs apart.
					return emit_kept(w, hs, t)
				}
			}
		}
	}
	return .Stop if a == .Stop else .Next
}

// Gives token `t` to the inner hook of the hook's `Keeps`, growing its room first for a node it has no place for.
@(private)
emit_kept :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), hs: ^hook.Regs, t: tape.Token) -> Emitted {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	when .Keeps in C {
		K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
		Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
		when .Rooms in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0) {
			inner := (^Inner)(hook.keeps_inner(w.hooks))
			if t.kind != .End && t.role <= .Key && uintptr(hs.a) == hook.rooms_end(inner) && !hook.rooms_grow(inner, hs, t.lo) {
				return .Stop
			}
		}
		a: hook.Action
		if w.keep_stubs {
			hs^, a = hook.keeps_give(w.hooks, hs^, t, true)
		} else {
			hs^, a = hook.keeps_give(w.hooks, hs^, t, false)
		}
		return .Stop if a == .Stop else .Next
	} else {
		return .Next
	}
}

// Gives the `End` that closes the container of the element with `open` open elements, or the document's for
// `DOCUMENT`, spanning `n` bytes at `lo`: to the inner hook of a keep of it and then to the hook, and to the hook alone
// once a skip of it ends.
@(private)
emit_close :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, open, lo: u64, n: int) -> Emitted {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	when .Skips in C {
		if w.mute == open {
			w.mute = 0
			if w.mute_end {
				w.mute_end = false
				return .Next
			}
		}
	}
	when .Keeps in C {
		if w.keep == open {
			if r := emit(w, on, hs, .End, .Value, lo, n); r != .Next {
				return r
			}
			w.keep = 0
		}
	}
	return emit(w, on, hs, .End, .Value, lo, n)
}

@(private, cold)
grow_room :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), hs: ^hook.Regs, at: u64) -> bool {
	when .Rooms in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0) {
		if !hook.rooms_grow(w.hooks, hs, at) {
			return false
		}
		w.rooms = hook.rooms_end(w.hooks)
	}
	return true
}

// The result for the token that `emit` refused: a stop of the walk, or a token wider than `Token.n` holds.
@(private, cold)
refused :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), hs: hook.Regs, e: Emitted, p: [^]u8) -> u64 {
	if e == .Wide {
		return fault(w, hs, p, .Too_Wide)
	}
	return stopped(w, hs, p)
}

@(private)
at :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), p: [^]u8) -> u64 {
	return u64(intrinsics.ptr_sub(p, w.base))
}

// A walk's result in one word, as `hook.Walk_Result` packs it: the offset, the detail and a fault kind or an outcome.
@(private)
fault_at :: #force_inline proc "contextless" (pos: u64, kind: tape.Fault_Kind, detail: u8 = 0) -> u64 {
	return pos << 16 | u64(detail) << 8 | u64(kind)
}

// The outcomes past the fault kinds that the walk's leaves return as a kind.
@(private)
TOO_DEEP :: tape.Fault_Kind(hook.WALK_TOO_DEEP)
@(private)
NO_MEMORY :: tape.Fault_Kind(hook.WALK_NO_MEMORY)
@(private)
EXPANSION :: tape.Fault_Kind(hook.WALK_EXPANSION)

@(private)
fault :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), hs: hook.Regs, p: [^]u8, kind: tape.Fault_Kind, detail := Detail.None) -> u64 {
	w.regs^ = hs
	return fault_at(at(w, p), kind, u8(detail))
}

// The result for a hook that stopped the walk at the token ending at `p`.
@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), hs: hook.Regs, p: [^]u8) -> u64 {
	w.regs^ = hs
	return fault_at(at(w, p), tape.Fault_Kind(hook.WALK_STOPPED))
}

// The fault for a run that `run` or `name_end` refused.
@(private, cold)
run_fault :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), hs: hook.Regs, r: Run) -> u64 {
	return fault(w, hs, r.q, r.kind, r.detail)
}

// Fault for a name that `name_end` refused at `q` where the name was due.
@(private, cold)
name_fault :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), hs: hook.Regs, q, end: [^]u8, f: Name_Fault, detail: Detail) -> u64 {
	switch f {
	case .Truncated:
		return fault(w, hs, end, .Truncated)
	case .Bad_Utf8:
		return fault(w, hs, q, .Bad_Char, .Invalid_Utf8)
	case .Not_Name, .None:
	}
	return fault(w, hs, q, .Bad_Char, detail)
}

// The fault of an element opened at `p` past the depth the walk holds, `.None` once the frames and the hook's levels
// hold twice the levels, up to the limit. An element under `d` others is read with the hook's levels when the walk
// started and `d` elements open in the hook.
@(private)
deepen :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), hs: ^hook.Regs, p: [^]u8) -> tape.Fault_Kind {
	return tape.Fault_Kind(hook.deepen(w, hs, int(w.opened), at(w, p)))
}

// Whether `[p, q)` holds a CR.
@(private)
has_cr :: #force_inline proc "contextless" (p, q: [^]u8) -> bool #no_bounds_check {
	for x := p; x < q; x = x[1:] {
		if x[0] == '\r' {
			return true
		}
	}
	return false
}

// The spelling of a text that the format decodes: a decode that reads the DTD under `dtd`.
@(private)
text_spelling :: #force_inline proc "contextless" (decode, dtd: bool) -> u16 {
	return (tape.SPELLING_DECODE if decode else 0) | (SPELLING_DTD if dtd else 0)
}

// Gives the text of `n` bytes at `lo` of the element whose frame is `f` as its value, or as the value of a `#text`
// member: a null when it holds no character, else a string, or under `infer` a text with no decode that is `true`,
// `false` or a JSON number as that value.
@(private)
emit_text :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, f: ^Frame, lo: u64, n: int, decode: bool) -> Emitted {
	when H == hook.No_Hooks {
		return .Next
	}
	if n == 0 || decode && .Chars not_in f.flags {
		return emit(w, on, hs, .Null, .Value, lo, n)
	}
	if !decode && w.infer && u64(n) <= u64(max(u32)) {
		t := tape.infer_token(w.base, lo, u32(n))
		return emit(w, on, hs, t.kind, .Value, lo, n, t.spelling)
	}
	return emit(w, on, hs, .String, .Value, lo, n, text_spelling(decode, .Dtd in f.flags))
}

// Opens the container of the element whose frame is `f`, with `e` open elements, when its first child starts at
// `child`: gives the `Object` and the text before the child as a `#text` member. Returns whether the walk is over, with
// its result.
@(private)
open_content :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, f: ^Frame, e: u64, child: [^]u8) -> (result: u64, done: bool) {
	if .Object not_in f.flags {
		f.flags += {.Object}
		if r := emit(w, on, hs, .Object, .Value, at(w, f.tag), int(f.tag_n), 0, e); r != .Next {
			return refused(w, hs^, r, child), true
		}
		when H != hook.No_Hooks {
			if .Held in f.flags {
				if r, over := give_held(w, on, hs, f, child, .Comment); over {
					return r, true
				}
			}
		}
	}
	return text_member(w, on, hs, f, child)
}

// Gives the comments and instructions of frame `f`'s content before `upto` with role `role`: those of the first
// member, given after the element's `Object`, or the foot comments of an element with no child, given before its value.
@(private, cold)
give_held :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, f: ^Frame, upto: [^]u8, role: tape.Role) -> (result: u64, done: bool) #no_bounds_check {
	f.flags -= {.Held}
	CDATA :: len("<![CDATA[")
	for x := w.base[f.text_lo:]; x < upto; {
		switch {
		case x[0] != '<':
			x = x[1:]
		case x[1] == '!' && x[2] == '[':
			x = run(w, x[CDATA:], upto, .Cdata, 0).q[3:]
		case:
			q, _ := misc_run(w, x, upto)
			if r, at_ := give_misc(w, on, hs, x, q, upto, false, role); r != .Next {
				return refused(w, hs^, r, at_), true
			}
			x = q
		}
	}
	return 0, false
}

// Gives the text run of frame `f` that ends at `end_of_run` as a `#text` member when it is text, and starts the next run.
@(private)
text_member :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, f: ^Frame, end_of_run: [^]u8) -> (result: u64, done: bool) {
	when H != hook.No_Hooks {
		if .Seen in f.flags {
			if r, over := text_member_emit(w, on, hs, f, end_of_run); over {
				return r, true
			}
		}
		f.flags -= {.Seen, .Decode, .Chars, .Dtd}
		f.flags += {.Prev}
	}
	return 0, false
}

// Emits a mixed-content `#text` member out of line so `st_start` and `st_end` do not inline multiple hook copies.
@(private, cold)
text_member_emit :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, f: ^Frame, end_of_run: [^]u8) -> (result: u64, done: bool) {
	lo := f.text_lo
	n := int(at(w, end_of_run) - lo)
	if r := emit(w, on, hs, .String, .Key, lo, 0, tape.SPELLING_DECODE | markup.SPELLING_TEXT_KEY); r != .Next {
		return refused(w, hs^, r, end_of_run), true
	}
	if r := emit_text(w, on, hs, f, lo, n, .Decode in f.flags); r != .Next {
		return refused(w, hs^, r, end_of_run), true
	}
	return 0, false
}

// `p` is at a `<` that starts an element, in the content of the element with `d` open elements, or at the document
// level when `d` is 0. Reads the start tag: the name, then the attributes, each given as a fact, then its `>` or
// `/>`. Gives the `Key` first.
@(private, enable_target_feature = STATE_FEATURES)
st_start :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
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
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	muted := false
	_ = muted
	when .Skips in C && !LAX {
		muted = w.mute != 0
	}
	when H != hook.No_Hooks || LAX {
		if !muted && d > 0 {
			if r, done := open_content(w, on, &hs, &w.stack[d - 1], d, p); done {
				return r
			}
		}
	}
	if q < end && q[0] == '>' && !w.tag_dtd && !colon {
		w.stack[d] = Frame{tag = p, text_lo = at(w, q) + 1, tag_n = u32(name_n + 2), name_n = u16(name_n)}
		when H != hook.No_Hooks {
			if !muted {
				if r := emit(w, on, &hs, .String, .Key, at(w, p) + 1, name_n); r != .Next {
					return refused(w, hs, r, q)
				}
			}
		}
		return #must_tail st_content(q[1:], end, d + 1, w, hs.a, hs.b, hs.c, on)
	}
	w.stack[d] = Frame{tag = p, name_n = u16(name_n)}
	w.nattr = 0
	w.tag_ns = colon
	when H != hook.No_Hooks {
		if !muted {
			if r := emit(w, on, &hs, .String, .Key, at(w, p) + 1, name_n); r != .Next {
				return refused(w, hs, r, q)
			}
		}
	}
	return #must_tail st_attributes(q, end, d + 1, w, hs.a, hs.b, hs.c, on)
}

// `p` is inside the start tag of the element with `e` open elements, after its name or an attribute. Reads the
// attributes, giving each as a `Role.Attribute` fact, to the tag's `>` or `/>`.
@(private, enable_target_feature = STATE_FEATURES)
st_attributes :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	hs := hook.Regs{s0, s1, s2}
	q := p
	for {
		gap := q
		q = kernel.skip_ws(q, end)
		if q >= end {
			return fault(w, hs, end, .Truncated)
		}
		switch q[0] {
		case '>':
			return #must_tail st_open_done(q, end, e, w, hs.a, hs.b, hs.c, on)
		case '/':
			if intrinsics.ptr_sub(end, q) < 2 {
				return fault(w, hs, end, .Truncated)
			}
			if q[1] != '>' {
				return fault(w, hs, q, .Bad_Char, .Empty_Tag)
			}
			return #must_tail st_empty_done(q, end, e, w, hs.a, hs.b, hs.c, on)
		}
		if q == gap {
			return fault(w, hs, q, .Bad_Char, .Space)
		}
		name_end_at, nf, colon := name_end_colon(q, end)
		if nf != .None {
			return name_fault(w, hs, name_end_at, end, nf, .Name)
		}
		name_n := intrinsics.ptr_sub(name_end_at, q)
		if name_n > int(max(u16)) {
			return fault(w, hs, q, .Too_Wide)
		}
		eq := kernel.skip_ws(name_end_at, end)
		if eq >= end {
			return fault(w, hs, end, .Truncated)
		}
		if eq[0] != '=' {
			return fault(w, hs, eq, .Bad_Char, .Equals)
		}
		v := kernel.skip_ws(eq[1:], end)
		if v >= end {
			return fault(w, hs, end, .Truncated)
		}
		r: Run
		switch v[0] {
		case '"':
			r = run(w, v[1:], end, .Attr, '"')
		case '\'':
			r = run(w, v[1:], end, .Attr, '\'')
		case:
			return fault(w, hs, v, .Bad_Char, .Quote)
		}
		if r.kind != .None {
			return run_fault(w, hs, r)
		}
		if kind := attr_repeats(w, q, u64(name_n)); kind != .None {
			return fault(w, hs, q, kind, .Duplicate_Attribute if kind == .Bad_Char else .None)
		}
		if colon || q[0] == 'x' {
			if kind, rule := attribute_scope(w, q, name_n, v[1:], r.q, e, colon); kind != .None {
				return fault(w, hs, q, kind, rule)
			}
		}
		value_end := r.q[1:]
		when H != hook.No_Hooks {
			spelling := markup.attribute_spelling(intrinsics.ptr_sub(v[1:], q), true) | (ATTRIBUTE_DTD if r.dtd else 0)
			if w.attr_dtd {
				spelling |= tokenized_bit(w, e, q, name_n)
			}
			if q[0] == 'x' && declares_ns(q, name_n) {
				spelling |= ATTRIBUTE_NS
			}
			if x := emit(w, on, &hs, .String, .Attribute, at(w, q), intrinsics.ptr_sub(value_end, q), spelling); x != .Next {
				return refused(w, hs, x, value_end)
			}
		}
		q = value_end
	}
}

// Whether walk `w` gives the hook no value of the element it reads: one the hook skipped at its key, or one inside an
// element it mutes.
@(private)
passing :: #force_inline proc "contextless" (w: ^Walk($H, $LAX)) -> bool {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	when .Skips in C {
		return w.mute != 0 || w.skip_value
	} else {
		return false
	}
}

// Adds the attribute name at `name` to the tag's names. Returns `.Bad_Char` when the tag already has it, `NO_MEMORY`
// when the names cannot be held, else `.None`.
@(private)
attr_repeats :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), name: [^]u8, n: u64) -> tape.Fault_Kind #no_bounds_check {
	i := w.nattr
	if i < ATTR_SLOTS {
		for j in 0 ..< i {
			if w.names[j].n == n && string(name[:n]) == string(w.names[j].p[:n]) {
				return .Bad_Char
			}
		}
		w.names[i] = Name_Ref{name, n}
		w.nattr += 1
		return .None
	}
	return attr_repeats_table(w, name, n)
}

// `attr_repeats` for a tag with more than `ATTR_SLOTS` attributes: the names are in an open-addressing table that
// doubles when half full.
@(private, cold)
attr_repeats_table :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX), name: [^]u8, n: u64) -> tape.Fault_Kind #no_bounds_check {
	if w.nattr == ATTR_SLOTS {
		w.table = ([^]Name_Ref)(grab(walk_grab(w), 64 * size_of(Name_Ref), true))
		if w.table == nil {
			return NO_MEMORY
		}
		w.table_cap = 64
		for j in 0 ..< ATTR_SLOTS {
			table_put(w.table, 64, w.names[j].p, w.names[j].n)
		}
	}
	cap := table_cap(w.nattr)
	if w.nattr * 2 >= cap {
		bigger := ([^]Name_Ref)(grab(walk_grab(w), int(cap * 2) * size_of(Name_Ref), true))
		if bigger == nil {
			return NO_MEMORY
		}
		for j in 0 ..< cap {
			if w.table[j].p != nil {
				table_put(bigger, cap * 2, w.table[j].p, w.table[j].n)
			}
		}
		table_free(w)
		w.table, w.table_cap = bigger, cap * 2
		cap *= 2
	}
	w.nattr += 1
	return .None if table_put(w.table, cap, name, n) else .Bad_Char
}

// The capacity of the table that holds `count` names, a power of two from 64.
@(private)
table_cap :: #force_inline proc "contextless" (count: u64) -> u64 {
	cap := u64(64)
	for cap < count * 2 {
		cap *= 2
	}
	return cap
}

// Puts a name in `table` of capacity `cap`. Returns false when it is already there.
@(private)
table_put :: proc "contextless" (table: [^]Name_Ref, cap: u64, name: [^]u8, n: u64) -> bool #no_bounds_check {
	h := u64(14695981039346656037)
	for b in name[:n] {
		h = (h ~ u64(b)) * 1099511628211
	}
	for i := h & (cap - 1); ; i = (i + 1) & (cap - 1) {
		if table[i].p == nil {
			table[i] = Name_Ref{name, n}
			return true
		}
		if table[i].n == n && string(table[i].p[:n]) == string(name[:n]) {
			return false
		}
	}
}

// `p` is at the `>` that ends the start tag of the element with `e` open elements. Its content follows.
@(private, enable_target_feature = STATE_FEATURES)
st_open_done :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	f := &w.stack[e - 1]
	n := intrinsics.ptr_sub(p[1:], f.tag)
	if u64(n) > u64(max(u32)) {
		return fault(w, {s0, s1, s2}, p, .Too_Wide)
	}
	f.tag_n = u32(n)
	f.text_lo = at(w, p) + 1
	if w.tag_dtd {
		return #must_tail st_defaults(p, end, e, w, s0, s1, s2, on)
	}
	if w.nattr > ATTR_SLOTS {
		table_free(w)
	}
	if w.tag_ns {
		if kind, d := tag_names(w, f.tag, p); kind != .None {
			return fault(w, {s0, s1, s2}, f.tag, kind, d)
		}
	}
	return #must_tail st_content(p[1:], end, e, w, s0, s1, s2, on)
}

// Pops the declarations of the element with `e` open elements, freeing the URIs they own, and goes on as `st_closed`.
// A call in `st_closed` itself would cost every close.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_unbind :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	for w.ns_len > 0 && w.ns[w.ns_len - 1].depth == e {
		w.ns_len -= 1
		ungrab(walk_grab(w), w.ns[w.ns_len].uri.p, w.ns[w.ns_len].owned)
	}
	return #must_tail st_closed(p, end, e, w, s0, s1, s2, on)
}

// `p` is at the `/` of the `/>` that ends the start tag of the element with `e` open elements. The element is empty,
// so its value is a null.
@(private, enable_target_feature = STATE_FEATURES)
st_empty_done :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	if w.tag_dtd {
		return #must_tail st_defaults(p, end, e, w, s0, s1, s2, on)
	}
	hs := hook.Regs{s0, s1, s2}
	if w.nattr > ATTR_SLOTS {
		table_free(w)
	}
	if w.tag_ns {
		if kind, d := tag_names(w, w.stack[e - 1].tag, p); kind != .None {
			return fault(w, hs, w.stack[e - 1].tag, kind, d)
		}
	}
	if x := emit(w, on, &hs, .Null, .Value, at(w, p), 0); x != .Next {
		return refused(w, hs, x, p[2:])
	}
	return #must_tail st_closed(p[2:], end, e, w, hs.a, hs.b, hs.c, on)
}

// An element with `e` open elements, itself included, ended with its last byte just before `p`. Hands the walk to the
// content of its parent, or to the epilog after the root.
@(private, enable_target_feature = STATE_FEATURES)
st_closed :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	for w.ns_len > 0 && w.ns[w.ns_len - 1].depth == e {
		if w.ns[w.ns_len - 1].owned != 0 {
			return #must_tail st_unbind(p, end, e, w, s0, s1, s2, on)
		}
		w.ns_len -= 1
	}
	if e == 1 {
		return #must_tail st_epilog(p, end, e, w, s0, s1, s2, on)
	}
	when H != hook.No_Hooks || LAX {
		f := &w.stack[e - 2]
		f.text_lo = at(w, p)
		when H != hook.No_Hooks {
			f.flags -= {.Seen, .Decode, .Chars, .Dtd}
			f.flags += {.Prev}
		}
	}
	return #must_tail st_content(p, end, e - 1, w, s0, s1, s2, on)
}

// `p` is in the content of the element with `d` open elements, at the start of a character run or a markup construct.
// Reads whitespace and then character data up to the next `<`, then branches on what the `<` opens.
@(private, enable_target_feature = STATE_FEATURES)
st_content :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	when LAX {
		if w.pause != nil && pause_due(w, p, end, d) {
			if r, stop := pause_content(w, p, end, d, {s0, s1, s2}); stop {
				return r
			}
		}
	}
	q := kernel.skip_ws(p, end)
	if q >= end {
		when H != hook.No_Hooks {
			if q > p {
				w.stack[d - 1].flags += {.Chars}
			}
		}
		w.halt = Run{q = end, decode = q > p && has_cr(p, q), kind = .Truncated}
		return #must_tail st_halt(q, end, d, w, s0, s1, s2, on)
	}
	if q[0] != '<' {
		r := run(w, q, end, .Text, 0)
		if r.kind != .None {
			when H != hook.No_Hooks {
				f := &w.stack[d - 1]
				if q > p {
					f.flags += {.Chars}
					if has_cr(p, q) {
						f.flags += {.Decode}
					}
				}
			}
			w.halt = r
			return #must_tail st_halt(q, end, d, w, s0, s1, s2, on)
		}
		when H != hook.No_Hooks {
			if !passing(w) {
				f := &w.stack[d - 1]
				flags := f.flags + {.Seen, .Chars}
				if r.decode || q > p && has_cr(p, q) {
					flags += {.Decode}
				}
				if r.dtd {
					flags += {.Dtd}
				}
				f.flags = flags
			}
		}
		q = r.q
	} else {
		when H != hook.No_Hooks {
			if q > p && !passing(w) {
				w.stack[d - 1].flags += {.Chars}
			}
		}
	}
	if intrinsics.ptr_sub(end, q) < 2 {
		return fault(w, {s0, s1, s2}, end, .Truncated)
	}
	switch q[1] {
	case '/':
		return #must_tail st_end(q, end, d, w, s0, s1, s2, on)
	case '!':
		return #must_tail st_bang(q, end, d, w, s0, s1, s2, on)
	case '?':
		return #must_tail st_misc(q, end, d, w, s0, s1, s2, on)
	}
	when LAX {
		if w.pause != nil && w.pause.members == d && !passing(w) {
			return pause_member(w, on, q, d, {s0, s1, s2})
		}
	}
	return #must_tail st_start(q, end, d, w, s0, s1, s2, on)
}

// `p` is at `<!` in the content of the element with `d` open elements: a comment or a CDATA section.
@(private, enable_target_feature = STATE_FEATURES)
st_bang :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	room := intrinsics.ptr_sub(end, p)
	if room >= 4 && p[2] == '-' && p[3] == '-' {
		return #must_tail st_misc(p, end, d, w, s0, s1, s2, on)
	}
	CDATA :: "<![CDATA["
	if !prefix_of(p, min(room, len(CDATA)), CDATA) {
		return fault(w, {s0, s1, s2}, p, .Bad_Char, .Markup)
	}
	if room < len(CDATA) {
		return fault(w, {s0, s1, s2}, end, .Truncated)
	}
	r := run(w, p[len(CDATA):], end, .Cdata, 0)
	if r.kind != .None {
		return run_fault(w, {s0, s1, s2}, r)
	}
	f := &w.stack[d - 1]
	f.flags += {.Seen, .Decode}
	if r.q > p[len(CDATA):] {
		f.flags += {.Chars}
	}
	return #must_tail st_content(r.q[3:], end, d, w, s0, s1, s2, on)
}

// `p` is at a comment or a processing instruction in the content of the element with `d` open elements. Reads the
// run of comments, instructions and whitespace up to the next byte, then gives them: those on the line where the
// element's last child ended are inline comments, and the rest are comments of what follows, or foot comments when
// the element's end tag follows a child. A run before the element's first child is held for `give_held`, except in
// a replacement text, which the end of the reference leaves.
@(private, enable_target_feature = STATE_FEATURES)
st_misc :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	hs := hook.Regs{s0, s1, s2}
	q, r := misc_run(w, p, end)
	if r.kind != .None {
		return run_fault(w, hs, r)
	}
	f := &w.stack[d - 1]
	f.flags += {.Decode}
	if has_ws(p, q) {
		f.flags += {.Chars}
	}
	when H != hook.No_Hooks {
		if .Object not_in f.flags && (w.dtd == nil || w.dtd.depth == 0) {
			f.flags += {.Held}
			return #must_tail st_content(q, end, d, w, hs.a, hs.b, hs.c, on)
		}
		foot := .Object in f.flags && intrinsics.ptr_sub(end, q) >= 2 && q[0] == '<' && q[1] == '/'
		inline := .Prev in f.flags && .Seen not_in f.flags
		// The whitespace before the run, which `st_content` has passed, says whether the first comment is on the line
		// where the element before it ended.
		lead := p
		for lead > w.base[f.text_lo:] && kernel.is_ws(lead[-1]) {
			lead = lead[-1:]
		}
		if x, at_ := give_misc(w, on, &hs, lead, q, end, inline, .Comment_Foot if foot else .Comment); x != .Next {
			return refused(w, hs, x, at_)
		}
	}
	return #must_tail st_content(q, end, d, w, hs.a, hs.b, hs.c, on)
}

// Whether markup whitespace stands among the comments and instructions from `p` to `q`, which `misc_run` read, so the
// text that holds them is not empty.
@(private, cold)
has_ws :: #force_no_inline proc "contextless" (p, q: [^]u8) -> bool #no_bounds_check {
	for x := p; x < q; {
		if kernel.is_ws(x[0]) {
			return true
		}
		e, _ := markup_end(x, q)
		x = e if e > x else x[1:]
	}
	return false
}

// `p` is at the `</` of an end tag in the content of the element with `d` open elements. Checks that the name is the
// element's, then closes it: gives its text as the value, or the text before its end as a `#text` member and the
// `End`.
@(private, enable_target_feature = STATE_FEATURES)
st_end :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	hs := hook.Regs{s0, s1, s2}
	f := &w.stack[d - 1]
	n := int(f.name_n)
	name := f.tag[1:]
	room := intrinsics.ptr_sub(end, p[2:])
	when !LAX && ODIN_ENDIAN == .Little {
		if n <= 8 && room >= 8 && (w.dtd == nil || w.dtd.depth == 0) {
			mask := ~u64(0) >> u64(64 - 8 * n)
			if (kernel.load8(p[2:]) ~ kernel.load8(name)) & mask != 0 {
				return fault(w, hs, p[2:], .Bad_Char, .Mismatched_Tag)
			}
		} else if room < n {
			if string(p[2:][:room]) != string(name[:room]) {
				return fault(w, hs, p[2:], .Bad_Char, .Mismatched_Tag)
			}
			return fault(w, hs, end, .Truncated)
		} else if string(p[2:][:n]) != string(name[:n]) {
			return fault(w, hs, p[2:], .Bad_Char, .Mismatched_Tag)
		}
	} else {
		if room < n {
			if string(p[2:][:room]) != string(name[:room]) {
				return fault(w, hs, p[2:], .Bad_Char, .Mismatched_Tag)
			}
			return fault(w, hs, end, .Truncated)
		}
		if string(p[2:][:n]) != string(name[:n]) {
			return fault(w, hs, p[2:], .Bad_Char, .Mismatched_Tag)
		}
	}
	q := p[2 + n:]
	after: [^]u8
	if q < end && q[0] == '>' {
		after = q[1:]
	} else {
		if q < end && NAME_BYTE[q[0]] != .No {
			return fault(w, hs, q, .Bad_Char, .Mismatched_Tag)
		}
		q = kernel.skip_ws(q, end)
		if q >= end {
			return fault(w, hs, end, .Truncated)
		}
		if q[0] != '>' {
			return fault(w, hs, q, .Bad_Char, .Close_Tag)
		}
		after = q[1:]
	}
	when H != hook.No_Hooks {
		C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
		when .Skips in C && !LAX {
			if w.mute != 0 {
				if w.mute == d {
					w.mute = 0
					if w.mute_end {
						w.mute_end = false
					} else if x := emit(w, on, &hs, .End, .Value, at(w, p), intrinsics.ptr_sub(after, p)); x != .Next {
						return refused(w, hs, x, after)
					}
				}
				if w.ns_len == 0 && d > 1 {
					pf := &w.stack[d - 2]
					pf.text_lo = at(w, after)
					pf.flags -= {.Seen, .Decode, .Chars, .Dtd}
					pf.flags += {.Prev}
					return #must_tail st_content(after, end, d - 1, w, hs.a, hs.b, hs.c, on)
				}
				return #must_tail st_closed(after, end, d, w, hs.a, hs.b, hs.c, on)
			}
		}
		if .Object in f.flags {
			if r, done := text_member(w, on, &hs, f, p); done {
				return r
			}
			if x := emit_close(w, on, &hs, d, at(w, p), intrinsics.ptr_sub(after, p)); x != .Next {
				return refused(w, hs, x, after)
			}
		} else {
			if .Held in f.flags {
				if r, done := give_held(w, on, &hs, f, p, .Comment_Foot); done {
					return r
				}
			}
			if passing(w) {
				// The text of an element the hook skipped at its key gives no token.
				w.skip_value = false
			} else {
				lo := f.text_lo
				// A run of white space alone is no text run, so no scan judged its line ends.
				decode := .Decode in f.flags || .Seen not_in f.flags && has_cr(w.base[lo:], p)
				if x := emit_text(w, on, &hs, f, lo, int(at(w, p) - lo), decode); x != .Next {
					return refused(w, hs, x, p)
				}
			}
		}
	}
	if w.ns_len == 0 && d > 1 {
		when H != hook.No_Hooks || LAX {
			pf := &w.stack[d - 2]
			pf.text_lo = at(w, after)
			when H != hook.No_Hooks {
				pf.flags -= {.Seen, .Decode, .Chars, .Dtd}
				pf.flags += {.Prev}
			}
		}
		return #must_tail st_content(after, end, d - 1, w, hs.a, hs.b, hs.c, on)
	}
	return #must_tail st_closed(after, end, d, w, hs.a, hs.b, hs.c, on)
}
