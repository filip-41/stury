package scan

// The two walks, monomorphized on the check level from one body each.
//
// Values (strict, RFC 8259) checks grammar: nesting, string boundaries and
// escapes, literals, number extents, the scalar caps. Locate does not check
// grammar. Framing, wire UTF-8 and the depth cap still bind. No Bad_Escape,
// Bad_Number or Bad_Literal comes out of Locate.
//
// The walk is iterative over a fixed `Open_Frame[MAX_DEPTH]` stack array, so the depth cap bounds its
// memory. A cap raised past MAX_DEPTH moves the frames to the heap once the input nests past MAX_DEPTH.
// Every Values-ok input is Locate-ok, and every Locate error is a Values error.

import "base:intrinsics"
import "base:runtime"
import c "../../core"
import index "index"
import lex "lex"
import number "./number"

// One dispatch for both walks: only the leaves differ by check level, and `$check` is comptime, so no
// runtime mode flag reaches a value. Locate runs on the index cursor: it checks no escape, so a string
// whose chunk is clean is passed without its leaf.
walk_value :: #force_inline proc(s: ^Scanner, max_depth: u64, $check: Check_Level) -> Maybe(Error) {
	when check == .Locate && !SCAN_FORCE_SLOW {
		// Stage 1 classifies every byte, so on long strings it costs more than the byte walk's span skips.
		if !head_is_mostly_string(s.src, int(s.pos)) {
			ix: index.Index(LOCATE_FACTS) = ---
			cur := index_cursor(&ix, s, true)
			return walk_value_q(s, nil, max_depth, check, {}, &cur, false, false)
		}
	}
	cur: Byte_Cursor
	return walk_value_q(s, nil, max_depth, check, {}, &cur, false, false)
}

// Path and demand epilogue after a scalar token, or after a container skipped or checked whole as one. True
// when a path or demand query settled there (`stopped^` set) and the walk should return. False to go on.
@(private = "file")
after_scalar :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	lo: u64,
	sp: u64,
	pend: ^Demand_Pend,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
) -> bool {
	when .Path in Q {
		if auto_member_closed(q, Q, may_stop, stopped, int(sp) - 1, lo, s.pos) {
			if stopped != nil && stopped^ {
				return true
			}
		}
	}
	when .Demand in Q {
		demand_value_closed(s, q, Q, sp, pend, may_stop, stopped)
		when may_stop {
			if stopped != nil && stopped^ {
				return true
			}
		}
	}
	return false
}

// The fact-collecting twin of `walk_value`. `q` is nil exactly when `$Q` is `{}`, and every use of it in
// that specialization is compiled out.
//
// `cur` moves the walk from token to token (see `Byte_Cursor`).
//
// `$may_stop` is true only for the `.Lazy` arm of `scan_queries` when a path or demand query can settle early (`stop_capable`), so the
// stop test exists in no other specialization. A stopped walk reports the offset it stopped at, not a
// result.
//
// The fixed frame array holds MAX_DEPTH frames, so `max_depth` is at most MAX_DEPTH here: a larger cap
// takes `walk_deep`, chosen above the walk, so this one compiles as if no other existed.
walk_value_q :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	max_depth: u64,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	cur: ^$C,
	$may_skip: bool,
	$may_stop: bool,
	stopped: ^bool = nil,
) -> Maybe(Error) {
	return walk_frames(s, q, max_depth, check, Q, cur, may_skip, may_stop, stopped, false, nil)
}

// The walk under a `limit` past MAX_DEPTH: a complete walk at `$check` on the JSONC cursor (JSON's grammar
// when `cur.json`) that never skips and never stops, on frames that spill to the scanner's allocator at the
// first push past MAX_DEPTH, freed here with the same one. Only two readings reach it: `.Locate` for
// `.Structural` (a raised cap is a depth limit, not a grammar switch) and `.Values` for the rest, so `.Lazy`
// loses its early stop and its skips past MAX_DEPTH. It is built for size: a raised cap is the rare reading,
// and these twins are what it costs the binary.
@(optimization_mode = "favor_size")
walk_deep :: #force_no_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	limit: u64,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	cur: ^Jsonc_Cursor,
	$may_stop: bool,
	stopped: ^bool,
) -> Maybe(Error) {
	#assert(.Shape not_in Q, "the shape walk holds its cap to MAX_DEPTH")
	spill: []byte
	err := walk_frames(s, q, limit, check, Q, cur, false, may_stop, stopped, true, &spill)
	if spill != nil {
		runtime.mem_free(raw_data(spill), s.alloc)
	}
	return err
}

// The frames past MAX_DEPTH: `limit` of them in `spill`, the fixed array's copied in. Nil when the allocator
// refuses.
@(private = "file", cold)
spill_frames :: proc(spill: ^[]byte, fixed: [^]Open_Frame, limit: u64, alloc: runtime.Allocator) -> [^]Open_Frame {
	buf, err := runtime.mem_alloc_non_zeroed(int(limit) * size_of(Open_Frame), align_of(Open_Frame), alloc)
	if err != nil {
		return nil
	}
	spill^ = buf
	frames := ([^]Open_Frame)(raw_data(buf))
	copy(frames[:MAX_DEPTH], fixed[:MAX_DEPTH])
	return frames
}

// A push with `sp` at the cap `max_depth`: `.Too_Deep`, or under `$deep`, short of `limit`, the frames move off
// the stack into the spill.
@(private = "file")
depth_cap_hit :: #force_inline proc(s: ^Scanner, $deep: bool, spill: ^[]byte, frames: ^$F, max_depth: ^u64, limit: u64) -> Maybe(Error) {
	when deep {
		if max_depth^ == limit {
			return Error{offset = s.pos, kind = .Too_Deep}
		}
		spilled := (^[^]Open_Frame)(frames)
		if spilled^ = spill_frames(spill, spilled^, limit, s.alloc); spilled^ == nil {
			return Error{offset = s.pos, kind = .Out_Of_Memory}
		}
		max_depth^ = limit
		return nil
	} else {
		return Error{offset = s.pos, kind = .Too_Deep}
	}
}

// The walk itself. Each pass of `descend` takes one value, in this order: value-start hooks (path, shape),
// the skip of a value no query reads (`may_skip`), a container below every armed level checked whole
// (`walk_unarmed`), then by class a container open (pushes its frame, a `[` run fused), or a scalar. The
// scalar or an emptied container then falls to `outer`'s close-and-comma arm, which folds the value into
// its parent, and either steps to the next member (`continue outer`) or closes the parent in turn.
//
// Without `$deep` the frames are the fixed array and `limit <= MAX_DEPTH`. With it they sit behind a pointer
// that `spill_frames` moves off the stack at the first push past MAX_DEPTH. `max_depth` is the cap the frames
// in hand hold.
@(private = "file")
walk_frames :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	limit: u64,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	cur: ^$C,
	$may_skip: bool,
	$may_stop: bool,
	stopped: ^bool,
	$deep: bool,
	spill: ^[]byte,
) -> Maybe(Error) {
	when may_skip {
		#assert(Q <= bit_set[Walk_Kind]{.Path, .Demand, .Gate, .Shape, .Unique})
	}
	// The depth of the frame whose answer is being checked whole, or max(u64) outside any. Nothing inside
	// an answer is skipped.
	when may_skip {
		whole_sp := max(u64)
	}
	// `= ---`: every frame is written before it is read, and zeroing the stack would tax every scan.
	when deep {
		fixed: [MAX_DEPTH]Open_Frame = ---
		frames := ([^]Open_Frame)(&fixed)
		max_depth := u64(MAX_DEPTH)
	} else {
		frames: [MAX_DEPTH]Open_Frame = ---
		max_depth := limit
	}
	sp: u64 = 0
	// Q is only the kinds that touch a value through its row (`.Nodes`, `.Dom`), nothing else at its start or
	// end, on a walk that visits every value.
	NUMBER_RUN :: .Dom in Q && Q <= {.Nodes, .Dom} && C == Byte_Cursor && !may_skip
	// The same walks, row-writing, take long bracket runs out of line (`open_run`, `close_run`).
	BRACKET_RUNS :: .Nodes in Q && Q <= {.Nodes, .Dom} && C == Byte_Cursor && !may_skip && !deep
	// Held in the walk, not `Query_Ctx`, so the key-to-close handoff stays in registers (`Demand_Pend`).
	demand_pend: Demand_Pend

	// Step 0 reads the members of the root, `frames[0]`, which is never pushed when the root is a scalar.
	// Arming it first gives `auto_root_scalar` a level to consult.
	when .Path in Q {
		auto_arm_root(q, Q)
	}

	// The byte at `s.pos` as the walk steps onto a value, or -1 at the end of input, handed over so the
	// dispatch does not read it again.
	b := lex.peek(s)
	// The bracket that closes the innermost open container. It also says whether a comma there introduces a
	// key. Kept beside `sp` to spare a frame load.
	closer := 0
	// A negative-`Index` re-entry resumes inside its root array, at the member `s.pos` names, with the
	// members before it already counted (`path_reenter_from_end`): the array's frame is pushed as its
	// open would have. Only the re-entry's `.Path` walk resumes, so no other kind's fields are seeded.
	when .Path in Q {
		if q.auto.levels[0].idx > 0 {
			frames[0] = Open_Frame{lo = q.root_lo}
			sp = 1
			closer = ']'
		}
	}

	outer: for {
		descend: for {
			if b < 0 {
				return Error{offset = s.pos, kind = .Truncated}
			}
			vc: u8
			#no_bounds_check {
				vc = lex.VCLASS[b]
			}
			// Value-start hook. Step `d` reads the members of `frames[d]`, so a member of the innermost
			// frame is offered at step `sp - 1`.
			when .Path in Q {
				if sp == 0 {
					// The root value itself: a scalar mismatches every step.
					if vc >= VC_STRING {
						auto_root_scalar(q, Q, may_stop, stopped)
						if stopped != nil && stopped^ {
							return nil
						}
					}
				} else if auto_member_open(q, Q, may_stop, stopped, int(sp) - 1, vc, s.pos) {
					if stopped != nil && stopped^ {
						return nil
					}
				}
			}
			when .Shape in Q {
				if err := shape_value_open(s, q, sp, vc); err != nil {
					return err
				}
			}
			// A value no query reads past its extent is left unvisited: it closes as a scalar would and
			// it counts as skipped.
			when may_skip {
				if sp > 0 && vc != VC_NONE && sp <= whole_sp {
					switch value_use(q, Q, sp, &demand_pend, vc) {
					case .Unread:
						lo := s.pos
						if cursor_skip_value(s, cur, vc, int(max_depth - sp)) {
							q.skipped = true
							if after_scalar(s, q, lo, sp, &demand_pend, Q, may_stop, stopped) {
								return nil
							}
							break descend
						}
					case .Whole:
						if vc <= VC_ARRAY {
							whole_sp = sp
						}
					case .Partly:
					}
				}
			}
			// A container below every level that may be armed answers nothing and arms nothing, so the plain
			// walk checks it whole and it closes as a scalar would.
			when Q == {.Path} && C == Byte_Cursor && !may_skip {
				if vc - VC_OBJECT < 2 && sp >= u64(q.path_top) {
					lo := s.pos
					if err := walk_unarmed(s, max_depth - sp, check); err != nil {
						return err
					}
					if after_scalar(s, q, lo, sp, &demand_pend, Q, may_stop, stopped) {
						return nil
					}
					break descend
				}
			}
			lo := s.pos
			switch vc {
			case VC_OBJECT, VC_ARRAY: // a container opens here
				if sp >= max_depth {
					if err := depth_cap_hit(s, deep, spill, &frames, &max_depth, limit); err != nil {
						return err
					}
				}
				fr := &frames[sp]
				fr.lo = s.pos
				fr.is_obj = vc == VC_OBJECT
				closer = b + 2 // `{` + 2 is `}`, `[` + 2 is `]`
				// `frames` is `= ---`, so every route that reads `fr.members` at the close must seed it here.
				when .Nodes in Q {
					fr.members = 0
				}
				sp += 1
				s.pos += 1
				cursor_advance(cur)
				// A row-scoped demand's owner object is latched at key time (`Demand_Pend.owner_lo`), not
				// here: the innermost container to open does not own a member read while a nested one is
				// still open above it.
				//
				// The `.Nodes` row is written now, before any child exists. `close_frame` patches `hi`,
				// `cnt` and `subtree_size` (see `dom_container_open`).
				dom_container_open(q, Q, fr, fr.lo)
				when .Path in Q {
					// Container-kind check (at `sp == 1` the root's).
					if auto_frame_open(q, Q, may_stop, stopped, int(sp) - 1, vc, fr.lo) {
						if stopped != nil && stopped^ {
							return nil
						}
					}
				}
				when .Demand in Q {
					c.demand_wild_open(q, Q, sp, vc)
				}
				// Run-length push: consecutive `[` open one frame each without a VCLASS load and dispatch
				// per level. Objects cannot fuse (a key sits between `{` and its value), and whitespace
				// between brackets falls back to the dispatch. Every push runs the single push's
				// statements, so results and rows are unchanged. The path ordinal test runs per level
				// against the parent's frame, before `sp` advances. A walk that skips decides at every
				// value, so it takes each level through the dispatch. So does the shape walk: each `[` is a
				// value its target must see open.
				FUSE_BRACKETS :: .Shape not_in Q
				if FUSE_BRACKETS && vc == VC_ARRAY && !may_skip && lex.peek(s) == '[' {
					when BRACKET_RUNS {
						if bracket_run_ahead(s, OPEN_RUN_WORD) {
							e := &q.nodes_edge
							s.pos, sp, e.len = open_run(s.src, s.pos, ([^]Open_Frame)(&frames), sp, max_depth, e.base, e.len, e.cap, .Dom in Q)
						}
					}
					when .Nodes in Q {
						run_rows := q.nodes_edge.len
					}
					for s.pos < u64(len(s.src)) && s.src[s.pos] == u8('[') {
					if sp >= max_depth {
						if err := depth_cap_hit(s, deep, spill, &frames, &max_depth, limit); err != nil {
							when .Nodes in Q {
								q.nodes_edge.len = run_rows
							}
							return err
						}
					}
					fr2 := &frames[sp]
					fr2.lo = s.pos
					fr2.is_obj = false
					// Per fused level: `close_frame` needs every frame's tally initialised.
					when .Nodes in Q {
						fr2.members = 0
					}
					when .Path in Q {
						if auto_member_open(q, Q, may_stop, stopped, int(sp) - 1, 2, s.pos) {
							if stopped != nil && stopped^ {
								when .Nodes in Q {
									q.nodes_edge.len = run_rows
								}
								return nil
							}
						}
					}
					// The level's `.Nodes` row is written at its open, below.
					sp += 1
					s.pos += 1
					cursor_advance(cur)
					// Per fused level, so rows come out parent-first and each `]` patches its own row.
					when .Nodes in Q {
						c.dom_run_open(q, Q, fr2, fr2.lo, &run_rows)
					}
					when .Path in Q {
						if auto_frame_open(q, Q, may_stop, stopped, int(sp) - 1, 2, fr2.lo) {
							if stopped != nil && stopped^ {
								when .Nodes in Q {
									q.nodes_edge.len = run_rows
								}
								return nil
							}
						}
					}
					}
					when .Nodes in Q {
						q.nodes_edge.len = run_rows
					}
				}
				skip_peek_open := indent_skip_peek(s, cur, Q)
				// Not `fr`: the run-length loop advances `sp` once per extra `[`.
				top := top_frame(&frames, sp)
				if skip_peek_open == closer {
					// Empty container: closes here and is handed to its parent as a value.
					close_frame(s, q, check, Q, top, sp - 1, &demand_pend, may_stop, stopped)
					when .Shape in Q {
						if err := shape_close(s, q, sp - 1); err != nil {
							return err
						}
					}
					cursor_advance(cur)
					sp -= 1
					if sp > 0 {
						closer = top_frame(&frames, sp).is_obj ? '}' : ']'
					}
					when may_skip {
						if sp == whole_sp {
							whole_sp = max(u64)
						}
					}
					// A path run or a demand may have settled at this close.
					when .Path in Q || .Demand in Q {
						if stopped != nil && stopped^ {
							return nil
						}
					}
					break descend
				}
				b = skip_peek_open
				when .Shape in Q && C == Byte_Cursor && !may_skip {
					if closer == ']' {
						switch shape_take_elements(s, q, sp) {
						case .Key, .Value:
							b = lex.peek(s)
						case .After:
							break descend
						case .Fault:
							return Error{offset = s.pos, kind = TYPED_FAULT}
						}
					}
				}
				if closer == '}' {
					when .Shape in Q && C == Byte_Cursor && !may_skip {
						switch shape_take_members(s, q, sp, .Unique in Q, .Pass_Unread in Q) {
						case .Key:
						case .Value:
							b = lex.peek(s)
							continue descend
						case .After:
							break descend
						case .Fault:
							return Error{offset = s.pos, kind = TYPED_FAULT}
						}
					}
					when Q - {.Gate} == MEMBER_RUN_KINDS && C != Byte_Cursor && may_skip {
						if sp <= whole_sp {
							switch take_members(s, cur, q, Q, sp, fr.lo, &demand_pend, int(max_depth - sp), stopped) {
							case .Key:
							case .Value:
								b = lex.peek(s)
								continue descend
							case .After:
								break descend
							}
						}
					}
					next, err := object_key(s, cur, q, check, Q, sp, fr, &demand_pend)
					if err != nil {
						return err
					}
					b = next
				}
				continue descend // the member value this level opened onto
			case VC_STRING:
				known := false
				when Q <= EXTENT_ONLY {
					known = cursor_string_known(s, cur, check, Q, false)
				}
				if !known {
					when check == .Values {
						if err := lex.parse_string_q(s, q, lo, false, Q); err != nil {
							return err
						}
					} else {
						if err := lex.skip_string_q(s, q, lo, false, Q); err != nil {
							return err
						}
					}
					cursor_advance(cur)
				}
				emit_scalar(q, Q, lo, s.pos, .String)
				when .Shape in Q {
					if err := shape_scalar(s, q, lo, sp, VC_STRING); err != nil {
						return err
					}
				}
			case VC_LITERAL: // true / false / null
				known := false
				when Q <= EXTENT_ONLY && check == .Locate {
					known = cursor_scalar_known(s, cur, Q)
				}
				if !known {
					when check == .Values {
						// The literal leaf emits its own row: it knows which literal it accepted.
						if err := lex.parse_literal_q(s, q, lo, Q); err != nil {
							return err
						}
					} else {
						if err := lex.skip_alpha_q(s, q, lo, Q); err != nil {
							return err
						}
					}
					cursor_advance(cur)
				}
				when .Shape in Q {
					if err := shape_scalar(s, q, lo, sp, VC_LITERAL); err != nil {
						return err
					}
				}
			case VC_NUMBER:
				known := false
				when Q <= EXTENT_ONLY && check == .Locate {
					known = cursor_scalar_known(s, cur, Q)
				}
				if !known {
					when check == .Values && NUMBER_RUN {
						// A compact run of array elements that are numbers stays in this loop, each one passing
						// the dispatch and the comma arm by. Each element still folds into its array as the comma
						// arm would fold it, and the run's last is folded there.
						for {
							if err := number.parse_number_q(s, q, lo, Q); err != nil {
								return err
							}
							if closer != ']' || !number_follows(s) {
								break
							}
							when .Nodes in Q {
								top_frame(&frames, sp).members += 1
							}
							s.pos += 1
							lo = s.pos
						}
					} else when check == .Values {
						if err := number.parse_number_q(s, q, lo, Q); err != nil {
							return err
						}
					} else {
						if err := number.skip_number_q(s, q, lo, Q); err != nil {
							return err
						}
					}
					cursor_advance(cur)
				}
				when .Shape in Q {
					if err := shape_scalar(s, q, lo, sp, VC_NUMBER); err != nil {
						return err
					}
				}
			case:
				return Error{offset = s.pos, kind = .Bad_Char}
			}
			// A scalar ended at `s.pos`.
			when .Path in Q || .Demand in Q {
				if after_scalar(s, q, lo, sp, &demand_pend, Q, may_stop, stopped) {
					return nil
				}
			}
			break descend
		}

		// The value just closed: fold it into its parent, then open the parent's next member or close the
		// parent in turn, until the root is reached.
		for {
			if sp == 0 {
				return nil
			}
			top := top_frame(&frames, sp)
			// The only place a child is counted, so the run-length `[` loop cannot skip a level's first element.
			when .Nodes in Q {
				top.members += 1
			}
			// Tested before whitespace: in a compact document a comma or the close follows every value.
			c := lex.peek(s)
			if c != ',' && c != closer {
				c = indent_skip_peek(s, cur, Q)
			}
			if c == ',' {
				s.pos += 1
				cursor_advance(cur)
				// Strict cursors keep the original comma body. `Jsonc_Cursor` is not one of them:
				// `walk_value` never builds it, so this arm is not in the strict walk.
				when C == Jsonc_Cursor {
					// Tested second: only a comma before the closer reads the grammar.
					if cursor_skip_peek(s, cur) != closer || cur.json {
						if closer == ']' {
							b = lex.peek(s)
						} else {
							next, err := object_key(s, cur, q, check, Q, sp, top, &demand_pend)
							if err != nil {
								return err
							}
							b = next
						}
						continue outer
					}
					c = closer
				} else {
					if closer == ']' {
						b = indent_skip_peek(s, cur, Q)
						when .Shape in Q && C == Byte_Cursor && !may_skip {
							switch shape_take_elements(s, q, sp) {
							case .Key, .Value:
								b = lex.peek(s)
							case .After:
								continue
							case .Fault:
								return Error{offset = s.pos, kind = TYPED_FAULT}
							}
						}
					} else {
						when .Shape in Q && C == Byte_Cursor && !may_skip {
							lex.skip_ws(s)
							switch shape_take_members(s, q, sp, .Unique in Q, .Pass_Unread in Q) {
							case .Key:
							case .Value:
								b = lex.peek(s)
								continue outer
							case .After:
								continue
							case .Fault:
								return Error{offset = s.pos, kind = TYPED_FAULT}
							}
						}
						when Q - {.Gate} == MEMBER_RUN_KINDS && C != Byte_Cursor && may_skip {
							cursor_skip(s, cur)
							if sp <= whole_sp {
								switch take_members(s, cur, q, Q, sp, top.lo, &demand_pend, int(max_depth - sp), stopped) {
								case .Key:
								case .Value:
									b = lex.peek(s)
									continue outer
								case .After:
									continue
								}
							}
						}
						next, err := object_key(s, cur, q, check, Q, sp, top, &demand_pend)
						if err != nil {
							return err
						}
						b = next
					}
					continue outer // the next member value
				}
			}
			if c == -1 {
				return Error{offset = s.pos, kind = .Truncated}
			}
			if c == closer {
				when BRACKET_RUNS {
					if closer == ']' && bracket_run_ahead(s, CLOSE_RUN_WORD) {
						s.pos, sp = close_run(s.src, s.pos, ([^]Open_Frame)(&frames), sp, q.nodes_edge.base, q.nodes_edge.len)
						if sp > 0 {
							closer = top_frame(&frames, sp).is_obj ? '}' : ']'
						}
						continue
					}
				}
				close_frame(s, q, check, Q, top, sp - 1, &demand_pend, may_stop, stopped)
				when .Shape in Q {
					if err := shape_close(s, q, sp - 1); err != nil {
						return err
					}
				}
				cursor_advance(cur)
				sp -= 1
				if sp > 0 {
					closer = top_frame(&frames, sp).is_obj ? '}' : ']'
				}
				when may_skip {
					if sp == whole_sp {
						whole_sp = max(u64)
					}
				}
				// A path run or a demand may have settled at this close.
				when .Path in Q || .Demand in Q {
					if stopped != nil && stopped^ {
						return nil
					}
				}
				continue // this container is a value for its parent
			}
			return Error{offset = s.pos, kind = .Bad_Char}
		}
	}
}

// The container at `s.pos` on the validate walk, `limit` levels deep at most. Out of line, so the path walk's
// registers stay its own.
@(private = "file")
walk_unarmed :: #force_no_inline proc(s: ^Scanner, limit: u64, $check: Check_Level) -> Maybe(Error) {
	cur: Byte_Cursor
	sc := s^
	err := walk_value_q(&sc, nil, min(limit, MAX_DEPTH), check, {}, &cur, false, false)
	s.pos = sc.pos
	return err
}

// The innermost open frame. `sp - 1` names a frame a checked push wrote, so it needs no second check.
@(private = "file")
top_frame :: proc {
	top_frame_fixed,
	top_frame_deep,
}

@(private = "file")
top_frame_fixed :: #force_inline proc(frames: ^[MAX_DEPTH]Open_Frame, sp: u64) -> ^Open_Frame {
	#no_bounds_check {
		return &frames[sp - 1]
	}
}

@(private = "file")
top_frame_deep :: #force_inline proc(frames: ^[^]Open_Frame, sp: u64) -> ^Open_Frame {
	return &frames[sp - 1]
}

// A long run of brackets on a walk that writes rows and nothing else (`BRACKET_RUNS`). Out of line, so the run
// keeps its cursor, depth and row count in registers the walk has no room for. It is entered only past eight
// brackets in a row, so its call is paid on deeply nested input alone.
@(private = "file")
BRACKET_RUN_MIN :: 8
@(private = "file")
OPEN_RUN_WORD :: 0x5b5b_5b5b_5b5b_5b5b // eight `[`
@(private = "file")
CLOSE_RUN_WORD :: 0x5d5d_5d5d_5d5d_5d5d // eight `]`

// Whether eight bytes at `s.pos` all equal the bracket in `word`.
@(private = "file")
bracket_run_ahead :: #force_inline proc(s: ^Scanner, word: u64) -> bool {
	#no_bounds_check {
		return s.pos + BRACKET_RUN_MIN <= u64(len(s.src)) && intrinsics.unaligned_load((^u64le)(&s.src[s.pos])) == u64le(word)
	}
}

// The fused `[` loop's levels, while the depth cap and the row capacity leave room: each `[` pushes a frame
// and writes its row as `dom_run_open` does. What is left (a cap reached, a full edge, the run's end) is
// the caller's loop's.
@(private = "file")
open_run :: #force_no_inline proc(
	src: []byte,
	pos: u64,
	frames: [^]Open_Frame,
	sp, max_depth: u64,
	base: [^]c.Row,
	rows, room: int,
	$dom: bool,
) -> (pos_after, sp_after: u64, rows_after: int) {
	n := u64(len(src))
	pos, depth, at := pos, sp, rows
	flags: c.Row_Flags
	when dom {
		flags = {.Decoded}
	}
	// The row goes out as four words, two paired stores, where field stores take five: the words of a
	// template whose only per-row fields, `lo` and `subtree_size`, each start a zero word's low half (the
	// layout `core/tape.odin` asserts).
	tw := transmute([4]u64)c.Row{key_lo = c.NO_KEY, key_hi = c.NO_KEY, kind = .Array, flags = flags}
	// One bound for the loop: the run stops at the depth cap, the end of the row block or the end of input.
	end := pos + min(max_depth - depth, u64(room - at), n - pos)
	#no_bounds_check for pos < end && src[pos] == '[' {
		frames[depth] = Open_Frame{lo = pos, row = u32(at)}
		w := ([^]u64)(&base[at])
		w[0] = u64(u32(pos))
		w[1] = tw[1]
		w[2] = tw[2] | u64(u32(at))
		w[3] = tw[3]
		at += 1
		depth += 1
		pos += 1
	}
	return pos, depth, at
}

// The closes of a run of `]`, the first of which closes `frames[sp - 1]`, an array: each patches its row as
// `close_frame` does and counts itself into its parent, while the parent is an array the next `]` closes.
// Leaves the walk just past a close with that close not yet counted into its parent, as `close_frame` does.
@(private = "file")
close_run :: #force_no_inline proc(src: []byte, pos: u64, frames: [^]Open_Frame, sp: u64, base: [^]c.Row, rows: int) -> (pos_after, sp_after: u64) {
	n := u64(len(src))
	pos, depth := pos, sp
	// A close inside the run counts into the frame the next close pops, so it rides along to that row
	// instead of being stored into a frame about to die.
	carry: u64
	#no_bounds_check for {
		fr := &frames[depth - 1]
		pos += 1
		if fr.row != c.NO_ROW {
			r := &base[fr.row]
			r.hi = u32(pos)
			r.subtree_size = u32(rows) - fr.row
			r.cnt = u32(fr.members + carry)
		}
		depth -= 1
		if depth == 0 || pos >= n || src[pos] != ']' {
			break
		}
		parent := &frames[depth - 1]
		if parent.is_obj {
			break
		}
		carry = 1
	}
	return pos, depth
}

// How much of a value the queries read: nothing past its extent, some of its
// members, or all of it, as an answer.
@(private = "file")
Value_Use :: enum u8 {
	Unread,
	Partly,
	Whole,
}

@(private = "file")
value_use :: #force_inline proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind], sp: u64, pend: ^Demand_Pend, vc: u8) -> Value_Use {
	when .Shape in Q {
		return .Partly if q.shape.reads else .Unread
	}
	use := Value_Use.Unread
	when .Demand in Q {
		if c.demand_answers_value(sp, pend) {
			return .Whole
		}
		if vc <= VC_ARRAY && c.demand_reaches_into(q, Q, sp) {
			use = .Partly
		}
	}
	when .Path in Q {
		if c.path_answers_member(q, int(sp) - 1) {
			return .Whole
		}
		if vc <= VC_ARRAY && c.path_reaches_into(q, int(sp) - 1) {
			use = .Partly
		}
	}
	return use
}

// Consume the closing bracket and record the container.
@(private = "file")
close_frame :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	fr: ^Open_Frame,
	idx: u64,
	pend: ^Demand_Pend,
	$may_stop: bool,
	stopped: ^bool,
) {
	s.pos += 1
	// The `.Nodes` row was written at the open, with its key. This patches it.
	dom_container_close(q, Q, fr, s.pos, fr.members)
	when .Path in Q {
		// Two transitions. `frames[idx]` was a member of `frames[idx-1]` at step `idx-1`, so unless it is
		// the root its extent is final here: the answer a terminal step was waiting for. It was also read
		// at step `idx`, so its close settles the miss, resolves a negative `Index` and, at the root,
		// flushes the `.Last` slots.
		//
		// No stop test: callers check `stopped` right after, and a re-entry inside `auto_frame_closed`
		// carries its own halt flag.
		if idx >= 1 {
			auto_member_closed(q, Q, may_stop, stopped, int(idx) - 1, fr.lo, s.pos)
		}
		auto_frame_closed(s, q, Q, may_stop, stopped, int(idx), fr.lo, s.pos)
	}
	when .Demand in Q {
		// The root is nobody's member.
		if idx != 0 {
			c.demand_value_closed(s, q, Q, idx, pend, may_stop, stopped)
		}
	}
	when .Unique in Q {
		key_set_close(q.keys, u32(idx + 1))
	} else when .Path in Q {
		if q.wild_keys {
			wild_close(q, u32(idx + 1))
		}
	}
}

// A key and its colon, skipping whitespace around each. A missing key faults at the byte that cannot
// start one, a missing colon at the byte that cannot be one. `next` is the byte the value starts with.
@(private = "file")
object_key :: #force_inline proc(
	s: ^Scanner,
	cur: ^$C,
	q: ^Query_Ctx,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	sp: u64,
	// The enclosing object's frame: its `lo` names the object a demand row belongs to.
	owner: ^Open_Frame,
	pend: ^Demand_Pend,
) -> (next: int, err: Maybe(Error)) {
	if lex.peek(s) != '"' {
		when C == Byte_Cursor && .Nodes in Q {
			lex.skip_indent(s)
		}
		cursor_skip(s, cur)
		if at := lex.peek(s); at != '"' {
			if at == -1 {
				return -1, Error{offset = s.pos, kind = .Truncated}
			}
			return -1, Error{offset = s.pos, kind = .Bad_Char}
		}
	}
	key_lo := s.pos
	// The key's parse records whether its text carried an escape, so no consumer rescans the key.
	when Q & lex.KEY_ESC_KINDS != {} {
		q.key_esc_live = true
		q.key_saw_escape = false
	}
	perr: Maybe(Error)
	known := false
	when Q <= EXTENT_ONLY {
		known = cursor_string_known(s, cur, check, Q, true)
	}
	if !known {
		when check == .Values {
			perr = lex.parse_string_q(s, q, key_lo, true, Q)
		} else {
			perr = lex.skip_string_q(s, q, key_lo, true, Q)
		}
		cursor_advance(cur)
	}
	when Q & lex.KEY_ESC_KINDS != {} {
		q.key_esc_live = false
	}
	if perr != nil {
		return -1, perr
	}
	when Q & lex.KEY_ESC_KINDS != {} {
		key_hi := s.pos
		// Latched before the colon is consumed. The next row written is the member value's, so the two
		// spans and the escape bit have one candidate row. `emit_node` consumes all three together.
		when .Nodes in Q {
			q.node_key_lo = key_lo
			q.node_key_hi = key_hi
			q.node_key_escaped = q.key_saw_escape
		}
		next, err = expect_colon(s, cur, Q)
		if err != nil {
			return
		}
		when .Shape in Q {
			if serr := shape_key(s, q, key_lo, key_hi, sp, .Unique in Q); serr != nil {
				return -1, serr
			}
		} else when .Unique in Q {
			if uerr := walk_key_unique(q, s.src, key_lo, key_hi, sp); uerr != nil {
				return -1, uerr
			}
		}
		when .Demand in Q {
			// Bound now, resolved when the value closes (half the answer is its extent). `owner.lo` names
			// the object an appended row belongs to.
			c.demand_key(q, Q, key_lo, key_hi, s.pos, sp, owner.lo, pend)
		}
		when .Path in Q {
			// `sp` is the object's frame index, so the step that reads its members is `sp - 1`.
			if auto_key(s, q, Q, int(sp) - 1, key_lo, key_hi) {
				wild_key(q, s.src, key_lo, key_hi, sp)
			}
		}
	} else {
		next, err = expect_colon(s, cur, Q)
	}
	return
}

// The colon between a key and its value, and the whitespace around it. A missing colon is Truncated at end
// of input and Bad_Char otherwise. `next` is the byte after the whitespace.
@(private = "file")
expect_colon :: #force_inline proc(s: ^Scanner, cur: ^$C, $Q: bit_set[Walk_Kind]) -> (next: int, err: Maybe(Error)) {
	// Fast path for a colon flush against its value, as in a compact document: `s.pos + 1 < n` keeps the
	// next byte in bounds and a byte above 0x20 is not whitespace. Every other shape falls through, which
	// keeps the error offsets unchanged. A JSONC `/` there may open a comment, so that walk skips it.
	when C != Jsonc_Cursor {
		#no_bounds_check {
			n := u64(len(s.src))
			if s.pos + 1 < n && s.src[s.pos] == ':' {
				after := s.src[s.pos + 1]
				if after > ' ' {
					s.pos += 1
					cursor_advance(cur)
					return int(after), nil
				}
				// A pretty printer's `": "`.
				when C == Byte_Cursor && .Nodes in Q {
					if after == ' ' && s.pos + 2 < n {
						after = s.src[s.pos + 2]
						if after > ' ' {
							s.pos += 2
							cursor_advance(cur)
							return int(after), nil
						}
					}
				}
			}
		}
	}
	cursor_skip(s, cur)
	if lex.peek(s) != ':' {
		if lex.peek(s) == -1 {
			return -1, Error{offset = s.pos, kind = .Truncated}
		}
		return -1, Error{offset = s.pos, kind = .Bad_Char}
	}
	s.pos += 1
	cursor_advance(cur)
	return cursor_skip_peek(s, cur), nil
}

// A comma and then a number start: the next element of a compact array of numbers.
@(private = "file")
number_follows :: #force_inline proc(s: ^Scanner) -> bool {
	#no_bounds_check {
		if s.pos + 1 >= u64(len(s.src)) || s.src[s.pos] != ',' {
			return false
		}
		b := s.src[s.pos + 1]
		return b - '0' <= 9 || b == '-'
	}
}

// `cursor_skip_peek` where a pretty printer puts a newline and an indent: the byte cursor passes the indent
// two spaces a step first (`lex.skip_indent`). Only the row-writing walks do, as with `": "` in `expect_colon`
// and the indent before a key in `object_key`: in the other walks the extra code adds instructions to every
// compact input.
@(private = "file")
indent_skip_peek :: #force_inline proc(s: ^Scanner, cur: ^$C, $Q: bit_set[Walk_Kind]) -> int {
	when C == Byte_Cursor && .Nodes in Q {
		#no_bounds_check {
			if s.pos < u64(len(s.src)) {
				b := s.src[s.pos]
				if b > ' ' {
					return int(b)
				}
				if b == '\n' {
					lex.skip_indent(s)
				}
			}
		}
	}
	return cursor_skip_peek(s, cur)
}
