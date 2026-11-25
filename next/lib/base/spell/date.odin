package spell

import "base:intrinsics"
import "core:time"

// RFC 3339 dates and times, as a format reads a value it holds as a date-time text, such as CBOR's tag 0.

// Whether `s` is an RFC 3339 `date-time`: a `full-date`, `T` or `t`, and a `full-time`. A leap second is the last second
// of a minute that is 23:59 in UTC.
is_date_time :: proc "contextless" (s: string) -> bool {
	if len(s) <= 11 || s[10] != 'T' && s[10] != 't' {
		return false
	}
	return is_full_date(s[:10]) && is_full_time(s[11:])
}

// Whether `s` is an RFC 3339 `full-date`.
is_full_date :: proc "contextless" (s: string) -> bool {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {
		return false
	}
	y, y_ok := date_digits(s[:4])
	m, m_ok := date_digits(s[5:7])
	d, d_ok := date_digits(s[8:])
	if !y_ok || !m_ok || !d_ok || m < 1 || m > 12 || d < 1 {
		return false
	}
	leap := y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
	days := [12]int{31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	return d <= days[m - 1]
}

// Whether `s` is an RFC 3339 `full-time`: `HH:MM:SS`, a fraction of one digit or more, and a `Z` or `+HH:MM` offset.
@(private)
is_full_time :: proc "contextless" (s: string) -> bool {
	if len(s) < 9 || s[2] != ':' || s[5] != ':' {
		return false
	}
	h, h_ok := date_digits(s[:2])
	m, m_ok := date_digits(s[3:5])
	sec, s_ok := date_digits(s[6:8])
	if !h_ok || !m_ok || !s_ok || h > 23 || m > 59 || sec > 60 {
		return false
	}
	rest := s[8:]
	if rest[0] == '.' {
		n := 0
		for n + 1 < len(rest) && rest[n + 1] >= '0' && rest[n + 1] <= '9' {
			n += 1
		}
		if n == 0 {
			return false
		}
		rest = rest[n + 1:]
	}
	// The offset in minutes east of UTC.
	offset := 0
	switch {
	case rest == "Z" || rest == "z":
	case len(rest) == 6 && (rest[0] == '+' || rest[0] == '-') && rest[3] == ':':
		oh, oh_ok := date_digits(rest[1:3])
		om, om_ok := date_digits(rest[4:])
		if !oh_ok || !om_ok || oh > 23 || om > 59 {
			return false
		}
		offset = (oh * 60 + om) * (1 if rest[0] == '+' else -1)
	case:
		return false
	}
	return sec < 60 || ((h * 60 + m - offset) % 1440 + 1440) % 1440 == 23 * 60 + 59
}

// The number the ASCII digits `s` spell, false for an empty `s` or any other byte.
@(private)
date_digits :: proc "contextless" (s: string) -> (n: int, ok: bool) {
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	return n, len(s) > 0
}

// The nanoseconds since the Unix epoch in UTC of the RFC 3339 date-time `text`, a space taken for its `T`. A leap
// second is the second after it. `spelled` is false for a text of another spelling, and `in_range` false for an
// instant `time.Time` does not hold.
date_time_nsec :: proc "contextless" (text: string) -> (nsec: i64, spelled, in_range: bool) {
	spaced: [64]u8 = ---
	s := text
	if len(s) > 10 && len(s) <= len(spaced) && s[10] == ' ' {
		intrinsics.mem_copy_non_overlapping(&spaced, raw_data(s), len(s))
		spaced[10] = 'T'
		s = string(spaced[:len(s)])
	}
	if !is_date_time(s) {
		return 0, false, false
	}
	digits :: proc "contextless" (s: string) -> i64 {
		n: i64
		for c in transmute([]u8)s {
			n = n * 10 + i64(c - '0')
		}
		return n
	}
	second := digits(s[17:19])
	frac: i64
	rest := s[19:]
	if rest[0] == '.' {
		k := 1
		for k < len(rest) && rest[k] >= '0' && rest[k] <= '9' {
			if k <= 9 {
				frac = frac * 10 + i64(rest[k] - '0')
			}
			k += 1
		}
		for _ in k ..< 10 {
			frac *= 10
		}
		rest = rest[k:]
	}
	offset: i64
	if rest[0] == '+' || rest[0] == '-' {
		offset = (digits(rest[1:3]) * 60 + digits(rest[4:6])) * (1 if rest[0] == '+' else -1)
	}
	t, held := time.components_to_time(digits(s[:4]), digits(s[5:7]), digits(s[8:10]), digits(s[11:13]), digits(s[14:16]), min(second, 59), frac)
	utc, past := intrinsics.overflow_sub(t._nsec, offset * i64(time.Minute))
	if second == 60 && !past {
		utc, past = intrinsics.overflow_add(utc, i64(time.Second))
	}
	if !held || past {
		return 0, true, false
	}
	return utc, true, true
}
