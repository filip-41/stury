package scan

// The two walks, monomorphized on the check level from one body each.
//
// Values (strict, RFC 8259) checks grammar: nesting, string boundaries and
// escapes, literals, number extents, the scalar caps. Locate does not check
// grammar. Framing, wire UTF-8 and the depth cap still bind. No Bad_Escape,
// Bad_Number or a literal's Bad_Char comes out of Locate.
//
// The walk is iterative over a fixed `Open_Frame[MAX_DEPTH]` stack array, so the depth cap bounds its
// memory. A cap raised past MAX_DEPTH moves the frames to the heap once the input nests past MAX_DEPTH.
// Every Values-ok input is Locate-ok, and every Locate error is a Values error.

import "base:intrinsics"
import "base:runtime"
import "walk"
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

// The walk under a `limit` past MAX_DEPTH: a complete walk at `check` on the JSONC cursor (JSON's grammar
// when `cur.json`) that never skips and never stops, on frames that spill to the scanner's allocator at the
// first push past MAX_DEPTH and double there as the input nests deeper, freed here with the same one. Only two
// readings reach it: `.Locate` for `.Structural` (a raised cap is a depth limit, not a grammar switch) and
// `.Values` for the rest, so `.Lazy` loses its early stop and its skips past MAX_DEPTH. A raised cap is the
// rare reading, so one instance per query kind reads either level, and a `{.Path}` walk is stop-capable
// whether or not the caller passes `stopped`. Its scalar leaves are out-of-line instances shared per leaf
// class (`DEEP_LEAF`).
walk_deep :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	limit: u64,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	cur: ^Dialect_Cursor($G),
	$may_stop: bool,
	stopped: ^bool,
) -> Maybe(Error) {
	#assert(!may_stop || Q == {.Path}, "only a path walk stops")
	return walk_deep_at(s, q, limit, check == .Locate, Q, cur, stopped)
}

@(optimization_mode = "favor_size", private = "file")
walk_deep_at :: #force_no_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	limit: u64,
	locate: bool,
	$Q: bit_set[Walk_Kind],
	cur: ^Dialect_Cursor($G),
	stopped: ^bool,
) -> Maybe(Error) {
	#assert(.Shape not_in Q, "the shape walk holds its cap to MAX_DEPTH")
	deep := Deep_State{locate = locate}
	err := walk_frames(s, q, limit, .Values, Q, cur, false, Q == {.Path}, stopped, true, &deep.spill)
	if deep.spill != nil {
		runtime.mem_free(raw_data(deep.spill), s.alloc)
	}
	return err
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
	// The grammar the walk reads: empty but on a dialect cursor (`Dialect_Cursor`).
	G :: intrinsics.type_polymorphic_record_parameter_value(C, 0) when intrinsics.type_is_specialization_of(C, Dialect_Cursor) else Grammar{}
	when .Json5_Scalars in G {
		#assert(.Shape not_in Q, "a JSON5 text is unmarshalled through its JSON spelling")
	}
	when deep {
		DEEP_LEAF :: (Q & {.Nodes, .Dom}) when Q & {.Nodes, .Dom} != {} else (bit_set[Walk_Kind]{.Path} when Q != {} else bit_set[Walk_Kind]{})
	}
	// Q is only the kinds that touch a value through its row (`.Nodes`, `.Dom`), nothing else at its start or
	// end, on a walk that visits every value.
	BYTES :: C == Byte_Cursor || C == Pretty_Cursor
	NUMBER_RUN :: .Dom in Q && Q <= {.Nodes, .Dom} && BYTES && !may_skip
	// The same walks, row-writing, take long bracket runs out of line (`open_run`, `close_run`).
	BRACKET_RUNS :: .Nodes in Q && Q <= {.Nodes, .Dom} && BYTES && !may_skip && !deep
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
			when .Json5_Scalars in G {
				if vc == VC_NONE {
					vc = json5_class(b)
				}
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
						if cursor_skip_value(s, cur, vc, int(max_depth - sp), check) {
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
			when Q == {.Path} && BYTES && !may_skip {
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
					walk.demand_wild_open(q, Q, sp, vc)
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
						walk.dom_run_open(q, Q, fr2, fr2.lo, &run_rows)
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
				skip_peek_open := indent_skip_peek(s, cur, Q, .Open)
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
				when .Shape in Q && BYTES && !may_skip {
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
					when .Shape in Q && BYTES && !may_skip {
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
					when Q - {.Gate} == MEMBER_RUN_KINDS && !BYTES && may_skip {
						if sp <= whole_sp {
							switch take_members(s, cur, q, Q, check, sp, fr.lo, &demand_pend, int(max_depth - sp), stopped) {
							case .Key:
							case .Value:
								b = lex.peek(s)
								continue descend
							case .After:
								break descend
							}
						}
					}
					next, err := object_key(s, cur, q, check, Q, sp, fr, &demand_pend, (^Deep_State)(spill))
					if err != nil {
						return err
					}
					b = next
				}
				continue descend // the member value this level opened onto
			case VC_STRING:
				when .Json5_Scalars in G {
					if err := json5_string(s, q, lo, false, Q); err != nil {
						return err
					}
					emit_scalar(q, Q, lo, s.pos, .String)
				} else when deep {
					// The dialect cursor knows no extent, and no shape reads here.
					if err := deep_string(s, q, lo, false, DEEP_LEAF, deep_locate(spill)); err != nil {
						return err
					}
					emit_scalar(q, Q, lo, s.pos, .String)
				} else {
					if err := walk_string(s, q, cur, check, Q, lo, sp); err != nil {
						return err
					}
				}
			case VC_LITERAL: // true / false / null
				when deep {
					if err := deep_literal(s, q, lo, DEEP_LEAF, deep_locate(spill)); err != nil {
						return err
					}
				} else {
					if err := walk_literal(s, q, cur, check, Q, lo, sp); err != nil {
						return err
					}
				}
			case VC_NUMBER:
				known := false
				when .Json5_Scalars in G {
					if err := json5_number(s, q, lo, Q); err != nil {
						return err
					}
					known = true
				}
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
					} else when deep {
						if err := deep_number(s, q, lo, DEEP_LEAF, deep_locate(spill)); err != nil {
							return err
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
				c = indent_skip_peek(s, cur, Q, .Close)
			}
			if c == ',' {
				s.pos += 1
				cursor_advance(cur)
				// Only a dialect walk compiles this arm. The deep walk's strict JSON, on a dialect cursor with
				// `cur.json`, takes it too and refuses the trailing comma.
				when .Trailing_Commas in G {
					// Tested second: only a comma before the closer reads the grammar.
					if cursor_skip_peek(s, cur) != closer || cur.json {
						if closer == ']' {
							b = lex.peek(s)
						} else {
							next, err := object_key(s, cur, q, check, Q, sp, top, &demand_pend, (^Deep_State)(spill))
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
						b = indent_skip_peek(s, cur, Q, .Member)
						when .Shape in Q && BYTES && !may_skip {
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
						when .Shape in Q && BYTES && !may_skip {
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
						when Q - {.Gate} == MEMBER_RUN_KINDS && !BYTES && may_skip {
							cursor_skip(s, cur)
							if sp <= whole_sp {
								switch take_members(s, cur, q, Q, check, sp, top.lo, &demand_pend, int(max_depth - sp), stopped) {
								case .Key:
								case .Value:
									b = lex.peek(s)
									continue outer
								case .After:
									continue
								}
							}
						}
						next, err := object_key(s, cur, q, check, Q, sp, top, &demand_pend, (^Deep_State)(spill))
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

// The string at `s.pos`, as a value of the walk. A string whose extent the cursor already knows is passed
// without its leaf.
@(private = "file")
walk_string :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, cur: ^$C, $check: Check_Level, $Q: bit_set[Walk_Kind], lo, sp: u64) -> Maybe(Error) {
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
	return nil
}

@(private = "file")
walk_literal :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, cur: ^$C, $check: Check_Level, $Q: bit_set[Walk_Kind], lo, sp: u64) -> Maybe(Error) {
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
	return nil
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
		if walk.demand_answers_value(sp, pend) {
			return .Whole
		}
		if vc <= VC_ARRAY && walk.demand_reaches_into(q, Q, sp) {
			use = .Partly
		}
	}
	when .Path in Q {
		if walk.path_answers_member(q, int(sp) - 1) {
			return .Whole
		}
		if vc <= VC_ARRAY && walk.path_reaches_into(q, int(sp) - 1) {
			use = .Partly
		}
	}
	return use
}

// What the deep walk keeps beside its frames: the heap array they spill to (`spill_frames`, which the walk
// holds by its first field), and whether its leaves check no grammar (`.Locate`; `$check` is `.Values` there).
@(private)
Deep_State :: struct {
	spill:  []byte,
	locate: bool,
}

@(private = "file")
deep_locate :: #force_inline proc(spill: ^[]byte) -> bool {
	return (^Deep_State)(spill).locate
}

// The deep walk's scalar leaves, out of line and generic over what they read of `Q`: whether they write rows
// (`.Nodes`, `.Dom`) and whether they latch a key's escape. Queries of every other kind share one instance of
// each. `DEEP_LEAF` is that class, written as a constant expression where it is used because Odin has no
// constant call.
@(private, optimization_mode = "favor_size")
deep_string :: #force_no_inline proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, key: bool, $Q: bit_set[Walk_Kind], locate: bool) -> Maybe(Error) {
	if locate {
		return lex.skip_string_q(s, q, lo, key, Q)
	}
	return lex.parse_string_q(s, q, lo, key, Q)
}

@(private = "file", optimization_mode = "favor_size")
deep_literal :: #force_no_inline proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, $Q: bit_set[Walk_Kind], locate: bool) -> Maybe(Error) {
	if locate {
		return lex.skip_alpha_q(s, q, lo, Q)
	}
	return lex.parse_literal_q(s, q, lo, Q)
}

@(private = "file", optimization_mode = "favor_size")
deep_number :: #force_no_inline proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, $Q: bit_set[Walk_Kind], locate: bool) -> Maybe(Error) {
	if locate {
		return number.skip_number_q(s, q, lo, Q)
	}
	return number.parse_number_q(s, q, lo, Q)
}
