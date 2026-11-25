package cbor

import "core:strconv"
import "stury:lib/base/spell"
import "stury:lib/ops/write"

// The tags a value of another format holds as text, written as the tags CBOR has for the types they name: tag 0 on a
// date-time's text (RFC 8949 section 3.4.1) and tag 1004 on a full date's (RFC 8943). A tag's number in decimal is
// that tag, which a CBOR document's tags are given as.

// The tag 1004 puts on a full date.
@(private)
FULL_DATE_TAG :: 1004

// A tag waiting for its value, whose text decides whether it is written.
@(private)
Text_Tag :: struct {
	kind:   Text_Tag_Kind,
	number: u64, // of `.Number`
}

@(private)
Text_Tag_Kind :: enum u8 {
	Number, // written on any value
	Date_Time, // on a string that is a date-time with an offset
	Full_Date, // on a string that is a full date
	Timestamp, // on a string of either, as YAML's timestamp is both
}

// The tag a name stands for: a date-time's or full date's type as TOML spells them, YAML's timestamp in its short,
// verbatim and URI spellings, or the number of a tag in decimal. False for a tag CBOR has no spelling of.
@(private)
text_tag_of :: proc(name: string) -> (t: Text_Tag, ok: bool) {
	switch name {
	case "datetime":
		return {kind = .Date_Time}, true
	case "date-local":
		return {kind = .Full_Date}, true
	case "!!timestamp", "!<tag:yaml.org,2002:timestamp>", "tag:yaml.org,2002:timestamp":
		return {kind = .Timestamp}, true
	}
	n, parsed := strconv.parse_u64_of_base(name, 10)
	return {kind = .Number, number = n}, parsed && len(name) > 0
}

// Writes the heads of `tags`, in order, before the value whose text is `text`, the heads that value takes. Returns how
// many it wrote.
@(private)
put_text_tags :: proc(out: ^write.Out, tags: []Text_Tag, text: string) -> (written: int) {
	for t in tags {
		number: u64
		switch t.kind {
		case .Number:
			number = t.number
		case .Date_Time:
			if !spell.is_date_time(text) {
				continue
			}
		case .Full_Date:
			if !spell.is_full_date(text) {
				continue
			}
			number = FULL_DATE_TAG
		case .Timestamp:
			switch {
			case spell.is_date_time(text):
			case spell.is_full_date(text):
				number = FULL_DATE_TAG
			case:
				continue
			}
		}
		put_head(out, 6, number)
		written += 1
	}
	return
}
