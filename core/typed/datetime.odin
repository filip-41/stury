package typed

// The types every plan reads and writes by its own hooks, after the caller's: `Datetime`, and `time.Time` as an RFC 3339
// date-time read into UTC, a leap second as the second after it, and written as a `Datetime`.

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:time"
import core ".."
import rules "../rules"

// A date, a time or both, of any of the kinds a format has: a string a format with datetimes writes as one of its own
// where the text is one, and every other format writes as a string.
Datetime :: distinct string

@(private, rodata)
BUILT_IN_HOOKS := [?]Type_Hook{{Datetime, datetime_read, datetime_write, nil, string}, {time.Time, time_read, time_write, nil, string}}

@(private = "file")
datetime_read :: proc(v: Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	if v.kind != .String {
		return .Wrong_Kind
	}
	text, failed := strings.clone(v.decoded, allocator)
	(^Datetime)(dest)^ = Datetime(text)
	return .No_Memory if failed != nil else nil
}

@(private = "file")
datetime_write :: proc(v: rawptr, _: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
	return any{v, typeid_of(Datetime)}, .None
}

// A date-time with a space between the date and the time reads as one with `T`, and one with no offset is `.Bad_Format`.
@(private = "file")
time_read :: proc(v: Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	if v.kind != .String {
		return .Wrong_Kind
	}
	text := v.decoded
	spaced: [64]u8
	if len(text) > 10 && len(text) <= len(spaced) && text[10] == ' ' {
		copy(spaced[:], text)
		spaced[10] = 'T'
		text = string(spaced[:len(text)])
	}
	p, ok := rules.date_time_of(text)
	if !ok {
		return .Bad_Format
	}
	t, in_range := time.components_to_time(p.year, p.month, p.day, p.hour, p.minute, min(p.second, 59), p.nanosecond)
	utc, past := intrinsics.overflow_sub(t._nsec, i64(p.offset) * i64(time.Minute))
	if p.second == 60 && !past {
		utc, past = intrinsics.overflow_add(utc, i64(time.Second))
	}
	if !in_range || past {
		return .Out_Of_Range
	}
	(^time.Time)(dest)^ = {utc}
	return nil
}

@(private = "file")
time_write :: proc(v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
	text, ok := time.time_to_rfc3339((^time.Time)(v)^, 0, true, allocator)
	held := new_clone(Datetime(text), allocator) or_else nil
	return any{held, typeid_of(Datetime)}, .Out_Of_Range if !ok else .No_Memory if held == nil else .None
}
