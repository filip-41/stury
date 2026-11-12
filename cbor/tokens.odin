package cbor

// The token write of CBOR. An open container's head is one byte held in the output, patched at the close once its
// count is known, and a count of 24 or more moves the container's bytes right to widen it. A deterministic write, or
// one that sorts keys, sorts a map's members by their encoded keys at the close. A write to a stream that must flush
// while a container is open writes every open container indefinite, which only `.Cbor` with unsorted keys allows, and is
// `.Unsupported` otherwise.

import "core:slice"
import core "../core"
import typed "../core/typed"
import write "../core/write"

@(private)
Token_State :: struct {
	enc:      Spec,
	sorted:   bool, // a map's members follow their encoded keys
	stream:   bool, // the output flushes to a stream
	key_next: bool, // the next string is a key
	definite: int, // the open containers whose heads are held in the output
	levels:   [core.MAX_DEPTH]Level,
	keys:     [dynamic]int, // the offsets of the keys of the open sorted maps, each level's from its `first_key`
}

// An open container: where its head is held, or -1 once it is indefinite, and how many items or members it holds.
@(private)
Level :: struct {
	head:      int,
	count:     u64,
	first_key: int,
}

// The room a stream keeps past an item for the widest head patch.
@(private)
PATCH_ROOM :: 8

@(private, rodata)
TOKENS := write.Token_Spelling {
	tree = TREE,
	start = proc(t: ^write.Tokens, as: core.As) -> core.Typed_Error_Kind {
		s, failed := new(Token_State, t.base.allocator)
		if failed != nil {
			return .No_Memory
		}
		s.enc = Spec(as.spec)
		s.sorted = s.enc >= .Deterministic || t.opts.sort_keys
		s.stream = t.out.stream.procedure != nil
		s.keys.allocator = t.base.allocator
		t.state = s
		if s.stream {
			write.room(t.out, 1)
		}
		return t.out.err
	},
	value = token_value,
	layout = token_layout,
	record = proc(t: ^write.Tokens, plan: ^typed.Plan, value: rawptr, err: ^core.Typed_Refusal) -> core.Typed_Error_Kind {
		return write.marshal_binary_into(t.out, plan, value, write_options(t.opts, plan.as), nil, binary_options(plan.as), err, TREE, put_string)
	},
	stop = proc(t: ^write.Tokens) {
		if s := (^Token_State)(t.state); s != nil {
			delete(s.keys)
			free(s, t.base.allocator)
			t.state = nil
		}
	},
}

@(private)
token_value :: proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
	s := (^Token_State)(t.state)
	if s.key_next {
		s.key_next = false
	} else {
		item(t, s)
	}
	need := PATCH_ROOM + 9
	#partial switch x in v {
	case string:
		need += len(x)
	case typed.Bytes:
		need += len(x)
	case write.Number_Literal:
		need += 2 * len(x.text)
	case write.Tagged_Text:
		need += len(x.text)
	}
	held(t, s, need, t.top) or_return
	out := t.out
	switch x in v {
	case string:
		return put_long_string(out, x)
	case write.Tagged_Text:
		return put_long_string(out, x.text)
	case typed.Bytes:
		out.cursor += write.put_head(write.room(out, 9), u64(len(x)), TREE, .Bytes)
		write.put_text(out, string(x))
	case core.Number:
		if x.kind == .Float && s.enc >= .Deterministic && x.bits & (1 << 63 - 1) > 0x7ff0000000000000 {
			write.put_text(out, DEFAULT_NAN)
			return .None
		}
		return write.put_binary_number(out, x, TREE)
	case write.Number_Literal:
		if len(x.text) == 0 {
			return .Bad_Raw
		}
		return write.put_binary_number_text(out, x.text, TREE)
	case write.Tree_Part:
		tree := TREE
		write.put_text(out, tree[x])
	}
	return .None
}

@(private)
token_layout :: proc(t: ^write.Tokens, step: write.Layout_Step) -> core.Typed_Error_Kind {
	s := (^Token_State)(t.state)
	switch step {
	case .Open_Object, .Open_Array:
		item(t, s)
		held(t, s, PATCH_ROOM + 1, t.top) or_return
		s.levels[t.top] = {head = t.out.cursor, first_key = len(s.keys)}
		s.definite += 1
		write.put_byte(t.out, 0xa0 if step == .Open_Object else 0x80)
	case .Key:
		at := &s.levels[t.top - 1]
		at.count += 1
		s.key_next = true
		if s.sorted && at.head >= 0 {
			if _, failed := append(&s.keys, t.out.cursor); failed != nil {
				return .No_Memory
			}
		}
	case .Close:
		return close_level(t, s, &s.levels[t.top], t.object[t.top])
	}
	return .None
}

// Counts an item of the open array, which a key has counted for an open map.
@(private)
item :: #force_inline proc(t: ^write.Tokens, s: ^Token_State) {
	if t.top > 0 && !t.object[t.top - 1] {
		s.levels[t.top - 1].count += 1
	}
}

// Keeps `need` bytes free past the cursor while a head is held. When they are not, the output must flush, and the
// `open` outermost containers are written indefinite.
@(private)
held :: proc(t: ^write.Tokens, s: ^Token_State, need, open: int) -> core.Typed_Error_Kind {
	out := t.out
	if !s.stream || s.definite == 0 || out.size - out.cursor >= need {
		return .None
	}
	if s.enc != .Cbor || s.sorted {
		return .Unsupported
	}
	for &l in s.levels[:open] {
		if l.head >= 0 {
			out.buf[l.head] |= 0x1f
			l.head = -1
		}
	}
	s.definite = 0
	return .None
}

@(private)
close_level :: proc(t: ^write.Tokens, s: ^Token_State, l: ^Level, object: bool) -> core.Typed_Error_Kind {
	out := t.out
	if l.count >= 24 && l.head >= 0 {
		held(t, s, PATCH_ROOM, t.top + 1) or_return
	}
	if l.head < 0 {
		write.put_byte(out, 0xff)
		return out.err
	}
	s.definite -= 1
	if object && s.sorted {
		defer resize(&s.keys, l.first_key)
		if l.count > 1 {
			sort_members(out, s.keys[l.first_key:], l.head + 1, s.enc) or_return
		}
	}
	if l.count < 24 {
		out.buf[l.head] |= u8(l.count)
		return out.err
	}
	var: [9]u8
	n := write.put_head(raw_data(var[:]), l.count, TREE, .Map) if object else write.put_head(raw_data(var[:]), l.count, TREE, .Array)
	write.room(out, n - 1)
	if out.err != .None {
		return out.err
	}
	body := out.buf[l.head + 1:out.cursor]
	copy(out.buf[l.head + n:out.cursor + n - 1], body)
	copy(out.buf[l.head:l.head + n], var[:n])
	out.cursor += n - 1
	return .None
}

// Sorts the members of the map whose body starts at `first`, its keys at `keys`, by their encoded keys, length first
// under `.Length_First`. A key two members write alike is `.Unwritable`.
@(private)
sort_members :: proc(out: ^write.Out, keys: []int, first: int, enc: Spec) -> core.Typed_Error_Kind {
	Member :: struct {
		lo, key, hi: int,
	}
	members, failed := make([]Member, len(keys), context.temp_allocator)
	if failed != nil {
		return .No_Memory
	}
	defer delete(members, context.temp_allocator)
	buf := out.buf[:out.cursor]
	for at, i in keys {
		hi := keys[i + 1] if i + 1 < len(keys) else out.cursor
		members[i] = {lo = at, key = at + key_length(buf[at:]), hi = hi}
	}
	Sorter :: struct {
		buf:          []u8,
		length_first: bool,
	}
	context.user_ptr = &Sorter{buf, enc == .Length_First}
	slice.sort_by(members, proc(a, b: Member) -> bool {
		s := (^Sorter)(context.user_ptr)
		x, y := string(s.buf[a.lo:a.key]), string(s.buf[b.lo:b.key])
		if s.length_first && len(x) != len(y) {
			return len(x) < len(y)
		}
		return x < y
	})
	for m, i in members[1:] {
		if string(buf[m.lo:m.key]) == string(buf[members[i].lo:members[i].key]) {
			return .Unwritable
		}
	}
	sorted, no_room := make([]u8, out.cursor - first, context.temp_allocator)
	if no_room != nil {
		return .No_Memory
	}
	defer delete(sorted, context.temp_allocator)
	w := 0
	for m in members {
		w += copy(sorted[w:], buf[m.lo:m.hi])
	}
	copy(buf[first:], sorted)
	return .None
}

// The length of the text string head and bytes at the start of `b`, a key the token write wrote.
@(private)
key_length :: proc(b: []u8) -> int {
	_, n, size := head_of(b)
	return size + int(n)
}
