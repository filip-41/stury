/^\/\// { next }
{
	if (NR_kept > 0 && $0 ~ /^[ \t]*[\]}]/) sub(/,$/, "", prev)
	if (NR_kept > 0) print prev
	prev = $0
	NR_kept++
}
END { print prev }
