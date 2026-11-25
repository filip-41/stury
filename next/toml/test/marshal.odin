package toml_tests

import "core:testing"
import "stury:testkit"
import "stury:toml"

// Typed writes: a value written as TOML reads back as the same value.

@(private = "file")
Server :: struct {
	name:  string,
	port:  int `toml:"listen"`,
	tags:  []string,
	inner: struct {
		on: bool,
	},
}

@(test)
a_value_marshals_to_a_table_that_reads_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	tags := []string{"a", "b"}
	value := Server{name = "n", port = 8080, tags = tags, inner = {on = true}}
	text, err := toml.marshal(&value)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "name = \"n\"\nlisten = 8080\ntags = [\"a\", \"b\"]\n\n[inner]\non = true\n", "%v\n%s", err, text)
	back: Server
	defer {
		delete(back.name)
		for s in back.tags {
			delete(s)
		}
		delete(back.tags)
	}
	uerr := toml.unmarshal(text, &back)
	testing.expectf(t, uerr == nil && back.name == "n" && back.port == 8080 && len(back.tags) == 2 && back.inner.on, "%v", uerr)

	// Non-bare struct tag keys are quoted, and u64 > max(i64) is refused.
	Odd :: struct {
		a: int `toml:"a b"`,
		b: int `toml:"a.b"`,
	}
	odd := Odd{1, 2}
	odd_text, odd_err := toml.marshal(&odd)
	defer delete(odd_text)
	testing.expectf(t, odd_err == nil && string(odd_text) == "\"a b\" = 1\n\"a.b\" = 2\n" && toml.validate(odd_text) == nil, "odd keys: %v %q", odd_err, odd_text)

	Too_Big :: struct {
		big: u64,
	}
	tb := Too_Big{max(u64)}
	_, tb_err := toml.marshal(&tb)
	r, ok := tb_err.(toml.Refused)
	testing.expectf(t, ok && r.why == .No_Spelling, "marshal u64 max: %v", tb_err)
}
