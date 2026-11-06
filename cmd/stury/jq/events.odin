package jq

// --stream's events of a document, made one at a time as jq's streaming parser makes them: `[path, leaf]` for each
// scalar and empty container, and `[path]` after a container's last member, `path` ending with that member's step.
// Every member is walked, a repeated key's too.

import "base:runtime"
import "core:strings"
import core_pkg "../../../core"

// An event is made whole in the allocator of the call that makes it, as `input` under -n empties one each call. The
// document, which the heap holds, and the walk are the heap's, and `next_event` frees both after the last event.
Events :: struct {
	doc:          core_pkg.Document,
	frames:       [dynamic]Event_Frame, // the containers open, the root first
	started:      bool,
	last:         core_pkg.Node_Index, // the node whose text made the event returned last,
	closing:      bool, // and whether the event closes that container,
	after_scalar: bool, // whose last member is then a scalar
}

@(private = "file")
Event_Frame :: struct {
	node:  core_pkg.Node_Index,
	it:    core_pkg.Child_Iter,
	array: bool,
	index: int, // the step of the member read last: an array's index,
	key:   core_pkg.Node_Index, // or an object's key node, decoded by each event, as a decoded key lives in its call's allocator
}

// The events of `doc`, which the heap holds.
events_start :: proc(doc: core_pkg.Document) -> ^Events {
	e := new(Events, runtime.heap_allocator())
	e.doc = doc
	e.frames.allocator = runtime.heap_allocator()
	return e
}

// The next event, or false once the last has been made, when the events are freed.
next_event :: proc(e: ^Events) -> (Value, bool) {
	doc := &e.doc
	if !e.started {
		e.started = true
		if is_leaf(doc, core_pkg.ROOT) {
			e.last = core_pkg.ROOT
			return event(e, core_pkg.ROOT), true
		}
		push_frame(e, core_pkg.ROOT)
	}
	for len(e.frames) > 0 {
		f := &e.frames[len(e.frames) - 1]
		row, ok := core_pkg.child_next(&f.it)
		if !ok {
			closing := event(e, core_pkg.NO_NODE)
			e.after_scalar = !e.closing && doc.nodes[e.last].kind < .Array
			e.last, e.closing = f.node, true
			pop(&e.frames)
			return closing, true
		}
		if f.array {
			f.index += 1
		} else {
			f.key = row - 1
		}
		if is_leaf(doc, row) {
			e.last, e.closing = row, false
			return event(e, row), true
		}
		push_frame(e, row)
	}
	core_pkg.destroy(&e.doc)
	delete(e.frames)
	free(e, runtime.heap_allocator())
	return nil, false
}

// The byte of the text whose reading makes the event returned last, as jq's streaming parser has it: a container's
// closing bracket for an empty container and for its closing event, or the byte after that bracket when its last member
// is a scalar, the ',' or closing bracket after any other member, the quote that ends a top-level string, else the byte
// after a top-level literal. Valid until the next `next_event`.
event_trigger :: proc(e: ^Events) -> int {
	src := e.doc.src
	lo := int(e.doc.nodes[e.last].lo)
	hi := lo + len(core_pkg.span(&e.doc, e.last))
	k := e.doc.nodes[e.last].kind
	switch {
	case e.closing:
		return hi - 1 + int(e.after_scalar)
	case k >= .Array:
		return hi - 1
	case len(e.frames) == 0:
		return hi - 1 if k == .String else hi
	}
	for hi < len(src) && is_space(src[hi]) {
		hi += 1
	}
	return hi
}

@(private = "file")
is_leaf :: proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> bool {
	it := core_pkg.children(doc, i)
	return it.done
}

@(private = "file")
push_frame :: proc(e: ^Events, n: core_pkg.Node_Index) {
	append(&e.frames, Event_Frame{node = n, it = core_pkg.children(&e.doc, n), array = e.doc.nodes[n].kind == .Array, index = -1})
}

// `[path, leaf]`, or `[path]` for NO_NODE, copied whole into the context's allocator.
@(private = "file")
event :: proc(e: ^Events, leaf: core_pkg.Node_Index) -> Value {
	path := new_array(len(e.frames))
	for f in e.frames {
		if f.array {
			append(&path.items, num(f64(f.index)))
		} else {
			key, _ := core_pkg.text_clone(&e.doc, f.key)
			append(&path.items, key)
		}
	}
	if leaf == core_pkg.NO_NODE {
		return event_of(path)
	}
	#partial switch e.doc.nodes[leaf].kind {
	case .Array:
		return event_of(path, new_array())
	case .Map:
		return event_of(path, new_object())
	}
	return event_of(path, event_clone(scalar(Ref{&e.doc, leaf})))
}

// A `--stream` event: `[path, leaf]`, or `[path]` with no leaf, after a container's last member.
event_of :: proc(path: ^Array, leaf: ..Value) -> Value {
	ev := new_array(2)
	append(&ev.items, path)
	append(&ev.items, ..leaf)
	return ev
}

// An event or a part of one, made anew in the context allocator. An event's container leaf is empty.
event_clone :: proc(v: Value) -> Value {
	#partial switch x in v {
	case Number:
		return Number{f = x.f, lit = strings.clone(x.lit)}
	case string:
		return strings.clone(x)
	case ^Array:
		a := new_array(len(x.items))
		for m in x.items {
			append(&a.items, event_clone(m))
		}
		return a
	case ^Object:
		return new_object()
	}
	return v
}
