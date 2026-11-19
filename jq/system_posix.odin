#+build !windows
#+private
package jq

// The C library's calendar time on POSIX, and paths as POSIX spells them. system_windows.odin has Windows's.

import "core:c/libc"
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

// The directory of `path`, as POSIX's dirname gives it: "." for a path with none, and the separators at the end of the
// path and of its directory dropped, but a root's own.
dir_name :: proc(path: string) -> string {
	end := len(path)
	for end > 1 && path[end - 1] == '/' {
		end -= 1
	}
	slash := end - 1
	for slash >= 0 && path[slash] != '/' {
		slash -= 1
	}
	if slash < 0 {
		return "."
	}
	for slash > 0 && path[slash - 1] == '/' {
		slash -= 1
	}
	return path[:slash] if slash > 0 else "/"
}

is_absolute_path :: proc(path: string) -> bool {
	return len(path) > 0 && path[0] == '/'
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

strptime :: proc(input, format: cstring, tm: ^libc.tm) -> cstring {
	return posix.strptime(([^]u8)(rawptr(input)), format, tm)
}
