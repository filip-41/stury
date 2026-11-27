package stury

import "stury:engine"

// Format specification union, lookup, detection, and cross-format conversion over the engine registry.

Spec :: engine.Spec
Format_Error :: engine.Format_Error
Diff_Error :: engine.Diff_Error

// Format lookup and detection.
format_by_name :: engine.format_by_name
format_of_path :: engine.format_of_path
detect_format :: engine.detect_format

// Cross-format conversion (buffer or streaming `io.Writer`).
format :: proc {
	engine.format,
	engine.format_to,
}
