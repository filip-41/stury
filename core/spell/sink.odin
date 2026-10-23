package spell

// The buffered byte count at which a streaming writer flushes. A single longer item (a long string, a `Raw`) is
// buffered whole before the flush.
SINK_FLUSH_AT :: 64 * 1024
