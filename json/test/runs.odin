package json_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import records "../../core/records"
import json ".."

// `records.validate` of NDJSON with the format's `judge_run` against the same read judging each record alone: the same
// faults at the same bytes. The records mix every line a run must stop at or count right.

@(private = "file")
LINES := []string{
	`{"ts":"2026-10-03T04:03:24.502Z","level":"info","n":[1,2.5,-3e2],"ok":true}`,
	`{"a":{"b":[[1,2],[3,4]]},"s":"x\"y\\u00e9"}`,
	`[1,2,3],[4]`, // two values on a line
	`[[1,2],[3,4],[5,6]]`,
	`12`, `"root"`, `null`, `{}`, `[]`,
	`{"a": 1, "b" : [ 1 , 2 ] }   `, // spaces inside and after
	"{\"t\":1}\t\r", // a tab and a CR before the LF
	"   {\"lead\":1}", // leading whitespace
	"", // a blank line
	`{"a":`, // a value whose rest is on the next line
	`1}`,
	`{"bad":01}`, `{"bad":"\q"}`, "{\"bad\":\"\xc3\x28\"}", "{\"bad\":\"a\x01\"}", `{"bad":tru}`, `{"a":1}x`, `]`, `{"a":1,}`,
}

@(private = "file")
expect_runs_as_records :: proc(t: ^testing.T, text: string, loc := #caller_location) -> bool {
	as := json.as(.Json)
	alone := (^records.Framing_Services)(core.services_of(as).records)^
	alone.judge_run = nil
	want, want_err := records.validate(transmute([]u8)text, as, .Lines, context.temp_allocator, services = &alone)
	got, got_err := records.validate(transmute([]u8)text, as, .Lines, context.temp_allocator)
	if !testing.expect(t, want_err == nil && got_err == nil, loc = loc) {
		return false
	}
	if !testing.expectf(t, len(want) == len(got), "%d faults alone, %d with runs, in %d bytes", len(want), len(got), len(text), loc = loc) {
		return false
	}
	for f, i in want {
		g := got[i]
		if !testing.expectf(t, f.at == g.at && f.kind == g.kind && f.detail == g.detail, "fault %d: %v at %d alone, %v at %d with runs", i, f.kind, f.at, g.kind, g.at, loc = loc) {
			return false
		}
	}
	return true
}

@(test)
records_judged_in_runs_as_alone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(2)
	gen := rand.default_random_generator(&state)
	b := strings.builder_make(context.temp_allocator)
	// Many short texts, then a few longer than a run, each line from `LINES` with the clean ones most often.
	for size in ([]int{200, 200, 200, 200, 200, 200, 200, 200, 4000, 9000}) {
		for round in 0 ..< 40 {
			strings.builder_reset(&b)
			if round % 7 == 0 {
				strings.write_string(&b, "\xef\xbb\xbf")
			}
			for _ in 0 ..< size {
				k := rand.int_max(len(LINES) * 4, gen)
				strings.write_string(&b, LINES[k if k < len(LINES) else k % 2])
				strings.write_string(&b, "\r\n" if rand.int_max(9, gen) == 0 else "\n")
			}
			text := strings.to_string(b)
			// Some texts end with no LF, or cut inside their last line.
			switch round % 3 {
			case 1:
				text = text[:len(text) - 1]
			case 2:
				text = text[:len(text) - 1 - rand.int_max(min(len(text) - 1, 30), gen)]
			}
			if !expect_runs_as_records(t, text) {
				return
			}
		}
	}
}

@(test)
records_judged_in_runs_of_clean_lines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Clean lines across several runs, and the same text with one fault near a run's end.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20_000 {
		strings.write_string(&b, LINES[i % 2])
		strings.write_byte(&b, '\n')
	}
	text := strings.to_string(b)
	if !expect_runs_as_records(t, text) {
		return
	}
	bad := strings.concatenate({text[:65_000], `{"bad":01}`, "\n", text[65_000:]}, context.temp_allocator)
	expect_runs_as_records(t, bad)
}
