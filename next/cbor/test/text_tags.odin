package cbor_tests

import "core:testing"
import "core:time"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

// A date-time of a TOML document, the tag of a text a caller gives and a `time.Time` are written with the tags CBOR
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
		tag:  string,
		kind: tape.Token_Kind,
		text: string,
	}{
		{"", .Array, ""},
		{"datetime", .String, "2013-03-21T20:04:00Z"},
		{"datetime", .String, "not a date"},
		{"date-local", .String, "2013-03-21"},
		{"!!timestamp", .String, "2013-03-21"},
		{"24", .String, "x"},
		{"custom", .String, "y"},
		{"", .Close, ""},
	}
	for s in steps {
		if s.tag != "" {
			testing.expect(t, cbor.tag(&w, s.tag) == nil)
		}
		testing.expect(t, cbor.token(&w, s.kind, s.text) == nil)
	}
	item, err := cbor.writer_end(&w)
	defer delete(item)
	want := "\x9F\xC0\x74" + "2013-03-21T20:04:00Z" + "\x6anot a date" + "\xD9\x03\xEC\x6A" + "2013-03-21" + "\xD9\x03\xEC\x6A" + "2013-03-21" + "\xD8\x18\x61x" + "\x61y\xFF"
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
}
