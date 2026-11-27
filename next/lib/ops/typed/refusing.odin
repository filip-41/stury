package typed

import "base:runtime"
import "core:slice"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The hook of a read under `.Refuse`: a `Reader` given every token of the text, which judges the keys of each object as
// it closes, so a key repeated in any object, in a value the read passes or past a refusal, ends the read with
// `.Duplicate_Key` at its first byte, as a build does. The walk passes nothing, so the read passes its values here.
Refusing_Reader :: struct {
	using reader: Reader,
	keys:         [dynamic]tape.Token, // the keys of the objects open, outermost first
	opens:        [dynamic]u32, // each open container's first key in `keys`, `max(u32)` for an array
	hashed:       [dynamic][2]u32, // an object's keys by hash, as its close sorts them
	repeat:       u64, // the first byte of the earliest repeated key, `max(u64)` for none
	passing:      int, // the containers open in a value the read passes
	ends:         bool, // the `End` that closes the value passed goes to the read, which took its opening
	value:        bool, // the next value is one the read passes, as it passed its key
	done:         bool, // the read takes no more tokens
	refused:      runtime.Allocator_Error, // memory refused for the keys
	protocol:     hook.Protocol({}, hook.Unused, hook.Unused, hook.Unused),
}

// The most keys an object's close compares pairwise without sorting them by hash.
@(private)
FEW_KEYS :: 16

// The refusing reader's hook: the keys and containers of token `t` noted, and `t` given to `reader_hook` unless the read
// passes it.
refusing_hook :: #force_inline proc "contextless" (h: ^Refusing_Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	if t.role <= .Key && (t.role == .Key || t.kind >= .Array) {
		note_token(h, t)
	}
	if h.done || .Dead in h.flags {
		return s, .Next
	}
	if h.passing > 0 {
		if t.role == .Value && t.kind >= .Array {
			h.passing += -1 if t.kind == .End else 1
			if h.passing == 0 && h.ends {
				return reader_hook(&h.reader, s, t, number, false)
			}
		}
		return s, .Next
	}
	if h.value && t.role == .Value {
		h.value = false
		if t.kind == .Array || t.kind == .Object {
			h.passing, h.ends = 1, false
		}
		return s, .Next
	}
	r, action := reader_hook(&h.reader, s, t, number, false)
	#partial switch action {
	case .Skip:
		if t.role == .Key {
			h.value = true
		} else if t.kind == .Array || t.kind == .Object {
			h.passing, h.ends = 1, true
		}
	case .Rest:
		h.done = true
	}
	return r, .Next
}

// Notes key, container or `End` token `t`, judging the keys of an object `t` closes.
@(private)
note_token :: #force_no_inline proc "contextless" (h: ^Refusing_Reader, t: tape.Token) {
	context = h.ctx
	if h.refused != nil {
		return
	}
	switch {
	case t.role == .Key:
		_, h.refused = append(&h.keys, t)
	case t.kind == .End:
		if len(h.opens) > 0 {
			close_keys(h)
		}
	case:
		_, h.refused = append(&h.opens, u32(len(h.keys)) if t.kind == .Object else max(u32))
	}
}

// Judges the keys of the innermost open container, if an object, and takes it off the open ones.
@(private)
close_keys :: proc(h: ^Refusing_Reader) {
	from := pop(&h.opens)
	if from == max(u32) {
		return
	}
	keys := h.keys[from:]
	defer resize(&h.keys, int(from))
	if len(keys) < 2 {
		return
	}
	src := h.base[:h.len]
	if len(keys) <= FEW_KEYS {
		for k, j in keys[1:] {
			for earlier in keys[:j + 1] {
				if tape.same_keys(h.format, src, earlier, src, k) {
					repeat_at(h, k)
					break
				}
			}
		}
		return
	}
	clear(&h.hashed)
	for k, j in keys {
		if _, h.refused = append(&h.hashed, [2]u32{h.format.key_hash(src, k), u32(j)}); h.refused != nil {
			return
		}
	}
	slice.sort_by(h.hashed[:], proc(a, b: [2]u32) -> bool {
		return a[0] < b[0] || a[0] == b[0] && a[1] < b[1]
	})
	for run := 0; run < len(h.hashed); {
		past := run + 1
		for past < len(h.hashed) && h.hashed[past][0] == h.hashed[run][0] {
			past += 1
		}
		for later in h.hashed[run + 1:past] {
			for earlier in h.hashed[run:past] {
				if earlier[1] >= later[1] {
					break
				}
				if tape.same_keys(h.format, src, keys[earlier[1]], src, keys[later[1]]) {
					repeat_at(h, keys[later[1]])
					break
				}
			}
		}
		run = past
	}
}

// Notes key `k` as a repeat, at the first byte of its spelling.
@(private)
repeat_at :: #force_inline proc "contextless" (h: ^Refusing_Reader, k: tape.Token) {
	head, _ := h.format.bounds(h.base[:h.len], k)
	h.repeat = min(h.repeat, k.lo - u64(head))
}

// Frees the temporary duplicate-key arrays of `Refusing_Reader`, safe to invoke repeatedly.
@(private)
refusing_free :: proc "contextless" (h: ^Refusing_Reader) {
	context = h.ctx
	delete(h.keys)
	delete(h.opens)
	delete(h.hashed)
	h.keys = {}
	h.opens = {}
	h.hashed = {}
}

// The error of a refusing read whose walk ended with `err`: a repeated key, judged in the objects still open too, unless
// a fault of the walk comes before it in the text. Frees what the hook kept.
refusing_end :: proc "contextless" (h: ^Refusing_Reader, err: tape.Error, rules: ^tape.Rules) -> tape.Error {
	context = h.ctx
	for len(h.opens) > 0 && h.refused == nil {
		close_keys(h)
	}
	refusing_free(h)
	if h.refused != nil && err == nil {
		return h.refused
	}
	if h.repeat != max(u64) {
		if f, is_fault := err.(tape.Fault); err == nil || is_fault && f.at > h.repeat {
			return tape.Fault{at = h.repeat, rules = rules, kind = .Duplicate_Key}
		}
	}
	return err
}
