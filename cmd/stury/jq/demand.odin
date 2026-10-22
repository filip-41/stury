package jq

// Which entries of a root's large array a program reads, when it reads them only by constant index and
// otherwise asks only the array's length, type or keys: `.users[0].id`, `.users | length`,
// `.users | reverse | .[0]`, `.users[2:9] | length`. The root is then run with only those entries built,
// every other one null, and gives what it gives with them all built.

// The first `head` entries and the last `tail`, and whether the program reads how many entries there are
// (`length`, `keys`, a slice): without it, the array may hold only an end's entries (`demanded_array_pieces`).
Entry_Demand :: struct {
	head, tail: int,
	counted:    bool,
}

// More entries than this are left to the whole build.
ENTRY_DEMAND_MAX :: 16

// What a filter's output is, run on part of a root whose array has entries that are not built: the root
// object holding it, the array, it reversed or sliced (so any entry is one not built), or a value with no
// unbuilt entry in it.
@(private = "file")
Shape :: enum u8 {
	Unknown, // anything else: the program reads more than `entry_demand` says
	Built,
	Spine,
	Reversed,
	Sliced,
	Root, // the root object; Root + i, the object `keys[i - 1]` of the one before
}

@(private = "file")
Demand_Walk :: struct {
	keys:   []string,
	demand: Entry_Demand,
}

// The entries `prog` reads of the array that is the root, or with `keys`, the member `keys[i]` of each object from
// the root's in. It returns false when it reads more, or outputs anything holding an entry not built.
entry_demand :: proc(prog: ^Node, keys: []string) -> (d: Entry_Demand, ok: bool) {
	w := Demand_Walk{keys = keys}
	if shape(&w, prog, .Root if len(keys) > 0 else .Spine, 0) != .Built {
		return
	}
	return w.demand, w.demand.head + w.demand.tail <= ENTRY_DEMAND_MAX
}

@(private = "file")
shape :: proc(w: ^Demand_Walk, n: ^Node, input: Shape, depth: int) -> Shape {
	if input == .Built {
		return .Built
	}
	if n == nil || input == .Unknown {
		return .Unknown
	}
	#partial switch n.kind {
	case .Identity:
		return input
	case .Literal, .Var:
		return .Built
	case .Pipe:
		return shape(w, n.b, shape(w, n.a, input, depth), depth)
	case .Field:
		t := shape(w, n.a, input, depth)
		if t == .Built {
			return .Built
		}
		if t >= .Root {
			i := int(t - .Root)
			if n.name != w.keys[i] {
				return .Built
			}
			return .Spine if i + 1 == len(w.keys) else t + Shape(1)
		}
	case .Index:
		#partial switch t := shape(w, n.a, input, depth); t {
		case .Built:
			return built(w, n.b, input, depth)
		case .Spine, .Reversed:
			i, ok := constant_index(n.b)
			if !ok {
				return .Unknown
			}
			// Entry i from the front of the array, or from its back: of the reversed array, the other end.
			from_back := (i < 0) != (t == .Reversed)
			k := -i if i < 0 else i + 1
			if from_back {
				w.demand.tail = max(w.demand.tail, k)
			} else {
				w.demand.head = max(w.demand.head, k)
			}
			return .Built
		}
	case .Slice:
		if built(w, n.b, input, depth) != .Built || built(w, n.c, input, depth) != .Built {
			return .Unknown
		}
		#partial switch shape(w, n.a, input, depth) {
		case .Built:
			return .Built
		case .Spine, .Reversed, .Sliced:
			w.demand.counted = true
			return .Sliced
		}
	case .Call:
		if len(n.args) > 0 {
			return .Unknown
		}
		if _, native := n.native.?; native {
			switch n.name {
			case "length", "keys", "keys_unsorted":
				w.demand.counted ||= input == .Spine || input == .Reversed
				return .Built
			case "type":
				return .Built
			case "reverse":
				#partial switch input {
				case .Spine:
					return .Reversed
				case .Reversed:
					return .Spine
				case .Sliced:
					return .Sliced
				}
			}
			return .Unknown
		}
		// `first`, `last` and any other definition of no parameters.
		if n.callee != nil && !n.is_param && len(n.callee.params) == 0 && depth < 8 {
			return shape(w, n.callee.body, input, depth + 1)
		}
	case .If:
		if n.c == nil {
			return .Unknown
		}
		return all_built(w, []^Node{n.a, n.b, n.c}, input, depth)
	case .Format:
		if n.a == nil {
			return .Unknown
		}
		return built(w, n.a, input, depth)
	case .Comma, .Binary, .And, .Or, .Alt, .Neg:
		return all_built(w, []^Node{n.a, n.b}, input, depth)
	case .Array:
		return built(w, n.a, input, depth)
	case .String:
		return all_built(w, n.args, input, depth)
	case .Object:
		for e in n.args {
			if e == nil || built(w, e, input, depth) != .Built {
				return .Unknown
			}
		}
		return .Built
	}
	return .Unknown
}

// Built when `n` is absent, or gives only values with no entry not built.
@(private = "file")
built :: proc(w: ^Demand_Walk, n: ^Node, input: Shape, depth: int) -> Shape {
	if n == nil {
		return .Built
	}
	return .Built if shape(w, n, input, depth) == .Built else .Unknown
}

@(private = "file")
all_built :: proc(w: ^Demand_Walk, nodes: []^Node, input: Shape, depth: int) -> Shape {
	for c in nodes {
		if built(w, c, input, depth) != .Built {
			return .Unknown
		}
	}
	return .Built
}

// The whole number `n` is, written as a literal or a negated one, within the entries a demand builds.
@(private = "file")
constant_index :: proc(n: ^Node) -> (i: int, ok: bool) {
	if n == nil {
		return
	}
	if n.kind == .Neg {
		i = constant_index(n.a) or_return
		return -i, true
	}
	if n.kind != .Literal {
		return
	}
	x := number_of(n.value) or_return
	if x.f != f64(int(x.f)) || abs(x.f) > ENTRY_DEMAND_MAX {
		return
	}
	return int(x.f), true
}
