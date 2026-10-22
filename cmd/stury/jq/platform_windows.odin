package jq

// The interpreter's calls into the system on Windows. platform_posix.odin has POSIX's. The UCRT has no gmtime_r,
// timegm or strptime: time_windows.odin has them in Odin.

import "core:c/libc"
import "core:os"
import "core:strings"
import win "core:sys/windows"

foreign import ucrt "system:libucrt.lib"

@(private = "file")
Invalid_Parameter_Handler :: #type proc "c" (expression, function, file: [^]u16, line: u32, reserved: uintptr)

@(private = "file", default_calling_convention = "c")
foreign ucrt {
	_localtime64_s :: proc(tm: ^libc.tm, t: ^libc.time_t) -> libc.int ---
	_mktime64 :: proc(tm: ^libc.tm) -> libc.time_t ---
	_putenv_s :: proc(name, value: cstring) -> libc.int ---
	_tzset :: proc() ---
	_set_thread_local_invalid_parameter_handler :: proc(handler: Invalid_Parameter_Handler) -> Invalid_Parameter_Handler ---
}

// The longest $HOME read without allocating. A longer one is not looked in for `~/.jq`.
PATH_MAX :: 4096

// $HOME, or else %USERPROFILE%, as jq finds the home directory on Windows.
home_dir :: proc() -> cstring {
	if home := libc.getenv("HOME"); home != nil {
		return home
	}
	return libc.getenv("USERPROFILE")
}

path_kind :: proc(path: cstring) -> Path_Kind {
	attrs := win.GetFileAttributesW(win.utf8_to_wstring(string(path), context.temp_allocator))
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		e := win.GetLastError()
		return .Missing if e == win.ERROR_FILE_NOT_FOUND || e == win.ERROR_PATH_NOT_FOUND else .Unreadable
	}
	return .Dir if attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0 else .File
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

// `path` made absolute (Windows's _fullpath, as jq takes for realpath there), or `path` itself when it cannot be.
real_path :: proc(path: string) -> string {
	full, err := os.get_absolute_path(path, context.allocator)
	return full if err == nil else strings.clone(path)
}

local_time :: proc(t: libc.time_t, tm: ^libc.tm) -> bool {
	t := t
	return _localtime64_s(tm, &t) == 0
}

local_mktime :: _mktime64

// libc's strftime, failing a conversion the UCRT does not know (`%s`, `%k`...) as a format that does not fit,
// where the UCRT's default handler would end the process.
c_strftime :: proc(buf: []byte, format: cstring, tm: ^libc.tm) -> uint {
	previous := _set_thread_local_invalid_parameter_handler(proc "c" (_, _, _: [^]u16, _: u32, _: uintptr) {})
	n := libc.strftime(raw_data(buf), len(buf), format, tm)
	_set_thread_local_invalid_parameter_handler(previous)
	return n
}

// TZ set to `tz`, or unset for nil, in the C runtime's environment, which its time functions read.
set_tz :: proc(tz: cstring) {
	_putenv_s("TZ", tz if tz != nil else "")
	_tzset()
}
