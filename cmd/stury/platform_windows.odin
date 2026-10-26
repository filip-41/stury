package main

// The command line's calls into the system on Windows. platform_posix.odin has POSIX's. Reads and writes go through
// core:os, which calls ReadFile and WriteFile, so stdin and stdout are binary as they are on POSIX.

import "core:io"
import "core:os"
import win "core:sys/windows"

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
	return os.open(path)
}

is_regular_file :: proc(f: ^os.File) -> bool {
	return win.GetFileType(win.HANDLE(os.fd(f))) == win.FILE_TYPE_DISK
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

// Every file is read.
map_file :: proc(f: ^os.File) -> ([]byte, bool) {
	return nil, false
}

unmap_file :: proc(data: []byte) {}
