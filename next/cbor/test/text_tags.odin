package cbor_tests

import "core:bytes"
import "core:testing"
import "core:time"
import "stury:cbor"
import "stury:testkit"
import "stury:toml"

// A date-time of a TOML document, the tag of a value a caller gives and a `time.Time` are written with the tags CBOR
// has for them.

@(test)
toml_date_times_are_tagged_in_cbor :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a = 1979-05-27T07:32:00Z\nb = 1979-05-27\nc = 07:32:00\nd = 1979-05-27T07:32:00\n"
	doc, err := toml.build(transmute([]u8)src)
	defer toml.destroy(&doc)
	testing.expect(t, err == nil)
	item, dropped, werr := cbor.write(&doc)
	defer delete(item)
	want := "\xA4\x61a\xC0\x74" + "1979-05-27T07:32:00Z" + "\x61b\xD9\x03\xEC\x6A" + "1979-05-27" + "\x61c\x68" + "07:32:00" + "\x61d\x73" + "1979-05-27T07:32:00"
	testing.expectf(t, werr == nil && string(item) == want, "%v % x", werr, item)
	testing.expect(t, .Tag in dropped)
	// A text that holds only the types CBOR tags drops no tag.
	doc2, _ := toml.build(transmute([]u8)string("a = 1979-05-27T07:32:00Z\nb = 1979-05-27\n"))
	defer toml.destroy(&doc2)
	item2, dropped2, _ := cbor.write(&doc2)
	defer delete(item2)
	testing.expectf(t, .Tag not_in dropped2, "%v", dropped2)
	back, berr := cbor.build(item2)
	defer cbor.destroy(&back)
	testing.expect(t, berr == nil)
}

@(test)
a_tag_given_to_the_token_writer_is_written_with_its_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: cbor.Writer
	testing.expect(t, cbor.writer_start(&w) == nil)
	steps := [?]struct {
		has_tag: bool,
		tag:     u64,
		kind:    cbor.Token_Kind,
		text:    string,
	}{
		{false, 0, .Array, ""},
		{true, 0, .String, "2013-03-21T20:04:00Z"},
		{true, 1004, .String, "2013-03-21"},
		{true, 24, .String, "x"},
		{false, 0, .String, "y"},
		{false, 0, .Close, ""},
	}
	for s in steps {
		if s.has_tag {
			testing.expect(t, cbor.tag(&w, s.tag) == nil)
		}
		testing.expect(t, cbor.token(&w, s.kind, s.text) == nil)
	}
	item, err := cbor.writer_end(&w)
	defer delete(item)
	want := "\x9F\xC0\x74" + "2013-03-21T20:04:00Z" + "\xD9\x03\xEC\x6A" + "2013-03-21" + "\xD8\x18\x61x" + "\x61y\xFF"
	testing.expectf(t, err == nil && string(item) == want, "%v % x", err, item)
}

@(private = "file")
Event :: struct {
	at: time.Time,
}

@(test)
a_time_is_marshalled_as_a_tagged_date_time :: proc(t: ^testing.T) {
	testkit.deadline(t)
	event := Event{time.unix(1363896240, 0)}
	item, err := cbor.marshal(&event)
	defer delete(item)
	testing.expectf(t, err == nil && len(item) > 5 && item[0] == 0xBF && item[4] == 0xC0, "%v % x", err, item)
	back: Event
	testing.expect(t, cbor.unmarshal(item, &back) == nil && back.at == event.at)

	// `.Preferred` and `.Deterministic` marshal with definite-length containers and keep tag 0.
	for spec in ([?]cbor.Spec{.Preferred, .Deterministic, .Length_First}) {
		det, derr := cbor.marshal(&event, spec)
		defer delete(det)
		testing.expectf(t, derr == nil && len(det) > 5 && det[0] == 0xA1 && det[4] == 0xC0, "%v: %v % x", spec, derr, det)
		testing.expectf(t, cbor.validate(det, spec) == nil, "%v: %v", spec, cbor.validate(det, spec))
		back2: Event
		testing.expect(t, cbor.unmarshal(det, &back2, spec) == nil && back2.at == event.at)
		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		serr := cbor.marshal_to(bytes.buffer_to_stream(&buf), &event, spec)
		testing.expectf(t, serr == nil && string(bytes.buffer_to_bytes(&buf)) == string(det), "%v marshal_to: %v", spec, serr)
	}
}
