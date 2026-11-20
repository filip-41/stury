package spell

// The word a misspelled one most likely meant, for a message's "did you mean" suggestion.

import "core:strings"

// The one of `candidates` nearest `word` by edit distance, ignoring case, when it is near enough to be a misspelling of
// it, or "". A `max_distance` below the default limit narrows it. Allocates only in `context.temp_allocator`.
nearest_word :: proc(candidates: []string, word: string, max_distance := max(int)) -> string {
	best, distance := "", max(int)
	lower := strings.to_lower(word, context.temp_allocator)
	for c in candidates {
		if d := strings.levenshtein_distance(lower, strings.to_lower(c, context.temp_allocator), context.temp_allocator); d < distance {
			best, distance = c, d
		}
	}
	return best if distance <= min((len(word) + 1) / 2, 3, max_distance) && distance < len(best) else ""
}
