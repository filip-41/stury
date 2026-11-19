package main

// --stream's events of a document, made one at a time as jq's streaming parser makes them: `[path, leaf]` for each
// scalar and empty container, and `[path]` after a container's last member, `path` ending with that member's step.
// Every member is walked, a repeated key's too. A document whose nodes are not its value's members, as a markup
// document's repeated name and a table's record are not, is walked by its value's members instead, as `tostream` does.

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "../../core/kernel"
import core "../../core"
import "../../jq"

// An event is made whole in the allocator of the call that makes it, as `input` under -n empties one each call. The
// document, which the heap holds, and the walk are the heap's, and `next_event` frees both after the last event.
Events :: struct {
	doc:          core.Document,
	frames:       [dynamic]Event_Frame, // the containers open, the root first
	started:      bool,
	last:         core.Node_Index, // the node whose text made the event returned last,
	closing:      bool, // and whether the event closes that container,
	after_scalar: bool, // whose last member is then a scalar
	// The walk by the value's members: its containers open, what iterating them holds, and the byte of the text that
	// triggers every event.
	members:      [dynamic]Member_Frame,
	walk:         virtual.Arena,
	end:          int,
	by_value:     bool,
}

@(private = "file")
Member_Frame :: struct {
	it:    jq.Members,
	array: bool,
	index: int,
	key:   string,
}

@(private = "file")
Event_Frame :: struct {
	node:  core.Node_Index,
	it:    core.Child_Iter,
	array: bool,
	index: int, // the step of the member read last: an array's index,
	key:   core.Node_Index, // or an object's key node, decoded by each event, as a decoded key lives in its call's allocator
}

// The events of `doc`, which the heap holds.
events_start :: proc(doc: core.Document) -> ^Events {
	e := new(Events, runtime.heap_allocator())
	e.doc = doc
	e.frames.allocator = runtime.heap_allocator()
	return e
}

// The events of the value of `doc`, which the heap holds, walked by its members, each triggered at byte `end` of the
// text.
value_events_start :: proc(doc: core.Document, end: int) -> ^Events {
	e := events_start(doc)
	e.members.allocator = runtime.heap_allocator()
	e.end, e.by_value = end, true
	return e
}

// The next event, or false once the last has been made, when the events are freed.
next_event :: proc(e: ^Events) -> (core.Value, bool) {
	if e.by_value {
		return next_member_event(e)
	}
	doc := &e.doc
	if !e.started {
		e.started = true
		if is_leaf(doc, core.ROOT) {
			e.last = core.ROOT
			return event(e, core.ROOT), true
		}
		push_frame(e, core.ROOT)
	}
	for len(e.frames) > 0 {
		f := &e.frames[len(e.frames) - 1]
		row, ok := core.child_next(&f.it)
		if !ok {
			closing := event(e, core.NO_NODE)
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
	core.destroy(&e.doc)
	delete(e.frames)
	free(e, runtime.heap_allocator())
	return nil, false
}

@(private = "file")
next_member_event :: proc(e: ^Events) -> (core.Value, bool) {
	caller := context.allocator
	if !e.started {
		e.started = true
		root := core.Value(core.Node_Ref{&e.doc, core.ROOT})
		if !member_push(e, root) {
			return member_event(e, root, false), true
		}
	}
	for len(e.members) > 0 {
		f := &e.members[len(e.members) - 1]
		context.allocator = virtual.arena_allocator(&e.walk)
		key, m, ok := jq.next_member(&f.it)
		context.allocator = caller
		if !ok {
			closing := member_event(e, nil, true)
			pop(&e.members)
			return closing, true
		}
		if f.array {
			f.index += 1
		} else {
			f.key = key
		}
		if !member_push(e, m) {
			return member_event(e, m, false), true
		}
	}
	core.destroy(&e.doc)
	delete(e.members)
	virtual.arena_destroy(&e.walk)
	free(e, runtime.heap_allocator())
	return nil, false
}

// Opens container `v` when it has a member, and answers whether it did.
@(private = "file")
member_push :: proc(e: ^Events, v: core.Value) -> bool {
	k := jq.kind(v)
	if k < .Array || core.length(v) == 0 {
		return false
	}
	context.allocator = virtual.arena_allocator(&e.walk)
	append(&e.members, Member_Frame{it = jq.iterate(v), array = k == .Array, index = -1})
	return true
}

// `[path, leaf]`, or `[path]` when `closing`, copied whole into the context's allocator.
@(private = "file")
member_event :: proc(e: ^Events, leaf: core.Value, closing: bool) -> core.Value {
	path := core.new_array(len(e.members))
	for f in e.members {
		append(&path.items, core.Value(f64(f.index)) if f.array else core.Value(strings.clone(f.key)))
	}
	switch {
	case closing:
		return jq.event_of(path)
	case jq.kind(leaf) == .Array:
		return jq.event_of(path, core.new_array())
	case jq.kind(leaf) == .Object:
		return jq.event_of(path, core.new_object())
	}
	return jq.event_of(path, jq.event_clone(jq.scalar(leaf)))
}

// The byte of the text whose reading makes the event returned last, as jq's streaming parser has it: a container's
// closing bracket for an empty container and for its closing event, or the byte after that bracket when its last member
// is a scalar, the ',' or closing bracket after any other member, the quote that ends a top-level string, else the byte
// after a top-level literal. Valid until the next `next_event`.
event_trigger :: proc(e: ^Events) -> int {
	if e.by_value {
		return e.end
	}
	src := e.doc.src
	lo := int(e.doc.nodes[e.last].lo)
	hi := lo + len(core.span(&e.doc, e.last))
	k := e.doc.nodes[e.last].kind
	switch {
	case e.closing:
		return hi - 1 + int(e.after_scalar)
	case k >= .Array:
		return hi - 1
	case len(e.frames) == 0:
		return hi - 1 if k == .String else hi
	}
	for hi < len(src) && kernel.is_ws(src[hi]) {
		hi += 1
	}
	return hi
}

@(private = "file")
is_leaf :: proc(doc: ^core.Document, i: core.Node_Index) -> bool {
	it := core.children(doc, i)
	return it.done
}

@(private = "file")
push_frame :: proc(e: ^Events, n: core.Node_Index) {
	append(&e.frames, Event_Frame{node = n, it = core.children(&e.doc, n), array = e.doc.nodes[n].kind == .Array, index = -1})
}

// `[path, leaf]`, or `[path]` for NO_NODE, copied whole into the context's allocator.
@(private = "file")
event :: proc(e: ^Events, leaf: core.Node_Index) -> core.Value {
	path := core.new_array(len(e.frames))
	for f in e.frames {
		if f.array {
			append(&path.items, core.Value(f64(f.index)))
		} else {
			key, _ := core.text_clone(&e.doc, f.key)
			append(&path.items, key)
		}
	}
	if leaf == core.NO_NODE {
		return jq.event_of(path)
	}
	#partial switch e.doc.nodes[leaf].kind {
	case .Array:
		return jq.event_of(path, core.new_array())
	case .Object:
		return jq.event_of(path, core.new_object())
	}
	return jq.event_of(path, jq.event_clone(jq.scalar(core.Node_Ref{&e.doc, leaf})))
}
