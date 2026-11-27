// Structured error reporting for SQL DDL lexing, parsing, and schema compilation.
// Zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package ddl

import "base:runtime"
import "core:strings"
import "stury:lib/schema/check"

Error_Kind :: enum u8 {
	None,
	Syntax,
	No_Table,
	Duplicate_Column,
	Bad_Check,
	Depth_Limit,
	Compile,
	No_Memory,
}

Error :: struct {
	kind:        Error_Kind,
	offset:      u64,
	line:        u32,
	col:         u32,
	message:     string,
	table:       string,
	column:      string,
	compile_err: check.Compile_Error,
	owned:       bool,
	allocator:   runtime.Allocator,
}

error_destroy :: proc(e: ^Error) {
	if e == nil {
		return
	}
	if e.owned {
		delete(e.message, e.allocator)
		delete(e.table, e.allocator)
		delete(e.column, e.allocator)
	}
	e^ = {}
}

@(private)
make_error :: proc(
	kind: Error_Kind,
	message: string,
	offset: u64 = 0,
	line: u32 = 0,
	col: u32 = 0,
	table := "",
	column := "",
	allocator := context.allocator,
) -> Error {
	if kind == .None {
		return {}
	}
	if allocator.procedure == nil || (table == "" && column == "" && kind == .No_Memory) {
		return {kind = kind, offset = offset, line = line, col = col, message = message}
	}
	out := Error{kind = kind, offset = offset, line = line, col = col, owned = true, allocator = allocator}
	e1, e2, e3: runtime.Allocator_Error
	out.message, e1 = strings.clone(message, allocator)
	if e1 == nil && table != "" {
		out.table, e2 = strings.clone(table, allocator)
	}
	if e1 == nil && e2 == nil && column != "" {
		out.column, e3 = strings.clone(column, allocator)
	}
	if e1 != nil || e2 != nil || e3 != nil {
		error_destroy(&out)
		return {kind = .No_Memory, offset = offset, line = line, col = col, message = "out of memory"}
	}
	return out
}
