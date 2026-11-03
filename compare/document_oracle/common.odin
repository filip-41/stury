// The oracle's arms share the fixtures and the directed texts. Each arm's `document_all` writes every text, through a
// built document and through `format`, to `<out>/<name>.<layout>.json`, and oracle.py compares the two trees' files.
package document_oracle

import "core:fmt"
import "core:os"
import "core:strings"

LAYOUTS := [?]string{"compact", "pretty2", "pretty4", "tab", "ascii", "html", "sort", "sortpretty"}

// A text whose name ends in `JSONC` is read as JSONC.
JSONC :: "_jsonc"

DIRECTED :: [?]string {
	`null`,
	`-0.0`,
	`"a"`,
	`[]`,
	`{}`,
	`[[],{},[[]],{"a":{}}]`,
	`{"a":1,"b":[true,false,null],"c":{"d":"e","f":[1.5e300,-0,0.1]}}`,
	"  [ 1 , 2 ,\n\t3 ]  ",
	`{"esc":"a\né\"\\\/😀","A":"k","":""}`,
	`["é","日本語","😀","<a href=\"x\">&amp;</a>"]`,
	`[1E400,-1e-400,123456789012345678901234567890,0.000000000000000000001]`,
	`[{"a":[{"a":[{"a":[]}]}]}]`,
}

// Texts with comments in every place a comment stands. The directed names add their index to `directedc`.
DIRECTED_JSONC :: [?]string {
	"// top\n{ // after open\n /* lead */ \"a\" /* k */ : /* v */ 1, // trail a\n // lead b\n \"b\": [1, // t1\n 2 /* t2 */ , 3 // last\n ] , \"c\": [] /* c */ , \"d\": { /* only */ } } // end",
	"[1 // a\n]\n// after\n/* more */",
	"1\n// after",
	"{ /* e */ }",
	"[ // x\n]",
	"{\"a\":1 /*t*/ , // t2\n /*f*/ }",
	"/*é😀<&>*/ [\"é\" /* <a href=\"x\">é😀 */]",
	"[[1 //\n,2,/**/],{},{\"k\":{/**/}}]//\n",
	"{\"b\":1, // one\n \"a\":2 /* two */, \"b\":3}",
	"[1,2,]",
}

Arm :: proc(name: string, src: []u8)

// Calls `arm` for each JSON file of the fixtures directory and its `corpus` directory, and each directed text.
all_texts :: proc(arm: Arm) {
	for dir in ([?]string{os.args[1], fmt.tprintf("%s/corpus", os.args[1])}) {
		entries, err := os.read_all_directory_by_path(dir, context.allocator)
		assert(err == nil, dir)
		for entry in entries {
			jsonc := strings.has_suffix(entry.name, ".jsonc")
			if !jsonc && !strings.has_suffix(entry.name, ".json") {
				continue
			}
			src, rerr := os.read_entire_file_from_path(entry.fullpath, context.allocator)
			assert(rerr == nil, entry.name)
			arm(fmt.tprintf("%s%s", strings.trim_suffix(strings.trim_suffix(entry.name, ".jsonc"), ".json"), JSONC if jsonc else ""), src)
		}
	}
	for text, i in DIRECTED {
		arm(fmt.tprintf("directed%02d", i), transmute([]u8)text)
	}
	for text, i in DIRECTED_JSONC {
		arm(fmt.tprintf("directedc%02d%s", i, JSONC), transmute([]u8)text)
	}
}

write_text :: proc(name: string, text: []u8) {
	assert(os.write_entire_file(fmt.tprintf("%s/%s", os.args[2], name), text) == nil, name)
}
