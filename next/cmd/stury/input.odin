package main

// Reading the files and stdin a run names.

import "base:runtime"
import "core:io"
import "core:os"
import "core:sys/posix"

// The inputs a run reads.
Inputs :: struct {}

// The name of the input whose file is mapped, which the fault handler reports when the file shrinks under its mapping.
mapped_input_name: string

// All of file `f`, to its end. os.read_entire_file reads as many bytes as fstat gives, which for a pipe is
// only what is in it so far, so it reads only a regular file.
read_whole :: proc(f: ^os.File, allocator: runtime.Allocator) -> (data: []byte, err: os.Error) {
	if is_regular_file(f) {
		return os.read_entire_file(f, allocator)
	}
	all := make([dynamic]byte, 0, 1 << 16, allocator)
	chunk: [1 << 16]byte
	for {
		n, rerr := read_some(f, chunk[:])
		append(&all, ..chunk[:n])
		if rerr != nil || n == 0 {
			if rerr != io.Error.EOF {
				err = rerr
			}
			break
		}
	}
	return all[:], err
}

// What C's strerror says of `err`, which jq prints.
strerror :: proc(err: os.Error) -> string {
	#partial switch e in err {
	case os.Platform_Error:
		return platform_error_text(e)
	case os.General_Error:
		if e == .Not_Exist {
			return string(posix.strerror(posix.Errno.ENOENT))
		}
	case io.Error:
		if e == .Permission_Denied {
			return string(posix.strerror(posix.Errno.EACCES))
		}
	}
	return os.error_string(err)
}
