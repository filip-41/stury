// Helpers the XML tests share: refusal formatting, built documents, reader, and a log of a walk's tokens.
package xml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

// The fault `validate` returns for `text`, as `code@at`, or "" for a text it accepts.
refusal :: proc(text: string, opts := xml.Options{}) -> string {
	err := xml.validate(transmute([]u8)text, .Xml, opts)
	if f, ok := err.(tape.Fault); ok {
		return fmt.tprintf("%s@%d", testkit.code_of(err), f.at)
	}
	return testkit.code_of(err)
}

// The document of `text`, in the temporary allocator.
built :: proc(t: ^testing.T, text: string, opts := xml.Options{}, loc := #caller_location) -> (doc: tape.Document, ok: bool) {
	d, err := xml.build(transmute([]u8)text, .Xml, opts, context.temp_allocator)
	testing.expectf(t, err == nil, "%v", err, loc = loc)
	return d, err == nil
}

// The reader over `doc`, which holds no index.
reader :: proc(doc: ^tape.Document) -> tape.Reader {
	return {doc = doc}
}

// The tokens of the walk of `text` as `testkit.Token_Log` writes them, where the walk ended and its error, in the
// temporary allocator.
tokens_of :: proc(text: string, opts := xml.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, err: tape.Error) {
	r := testkit.Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
		mode = .Markup,
		ctx  = context,
	}
	r.out = strings.builder_make(context.temp_allocator)
	regs: hook.Regs
	hi, err, _ = xml.walk(r.text, .Xml, opts, &r, &regs, testkit.log_token, context.temp_allocator)
	return strings.trim_space(strings.to_string(r.out)), hi, err
}
