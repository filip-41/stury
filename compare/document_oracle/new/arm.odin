package document_oracle

import "core:fmt"
import "core:strings"
import core "next:core"
import json "next:json"

OPTS :: [?]core.Write_Options {
	{},
	{pretty = true, indent = 2},
	{pretty = true, indent = 4},
	{pretty = true, tab = true},
	{ascii = true},
	{escape_html = true},
	{sort_keys = true},
	{pretty = true, indent = 2, sort_keys = true},
}

arm :: proc(name: string, src: []u8) {
	jsonc := strings.has_suffix(name, JSONC)
	doc: core.Document
	err: core.Document_Error
	if jsonc {
		doc, err = json.build(src, .Jsonc)
	} else {
		doc, err = json.build(src, .Json)
	}
	if err.kind != .None {
		write_text(fmt.tprintf("%s.refused", name), transmute([]u8)string("refused"))
		return
	}
	defer core.destroy(&doc)
	for opts, i in OPTS {
		text, _, werr := core.write(&doc, opts)
		assert(werr.kind == .None, fmt.tprint(name, werr))
		write_text(fmt.tprintf("%s.%s.json", name, LAYOUTS[i]), text)
		direct: []u8
		ferr: core.Typed_Error
		if jsonc {
			direct, ferr = json.format(src, .Jsonc, opts)
		} else {
			direct, ferr = json.format(src, .Json, opts)
		}
		assert(ferr.kind == .None, fmt.tprint(name, ferr))
		write_text(fmt.tprintf("%s.%s.format.json", name, LAYOUTS[i]), direct)
	}
}

main :: proc() {
	all_texts(arm)
}
