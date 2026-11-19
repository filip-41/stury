#+private
package jq

// The C runtime's calendar time on Windows, and paths as Windows spells them. system_posix.odin has POSIX's. The UCRT
// has no gmtime_r, timegm or strptime: time_windows.odin has them in Odin.

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"

foreign import ucrt "system:libucrt.lib"

@(private = "file")
Invalid_Parameter_Handler :: #type proc "c" (expression, function, file: [^]u16, line: u32, reserved: uintptr)

@(private = "file", default_calling_convention = "c")
foreign ucrt {
	_localtime64_s :: proc(tm: ^libc.tm, t: ^libc.time_t) -> libc.int ---
	_mktime64 :: proc(tm: ^libc.tm) -> libc.time_t ---
	_set_thread_local_invalid_parameter_handler :: proc(handler: Invalid_Parameter_Handler) -> Invalid_Parameter_Handler ---
}

// The directory of `path`, "." for one with none, as the MinGW dirname jq's Windows build calls gives it:
// separators at the end of the path and of its directory dropped, but a root's own.
dir_name :: proc(path: string) -> string {
	trim :: proc(s: string) -> string {
		s := s
		for len(s) > 1 && (s[len(s) - 1] == '/' || s[len(s) - 1] == '\\') && s[len(s) - 2] != ':' {
			s = s[:len(s) - 1]
		}
		return s
	}
	d := trim(os.dir(trim(path)))
	return strings.clone(d if d != "" else ".")
}

is_absolute_path :: os.is_absolute_path

local_time :: proc(t: libc.time_t, tm: ^libc.tm) -> bool {
	t := t
	return _localtime64_s(tm, &t) == 0
}

local_mktime :: _mktime64

// libc's strftime. `%s`, `%k` and `%l`, which jq's Windows build gives and the UCRT does not know, are written
// first (`%s` from the C runtime's TZ, as POSIX's strftime reads it). Any other conversion the UCRT does not know
// fails as a format that does not fit, where the UCRT's default handler would end the process.
c_strftime :: proc(buf: []byte, format: cstring, tm: ^libc.tm) -> uint {
	f := string(format)
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(f); i += 1 {
		if f[i] != '%' || i + 1 == len(f) {
			strings.write_byte(&b, f[i])
			continue
		}
		i += 1
		switch f[i] {
		case 's':
			t := tm^
			fmt.sbprintf(&b, "%d", _mktime64(&t))
		case 'k', 'l':
			// The hour padded with a space to two places, as glibc's `%k` and `%l`.
			hour := tm.tm_hour if f[i] == 'k' else (tm.tm_hour + 11) % 12 + 1
			if hour < 10 {
				strings.write_byte(&b, ' ')
			}
			fmt.sbprintf(&b, "%d", hour)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, f[i])
		}
	}
	previous := _set_thread_local_invalid_parameter_handler(proc "c" (_, _, _: [^]u16, _: u32, _: uintptr) {})
	n := libc.strftime(raw_data(buf), len(buf), strings.to_cstring(&b) or_else format, tm)
	_set_thread_local_invalid_parameter_handler(previous)
	return n
}

