package main

// The command line's calls into the system on Windows. platform_posix.odin has POSIX's. Reads and writes go through
// core:os, which calls ReadFile and WriteFile, so stdin and stdout are binary as they are on POSIX.

import "core:c/libc"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:time"
import "../../jq"

// The main thread gets the 8 MiB of stack POSIX gives it, not the linker's 1 MiB: a schema's read and bind recurse
// there as deep as their depth bound.
@(extra_linker_flags = "/STACK:8388608")
foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	SetThreadStackGuarantee :: proc(StackSizeInBytes: ^win.ULONG) -> win.BOOL ---
}

// The stack the overflow handler is left to run on, once the interpreter's is spent.
@(private = "file")
STACK_GUARANTEE :: 64 << 10
@(private = "file")
deep_thread: win.DWORD

// `body` on a thread of its own whose stack is DEEP_STACK reserved and committed only as it is touched. The run ends
// as one out of memory if the thread cannot be had.
run_deep :: proc(run: ^Run, ins: ^Inputs, body: proc(run: ^Run, ins: ^Inputs)) {
	job := Deep_Job{run, ins, body, context}
	win.AddVectoredExceptionHandler(1, stack_spent)
	t := win.CreateThread(nil, DEEP_STACK, proc "system" (arg: rawptr) -> win.DWORD {
		job := (^Deep_Job)(arg)
		context = job.ctx
		guarantee := win.ULONG(STACK_GUARANTEE)
		SetThreadStackGuarantee(&guarantee)
		deep_thread = win.GetCurrentThreadId()
		job.body(job.run, job.ins)
		return 0
	}, &job, win.STACK_SIZE_PARAM_IS_A_RESERVATION, nil)
	if t == nil {
		// As on POSIX: no stack, no guard against the recursion.
		os.write_string(os.stderr, "stury: error: cannot allocate memory\n")
		os.exit(EXIT_USAGE)
	}
	win.WaitForSingleObject(t, win.INFINITE)
	win.CloseHandle(t)
}

// The interpreter's stack overflowing its reservation: jq's message for memory run out, then the end abort()
// gives, as jq ends then (jv_alloc.c's memory_exhausted). Any other exception is left to the next handler.
@(private = "file")
stack_spent :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	if info.ExceptionRecord.ExceptionCode == win.EXCEPTION_STACK_OVERFLOW && win.GetCurrentThreadId() == deep_thread {
		msg: string = "stury: error: cannot allocate memory\n"
		written: win.DWORD
		win.WriteFile(win.GetStdHandle(win.STD_ERROR_HANDLE), raw_data(msg), win.DWORD(len(msg)), &written, nil)
		win.TerminateProcess(win.GetCurrentProcess(), 3)
	}
	return win.EXCEPTION_CONTINUE_SEARCH
}

// All of `p` written to stdout. core:os continues a short write.
write_stdout :: proc(p: []byte) -> os.Error {
	_, err := os.write(os.stdout, p)
	return err
}

// Closes stdout, which fails when the process has none.
close_stdout :: proc() -> os.Error {
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	if h == nil || h == win.INVALID_HANDLE_VALUE {
		return os.Platform_Error(win.System_Error.INVALID_HANDLE)
	}
	if !win.CloseHandle(h) {
		return os.Platform_Error(win.GetLastError())
	}
	return nil
}

// A console, as isatty tells one: GetConsoleMode fails on a pipe, a file and the NUL device.
is_terminal :: proc(f: ^os.File) -> bool {
	mode: win.DWORD
	return bool(win.GetConsoleMode(win.HANDLE(os.fd(f)), &mode))
}

// jq's colours are escape sequences, which a console reads only in its virtual terminal mode.
enable_color :: proc() {
	for which in ([]win.DWORD{win.STD_OUTPUT_HANDLE, win.STD_ERROR_HANDLE}) {
		h := win.GetStdHandle(which)
		mode: win.DWORD
		if win.GetConsoleMode(h, &mode) {
			win.SetConsoleMode(h, mode | win.ENABLE_PROCESSED_OUTPUT | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
		}
	}
}

// The command line in UTF-8. os.args is the C runtime's argv, in the ANSI code page, which spells no character
// outside it. An argument UTF-8 cannot spell (a lone surrogate) is os.args's.
command_args :: proc() -> []string {
	argc: i32
	argv := win.CommandLineToArgvW(win.GetCommandLineW(), &argc)
	if argv == nil || int(argc) != len(os.args) {
		return os.args
	}
	args := make([]string, argc)
	for arg, i in argv[:argc] {
		text, _ := win.wstring_to_utf8(arg, -1, context.allocator)
		args[i] = text if text != "" || len(arg) == 0 else os.args[i]
	}
	return args
}

// Windows keeps no owner or group to give.
keep_owner :: proc(f: ^os.File, path: string) {}

// os.open for a file the user names.
open_input :: proc(path: string) -> (^os.File, os.Error) {
	return os.open(long_path(path))
}

// `path`, made absolute when it is too long to be taken as relative: where LongPathsEnabled is off, core:os gives a
// long absolute path the `\\?\` prefix that lifts MAX_PATH, and leaves a relative one as it is.
long_path :: proc(path: string) -> string {
	if len(path) < 248 {
		return path
	}
	full, err := os.get_absolute_path(path, context.temp_allocator)
	return full if err == nil else path
}

// Ctrl-C and Ctrl-Break set `stopped`, which a --follow run takes as its file's end, as SIGINT does on POSIX.
catch_stop :: proc() {
	win.SetConsoleCtrlHandler(proc "system" (kind: win.DWORD) -> win.BOOL {
		if kind != win.CTRL_C_EVENT && kind != win.CTRL_BREAK_EVENT {
			return false
		}
		sync.atomic_store(&stopped, 1)
		return true
	}, true)
}

// Ends the process with STATUS_CONTROL_C_EXIT once a stopped --follow run's answers are written, the status Ctrl-C
// ends jq with.
end_if_stopped :: proc() {
	if sync.atomic_load(&stopped) != 0 {
		os.exit(0xC000013A)
	}
}

// Whether a read of `f` would not wait, found within `wait`. A file, a console and a pipe its writer closed are read
// at once.
read_ready :: proc(f: ^os.File, wait: time.Duration) -> bool {
	held: u32
	peek := !win.PeekNamedPipe(win.HANDLE(os.fd(f)), nil, 0, nil, &held, nil) || held > 0
	if !peek && wait > 0 {
		time.sleep(wait)
		peek = !win.PeekNamedPipe(win.HANDLE(os.fd(f)), nil, 0, nil, &held, nil) || held > 0
	}
	return peek
}

is_regular_file :: proc(f: ^os.File) -> bool {
	return win.GetFileType(win.HANDLE(os.fd(f))) == win.FILE_TYPE_DISK
}

// Whether a read of `f` gives bytes within `wait`: a pipe holding some.
readable :: proc(f: ^os.File, wait: time.Duration = 0) -> bool {
	held: u32
	peek := bool(win.PeekNamedPipe(win.HANDLE(os.fd(f)), nil, 0, nil, &held, nil)) && held > 0
	if !peek && wait > 0 {
		time.sleep(wait)
		peek = bool(win.PeekNamedPipe(win.HANDLE(os.fd(f)), nil, 0, nil, &held, nil)) && held > 0
	}
	return peek
}

// os.read, with a pipe closed by its writer as its end: ReadFile fails it as ERROR_BROKEN_PIPE.
read_some :: proc(f: ^os.File, p: []byte) -> (int, os.Error) {
	n, err := os.read(f, p)
	if err == os.General_Error.Broken_Pipe {
		err = io.Error.EOF
	}
	return n, err
}

// A Windows error code's name: core:os has already told the ones C's strerror has words for (a file not
// found, access denied) as General_Error.
platform_error_text :: proc(e: os.Platform_Error) -> string {
	return os.error_string(e)
}

peak_rss :: proc() -> int {
	counters := win.PROCESS_MEMORY_COUNTERS{cb = size_of(win.PROCESS_MEMORY_COUNTERS)}
	if !win.GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, size_of(counters)) {
		return 0
	}
	return int(counters.PeakWorkingSetSize)
}

// Windows refuses to rename over a file while a view of it is mapped.
REPLACES_MAPPED :: false

// Regular file `f`, from its current offset `at` to its end, mapped read-only, as platform_posix.odin maps it, and left
// at its end. The view starts at the allocation granule before the offset, which `unmap_file` finds again. Windows
// refuses to truncate a file while a view of it is mapped, so no page of the view loses its bytes.
map_file :: proc(f: ^os.File) -> (data: []byte, at: i64, ok: bool) {
	if !is_regular_file(f) {
		return
	}
	size, err := os.file_size(f)
	if err != nil {
		return
	}
	if at, err = os.seek(f, 0, .Current); err != nil || size <= at {
		return
	}
	granule := i64(system_info().dwAllocationGranularity)
	lo := at / granule * granule
	m := win.CreateFileMappingW(win.HANDLE(os.fd(f)), nil, win.PAGE_READONLY, 0, 0, nil)
	if m == nil {
		return
	}
	p := win.MapViewOfFile(m, win.FILE_MAP_READ, win.DWORD(u64(lo) >> 32), win.DWORD(u64(lo)), uint(size - lo))
	// The view holds the mapping open.
	win.CloseHandle(m)
	if p == nil {
		return
	}
	os.seek(f, size, .Start)
	return ([^]byte)(p)[at - lo:size - lo], at, true
}

// The whole pages of data[from:to], and the page data[from] is in, dropped from the working set: VirtualUnlock on pages
// that are not locked removes them from it and returns ERROR_NOT_LOCKED, which is no failure here. A read of them maps
// them again from the file.
map_afresh :: proc(f: ^os.File, data: []byte, at: i64, from, to: int) {
	page := i64(system_info().dwPageSize)
	lo, hi := (at + i64(from)) / page * page, (at + i64(to)) / page * page
	if lo < hi {
		win.VirtualUnlock(rawptr(uintptr(raw_data(data)) + uintptr(lo - at)), uint(hi - lo))
	}
}

unmap_file :: proc(data: []byte) {
	granule := uintptr(system_info().dwAllocationGranularity)
	win.UnmapViewOfFile(rawptr(uintptr(raw_data(data)) / granule * granule))
}

@(private = "file")
system_info :: proc() -> (info: win.SYSTEM_INFO) {
	win.GetSystemInfo(&info)
	return
}

// $HOME, or else %USERPROFILE%, as jq finds the home directory on Windows.
home_dir :: proc(_: rawptr) -> (string, bool) {
	home := libc.getenv("HOME")
	if home == nil {
		home = libc.getenv("USERPROFILE")
	}
	return string(home), home != nil
}

path_kind :: proc(_: rawptr, path: string) -> jq.Path_Kind {
	attrs := win.GetFileAttributesW(win.utf8_to_wstring(path, context.temp_allocator))
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		e := win.GetLastError()
		return .Missing if e == win.ERROR_FILE_NOT_FOUND || e == win.ERROR_PATH_NOT_FOUND else .Unreadable
	}
	return .Dir if attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0 else .File
}

// `path` made absolute (Windows's _fullpath, as jq takes for realpath there), or `path` itself when it cannot be.
real_path :: proc(_: rawptr, path: string, allocator := context.allocator) -> string {
	full, err := os.get_absolute_path(path, allocator)
	return full if err == nil else strings.clone(path, allocator)
}

// Whether `path` names a directory, and its size. False when it names nothing.
path_stat :: proc(path: string) -> (kind: Entry_Kind, ok: bool) {
	info, err := os.stat(long_path(path), context.temp_allocator)
	if info.type == .Regular {
		return .Long if int(info.size) >= FILES_LONG else .File, err == nil
	}
	return .Dir if info.type == .Directory else .Other, err == nil
}

// The bytes of the regular file `path`, read whole into `buf` when it holds fewer than `limit`. `.Left` when it is
// longer, is not a regular file or does not open or read, which the caller then opens as any other.
read_short :: proc(path: string, buf: ^[dynamic]byte, limit: int) -> (data: []byte, read: Short_Read) {
	f, err := os.open(long_path(path))
	if err != nil {
		return nil, .Left
	}
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil || !is_regular_file(f) {
		return nil, .Left
	}
	if size >= i64(limit) {
		return nil, .Long
	}
	// One byte past the size, so a file that grew since its size was taken is read to its end or found long.
	non_zero_resize(buf, int(size) + 1)
	n := 0
	for n < len(buf) {
		got, rerr := os.read(f, buf[n:])
		if got == 0 || rerr == io.Error.EOF {
			return buf[:n], .Read
		}
		if rerr != nil {
			return nil, .Left
		}
		n += got
	}
	return nil, .Long
}

// The entries of directory `path` but `.` and `..`, each of the kind its directory entry gives.
list_dir :: proc(path: string) -> (entries: [dynamic]Dir_Entry, err: os.Error) {
	infos := os.read_all_directory_by_path(long_path(path), context.allocator) or_return
	defer os.file_info_slice_delete(infos, context.allocator)
	for fi in infos {
		#partial switch fi.type {
		case .Regular:   append(&entries, Dir_Entry{strings.clone(fi.name), .File})
		case .Directory: append(&entries, Dir_Entry{strings.clone(fi.name), .Dir})
		}
	}
	return
}
