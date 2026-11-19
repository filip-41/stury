package jq

// What the interpreter asks of the program that runs it, which alone reaches the system: the inputs `input` reads,
// where `debug`, `stderr` and `halt_error` write, the environment `$ENV` reads, and the files and directories modules
// are found and loaded from. A nil procedure is a system the caller does not give: no inputs, no messages, an empty
// environment, no module or data file, no home directory.

import "core:c/libc"
import "core:strings"
import core_pkg "../core"

Hooks :: struct {
	inputs:    Input_Source,
	data:      rawptr, // what every procedure below is given
	// Writes `debug`, `stderr` and `halt_error` output, as the run writes it.
	messages:  proc(data: rawptr, text: []byte),
	// The environment as `NAME=value` texts, or why it cannot be read.
	environ:   proc(data: rawptr, allocator := context.allocator) -> (vars: []string, err: string),
	// jq's jv_load_file, which modules and data files are read with: the file as one string (`raw`) or as the array of
	// its JSON texts read as `r` says, or jq's message for why not.
	load_file: proc(data: rawptr, path: string, raw: bool, r: core_pkg.As) -> (core_pkg.Value, string),
	path_kind: proc(data: rawptr, path: string) -> Path_Kind,
	// `path` made real, or `path` itself when it cannot be.
	real_path: proc(data: rawptr, path: string, allocator := context.allocator) -> string,
	// The home directory, as $HOME names it (jq's Windows build: else %USERPROFILE%), and whether it is set.
	home:      proc(data: rawptr) -> (string, bool),
	// The time in seconds since the Unix epoch, which `now` and `uuid_v7` read.
	now:       proc(data: rawptr) -> f64,
	// The zone in force at the instant `secs` seconds since the Unix epoch, and whether it can be had. Everything the
	// interpreter reads as local time (`localtime`, `strflocaltime`, `%Z`, `%s` and `%z` of a local time, `mktime` of a
	// local broken-down time, strptime's `%s` on Windows) is this zone's. Nil is the process's own time zone.
	zone:      proc(data: rawptr, secs: i64) -> (zone: Zone, ok: bool),
	// `buf` filled with random bytes, which the uuids are made of.
	random:    proc(data: rawptr, buf: []byte),
}

// The inputs `input` and `inputs` read, and where the input being read lies.
Input_Source :: struct {
	data:     rawptr,
	next:     proc(data: rawptr) -> (v: core_pkg.Value, msg: string, status: Input_Status),
	position: proc(data: rawptr) -> (name: string, line: int), // the input being read, "" before any
}

// What stat tells of a path: a missing one is ENOENT, and an unreadable one any other failure.
Path_Kind :: enum {
	File,
	Dir,
	Missing,
	Unreadable,
}

@(private)
path_kind :: proc(ip: ^Interp, path: string) -> Path_Kind {
	if ip.hooks.path_kind == nil {
		return .Missing
	}
	return ip.hooks.path_kind(ip.hooks.data, path)
}

@(private)
real_path :: proc(ip: ^Interp, path: string) -> string {
	if ip.hooks.real_path == nil {
		return path
	}
	return ip.hooks.real_path(ip.hooks.data, path)
}

@(private)
home_dir :: proc(ip: ^Interp) -> (string, bool) {
	if ip.hooks.home == nil {
		return "", false
	}
	return ip.hooks.home(ip.hooks.data)
}

@(private)
load_file :: proc(ip: ^Interp, path: string, raw: bool) -> (core_pkg.Value, string) {
	if ip.hooks.load_file == nil {
		return nil, strings.concatenate({"Could not open ", path, ": no files are given"})
	}
	return ip.hooks.load_file(ip.hooks.data, path, raw, ip.reading)
}

// A time zone at one instant: its offset east of UTC in seconds, its abbreviation, and whether it is daylight time.
Zone :: struct {
	offset: int,
	name:   string,
	dst:    bool,
}

// `t` as broken-down local time, in the hook's zone when there is one, else the process's.
@(private)
local_tm :: proc(ip: ^Interp, t: libc.time_t, tm: ^libc.tm) -> bool {
	if ip.hooks.zone == nil {
		return local_time(t, tm)
	}
	z, ok := ip.hooks.zone(ip.hooks.data, i64(t))
	if !ok || !utc_time(t + libc.time_t(z.offset), tm) {
		return false
	}
	tm.tm_isdst = 1 if z.dst else 0
	return true
}

// Normalizes `tm`, read as local time, as mktime does, and gives the zone in force at it. Without a zone hook it is
// the C library's mktime, and the zone comes back empty.
@(private)
local_mktime_in :: proc(ip: ^Interp, tm: ^libc.tm) -> (z: Zone, ok: bool) {
	if ip.hooks.zone == nil {
		local_mktime(tm)
		return {}, true
	}
	// The offset at the wall-clock time read as UTC names the instant, unless the zone changes between the two.
	wall := tm^
	t0 := i64(timegm(&wall))
	z = ip.hooks.zone(ip.hooks.data, t0) or_return
	t := t0 - i64(z.offset)
	if again, found := ip.hooks.zone(ip.hooks.data, t); found && again.offset != z.offset {
		z = again
		t = t0 - i64(z.offset)
	}
	return z, local_tm(ip, libc.time_t(t), tm)
}
