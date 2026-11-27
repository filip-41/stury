#+test
package xml

// Whether the units of a text in pieces framed in blocks are those the byte machine frames: `text` framed to `cut` and
// then to its end, once each way. Only a test build holds it.
units_agree :: proc "contextless" (text: []u8, cut: int) -> bool {
	blocks, bytes: Units
	units_frame(&blocks, raw_data(text), u64(cut), true)
	units_frame(&blocks, raw_data(text), u64(len(text)), true)
	units_frame(&bytes, raw_data(text), u64(cut), false)
	units_frame(&bytes, raw_data(text), u64(len(text)), false)
	// Outside a tag the quote is no state.
	for u in ([]^Units{&blocks, &bytes}) {
		if u.state == .Text || u.state == .End_Tag {
			u.quote = 0
		}
	}
	return blocks == bytes
}
