package spell

// The buffered bytes at which a streaming writer flushes. A single item longer than this (a long string, a
// `Raw`) is buffered whole first.
SINK_FLUSH_AT :: 64 * 1024
