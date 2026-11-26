package stury

import "stury:engine"

// Format specification union, lookup, detection, and cross-format conversion over the engine registry.

Spec :: engine.Spec
Format_Id :: engine.Format_Id
Family :: engine.Family
Framing :: engine.Framing
Format_Entry :: engine.Format_Entry
Format_Error :: engine.Format_Error
Diff_Error :: engine.Diff_Error
Compression_Kind :: engine.Compression_Kind

// Format lookup and detection.
format_by_name :: engine.format_by_name
format_and_framing_by_name :: engine.format_and_framing_by_name
format_of_path :: engine.format_of_path
detect_format :: engine.detect_format
strip_compression_suffix :: engine.strip_compression_suffix

// Registry helpers converting between `Spec`, `Format_Id`, `^tape.Format`, and `Format_Entry`.
format_of :: engine.format_of
spec_of :: engine.spec_of
spec_of_id :: engine.spec_of_id
id_of_spec :: engine.id_of_spec
entry_of :: engine.entry_of
supports_scan :: engine.supports_scan

// Cross-format conversion (buffer and streaming `io.Writer`).
format :: engine.format
format_to :: engine.format_to
