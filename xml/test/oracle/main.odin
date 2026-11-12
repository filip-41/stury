package xml_oracle

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import core "../../../core"
import xml "../.."

// The texts `cmd/stury/test/xml_diff.py` sends, read from standard input as a four-byte little-endian length and that
// many bytes each. Writes for each its verdict on a line: `ok`, or `err` with the offset and the rule's code. A reference
// to an entity no subset read declares is read as its text, as expat skips it.
main :: proc() {
	in_stream := os.to_stream(os.stdin)
	reader: bufio.Reader
	bufio.reader_init(&reader, in_stream)
	out := os.to_stream(os.stdout)
	writer: bufio.Writer
	bufio.writer_init(&writer, out)
	defer bufio.writer_flush(&writer)
	size: [4]u8
	for {
		if _, err := io.read_full(bufio.reader_to_stream(&reader), size[:]); err != nil {
			return
		}
		text := make([]u8, int(size[0]) | int(size[1]) << 8 | int(size[2]) << 16 | int(size[3]) << 24)
		if _, err := io.read_full(bufio.reader_to_stream(&reader), text); err != nil {
			fmt.eprintln("short text")
			os.exit(2)
		}
		if fault, bad := xml.validate(text, .Xml, {tolerate = {.Unread_Entity}}).(core.Fault); bad {
			fmt.wprintfln(bufio.writer_to_stream(&writer), "err %d %s", fault.at, core.rule_of(fault).code)
		} else {
			fmt.wprintln(bufio.writer_to_stream(&writer), "ok")
		}
		delete(text)
	}
}
