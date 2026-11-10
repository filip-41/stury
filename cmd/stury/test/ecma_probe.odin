// ecma_diff.py's reader of ECMA patterns: a file of a JSON array of [pattern, text] pairs, and for each a line on stdout,
// `E` for a pattern core/regex refuses, `W` where a search that reads no bounds answers otherwise, `-` for no match, or each group's start and length in code points with the
// whole match first, -1 -1 for a group that did not take part.
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "../../../core/regex"

main :: proc() {
	input, read_err := os.read_entire_file(os.args[1] if len(os.args) > 1 else "", context.allocator)
	cases: [][]string
	if read_err != nil || json.unmarshal(input, &cases) != nil {
		fmt.eprintln("usage: ecma_probe FILE, of a JSON array of [pattern, text] pairs")
		os.exit(2)
	}
	scratch: regex.Scratch
	for c in cases {
		if len(c) != 2 {
			fmt.eprintln("usage: ecma_probe FILE, of a JSON array of [pattern, text] pairs")
			os.exit(2)
		}
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		defer virtual.arena_destroy(&arena)
		re, err := regex.compile(c[0], {ecma = true}, virtual.arena_allocator(&arena))
		if err != "" {
			fmt.println("E")
			continue
		}
		caps := make([]int, 2 * len(re.names), virtual.arena_allocator(&arena))
		found, search_err := regex.search(&re, c[1], 0, caps, &scratch)
		if search_err != "" {
			fmt.println("E", search_err)
			continue
		}
		// A search that reads no bounds takes the automaton where there is one, and must find a match as this one does.
		if whether, _ := regex.search(&re, c[1], 0, nil, &scratch); whether != found {
			fmt.println("W")
			continue
		}
		if !found {
			fmt.println("-")
			continue
		}
		b := strings.builder_make(virtual.arena_allocator(&arena))
		for k := 0; k < len(caps); k += 2 {
			lo, hi := caps[k], caps[k + 1]
			if lo < 0 || hi < 0 {
				strings.write_string(&b, " -1 -1")
			} else {
				fmt.sbprintf(&b, " %d %d", utf8.rune_count(c[1][:lo]), utf8.rune_count(c[1][lo:hi]))
			}
		}
		fmt.println(strings.to_string(b)[1:])
	}
}
