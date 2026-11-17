"""Running a case through stury and jq and judging the two answers as alike or as differing where docs/cli.md's
"Differences from jq" documents it: an input outside RFC 8259 that stury refuses where jq read on, and a parse error's
message. A case whose difference is documented counts as alike."""

import json
import re
import signal
from decimal import Decimal

from capped import as_jq, outcome

TIMEOUT = 5


def run(binary, opts, prog, stdin):
    got = outcome([binary, *opts, prog], stdin.encode(), TIMEOUT)
    # On a host with less memory than two capped runs, the kernel's OOM killer (a SIGKILL) can stop a run first.
    return ("timeout", b"", b"") if got[0] == -signal.SIGKILL else got


def refuse(name):
    raise ValueError(name)


def strict_texts(stdin):
    """Whether stdin is JSON texts as RFC 8259 has them, apart by whitespace (or record separators) or not:
    the grammar stury reads."""
    decoder, space = json.JSONDecoder(parse_constant=refuse), re.compile(r"[ \t\n\r\x1e]*")
    at = space.match(stdin).end()
    while at < len(stdin):
        try:
            _, at = decoder.raw_decode(stdin, at)
        except ValueError:
            return False
        at = space.match(stdin, at).end()
    return True


# jq prints a number literal in its own canonical spelling (`1E+3`), stury as written (`1e3`). A text with its literals
# spelled as jq prints them, which a string keeps as it is, makes stury print what jq does.
STRING_OR_NUMBER = re.compile(r'"(?:[^"\\]|\\.)*"|(?<![\w$.@])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?')


def jq_spelling(text):
    return STRING_OR_NUMBER.sub(lambda m: m.group() if m.group()[0] == '"' else str(Decimal(m.group())), text)


def documented(stdin, got, want):
    """Which of docs/cli.md's "Differences from jq" explains stury's answer `got` where jq's is `want`, or None."""
    parse_error = lambda err: b"parse error: " in err
    # A parse error's words and position, in a run's message, in `fromjson`'s, or in the error `input` raises.
    careted = lambda err: re.sub(rb"(parse error: [^\n]*)\n[^\n]*\n *\^(?=\n)", rb"\1", err)
    unworded = lambda err: re.sub(rb"(parse error: )[^\n]*|(\): )[^\n]*( \(while parsing ')|(\(at <stdin>:\d+\): )[^\n]* at line \d+, column \d+$", rb"\1\2\3\4", err, flags=re.M)
    if not strict_texts(stdin) and parse_error(got[2]) and want[1].startswith(got[1]):
        return "grammar"
    # The same, in a string `fromjson`'s error was caught as.
    caught = lambda out: re.sub(rb'"(?:[^"\\\n]|\\.)*? \(while parsing ', b'"(while parsing ', out)
    if got[0] == want[0] and caught(got[1]) == caught(want[1]) and unworded(careted(got[2])) == unworded(want[2]):
        return "message"
    # A filter's error with no input to name has no `(at <unknown>)`, and `input` past the last input says `No more
    # inputs` where jq prints `break`.
    unplaced = lambda err: re.sub(rb"jq: error \(at <unknown>\)", b"jq: error", err)
    if got[:2] == want[:2] and got[2] == unplaced(want[2]).replace(b"): break\n", b"): No more inputs\n").replace(b"error: break\n", b"error: No more inputs\n"):
        return "unplaced error"
    if got == (want[0], want[1], b"") and re.fullmatch(rb"jq: ignoring parse error: Unfinished abandoned text at EOF at line 1, column 0\n", want[2]):
        return "empty --seq stream"
    return None


def compare(stury, jq, case):
    """None where the answers are alike or differ as documented, otherwise how they differ. A run that timed out is
    run again, as a loaded host can cause it."""
    opts, prog, stdin = case
    got, want = run(stury, opts, prog, stdin), run(jq, opts, prog, stdin)
    if "timeout" in (got[0], want[0]):
        got, want = run(stury, opts, prog, stdin), run(jq, opts, prog, stdin)
    # `stderr` leaves no newline before an error message, which as_jq looks for.
    got = (got[0], got[1], re.sub(rb"stury: (?=error[ :(]|parse error)", b"jq: ", as_jq(got[2])))
    if got == want:
        return None
    if documented(stdin, got, want):
        return None
    spelled = run(stury, opts, jq_spelling(prog), jq_spelling(stdin))
    spelled = (spelled[0], spelled[1], re.sub(rb"stury: (?=error[ :(]|parse error)", b"jq: ", as_jq(spelled[2])))
    if spelled == want or documented(stdin, spelled, want):
        return None
    return f"{' '.join(opts)} {prog!r}\n  stdin {stdin!r}\n  stury: exit {got[0]} out {got[1][:300]!r} err {got[2][:300]!r}\n  jq:    exit {want[0]} out {want[1][:300]!r} err {want[2][:300]!r}"


