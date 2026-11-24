package cbor_tests

import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

// The protocol a hook keeps with the walk, and what cancels it.

// The walk of a text of spec `S` that the law of the hook protocol drives with its probe hook.
@(private = "file")
walk_of :: proc($S: cbor.Spec) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := cbor.walk(src, S, opts, h, regs, testkit.probe_hook)
		return at, err
	}
}

// The same walk for the laws that give it no hook.
@(private = "file")
bare_walk_of :: proc($S: cbor.Spec) -> testkit.Bare_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe_Bare, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := cbor.walk(src, S, opts, h, regs, testkit.bare_hook)
		return at, err
	}
}

// Texts of every kind of item, definite and indefinite containers, tags and keys of each kind, and tags before a
// member's value, which a skip at its key passes.
PROTOCOL_HEX := [?]string {
	"01",
	"80",
	"bf ff",
	"86 01 63 616263 f5 f6 82 02 81 03 a1 61 6b a1 61 6c 80",
	"a3 61 61 01 61 62 9f a1 61 63 02 a1 61 64 82 03 04 ff 61 65 a0",
	"9f 9f 9f 9f 9f 9f 9f 9f 81 64 64656570 ff ff ff ff ff ff ff ff",
	"a2 01 c1 1a 514b67b0 41 ff 82 c2 49 010000000000000000 d8 18 41 00",
	"83 7f 61 61 61 62 ff 5f 41 01 ff f9 3c00",
	"a3 61 61 d9 d9f7 a1 61 62 c1 01 7f 61 63 ff d8 20 61 64 20 bf 01 9f ff ff",
	"82 d9 d9f7 d9 d9f7 a0 9f 9f 9f 9f 9f 9f ff ff ff ff ff ff",
}

// Every CBOR walk keeps the hook protocol: actions at every token, room and level growth, and `Budget.steps`.
@(test)
walks_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// The protocol frees the temporary allocator after each text, so the texts are in the context's allocator.
	texts := make([dynamic]string)
	defer {
		for text in texts {
			delete(text)
		}
		delete(texts)
	}
	for h in PROTOCOL_HEX {
		append(&texts, strings.clone(string(hex(h))))
	}
	testkit.hook_protocol(t, walk_of(.Cbor), texts[:])
	testkit.hook_inner_rooms(t, bare_walk_of(.Cbor), texts[:])
	deterministic := strings.clone(string(hex("a2 61 61 01 61 62 82 a1 01 02 80")))
	defer delete(deterministic)
	testkit.hook_protocol(t, walk_of(.Deterministic), {deterministic})
}

// A hook stops a walk from another thread through a flag.
@(test)
walk_cancels_through_a_flag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_bytes(&b, hex("99 00c8"))
	for _ in 0 ..< 200 {
		strings.write_bytes(&b, hex("a1 61 61 83 01 02 a1 61 62 61 63"))
	}
	testkit.hook_cancel(t, walk_of(.Cbor), strings.to_string(b), 300)
}

// A hook that writes the kind of each token it is given, `Tag:` or `Key:` before the kind of a fact or a key, and
// answers `skip` on the first token of that kind and `Stop` at the token numbered `stop`.
@(private = "file")
Recorder :: struct {
	out:      [128]u8,
	size:     int,
	tokens:   int,
	skip:     tape.Kind,
	stop:     int,
	protocol: hook.Protocol(hook.Capabilities{.Skips}, hook.Unused, hook.Unused, hook.Unused),
}

@(private = "file")
recorded :: proc "contextless" (h: ^Recorder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	prefix := ""
	#partial switch t.role {
	case .Tag:
		prefix = "Tag:"
	case .Key:
		prefix = "Key:"
	}
	words := [tape.Kind]string {
		.Null   = "Null",
		.False  = "False",
		.True   = "True",
		.Number = "Number",
		.Bytes  = "Bytes",
		.String = "String",
		.Plain  = "Plain",
		.Array  = "Array",
		.Object = "Object",
		.End    = "End",
	}
	h.size += copy(h.out[h.size:], prefix)
	h.size += copy(h.out[h.size:], words[t.kind])
	h.size += copy(h.out[h.size:], " ")
	h.tokens += 1
	if h.stop != 0 && h.tokens == h.stop {
		return s, .Stop
	}
	if t.role == .Value && t.kind == h.skip && h.skip != .End {
		return s, .Skip
	}
	return s, .Next
}

// A walk gives a tag as a fact before its content, a bignum as one number, and a simple value that is no boolean as
// null. It obeys `Skip` with no token for what the container holds, still judges it, and `Stop` ends it with no fault.
@(test)
walk_tokens :: proc(t: ^testing.T) {
	testkit.deadline(t)
	rows := [?]struct {
		hex, want: string,
	} {
		{"c1 1a 51 4b 67 b0", "Tag:Number Number "},
		{"c2 41 01", "Tag:Number Number "},
		{"a1 01 02", "Object Key:Number Number End "},
		{"82 f7 f5", "Array Null True End "},
		{"9f 01 ff", "Array Number End "},
		{"5f 41 01 ff", "Bytes "},
		{"f9 3c 00", "Number "},
	}
	for r in rows {
		h := Recorder {
			skip = .End,
		}
		src := hex(r.hex)
		at, err, _ := cbor.walk(src, .Cbor, {}, &h, &hook.Regs{}, recorded)
		testing.expectf(t, err == nil && at == u64(len(src)), "%s: %v %d", r.hex, err, at)
		got := string(h.out[:h.size])
		testing.expectf(t, got == r.want, "%s: want %s, got %s", r.hex, r.want, got)
	}
	// A skipped container sends no token of its content, only its `End`.
	h := Recorder {
		skip = .Array,
	}
	_, err, _ := cbor.walk(hex("82 81 01 02"), .Cbor, {}, &h, &hook.Regs{}, recorded)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(h.out[:h.size]), "Array End ")
	// A skipped value is still judged.
	h = Recorder {
		skip = .Array,
	}
	_, err, _ = cbor.walk(hex("82 81 62 c3 28 01"), .Cbor, {}, &h, &hook.Regs{}, recorded)
	testing.expect(t, err != nil)
	// Stop ends the read with no fault, and the text past it is not read.
	h = Recorder {
		skip = .End,
		stop = 2,
	}
	_, err, _ = cbor.walk(hex("83 01 02 ff"), .Cbor, {}, &h, &hook.Regs{}, recorded)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(h.out[:h.size]), "Array Number ")
}
