package testkit

import "base:runtime"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "stury:lib/ops/typed"
import "stury:lib/core/tape"

// The typed read law: a read of a text into a value gives what the text's build converts to, and a text the build
// refuses is refused alike.

// A value of any shape and depth, which a typed read of any format takes.
Value :: union {
	bool,
	f64,
	string,
	Value_List,
	Value_Table,
}
Value_List :: distinct [dynamic]Value
Value_Table :: distinct map[string]Value

// Frees a `Value` a typed read made in `allocator`, with no recursion, so that a value of any depth frees on a small
// stack.
value_free :: proc(v: Value, allocator := context.allocator) {
	context.allocator = allocator
	pending := make([dynamic]Value)
	defer delete(pending)
	append(&pending, v)
	for len(pending) > 0 {
		switch x in pop(&pending) {
		case Value_List:
			append(&pending, ..x[:])
			delete(x)
		case Value_Table:
			for k, e in x {
				delete(k)
				append(&pending, e)
			}
			delete(x)
		case string:
			delete(x)
		case bool, f64:
		}
	}
}

// Whether two values are the same: numbers by their bits, tables by their entries.
values_equal :: proc(a, b: Value) -> bool {
	switch x in a {
	case nil:
		return b == nil
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case f64:
		y, ok := b.(f64)
		return ok && (transmute(u64)x == transmute(u64)y || math.is_nan(x) && math.is_nan(y))
	case string:
		y, ok := b.(string)
		return ok && x == y
	case Value_List:
		y, ok := b.(Value_List)
		if !ok || len(x) != len(y) {
			return false
		}
		for e, i in x {
			if !values_equal(e, y[i]) {
				return false
			}
		}
		return true
	case Value_Table:
		y, ok := b.(Value_Table)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, e in x {
			f, found := y[k]
			if !found || !values_equal(e, f) {
				return false
			}
		}
		return true
	}
	return false
}

// Drops the null entries of every table in `v`.
@(private)
drop_nulls :: proc(v: ^Value) {
	#partial switch &x in v {
	case Value_List:
		for &e in x {
			drop_nulls(&e)
		}
	case Value_Table:
		nulls := make([dynamic]string, context.temp_allocator)
		for k, &e in x {
			if e == nil {
				append(&nulls, k)
			} else {
				drop_nulls(&e)
			}
		}
		for k in nulls {
			delete_key(&x, k)
		}
	}
}

// A typed read of `src`, a text of format `f`, into `v`.
Value_Read :: #type proc(f: ^tape.Format, src: []u8, v: ^Value, opts: tape.Options, allocator: runtime.Allocator) -> tape.Error

// What the typed law met over a run of texts: those read alike, those refused alike for their syntax, and those whose
// values `Value` does not take.
Typed_Agreement :: struct {
	read, refused, typed: int,
}

// Expects `read` of `src` to give the value the build of `src` through `reads` converts to, its repeated keys taken
// under the read's duplicates policy, or the refusal of a value `Value` does not take, and a text the build refuses to
// be refused with the build's error. Under `nulls_absent`, for a format whose empty value is absent, a table's null
// entry is dropped from both values, as an empty repeat of a key leaves the entry zero.
unmarshal_agrees :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, read: Value_Read, src: []u8, opts: tape.Options, name: string, a: ^Typed_Agreement, nulls_absent := false, loc := #caller_location) -> bool {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator
	got: Value
	err := read(f, src, &got, opts, allocator)
	doc, built := reads.build(f, src, opts, allocator)
	if built != nil {
		a.refused += 1
		return testing.expectf(t, same_refusal(err, built), "%s: the build refuses %v, the typed read %v", name, built, err, loc = loc)
	}
	root, _ := tape.root({&doc, nil})
	want, refusal := value_of(&doc, root, f.dups if opts.dups == .Default else opts.dups, allocator)
	if refusal != .None {
		a.typed += 1
		x, refused := err.(tape.Fault)
		return testing.expectf(t, refused && x.rules == &typed.RULES && typed.Typed_Refusal(x.detail) == refusal, "%s: the typed read gives %v, the build %v", name, err, refusal, loc = loc)
	}
	a.read += 1
	if nulls_absent {
		drop_nulls(&got)
		drop_nulls(&want)
	}
	fault, _ := err.(tape.Fault)
	if !testing.expectf(t, err == nil, "%s %x: the typed read refuses %v, the build gives %v", name, src, typed.Typed_Refusal(fault.detail), want, loc = loc) {
		return false
	}
	return testing.expectf(t, values_equal(got, want), "%s: the typed read gives %v, the build %v", name, got, want, loc = loc)
}

// The value of node `at` of `doc` as a typed read into a `Value` takes it, its repeated keys taken under `dups`, or the
// refusal of the first value it reads and does not take: a byte string, or a number past binary64.
@(private)
value_of :: proc(doc: ^tape.Document, at: tape.Node_Index, dups: tape.Duplicates, allocator: runtime.Allocator) -> (Value, typed.Typed_Refusal) {
	r := tape.Reader{doc, nil}
	#partial switch doc.nodes[at].kind {
	case .Null:
		return nil, .None
	case .True, .False:
		return doc.nodes[at].kind == .True, .None
	case .Bytes:
		return nil, .No_Arm
	case .Number:
		n, _ := tape.node_number(doc, at)
		text := typed_text_at(doc, at, allocator)
		switch n.kind {
		case .Int:
			// `-0` is the integer 0, and a float keeps its sign.
			x := f64(i64(n.bits))
			return -x if n.bits == 0 && strings.has_prefix(text, "-") else x, .None
		case .Uint:
			return f64(n.bits), .None
		case .Float:
			return transmute(f64)n.bits, .None
		case .Wide:
		}
		// A number past what the format's readers give a value of reads by its text.
		x, parsed := strconv.parse_f64(text)
		if parsed && abs(x) <= max(f64) {
			return x, .None
		}
		return nil, .Below_Minimum if strings.has_prefix(text, "-") else .Above_Maximum
	case .Array, .Object:
		c, _, _ := tape.children(r, at, allocator)
		defer tape.destroy_children(&c)
		list := make(Value_List, allocator)
		table := make(Value_Table, allocator)
		// Under `.Last` the read takes every member as written, as it cannot know a later one repeats a key, and the last
		// stands.
		walk := tape.Duplicates.Group if dups == .Last else dups
		for {
			k, e, p := tape.next_child(r, &c, walk)
			if p != .Found {
				break
			}
			x, refusal := value_of(doc, e, dups, allocator)
			if refusal != .None {
				return nil, refusal
			}
			if doc.nodes[at].kind == .Array {
				append(&list, x)
			} else {
				key, _ := member_key(doc, c, k)
				table[strings.clone(token_text(doc, key), allocator)] = x
			}
		}
		if doc.nodes[at].kind == .Array {
			return list, .None
		}
		return table, .None
	}
	return typed_text_at(doc, at, allocator), .None
}

// The text of scalar node `at` of `doc`, decoded.
@(private)
typed_text_at :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> string {
	buf := make([]u8, max(tape.text_room(doc, at), 64), allocator)
	s, _ := tape.node_text(doc, at, buf)
	return strings.clone(s, allocator)
}

// Expects `e` to be a typed refusal `want` at byte `at`.
expect_typed_refusal :: proc(t: ^testing.T, e: tape.Error, want: typed.Typed_Refusal, at: u64, loc := #caller_location) -> bool {
	f, is_fault := e.(tape.Fault)
	if !testing.expectf(t, is_fault && f.kind == .Refused, "got %v, wanted a refusal %v", e, want, loc = loc) {
		return false
	}
	testing.expect_value(t, typed.Typed_Refusal(f.detail), want, loc)
	testing.expect_value(t, f.at, at, loc)
	return true
}

// Expects `steps` to be the path `want`, a name for a string and an index for an int.
expect_path :: proc(t: ^testing.T, steps: []tape.Step, want: []union {
		int,
		string,
	}, loc := #caller_location) {
	if !testing.expect_value(t, len(steps), len(want), loc) {
		return
	}
	for w, i in want {
		switch v in w {
		case int:
			testing.expect_value(t, steps[i], tape.Step(tape.Index(v)), loc)
		case string:
			testing.expect_value(t, steps[i], tape.Step(tape.Name(v)), loc)
		}
	}
}
