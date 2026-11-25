package toml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The walk of a TOML text. A text names a member where it is written and a table's members may be written apart, so
// the walk reads statements into a table tree (tree.odin, parse.odin), which judges every byte and the rules on keys
// and tables, and gives the hook the tree's nodes in document order: a table's members in the order the text first
// names them. A walk for a hook that may stop reads statements only as far as the members it gives need, and any other
// reads the whole text first.
//
// The tokens: an `Object` for the text, then for each member its head comments, a `Key` (`String`, role `Key`) and its
// value, and the comment on the line the value ends on, and before each container's `End` its foot comments. A table
// is an `Object` and an array an `Array`, each with its `tape.CONTAINER_STYLE`. A string's or quoted key's span leaves
// its quotes out, a date-time is a `String` of its text whose spelling names its type, a number a `Number` of its text,
// and a comment a `Plain` fact of its span from its `#`.

// An open container of a walk: its node, the member it gave last, `NIL` before its first, and where the value of that
// member ends, the container's own offset before its first, and `max(u64)` once a member passed unread left the end
// for the close to take from the tree. A table no bracket closes ends there.
@(private)
Frame :: struct {
	node, last: u32,
	end:        u64,
	// No later statement can add a member to the container: it is written whole where it stands (an inline table or an
	// array of values), or lies in an element of an array of tables that a later element follows, as a header reaches
	// only the last element.
	sealed:     bool,
	tables:     bool, // the container or one it lies in is an element of an array
}

// The frame of container node `id` opened in the container of frame `up`, its token at `lo`.
@(private)
frame_in :: proc "contextless" (t: ^Table_Tree, up: Frame, id: u32, lo: u64) -> Frame {
	n := &t.nodes[id]
	parent := &t.nodes[n.parent]
	element := parent.kind == .Array
	sealed := up.sealed || .Inline in n.flags || n.kind == .Array && .Tables not_in n.flags || element && parent.last != id
	return {node = id, last = NIL, end = lo, sealed = sealed, tables = up.tables || element}
}

// Seals the open containers that lie in an element of the array of tables `t.extended`, which a new element now
// follows.
@(private, cold)
seal_frames :: proc "contextless" (t: ^Table_Tree, frames: []Frame) {
	a := t.extended
	t.extended = NIL
	if len(frames) == 0 {
		return
	}
	d := int(t.nodes[a].depth) - int(t.nodes[frames[0].node].depth)
	if d < 0 || d + 1 >= len(frames) || frames[d].node != a || frames[d + 1].node == t.nodes[a].last {
		return
	}
	for &f in frames[d + 1:] {
		if f.sealed {
			break
		}
		f.sealed = true
	}
}

// A walk's state, for hook type `H` of capabilities `C`, its protocol's. A walk with `LAX` counts its containers within
// `Budget.steps`, and one without counts nothing. Its frames hold the containers open, whatever way the walk is
// nested: a hook's `Skip`, `Keep` or `Rest` of a container sets `nest` and `floor`, the frame the nest ends with.
@(private)
Walk :: struct($H: typeid, $LAX: bool, $C: hook.Capabilities) {
	p:      ^Parser,
	hooks:  ^H,
	// The address one past the hook's room for nodes, for a hook with `.Rooms`.
	rooms:  uintptr,
	frames: ^[dynamic]Frame,
	// The most levels the hook needs, its open containers before the walk and the levels of the text.
	levels: int,
	floor:  int,
	nest:   hook.Nest,
	failed: bool, // a level of the hook or of the walk could not be had
	// With `LAX`, one more than the containers the walk may still give within `Budget.steps`, 0 once it reached one
	// past it.
	steps:  [int(LAX)]u64,
	// With `LAX`, the text in pieces whose window the walk reads, nil for a whole text.
	piece:  [int(LAX)]^Piece,
	// For a builder, the date-time bits of the values given and whether a node given spells a style, which
	// `spelled_into` adds to the document's facts. A scan, which keeps only some of the nodes given, reads its
	// document instead.
	dates:  u16,
	styled: bool,
}

// Reads `src` as `S` and gives its tokens to `on` from registers `regs`, which hold the hook's last registers when it
// returns. Returns the end of the text, or the error, and whether the walk took a rule of `opts.tolerate`, which TOML
// has none of. The tree and the walk's levels come from `hook.scratch(opts, allocator)`, called in `ctx`.
@(private)
walk_text :: proc "contextless" (src: []u8, $S: Spec, $LAX: bool, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	hook.check(H)
	context = ctx^
	context.allocator = allocator
	local: hook.Memory_Budget
	tree_allocator := hook.scratch(opts, allocator, &local)
	r := walk_tree(src, S == .Toml_1_1, LAX, opts, h, regs, tree_allocator, on)
	if u8(r) == 0 {
		return u64(len(src)), nil, false
	}
	at: u64
	at, err, _ = hook.walk_error(r, &RULES)
	return at, hook.memory_budget_error(&local, err), false
}

@(private)
walk_tree :: proc(src: []u8, v11: bool, $LAX: bool, opts: Options, h: ^$H, regs: ^hook.Regs, tree_allocator: runtime.Allocator, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	p: Parser
	defer parser_destroy(&p)
	if !parser_init(&p, src, v11, build.read_depth(opts), tree_allocator) {
		return hook.walk_result(0, hook.WALK_NO_MEMORY)
	}
	p.pos = text_start(src, 0)
	if reads_whole(h, C) && !parse_rest(&p) {
		return p.fail
	}
	when H == hook.No_Hooks && !LAX {
		return 0
	}
	if !p.done && !statement(&p) {
		return p.fail
	}
	frames: [dynamic]Frame
	frames.allocator = tree_allocator
	defer delete(frames)
	w := Walk(H, LAX, C) {
		p      = &p,
		hooks  = h,
		frames = &frames,
	}
	when LAX {
		w.steps[0] = build.read_steps(opts)
	}
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	hs := regs^
	defer regs^ = hs
	r := walk_root(&w, &hs, on)
	spelled_into(&w)
	return walk_end(&w, r)
}

// Whether a walk for hook `h` reads the text whole before the first token: for a hook that cannot stop, which takes
// every token, and for a scan that keeps facts, which places a table's comments as a build does, the comments above a
// header that defines it once other headers made it among them.
@(private)
reads_whole :: #force_inline proc "contextless" (h: ^$H, $C: hook.Capabilities) -> bool {
	when .Skips not_in C {
		return true
	} else when H == build.Scanner {
		return h.facts
	} else {
		return false
	}
}

// The result of a walk that ended in `r`, which says a stop for the step budget or for a level the hook could not hold.
@(private)
walk_end :: proc "contextless" (w: ^Walk($H, $LAX, $C), r: hook.Walk_Result) -> hook.Walk_Result {
	r := r
	when LAX {
		r = hook.steps_result(r, w.steps[0])
	}
	if u8(r) == hook.WALK_STOPPED && w.failed {
		return hook.walk_result(u64(r) >> 16, hook.WALK_NO_MEMORY)
	}
	return r
}

// Gives the text's head comments and its root table, and runs the walk to the root's `End`.
@(private)
walk_root :: proc(w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	p := w.p
	w.levels = int(hs.c) + int(p.tree.deepest) + 1
	when H == build.Builder {
		// A document of the whole tree holds a node for each node of the tree and one for each key.
		if p.done {
			hs^ = build.builder_room(w.hooks, hs^, len(p.tree.nodes) + p.tree.keyed)
			when .Rooms in C {
				w.rooms = hook.rooms_end(w.hooks)
			}
		}
	}
	x := notes_of(&p.tree, 0)
	if r, stop := give_comments(w, hs, x.head, x.heads, .Comment, on); stop {
		return r
	}
	t := tape.Token{kind = .Object}
	a := give(w, hs, t, on)
	if _, err := append(w.frames, Frame{node = 0, last = NIL}); err != nil {
		return hook.walk_result(0, hook.WALK_NO_MEMORY)
	}
	if a != .Next {
		if r, done := enter(w, hs, a, t, false, on); done {
			return r
		}
	}
	return drive(w, hs, on)
}

// Runs the walk on from where it is: finishes the skip or keep it is inside, then gives the members of the open
// containers and their `End`s, to the end of the text.
@(private)
drive :: proc(w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	if w.nest != .None {
		if r, done := nested(w, hs, on); done {
			return r
		}
	}
	r, _ := run(w, 0, hs, on)
	return r
}

// Marks the date-time bits of value `v` given, and its style for a value with no key, which a key spells otherwise:
// a number's and a quoted string's. A quoted string's spelling has no date-time bits.
@(private)
spelled_value :: #force_inline proc "contextless" (w: ^Walk($H, $LAX, $C), v: tape.Token, keyed: bool) {
	w.dates |= v.spelling >> DATE_SHIFT if v.kind == .String else 0
	if !keyed && (v.kind == .Number || v.spelling & tape.SPELLING_QUOTED != 0) {
		w.styled = true
	}
}

// Adds to the facts of the document a builder builds `.Style` and `.Tag` once the walk gave a node that spells one.
@(private)
spelled_into :: #force_inline proc "contextless" (w: ^Walk($H, $LAX, $C)) {
	when H == build.Builder {
		if w.styled {
			w.hooks.doc.present += {.Style}
		}
		if w.dates != 0 {
			w.hooks.doc.present += {.Tag}
		}
	}
}

@(private)
stopped :: #force_inline proc "contextless" (at: u64) -> hook.Walk_Result {
	return hook.walk_result(at, hook.WALK_STOPPED)
}

// Gives the `n` comments of the tree from `from` as facts of `role`. True with the stop once the hook stops.
@(private)
give_comments :: #force_inline proc(w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, from, n: u32, role: tape.Role, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (hook.Walk_Result, bool) {
	for k in 0 ..< n {
		c := w.p.tree.comments[from + k]
		if give(w, hs, comment_token(c, role), on) == .Stop {
			return stopped(c.lo + u64(c.n)), true
		}
	}
	return 0, false
}

@(private)
comment_token :: #force_inline proc "contextless" (c: Comment, role: tape.Role) -> tape.Token {
	return {c.lo, c.n, .Plain, role, tape.HASH_COMMENT}
}

// The `End` of the container the frame `f` holds: at its close for one in brackets or braces, at the text's end for
// the root, and where its last member's value ends for any other.
@(private)
end_token :: #force_inline proc "contextless" (p: ^Parser, f: Frame) -> tape.Token {
	if f.node == 0 {
		return {lo = u64(len(p.src)), kind = .End}
	}
	v := p.tree.nodes[f.node].value
	if v.spelling == STYLE_INLINE {
		return {lo = v.lo + u64(v.n), n = 1, kind = .End, spelling = STYLE_INLINE}
	}
	// A member passed unread left its end for the close to take from the tree. A table closes once no statement can add
	// to it, so whether a header defined it is known by its `End`.
	n := &p.tree.nodes[f.node]
	spelling := v.spelling
	if n.kind == .Table && n.flags - {.Given} == {} {
		spelling = STYLE_IMPLICIT
	}
	return {lo = end_of(&p.tree, p.src, f.node) if f.end == max(u64) else f.end, kind = .End, spelling = spelling}
}

// Gives the hook token `t`, growing the hook's room first for a node it has no place for, and its levels for a
// container it has no level for. With `LAX` the walk takes a step of `Budget.steps` per container, and stops at the
// first past it with no token. `.Stop` when the room or the levels cannot grow.
@(private)
give :: #force_inline proc(w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, t: tape.Token, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Action {
	when .Rooms in C {
		if t.kind != .End && t.role <= .Key && uintptr(hs.a) == w.rooms && !grow_room(w, hs, t.lo) {
			return .Stop
		}
	}
	if t.kind > .Plain && t.kind != .End {
		when .Levels in C {
			if hook.levels_held(w.hooks) <= int(hs.c) && !deepen(w, hs, t.lo) {
				return .Stop
			}
		}
		when LAX {
			w.steps[0] -= 1
			if w.steps[0] == 0 {
				return .Stop
			}
		}
	}
	when H == hook.No_Hooks {
		return .Next
	} else {
		a: hook.Action
		hs^, a = on(w.hooks, hs^, t)
		return a
	}
}

@(private, cold)
grow_room :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, at: u64) -> bool {
	when .Rooms in C {
		if !hook.rooms_grow(w.hooks, hs, at) {
			return false
		}
		w.rooms = hook.rooms_end(w.hooks)
	}
	return true
}

// Doubles the levels the hook holds, up to the levels it can need, for the container at `at`.
@(private, cold)
deepen :: #force_no_inline proc "contextless" (w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, at: u64) -> bool {
	want := min(max(2 * hook.levels_held(w.hooks), int(hs.c) + 1), max(w.levels, int(hs.c) + 1))
	if !hook.levels_need(w, want, hs, at) {
		w.failed = true
		return false
	}
	return true
}

// Reads the next statement into the tree, which the walk needs for the container it is in. The walk is done with the
// text's window, and returns its result with false, when the statement lies in a window to come or is at fault.
@(private)
read_on :: #force_inline proc(w: ^Walk($H, $LAX, $C)) -> (r: hook.Walk_Result, ok: bool) {
	p := w.p
	when LAX {
		if s := w.piece[0]; s != nil && !p.final {
			if !statement_ends(s, p) {
				return hook.walk_result(u64(p.pos), hook.WALK_MORE), false
			}
		}
	}
	if !statement(p) {
		return p.fail, false
	}
	if p.tree.extended != NIL {
		seal_frames(&p.tree, w.frames[:])
	}
	return 0, true
}

// Gives the members of the containers `w.frames` holds above `floor` and their `End`s, reading statements as the
// innermost needs them, until the container at `floor` closes. Returns the walk's result, and the `End` of the
// container at `floor` once it closed, whose offset the result holds.
@(private)
run :: proc(w: ^Walk($H, $LAX, $C), floor: int, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, close: tape.Token) {
	p := w.p
	for {
		f := &w.frames[len(w.frames) - 1]
		next := p.tree.nodes[f.node].first if f.last == NIL else p.tree.nodes[f.last].next
		if next == NIL {
			if !p.done && !f.sealed {
				for {
					if res, ok := read_on(w); !ok {
						return res, {}
					}
					if p.done || f.sealed || (p.tree.nodes[f.node].first if f.last == NIL else p.tree.nodes[f.last].next) != NIL {
						break
					}
				}
				continue
			}
			id := f.node
			x := notes_of(&p.tree, id)
			if res, stop := give_comments(w, hs, x.foot, x.foots, .Comment_Foot, on); stop {
				return res, {}
			}
			close = end_token(p, f^)
			pop(w.frames)
			if give(w, hs, close, on) == .Stop {
				return stopped(close.lo + u64(close.n)), close
			}
			if len(w.frames) == floor {
				return hook.walk_result(close.lo + u64(close.n), 0), close
			}
			w.frames[len(w.frames) - 1].end = close.lo + u64(close.n)
			if c := notes_of(&p.tree, id).inline; c.n != 0 && give(w, hs, comment_token(c, .Comment_Inline), on) == .Stop {
				return stopped(c.lo + u64(c.n)), {}
			}
			continue
		}
		f.last = next
		keyed := p.tree.nodes[f.node].kind == .Table
		m := p.tree.nodes[next]
		x := notes_of(&p.tree, next)
		if res, stop := give_comments(w, hs, x.head, x.heads, .Comment, on); stop {
			return res, {}
		}
		// The hook passes the value of a member whose key it answered `Skip` for, which is judged and given no token.
		pass := false
		if keyed {
			if !p.done && m.flags == {} && m.kind == .Table {
				p.tree.nodes[next].flags = {.Given}
			}
			switch give(w, hs, m.key, on) {
			case .Stop:
				return stopped(m.key.lo + u64(m.key.n)), {}
			case .Skip:
				pass = true
			case .Next, .Rest, .Keep, .Keep_Stubs, .Grow:
				when H == build.Builder {
					w.styled = true
				}
			}
		}
		if m.kind == .Scalar {
			if !pass {
				if give(w, hs, m.value, on) == .Stop {
					return stopped(m.value.lo + u64(m.value.n)), {}
				}
				when H == build.Builder {
					spelled_value(w, m.value, keyed)
				}
			}
			_, tail := bounds(p.src, m.value)
			f.end = m.value.lo + u64(m.value.n) + u64(tail)
			if x.inline.n != 0 && give(w, hs, comment_token(x.inline, .Comment_Inline), on) == .Stop {
				return stopped(x.inline.lo + u64(x.inline.n)), {}
			}
			continue
		}
		t := tape.Token{lo = m.value.lo, kind = m.value.kind, spelling = m.value.spelling}
		a := hook.Action.Skip
		if pass {
			when LAX {
				// The container is not given, but it takes its step.
				w.steps[0] -= 1
				if w.steps[0] == 0 {
					return stopped(t.lo), {}
				}
			} else {
				// A walk that counts no steps closes the container unread. Its `End` is given to no hook, so the parent
				// takes its end from the tree, and the statements that later add to it are read when the walk needs the
				// next member of the parent.
				f.end = max(u64)
				if x.inline.n != 0 && give(w, hs, comment_token(x.inline, .Comment_Inline), on) == .Stop {
					return stopped(x.inline.lo + u64(x.inline.n)), {}
				}
				continue
			}
		} else {
			a = give(w, hs, t, on)
			when H == build.Builder {
				w.styled = true
			}
		}
		// Once the text is read whole no walk asks whether a frame is sealed.
		frame := Frame{node = next, last = NIL, end = t.lo}
		if !p.done {
			frame = frame_in(&p.tree, f^, next, t.lo)
		}
		if _, err := append(w.frames, frame); err != nil {
			w.failed = true
			return stopped(t.lo), {}
		}
		if a == .Next {
			continue
		}
		if res, done := enter(w, hs, a, t, pass, on); done {
			return res, {}
		}
	}
}

// Starts the nest the hook's answer `a` other than `Next` to container `t` asks for, whose frame the walk holds last,
// and runs it, as the value of a key the hook skipped when `pass`. Returns the walk's result with `done`, or else the
// walk is past the container, its `End` given if the hook took the container's token.
@(private)
enter :: proc(w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, a: hook.Action, t: tape.Token, pass: bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	when .Skips in C {
		w.floor = len(w.frames) - 1
		#partial switch a {
		case .Skip:
			w.nest = .Pass if pass else .Skip
		case .Rest:
			w.nest = .Rest
		case .Keep:
			w.nest = .Keep
		case .Keep_Stubs:
			w.nest = .Keep_Stubs
		case:
			return stopped(t.lo), true
		}
		when .Keeps in C {
			if w.nest == .Keep {
				if r, _, done = keep_in(w, hs, t, false, true); done {
					return
				}
			} else if w.nest == .Keep_Stubs {
				if r, _, done = keep_in(w, hs, t, true, true); done {
					return
				}
			}
		} else {
			if w.nest == .Keep || w.nest == .Keep_Stubs {
				return stopped(t.lo), true
			}
		}
		return nested(w, hs, on)
	} else {
		return stopped(t.lo), true
	}
}

// Runs the nest `w.nest` the walk is in to the close of the container at `w.floor`, or to the end of the text for
// `Rest`, which a hook with `.Skips` and no tokens passes. Gives the container's `End` to the hook unless the container
// was the value of a key the hook skipped, and moves the walk past it. Returns the walk's result with `done`, which a
// window's end, a fault, a stop and the end of the text set.
@(private)
nested :: proc(w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	when .Skips in C {
		// A walk's hooks are behind a pointer, so a walk with `No_Hooks` has the same layout.
		#assert(size_of(Walk(H, LAX, C)) == size_of(Walk(hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS)))
		none := (^Walk(hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w)
		nest := w.nest
		// A rest has no container of its own to close.
		node := w.frames[w.floor].node if nest != .Rest else NIL
		close: tape.Token
		regs := hs^
		#partial switch nest {
		case .Skip, .Pass:
			// Only a walk that counts steps nests a `Pass`, as `run` closes the value of a skipped key in any other.
			when LAX {
				r, close = run(none, w.floor, &regs, hook.no_hook)
			} else {
				r, close = skip_whole(none)
			}
		case .Rest:
			r, close = run(none, 0, &regs, hook.no_hook)
			if u8(r) == 0 {
				w.nest = .None
			}
			return r, true
		case .Keep, .Keep_Stubs:
			when .Keeps in C {
				if nest == .Keep {
					r, close, _ = keep_in(w, hs, {}, false, false)
				} else {
					r, close, _ = keep_in(w, hs, {}, true, false)
				}
			}
		}
		if u8(r) != 0 {
			return r, true
		}
		w.nest = .None
		if nest != .Pass && give(w, hs, close, on) == .Stop {
			return stopped(close.lo + u64(close.n)), true
		}
		if len(w.frames) == 0 {
			return hook.walk_result(close.lo + u64(close.n), 0), true
		}
		w.frames[len(w.frames) - 1].end = close.lo + u64(close.n)
		if c := notes_of(&w.p.tree, node).inline; c.n != 0 && give(w, hs, comment_token(c, .Comment_Inline), on) == .Stop {
			return stopped(c.lo + u64(c.n)), true
		}
		return 0, false
	} else {
		return stopped(0), true
	}
}

// Passes the container whose frame the walk holds last, which no step budget counts into: reads statements until no
// later one can add to it, and closes it where the tree says its last member ends.
@(private)
skip_whole :: proc(w: ^Walk($H, false, $C)) -> (r: hook.Walk_Result, close: tape.Token) {
	p := w.p
	f := &w.frames[len(w.frames) - 1]
	// Only a new element of an array of tables can seal what is open, so with none above the container the rest of the
	// text is read, and else statements until one does.
	if !p.done && !f.sealed && !f.tables && !parse_rest(p) {
		return p.fail, {}
	}
	for !p.done && !f.sealed {
		if res, ok := read_on(w); !ok {
			return res, {}
		}
	}
	f.end = end_of(&p.tree, p.src, f.node)
	close = end_token(p, f^)
	pop(w.frames)
	return hook.walk_result(close.lo + u64(close.n), 0), close
}

// Walks a keep through the inner hook of the hook's `Keeps`, through its `Stubs` under `STUBS` and else its `Whole`:
// under `FIRST` gives it the container `t`, whose frame the walk holds last, and else runs the walk on to the close of
// the container at `w.floor`. `done` is set once the first token stops the walk.
@(private)
keep_in :: #force_inline proc(w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, t: tape.Token, $STUBS, $FIRST: bool) -> (r: hook.Walk_Result, close: tape.Token, done: bool) {
	K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
	Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
	when STUBS {
		return keep_walk(Inner, intrinsics.type_polymorphic_record_parameter_value(K, 1), intrinsics.type_polymorphic_record_parameter_value(K, 3), FIRST, w, hs, t)
	} else {
		return keep_walk(Inner, intrinsics.type_polymorphic_record_parameter_value(K, 1), intrinsics.type_polymorphic_record_parameter_value(K, 2), FIRST, w, hs, t)
	}
}

// The inner walk reads the inner hook's room when it starts, and the walk the hook's room when it ends, as a hook with
// `.Rooms` is given a node only while its room has place for it, in every walk.
@(private)
keep_walk :: proc($Inner: typeid, $of: proc "contextless" (h: rawptr) -> rawptr, $keep: proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $FIRST: bool, w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, t: tape.Token) -> (r: hook.Walk_Result, close: tape.Token, done: bool) {
	IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
	#assert(size_of(Walk(H, LAX, C)) == size_of(Walk(Inner, LAX, IC)))
	on :: #force_inline proc "contextless" (h: ^Inner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
		return keep(h, s, t)
	}
	inner := (^Walk(Inner, LAX, IC))(w)
	hooks := w.hooks
	inner.hooks = (^Inner)(of(hooks))
	when .Rooms in IC {
		inner.rooms = hook.rooms_end(inner.hooks)
	}
	when FIRST {
		// The container's step, taken again as its token is given again.
		when LAX {
			w.steps[0] += 1
		}
		if give(inner, hs, t, on) == .Stop {
			r, done = stopped(t.lo), true
		}
	} else {
		r, close = run(inner, w.floor, hs, on)
	}
	w.hooks = hooks
	when .Rooms in C {
		w.rooms = hook.rooms_end(hooks)
	}
	return
}
