package build

import "base:runtime"
import "stury:lib/core/tape"

// The framing of the records at a path under `.Elements` and `.Members`, which every format whose records are the
// children of a container shares: down `Records.path` to the container whose children are the records, each of them,
// then what follows to the text's end. A format gives its grammar as four steps at `Records.pos`, and the framing holds
// the containers it is in and the order of the steps. In a text in pieces a step whose bytes the window does not hold
// whole waits, and the next window takes it again from where it started, so a step's bytes are read once a window holds
// them.

// The containers a framing holds in place. More are held in memory `frame_init` takes from the context's allocator.
@(private)
FRAME_ROOM :: 8

// What the framing holds of each container it is in, the first field of a format's own.
Frame_Level :: struct {
	passed:  u64, // the children read
	taken:   bool, // a member of the key of the path's `Name` step was taken
	object:  bool, // the container is an object
	// The container is a value off the path that a window cut, passed a child at a time so that the next window reads
	// again only the child it cuts.
	passing: bool,
}

// What a step of a format's grammar gives.
Frame_Step :: enum u8 {
	Done,
	Other, // `open` met a value that is no container of the kind asked, or one it leaves to `pass` to judge
	End, // `child` met the container's close
	Wait, // in a text in pieces, the window ends inside the step, which the next window takes again
	Fault, // the text fails in the step, and `Records.err` says how
}

@(private)
Frame_Stage :: enum u8 {
	Open, // the value at `pos`, which the path takes
	Child, // the next child of a container of the path, or its close
	Pass, // the value at `pos` of a child the path does not take
	Records, // the next child of the records' container, or its close
	Tail, // what follows the root
}

// The framing of a format whose containers hold `L`.
Frame :: struct($L: typeid) {
	room:      [FRAME_ROOM]L,
	more:      []L, // the containers past the room
	allocator: runtime.Allocator, // what `more` is in
	from:      u64, // where the step of the last record given started
	depth:     int, // the containers open
	stage:     Frame_Stage,
	record:    bool, // the last step gave the record at `from`
	given:     bool, // a record was given
	pending:   bool, // under `.Last`, the value the path reached last is no container of the framing's kind
}

// Readies `f` for the records at `path`, taking memory from the context's allocator for a path past `FRAME_ROOM`
// steps, and in a text in pieces for the containers of a value a window cuts past the room, which `frame_free` frees.
frame_init :: proc(f: ^Frame($L), path: []tape.Step) -> runtime.Allocator_Error {
	f.allocator = context.allocator
	return frame_room(f, len(path))
}

frame_free :: proc(f: ^Frame($L)) {
	if f.more != nil {
		delete(f.more, f.allocator)
		f.more = nil
	}
}

// The container `k` levels deep, the root's at 0, the records' at `len(path)`.
frame_level :: #force_inline proc "contextless" (f: ^Frame($L), k: int) -> ^L {
	return &f.more[k] if f.more != nil else &f.room[k]
}

// Readies the room of `f` for a container `k` levels deep.
@(private)
frame_room :: proc(f: ^Frame($L), k: int) -> runtime.Allocator_Error {
	held := len(f.more) if f.more != nil else FRAME_ROOM
	if k < held {
		return nil
	}
	more := make([]L, max(2 * held, k + 1), f.allocator) or_return
	copy(more, f.more if f.more != nil else f.room[:])
	delete(f.more, f.allocator)
	f.more = more
	return nil
}

// Under `.Elements` and `.Members`, the next record's first byte, past its key under `.Members`, whose token is in
// `r.key`. False once the records have ended, with `r.err` saying why, nil at the text's end, or in a text in pieces
// once the window holds no more. The value the path reaches holds the records when it is a container of the
// framing's kind, and the path's steps take members under the read's policy as `Records.path` says. A text with no
// such value holds no records and is judged to its end, and a value of another kind ends the records with the refusal
// `records_path_refused` names. Every value off the path is judged, as `validate` judges it, each within `Budget`
// with memory from `allocator`, and in a text in pieces a container off the path that the window cuts is passed a
// child at a time, as a container of the path is.
//
// A format's grammar: `open` the container of kind `object` at `pos`, the value of a child of `outer`, `depth`
// containers deep, into `lv` and past its head, else `.Other` with `pos` kept. `child` of `lv`, which is an object for
// `object`: the next child's value's first byte, past its key under an object, or `.End` with the first byte past the
// container. `pass` the value at `pos` in `outer`, `depth` containers deep. `tail`: the rest of the text past the root,
// `.Done` at its end. A step that gives `.Done` or `.End` moves `pos` past what it read, but `child`, which leaves it.
// The child of the records' container that `child` reads stays unread in `lv` until the record's walk moves `pos` past
// it, as a record the window cuts is read again whole in the next.
frame_path :: #force_inline proc(r: ^$R, f: ^Frame($L), format: ^tape.Format, rules: ^tape.Rules, allocator: runtime.Allocator, $open: proc(r: ^R, outer, lv: ^L, object: bool, depth: u64) -> Frame_Step, $child: proc(r: ^R, lv: ^L, object: bool) -> (u64, Frame_Step), $pass: proc(r: ^R, outer: ^L, depth: u64, allocator: runtime.Allocator) -> Frame_Step, $tail: proc(r: ^R) -> Frame_Step) -> (lo: u64, ok: bool) {
	for r.at != .Done {
		if f.stage != .Records {
			frame_steps(r, f, format, rules, allocator, open, child, pass, tail) or_return
		}
		lv := frame_level(f, f.depth - 1)
		// The record the last step gave was read once its walk moved `pos`, and one that waited is read again from
		// where its step started.
		if f.record && r.pos != f.from {
			lv.passed += 1
		}
		f.record, f.from = false, r.pos
		at, s := child(r, lv, lv.object)
		if s == .Done {
			f.record, f.given = true, true
			return at, true
		}
		if s != .End {
			frame_stepped(r, s)
			return
		}
		r.pos = at
		f.depth -= 1
		frame_up(r, f) or_return
	}
	return
}

// The steps of `frame_path` outside the records' container, up to it. False once the records have ended, or in a text
// in pieces once the window holds no more.
@(private)
frame_steps :: proc(r: ^$R, f: ^Frame($L), format: ^tape.Format, rules: ^tape.Rules, allocator: runtime.Allocator, $open: proc(r: ^R, outer, lv: ^L, object: bool, depth: u64) -> Frame_Step, $child: proc(r: ^R, lv: ^L, object: bool) -> (u64, Frame_Step), $pass: proc(r: ^R, outer: ^L, depth: u64, allocator: runtime.Allocator) -> Frame_Step, $tail: proc(r: ^R) -> Frame_Step) -> bool {
	if r.at == .Start {
		r.at = .Open
	}
	dups := format.dups if r.opts.dups == .Default else r.opts.dups
	if dups == .Refuse {
		dups = .Last
	}
	last := len(r.path)
	root: L
	for {
		k := f.depth
		switch f.stage {
		case .Open:
			outer := frame_level(f, k - 1) if k > 0 else &root
			lv := frame_level(f, k)
			lv^ = {object = frame_object(r, k)}
			switch open(r, outer, lv, lv.object, u64(k)) {
			case .Done:
				f.depth += 1
				if k == last {
					f.stage = .Records
					return true
				}
				f.stage = .Child
			case .Other:
				s := pass(r, outer, u64(k), allocator)
				if s == .Wait && k > 0 && (k < last || dups == .Last) {
					// The path does not reach this value, or under `.Last` a later member of its key may take its place.
					frame_pass_cut(r, f, k, open, !lv.object) or_return
					f.pending = f.pending || k == last
					continue
				}
				frame_stepped(r, s) or_return
				if k == last {
					if dups != .Last {
						records_stop(r, records_kind_refusal())
						return false
					}
					f.pending = true
				}
				frame_up(r, f) or_return
			case .Wait:
				return false
			case .End, .Fault:
				r.at = .Done
				return false
			}
		case .Child:
			lv := frame_level(f, k - 1)
			at, s := child(r, lv, lv.object)
			#partial switch s {
			case .Done:
				lv.passed += 1
				r.pos = at
				if lv.passing {
					r.key, f.stage = {}, .Pass
				} else {
					frame_take(r, f, lv, k - 1, dups, format, rules) or_return
				}
			case .End:
				r.pos = at
				f.depth -= 1
				frame_up(r, f) or_return
			case:
				frame_stepped(r, s)
				return false
			}
		case .Pass:
			s := pass(r, frame_level(f, k - 1), u64(k), allocator)
			if s == .Wait {
				frame_pass_cut(r, f, k, open) or_return
				continue
			}
			frame_stepped(r, s) or_return
			f.stage = .Child
		case .Tail:
			frame_stepped(r, tail(r)) or_return
			r.key, r.at = {}, .Done
			return false
		case .Records:
			return true
		}
	}
}

// Opens the container at `pos`, `k` levels deep, whose value the window cuts, to pass it a child at a time, which
// the next step goes on with, an object or an array, or only of kind `object` when it is set. False while it is no
// such container the window holds the head of, which the next window passes again from its start.
@(private)
frame_pass_cut :: proc(r: ^$R, f: ^Frame($L), k: int, $open: proc(r: ^R, outer, lv: ^L, object: bool, depth: u64) -> Frame_Step, only: Maybe(bool) = nil) -> bool {
	if err := frame_room(f, k); err != nil {
		records_stop(r, err)
		return false
	}
	outer, lv := frame_level(f, k - 1), frame_level(f, k)
	for object in ([2]bool{true, false}) {
		if kind, one := only.?; one && kind != object {
			continue
		}
		lv^ = {object = object, passing = true}
		if open(r, outer, lv, object, u64(k)) == .Done {
			f.depth += 1
			f.stage = .Child
			return true
		}
	}
	return false
}

// Whether the container `k` levels deep is an object: one whose member a `Name` step takes, or under `.Members` the
// records'.
@(private)
frame_object :: #force_inline proc "contextless" (r: ^tape.Records, k: int) -> bool {
	if k < len(r.path) {
		_, named := r.path[k].(tape.Name)
		return named
	}
	return r.framing == .Members
}

// Whether the framing goes on after step result `s`, which ends the records at a fault.
@(private)
frame_stepped :: #force_inline proc "contextless" (r: ^tape.Records, s: Frame_Step) -> bool {
	if s == .Fault {
		r.at = .Done
	}
	return s == .Done
}

// Leaves the value the framing passed or closed for the container holding it, or past the root for the text's tail,
// which a value the path reached last of another kind is refused at under `.Last`.
@(private)
frame_up :: #force_inline proc "contextless" (r: ^tape.Records, f: ^Frame($L)) -> bool {
	if f.depth > 0 {
		f.stage = .Child
		return true
	}
	if f.pending {
		records_stop(r, records_kind_refusal())
		return false
	}
	f.stage = .Tail
	return true
}

// Whether the path takes the child of container `lv`, `k` levels deep, whose value is at `pos`: the element of its
// `Index` step, or a member of the key of its `Name` step under policy `dups`. Under `.Last` a member of the key met
// once a record was given ends the records with `.Duplicate_Key` at its key, as the records before it cannot be taken
// back.
@(private)
frame_take :: proc "contextless" (r: ^tape.Records, f: ^Frame($L), lv: ^L, k: int, dups: tape.Duplicates, format: ^tape.Format, rules: ^tape.Rules) -> bool {
	take: bool
	#partial switch s in r.path[k] {
	case tape.Name:
		if tape.key_names(format, r.src, r.key, string(s)) {
			#partial switch dups {
			case .First:
				take = !lv.taken
			case .Group:
				take = true
			case:
				if f.given {
					head, _ := format.bounds(r.src, r.key)
					records_stop(r, tape.Fault{at = r.key.lo - u64(head), rules = rules, kind = .Duplicate_Key})
					return false
				}
				take = true
			}
		}
	case tape.Index:
		take = lv.passed == u64(s) + 1
	}
	r.key = {}
	if take {
		lv.taken, f.pending, f.stage = true, false, .Open
	} else {
		f.stage = .Pass
	}
	return true
}
