// Redaction policy, RFC 6901 JSON Pointer / wildcard path matching, and secret-safe formatting helpers.
package model

import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"

// Default replacement mask emitted when redacting secret fields or paths.
DEFAULT_REDACT_MASK :: "[REDACTED]"

// Options controlling redaction of RFC 9457 `Problem` documents and error messages.
Problem_Opts :: struct {
	// When true, masks details of entries marked `secret` (which are always masked) and any `redact_paths`.
	redact:       bool,
	// Custom replacement string; empty defaults to `DEFAULT_REDACT_MASK` (`"[REDACTED]"`).
	redact_mask:  string,
	// Additional RFC 6901 JSON Pointer paths (supporting `*` segment wildcards) whose errors must be redacted.
	redact_paths: []string,
}

@(private)
resolve_redact_mask :: proc "contextless" (mask: string) -> string {
	return mask if len(mask) > 0 else DEFAULT_REDACT_MASK
}

// Returns true if `steps` matches any pattern in `patterns`.
// Patterns use RFC 6901 JSON Pointer syntax (`/a/b/0`, `~1` -> `/`, `~0` -> `~`) and optional `*` wildcard segments.
// When `match_prefix` is true, also matches if `pattern` is an ancestor of `steps` (e.g. pattern `/auth` matches `/auth/token`).
@(private)
redact_steps_match :: proc(steps: []tape.Step, patterns: []string, match_prefix := false) -> bool {
	if len(patterns) == 0 { return false }
	for pat in patterns {
		if redact_steps_match_one(steps, pat, match_prefix) { return true }
	}
	return false
}

@(private)
redact_steps_match_one :: proc(steps: []tape.Step, pattern: string, match_prefix: bool) -> bool {
	if len(pattern) == 0 { return len(steps) == 0 || match_prefix }
	if pattern[0] != '/' { return false }
	rest := pattern[1:]
	idx := 0
	for {
		slash := strings.index_byte(rest, '/')
		seg := rest[:slash] if slash >= 0 else rest
		if idx >= len(steps) { return false }
		if seg != "*" && !step_matches_pointer_segment(steps[idx], seg) { return false }
		idx += 1
		if slash < 0 { break }
		rest = rest[slash + 1:]
	}
	return idx == len(steps) || (match_prefix && idx < len(steps))
}

@(private)
step_matches_pointer_segment :: proc(st: tape.Step, seg: string) -> bool {
	#partial switch v in st {
	case tape.Name:
		return pointer_segment_equals(seg, string(v))
	case tape.Index:
		buf: [24]u8 = ---
		num := strconv.write_int(buf[:], i64(v), 10)
		return seg == num
	}
	return false
}

// Compares an RFC 6901 escaped pointer segment `seg` against unescaped key `name` without allocation.
@(private)
pointer_segment_equals :: proc "contextless" (seg, name: string) -> bool {
	si, ni := 0, 0
	for si < len(seg) && ni < len(name) {
		c := seg[si]
		if c == '~' && si + 1 < len(seg) {
			next := seg[si + 1]
			if next == '1' {
				if name[ni] != '/' { return false }
				si += 2; ni += 1
				continue
			} else if next == '0' {
				if name[ni] != '~' { return false }
				si += 2; ni += 1
				continue
			}
		}
		if c != name[ni] { return false }
		si += 1; ni += 1
	}
	return si == len(seg) && ni == len(name)
}

// Returns true if RFC 6901 `pointer` matches any pattern in `patterns` (exact, wildcard `*`, or ancestor prefix).
@(private)
redact_pointer_matches :: proc(pointer: string, patterns: []string) -> bool {
	if len(patterns) == 0 { return false }
	for pat in patterns {
		if redact_pointer_match_one(pointer, pat) { return true }
	}
	return false
}

@(private)
redact_pointer_match_one :: proc(pointer, pattern: string) -> bool {
	if len(pattern) == 0 { return true }
	if len(pointer) == 0 || pointer[0] != '/' || pattern[0] != '/' { return false }
	pr, pa := pointer[1:], pattern[1:]
	for {
		ps := strings.index_byte(pr, '/')
		as := strings.index_byte(pa, '/')
		pseg := pr[:ps] if ps >= 0 else pr
		aseg := pa[:as] if as >= 0 else pa
		if aseg != "*" && pseg != aseg { return false }
		if as < 0 {
			// Pattern ended: matches exact path or any descendant (`ps >= 0`).
			return true
		}
		if ps < 0 { return false }
		pr = pr[ps + 1:]
		pa = pa[as + 1:]
	}
}
