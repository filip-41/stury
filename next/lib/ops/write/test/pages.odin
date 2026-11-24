package write_tests

import "core:mem"
import "core:mem/virtual"

// A mapping whose last page has no access, with texts copied to end at its last readable byte, so a write that reads
// a byte past the text it was given faults.
@(private)
Fence :: struct {
	base: rawptr,
	span: uint,
	size: uint,
}

// Copies `src` to the end of the readable pages of `f`, mapping it first when it holds less than `len(src)` bytes.
@(private)
fence_copy :: proc(f: ^Fence, src: []u8) -> []u8 {
	page := uint(mem.PAGE_SIZE)
	span := max((uint(len(src)) + page - 1) & ~(page - 1), page)
	if f.base == nil || f.span < span {
		fence_release(f)
		size := span + page
		mapped, err := virtual.reserve_and_commit(size)
		if err != nil || !virtual.protect(rawptr(uintptr(raw_data(mapped)) + uintptr(span)), page, virtual.Protect_No_Access) {
			panic("the fence could not be mapped")
		}
		f^ = {raw_data(mapped), span, size}
	}
	dst := ([^]u8)(f.base)[f.span - uint(len(src)):f.span]
	copy(dst, src)
	return dst
}

@(private)
fence_release :: proc(f: ^Fence) {
	if f.base != nil {
		virtual.release(f.base, f.size)
	}
	f^ = {}
}
