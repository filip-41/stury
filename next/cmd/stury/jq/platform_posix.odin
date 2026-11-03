#+build !windows
package jq

// The interpreter's calls into the system on POSIX. platform_windows.odin has Windows's.

import "core:c/libc"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import system "system:System"
} else {
	foreign import system "system:c"
}

// core:sys/posix does not bind it.
@(default_calling_convention = "c")
foreign system {
	timegm :: proc(tm: ^libc.tm) -> libc.time_t ---
}

// The longest $HOME looked in for `~/.jq`, on Darwin (1024) as on Linux (4096).
PATH_MAX :: 4096

home_dir :: proc() -> cstring {
	return posix.getenv("HOME")
}

path_kind :: proc(path: cstring) -> Path_Kind {
	st: posix.stat_t
	if posix.stat(path, &st) == .OK {
		return .Dir if posix.S_ISDIR(st.st_mode) else .File
	}
	return .Missing if posix.errno() == .ENOENT else .Unreadable
}

// The directory of `path`, or `path` itself when dirname gives none. (Darwin's dirname returns one static buffer:
// the callers are on one thread, or have the answer before any other starts: `jq_origin`.)
dir_name :: proc(path: string) -> string {
	dir := posix.dirname(strings.clone_to_cstring(path, context.temp_allocator))
	if dir == nil {
		return strings.clone(path)
	}
	return strings.clone_from_cstring(dir)
}

// `path` made real, or `path` itself when it cannot be.
real_path :: proc(path: string) -> string {
	real := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator))
	if real == nil {
		return strings.clone(path)
	}
	defer posix.free(real)
	return strings.clone_from_cstring(real)
}

utc_time :: proc(t: libc.time_t, tm: ^libc.tm) -> bool {
	t := t
	return posix.gmtime_r(&t, tm) != nil
}

local_time :: proc(t: libc.time_t, tm: ^libc.tm) -> bool {
	t := t
	return posix.localtime_r(&t, tm) != nil
}

local_mktime :: libc.mktime

c_strftime :: proc(buf: []byte, format: cstring, tm: ^libc.tm) -> uint {
	return libc.strftime(raw_data(buf), len(buf), format, tm)
}

// TZ set to `tz`, or unset for nil.
set_tz :: proc(tz: cstring) {
	if tz != nil {
		posix.setenv("TZ", tz, true)
	} else {
		posix.unsetenv("TZ")
	}
	// Darwin's libc notices the change itself, and a tzset there reloads the zone file on every call.
	when ODIN_OS != .Darwin {
		posix.tzset()
	}
}

strptime :: proc(input, format: cstring, tm: ^libc.tm) -> cstring {
	return posix.strptime(([^]u8)(rawptr(input)), format, tm)
}
