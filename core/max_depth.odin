package core

// The default cap on nesting, and the depth a format's walk holds in fixed frames, so its stack is bounded
// whatever the document says. A `max_depth` above it walks on frames that spill to `context.allocator` once the
// input passes this depth.
MAX_DEPTH :: 1024
