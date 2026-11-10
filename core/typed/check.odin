package typed

import "base:runtime"
import core ".."

// A read that reports every refusal to its sink as a `core.Error_Entry` with the full path, a `Reader` with the hook the
// checks of a model add to. `check_start` starts one.
Check :: struct {
	using reader: Reader,
}

// A format's read of a whole text into `target`, a value of `plan`'s type `T`, under the handle `as`.
Text_Read :: #type proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Error

// A format's read of a node of a built document into `target`.
Node_Read :: #type proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Error

// What a format reads typed values with, where its `Services.reads` points. A plan copies the procedures. `check` and
// `node_check` are the reads that report to a `Sink`'s `entries`, nil for a format that has none.
Format_Reads :: struct {
	read, check:           Text_Read,
	node_read, node_check: Node_Read,
	build:                 Text_Build,
}

// Builds `src` as a document of the format `as` names, as a format's `Format_Reads` does for `write.marshal_value`.
Text_Build :: #type proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error)

// Starts a `Check` read, as `read_start` starts a read of the plan's own type. Its sink takes `core.Error_Entry`s.
check_start :: proc(c: ^Check, src: []u8, plan: ^Plan, as: core.As, T: typeid, target: rawptr, read: Read_Options, frames: []Frame, allocator: runtime.Allocator) -> (regs: core.Hook_Regs, err: core.Typed_Error) {
	regs, err = read_start(&c.reader, src, plan, as, T, target, read, frames, allocator)
	c.wide = true
	return
}

// Reads `src` into `target` as the plan's format does, `.Plan_Mismatch` when the plan has no read.
unmarshal_text :: proc(src: []u8, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator := context.allocator) -> core.Error {
	if plan == nil || plan.read == nil {
		return core.error_of(plan_mismatch(plan, nil, T))
	}
	return core.error_of(plan.read(src, plan.as, target, T, plan, read, allocator))
}

// Reads `src` into `target` as `unmarshal_text` does, with every refusal in `read.sink.entries`. Returns the first.
check_text :: proc(src: []u8, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator := context.allocator) -> core.Error {
	if plan == nil || plan.check == nil {
		return core.error_of(plan_mismatch(plan, nil, T))
	}
	return core.error_of(plan.check(src, plan.as, target, T, plan, read, allocator))
}
