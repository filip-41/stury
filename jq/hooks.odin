package jq

// What the interpreter asks of the program that runs it, which alone reaches the system: the inputs `input` reads,
// where `debug`, `stderr` and `halt_error` write, the environment `$ENV` reads, and the files and directories modules
// are found and loaded from. A nil procedure is a system the caller does not give: no inputs, no messages, an empty
// environment, no module or data file, no home directory.

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
