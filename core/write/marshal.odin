// The typed write: one iterative loop over a plan's records, with one stack of frames. A struct, a list, a map, a pointer
// and an `any` each take a frame, so a value of any shape nests on the stack `marshal_as` holds, not on the thread's. A format
// instantiates the loop with its string writer and its tree bytes at compile time, and the plan reaches that instance
// through `Plan.marshal`.
package write

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "../spell"
import core ".."
import "../typed"

// The text of a tree, which belongs to its format. All but the last three parts are one byte, and `After_Colon` follows a
// colon in pretty text.
Tree_Part :: enum {
	Open_Object,
	Close_Object,
	Open_Array,
	Close_Array,
	Comma,
	Colon,
	After_Colon,
	Null,
	True,
	False,
}
Tree :: [Tree_Part]string

// A format's string writer. `p` is `room(out, 18)` at the cursor. It writes `s` with its quotes and moves the cursor, and
// `opts` are the call's, for a writer that has any to read.
@(private)
Put :: #type proc(out: ^Out, p: [^]u8, s: string, opts: ^core.Write_Options) -> core.Typed_Error_Kind

// What the loop reserves for a value that stays in line: a string's 18 bytes, a number's text.
@(private)
LEAF_ROOM :: 48
#assert(LEAF_ROOM >= spell.F64_ROOM && LEAF_ROOM >= spell.INT_ROOM && LEAF_ROOM >= 18)

// The longest line break and indent stored under the reservation past a token or a member. Deeper text takes `long_line`
// in the typed write and `rare_line` in the document write.
LINE_ROOM :: 1024

@(private)
MEMBER_ROOM :: 1 + typed.KEY_SIZE_MAX + 16 + LEAF_ROOM
@(private)
PRETTY_ROOM :: MEMBER_ROOM + 1 + LINE_ROOM + 16 + 1
#assert(PRETTY_ROOM <= ROOM_MAX)
// A struct's close: its line, its bracket, and in a list the comma and the line of the next element.
@(private)
CLOSE_ROOM :: 3 + 2 * (1 + LINE_ROOM + 16)
#assert(CLOSE_ROOM <= ROOM_MAX)

@(private)
Frame_Mode :: enum u32 {
	Target, // one value through a pointer, no bytes of its own. The root's frame too
	Side, // a `Target` read by a side plan, which ends with the frame
	Elements,
	Members,
	Entries, // an object whose members were listed in `Walker.entries`
}

// What the loop holds of one open value. `r` is a member frame's next record, or the element's. `at` is a member frame's
// struct, the next element, or the next index in `entries`. `step` is the stride of the elements, or for entries the
// mark in `keys` their text starts at. It has no padding, since `---` zeroes a padded array.
@(private)
Frame :: struct {
	r:     ^typed.Field,
	at:    uintptr,
	left:  int,
	total: int,
	step:  int,
	mode:  Frame_Mode,
	lead:  u32, // a member frame's byte before its next member. An element frame's 1 once an element is written
}
#assert(size_of(Frame) == 48)

// A pointer's or an `any`'s target on the open path. A cycle meets one address by one record again: a struct and its
// first member share an address and not a record.
@(private)
Target :: struct {
	at:  rawptr,
	rec: ^typed.Field,
}

// A member of an object listed before writing: a map's key, a struct's member under `sort_keys`, a union's tag. `text` is
// the key's own bytes, set while its object sorts, since `keys` may move. `at` is where the key's written bytes start in
// `keys`, and the key's own bytes follow them.
@(private)
Entry :: struct {
	text:  string, // the key as the caller holds it, set to sort by
	at:    int,
	size:  int, // the key's written bytes, which the key's own bytes follow
	named: int, // the count of the key's own bytes
	value: uintptr,
	rec:   ^typed.Field,
}

// A typed write's state. `frames` has `MAX_DEPTH + 1` slots and `ptrs` `MAX_DEPTH`, on `marshal_as`'s stack or in a
// `Held_Walker`. Between two values it holds no frame, so one walker writes a run of values. `out` is held in place, so
// a store to it does not alias the walker's other fields.
@(private)
Walker :: struct {
	out:       Out,
	plan:      ^typed.Plan,
	meta:      [^]typed.Meta,
	opts:      core.Write_Options,
	frames:    [^]Frame,
	ptrs:      [^]Target,
	n_ptrs:    int,
	fill:      #simd[16]u8, // what an indent is made of
	unit:      int, // the indent's bytes per level
	keys:      Out, // the text of the keys in `entries`
	entries:   [dynamic]Entry,
	order:     [dynamic]Sort_Item, // the words an object's entries sort by
	listed:    int, // the entries of the object just listed
	mark:      int, // where their text starts in `keys`
	plans:     [dynamic]^typed.Plan, // the plans the open `Side` frames interrupted
	side:      map[typeid]^typed.Plan,
	arena:     runtime.Arena, // what hooks allocate
	tag_field: typed.Field, // the record of a union's tag, a string
	err:       core.Typed_Error,
}

// Writes `value` by `plan`, which a format built, as `opts` says. `plan` must be of `value`'s type, and the bytes are the
// caller's. A nil `value` writes the format's null only through a plan of its type, see `marshal_once`.
marshal :: proc(value: any, plan: ^typed.Plan, opts := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	if err := check_value(value, plan); err != .None {
		return nil, {kind = err}
	}
	return plan.marshal(plan, value.data, opts, {}, allocator)
}

// `marshal` to `w`, as the text is made. On a refusal `w` may hold a prefix of the text.
marshal_stream :: proc(w: io.Stream, value: any, plan: ^typed.Plan, opts := core.Write_Options{}, allocator := context.allocator) -> core.Typed_Error {
	if err := check_value(value, plan); err != .None {
		return {kind = err}
	}
	_, err := plan.marshal(plan, value.data, opts, w, allocator)
	return err
}

// `marshal` of a value with no plan of its own: a plan is built for the call. A nil `any` has no type to plan and is
// written as a null value of an `any`.
marshal_once :: proc(value: any, make_plan: proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Error), opts := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	v := value
	nothing: any
	if v.id == nil || v.data == nil {
		v = any{&nothing, typeid_of(any)}
	}
	plan, err := make_plan(v.id, {}, context.allocator)
	if err.kind != .None {
		return nil, err
	}
	defer typed.plan_destroy(&plan)
	if plan.marshal == nil {
		return nil, {kind = .Unsupported}
	}
	return plan.marshal(&plan, v.data, opts, {}, allocator)
}

@(private)
check_value :: proc(value: any, plan: ^typed.Plan) -> core.Typed_Error_Kind {
	if plan == nil || plan.marshal == nil {
		return .Unsupported
	}
	if value.id != plan.type || value.data == nil {
		return .Plan_Mismatch
	}
	return .None
}

// The compact and pretty instances of a format's walk, each with the plain string writer `put` and with `put_opted`, the
// one a call with `ascii` or `escape_html` takes. `Plan.marshal` is a format's one call of this. The text comes from
// `allocator`, and what lasts only the call from `context.allocator`.
marshal_as :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, $T: Tree, $put, $put_opted: Put) -> ([]u8, core.Typed_Error) {
	frames: [core.MAX_DEPTH + 1]Frame = ---
	ptrs: [core.MAX_DEPTH]Target = ---
	spill: [ROOM_MAX]u8 = ---
	w: Walker
	init(&w.out, &spill, allocator, stream)
	walker_init(&w, opts, raw_data(frames[:]), raw_data(ptrs[:]))
	kind := walker_value(&w, plan, uintptr(value), T, put, put_opted)
	release_walker(&w)
	if kind != .None {
		destroy(&w.out)
		w.err.kind = kind
		w.err.cause = w.out.cause
		return nil, w.err
	}
	return finish((^Out)(rawptr(&w.out)))
}

// Starts a walker that writes to its started `out` as `opts` says, over `frames` of `MAX_DEPTH + 1` slots and `ptrs` of
// `MAX_DEPTH`. What it allocates for itself comes from `context.allocator`, and `release_walker` frees it.
@(private)
walker_init :: proc(w: ^Walker, opts: core.Write_Options, frames: [^]Frame, ptrs: [^]Target) {
	init(&w.keys, w.out.spill)
	w.opts, w.frames, w.ptrs = opts, frames, ptrs
	w.fill, w.unit = 0x20, int(opts.indent)
	if opts.tab {
		w.fill, w.unit = 0x09, 1
	}
	w.tag_field.kind = .String
	w.entries.allocator, w.plans.allocator = context.allocator, context.allocator
	w.side.allocator = context.allocator
	w.arena.backing_allocator = context.allocator
}

// Writes one value by `plan`, in the instance of the walk `opts` picks. A refusal's path is in `w.err`.
@(private)
walker_value :: proc(w: ^Walker, plan: ^typed.Plan, value: uintptr, $T: Tree, $put, $put_opted: Put) -> core.Typed_Error_Kind {
	w.plan, w.meta = plan, raw_data(plan.meta)
	switch {
	case w.opts.pretty && (w.opts.ascii || w.opts.escape_del || w.opts.escape_html):
		return walk(w, value, true, T, put_opted)
	case w.opts.pretty:
		return walk(w, value, true, T, put)
	case w.opts.ascii || w.opts.escape_del || w.opts.escape_html:
		return walk(w, value, false, T, put_opted)
	}
	return walk(w, value, false, T, put)
}

// A walker that outlives one value, with its stacks, which a token write keeps in `Tokens.state`.
@(private)
Held_Walker :: struct {
	w:      Walker,
	frames: [core.MAX_DEPTH + 1]Frame,
	ptrs:   [core.MAX_DEPTH]Target,
}

// Writes `value` by `plan` at the output of the token write `t`, by the walk of tree `T`, with nothing around it. The
// walker is made at the first value and kept until `tokens_release`, so a run of values sets it up once, and the token
// write's output moves into it, so `t.out` points into the walker from then on. A refusal's
// kind and path go to `err`, and the kind is returned.
tokens_marshal :: proc(t: ^Tokens, plan: ^typed.Plan, value: rawptr, err: ^core.Typed_Error, $T: Tree, $put, $put_opted: Put) -> core.Typed_Error_Kind {
	h := (^Held_Walker)(t.state)
	if h == nil {
		// The stacks are written before they are read, so only the walker is zeroed.
		made, failed := runtime.mem_alloc_non_zeroed(size_of(Held_Walker), align_of(Held_Walker))
		if failed != nil {
			err^ = {kind = .Out_Of_Memory}
			return .Out_Of_Memory
		}
		h = (^Held_Walker)(raw_data(made))
		h.w = {}
		h.w.out = t.out^
		t.out, t.state = &h.w.out, h
		walker_init(&h.w, t.opts, raw_data(h.frames[:]), raw_data(h.ptrs[:]))
	}
	w := &h.w
	// A side plan is built with its parent plan's options, so another plan builds its own.
	if w.plan != plan {
		release_sides(&w.side)
	}
	if w.arena.total_used > 0 {
		runtime.arena_free_all(&w.arena)
	}
	kind := walker_value(w, plan, uintptr(value), T, put, put_opted)
	if kind != .None {
		// A refusal leaves open what its value had open.
		w.n_ptrs, w.keys.cursor = 0, 0
		clear(&w.entries)
		err^ = w.err
		err.kind, err.cause = kind, t.out.cause
	}
	return kind
}

// Frees the walker `tokens_marshal` kept: a token write's `stop`.
tokens_release :: proc(t: ^Tokens) {
	if h := (^Held_Walker)(t.state); h != nil {
		release_walker(&h.w)
		free(h, h.w.entries.allocator)
	}
}

// The walk. `cur` is the open frame, kept out of `frames` so its fields stay in registers, so `refused` gets a copy, since
// the proc takes a by-value struct's address. Each pass through the loop
// writes what comes before one value, then the value, which is written in the switch or opens a frame.
@(private)
walk :: #force_no_inline proc(w: ^Walker, value: uintptr, $P: bool, $T: Tree, $put: Put) -> core.Typed_Error_Kind #no_bounds_check {
	out := &w.out
	cur := Frame{r = &w.plan.fields[0], at = value, left = 1, mode = .Target}
	top, nest := 0, 0
	next: for {
		vf: ^typed.Field
		va: uintptr
		p: [^]u8
		if cur.mode == .Members {
			r := cur.r
			if r.key_size == 0 {
				for r.omit && is_empty(w, r, cur.at + uintptr(r.offset)) {
					r = intrinsics.ptr_offset(r, 1)
				}
				if r.kind == .Never {
					p = room(out, CLOSE_ROOM)
					if cur.lead == u32(T[.Open_Object][0]) {
						p[0] = T[.Open_Object][0]
						out.cursor += 1
						p = p[1:]
					} else {
						when P {
							p = line(w, p, nest - 1)
						}
					}
					p[0] = T[.Close_Object][0]
					out.cursor += 1
					when P {
						nest -= 1
					}
					// The next struct of a list takes this frame over: a push and a pop for each element is the
					// most a list of small structs pays per byte. `Elements` under `Members` means the frame is
					// an element's, and a `.Struct` record means it was not listed.
					up := &w.frames[top]
					if up.mode == .Elements && up.left > 0 && up.r.kind == .Struct && out.err == .None {
						up.left -= 1
						p[1] = T[.Comma][0]
						out.cursor += 1
						when P {
							line(w, p[2:], nest)
							nest += 1
						}
						cur.r, cur.at, cur.lead = up.r.first, up.at, u32(T[.Open_Object][0])
						up.at += uintptr(up.step)
						continue
					}
					cur = w.frames[top]
					top -= 1
					if out.err != .None {
						return out.err
					}
					continue
				}
			}
			p = room(out, PRETTY_ROOM when P else MEMBER_ROOM)
			p[0] = u8(cur.lead)
			cur.lead = u32(T[.Comma][0])
			p = p[1:]
			when P {
				out.cursor += 1
				p = line(w, p, nest)
				start := out.cursor
			} else {
				start := out.cursor + 1
			}
			cur.r = intrinsics.ptr_offset(r, 1)
			n := uintptr(r.key_size)
			if n == 0 {
				out.cursor = start
				if k := member_key(w, r, T, put); k != .None {
					open := cur
					return refused(w, open, top, k)
				}
				p = room(out, LEAF_ROOM + 1)
				start = out.cursor
			} else {
				intrinsics.unaligned_store((^[2]u64)(p), r.word)
				if n > 16 {
					intrinsics.mem_copy_non_overlapping(p[16:], r.rest, n - 16)
				}
				start += int(n)
				p = p[n:]
			}
			when P {
				p[0] = T[.After_Colon][0]
				p = p[1:]
				start += 1
			}
			// One store of the cursor per member: the value's text reads it next, through memory.
			out.cursor = start
			vf, va = r, cur.at + uintptr(r.offset)
		} else if cur.left == 0 {
			if top == 0 {
				return out.err
			}
			if cur.mode >= .Elements {
				p = room(out, 1 + LINE_ROOM + 16)
				when P {
					if cur.total > 0 {
						p = line(w, p, nest - 1)
					}
					nest -= 1
				}
				if cur.mode == .Elements {
					p[0] = T[.Close_Array][0]
				} else {
					p[0] = T[.Close_Object][0]
					resize(&w.entries, int(cur.at) - cur.total)
					w.keys.cursor = cur.step
				}
				out.cursor += 1
			} else {
				w.n_ptrs -= 1
				if cur.mode == .Side {
					leave_side(w)
				}
			}
			cur = w.frames[top]
			top -= 1
			if out.err != .None {
				return out.err
			}
			continue
		} else if cur.mode == .Elements {
			cur.left -= 1
			p = room(out, 1 + 1 + LINE_ROOM + 16 + LEAF_ROOM when P else 1 + LEAF_ROOM)
			p[0] = T[.Comma][0]
			p = p[cur.lead:]
			out.cursor += int(cur.lead)
			cur.lead = 1
			when P {
				p = line(w, p, nest)
			}
			vf, va = cur.r, cur.at
			cur.at += uintptr(cur.step)
		} else if cur.mode == .Entries {
			vf, va = entry_key(w, int(cur.at), cur.left == cur.total, nest, T)
			cur.at += 1
			cur.left -= 1
			p = out.buf[out.cursor:]
		} else {
			cur.left = 0
			p = room(out, LEAF_ROOM)
			vf, va = cur.r, cur.at
		}
		k := core.Typed_Error_Kind.None
		value: for {
			// Before the switch: a string is most of a text, and a compare costs less than a jump through a table.
			if vf.kind == .String {
				k = put(out, p, (^string)(va)^, &w.opts)
			} else {
				#partial switch vf.kind {
				case .I64:
					out.cursor += spell.i64_text(p, (^i64)(va)^)
				case .F64:
					x := (^f64)(va)^
					if x - x != 0 {
						k = .Non_Finite
					} else {
						out.cursor += spell.f64_text(p, x)
					}
				case .Bool:
					out.cursor += put_bool(p, (^bool)(va)^, T)
				case .Struct, .Required:
					if top == core.MAX_DEPTH {
						k = .Too_Deep
					} else if w.opts.sort_keys || vf.kind == .Required && w.meta[w.meta[vf.meta].block + w.meta[vf.meta].members].capture >= 0 {
						k = list_struct(w, vf, va, nil, put)
						if k == .None {
							break value
						}
					} else {
						top += 1
						w.frames[top] = cur
						cur = Frame{r = vf.first, at = va, lead = u32(T[.Open_Object][0]), mode = .Members}
						when P {
							nest += 1
						}
					}
				case .Slice, .Dynamic, .Array, .Fixed_List:
					if top == core.MAX_DEPTH {
						k = .Too_Deep
					} else {
						at := va
					n: int
						#partial switch vf.kind {
						case .Slice, .Dynamic:
							s := (^runtime.Raw_Slice)(va)^
							at, n = uintptr(s.data), s.len
						case .Array:
							n = int(w.meta[vf.meta].count)
						case:
							n = (^int)(va + uintptr(w.meta[vf.meta].tag))^
						}
						e := elem_of(vf)
						top += 1
						w.frames[top] = cur
						cur = Frame{r = e, at = at, left = n, total = n, step = int(e.stride), mode = .Elements}
						when P {
							nest += 1
						}
						p[0] = T[.Open_Array][0]
						out.cursor += 1
					}
				case .Map:
					if top == core.MAX_DEPTH {
						k = .Too_Deep
					} else {
						k = list_map(w, vf, va, put)
						if k == .None {
							break value
						}
					}
				case .Ptr:
					target := (^rawptr)(va)^
					if target == nil {
						out.cursor += put_word(p, T[.Null])
					} else {
						e := elem_of(vf)
						k = enter_target(w, top, target, e)
						if k == .None {
							top += 1
							w.frames[top] = cur
							cur = Frame{r = e, at = uintptr(target), left = 1, mode = .Target}
						}
					}
				case .Maybe:
					if (^bool)(va + uintptr(w.meta[vf.meta].tag))^ {
						vf = elem_of(vf)
						continue value
					}
					out.cursor += put_word(p, T[.Null])
				case .Union:
					arm := union_arm(&w.meta[vf.meta], va)
					if arm == nil {
						out.cursor += put_word(p, T[.Null])
					} else if len(arm.name) == 0 {
						vf = &w.plan.fields[arm.fields]
						continue value
					} else if top == core.MAX_DEPTH {
						k = .Too_Deep
					} else {
						k = list_struct(w, &w.plan.fields[arm.fields], va, &arm.name, put)
						if k == .None {
							break value
						}
					}
				case .Any, .Hook:
					a: any
					// A hook's stand-in may come from `Walker.arena`, which lasts the call. A hook with no write proc refuses the value.
					if vf.kind == .Any {
						a = (^any)(va)^
					} else if write := w.meta[vf.meta].write; write == nil {
						k = .Unsupported
					} else {
						a, k = write(rawptr(va), runtime.arena_allocator(&w.arena))
					}
					if k == .None {
						rec, e := any_value(w, a, top, T, put)
						k = e
						if rec != nil {
							top += 1
							w.frames[top] = cur
							cur = Frame{r = rec, at = uintptr(a.data), left = 1, mode = .Side}
						}
					}
				case:
					k = leaf(w, vf, va, top, nest, P, T, put)
				}
			}
			if k != .None {
				open := cur
				return refused(w, open, top, k)
			}
			continue next
		}
		top += 1
		w.frames[top] = cur
		cur = open_entries(w, T)
		when P {
			nest += 1
		}
	}
}

// Writes a line break and the indent of `nest` levels at `p`, under a reservation of `1 + LINE_ROOM + 16` bytes, and
// returns the cursor's new place. The cursor is at `p`.
@(private)
line :: #force_inline proc(w: ^Walker, p: [^]u8, nest: int) -> [^]u8 #no_bounds_check {
	n := nest * w.unit
	if n > LINE_ROOM {
		return long_line(w, n)
	}
	p[0] = '\n'
	for k := 0; k < n; k += 16 {
		intrinsics.unaligned_store((^#simd[16]u8)(p[1 + k:]), w.fill)
	}
	w.out.cursor += n + 1
	return p[n + 1:]
}

// A line whose indent passes `LINE_ROOM`, which may be past what one `room` holds, written in pieces. It returns the
// place of a reservation as `line` leaves one.
@(cold)
@(private)
long_line :: proc(w: ^Walker, n: int) -> [^]u8 #no_bounds_check {
	fill := (transmute([16]u8)w.fill)[0]
	put_fill(&w.out, n, fill)
	return room(&w.out, MEMBER_ROOM)
}

@(private)
elem_of :: #force_inline proc "contextless" (f: ^typed.Field) -> ^typed.Field {
	return intrinsics.ptr_offset(f.first, -1)
}

// Stores `text` whole under a reservation of 8 bytes and returns its length, at most 8.
@(private)
put_word :: #force_inline proc "contextless" (p: [^]u8, text: string) -> int {
	intrinsics.mem_copy_non_overlapping(p, raw_data(text), len(text))
	return len(text)
}

@(private)
put_bool :: #force_inline proc "contextless" (p: [^]u8, b: bool, $T: Tree) -> int {
	if b {
		return put_word(p, T[.True])
	}
	return put_word(p, T[.False])
}
