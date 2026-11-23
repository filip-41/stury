// lib/base/regex under ECMA-262's syntax, as main.odin of the oracle uses it.
package ecma

import "core:mem"
import regex "stury:lib/base/regex"

Regex :: regex.Regex
Scratch :: regex.Scratch

scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	return regex.scratch_make(allocator)
}

compile :: proc(pattern: string, allocator: mem.Allocator) -> (re: Regex, ok: bool) {
	err: string
	re, err = regex.compile(pattern, {ecma = true}, allocator, context.allocator)
	return re, err == ""
}

groups :: proc(re: ^Regex) -> int {
	return len(regex.group_names(re))
}

// The message of a search that gave up, "" otherwise.
search :: proc(re: ^Regex, text: string, caps: []int, scratch: ^Scratch) -> (found: bool, message: string) {
	err: regex.Error
	found, err = regex.search(re, text, 0, caps, scratch)
	return found, err.message
}
