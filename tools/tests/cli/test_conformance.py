"""toml-test's and yaml-test-suite's valid cases through the command line, each read as the case's JSON (TOML as the tagged
JSON of TAGGED, YAML as in.json), and the first few invalid cases of each format, since the library suites judge the rest.
TOML datetimes and floats compare as toml-test compares them."""

import json
import math
import os
import re
import subprocess

import pytest

from capped import ROOT, values

TOML = os.path.join(ROOT, "toml", "test", "conformance", "toml-test")
YAML = os.path.join(ROOT, "yaml", "test", "suite")
EXIT_PARSE = 5
REFUSED = 3
DATETIMES = {"datetime", "datetime-local", "date-local", "time-local"}
# The suite accepts a mapping with two empty keys, and stury refuses a key that repeats.
YAML_SKIP = {"2JQS"}
# Writes a TOML document as toml-test's tagged JSON: every scalar is {"type": ..., "value": ...}, and a datetime's type is
# its `.@tag`. A number's type and spelling come from its `.@style`.
TAGGED = """def tagged:
  . as $v
  | ($v | type) as $type
  | if $type == "object" then
      reduce ($v | keys_unsorted[]) as $k ({}; .[$k] = ($v[$k] | tagged))
    elif $type == "array" then
      [range(0; $v | length) as $i | $v[$i] | tagged]
    elif $type == "boolean" then
      {type: "bool", value: ($v | tostring)}
    elif $type == "string" then
      {type: ($v | .@tag // "string"), value: $v}
    else
      ($v | .@style) as $style
      | if $style == "inf" then {type: "float", value: (if $v > 0 then "inf" else "-inf" end)}
        elif $style == "nan" then {type: "float", value: "nan"}
        elif $style == "float" then {type: "float", value: ($v | tojson)}
        else {type: "integer", value: ($v | tojson)}
        end
    end;
tagged
"""


def datetime_form(text):
    text = text.replace("t", "T").replace("z", "Z")
    text = re.sub(r"^(\d{4}-\d\d-\d\d) (?=\d)", r"\1T", text)
    text = re.sub(r"(^|T)(\d\d:\d\d)(?=$|[Z+-])", r"\1\2:00", text)
    return re.sub(r"\.(\d*?)0*(?=$|[Z+-])", lambda m: "." + m.group(1) if m.group(1) else "", text)


def same(got, want):
    """Whether `got` equals `want`: a toml-test tagged value as toml-test compares it, a number as a number."""
    if isinstance(want, dict) and set(want) == {"type", "value"} and isinstance(want["value"], str):
        if not (isinstance(got, dict) and set(got) == {"type", "value"} and got["type"] == want["type"]):
            return False
        if want["type"] in DATETIMES:
            return datetime_form(got["value"]) == datetime_form(want["value"])
        if want["type"] == "float":
            try:
                a, b = float(got["value"]), float(want["value"].replace("_", ""))
            except ValueError:
                return False
            return a == b or math.isnan(a) and math.isnan(b)
        return got["value"] == want["value"]
    if isinstance(want, dict):
        return isinstance(got, dict) and set(got) == set(want) and all(same(got[k], want[k]) for k in want)
    if isinstance(want, list):
        return isinstance(got, list) and len(got) == len(want) and all(same(g, w) for g, w in zip(got, want))
    if isinstance(want, bool) or isinstance(got, bool):
        return got is want
    if isinstance(want, float) and isinstance(got, (int, float)):
        return got == want or math.isnan(got) and math.isnan(want)
    return got == want


def toml_cases():
    """(valid, invalid): each valid case is (name, the values it must print), each invalid one a path. 1.1 reads every
    text 1.0 does, so a valid case of either list reads, and an invalid case of 1.1's list is refused."""

    def listed(version):
        with open(os.path.join(TOML, f"files-toml-{version}")) as f:
            return {line.strip() for line in f if line.strip().endswith(".toml")}

    newest = listed("1.1.0")
    valid = []
    for name in sorted(n for n in newest | listed("1.0.0") if n.startswith("valid/")):
        with open(os.path.join(TOML, name[: -len(".toml")] + ".json"), encoding="utf-8") as f:
            valid.append((name, json.load(f)))
    return valid, [n for n in sorted(newest) if n.startswith("invalid/")]


def yaml_cases():
    valid, invalid = [], []
    for name in sorted(n for n in os.listdir(YAML) if os.path.isfile(os.path.join(YAML, n, "in.yaml")) and n not in YAML_SKIP):
        case = os.path.join(YAML, name)
        if os.path.exists(os.path.join(case, "error")):
            invalid.append(os.path.join(name, "in.yaml"))
        elif os.path.exists(os.path.join(case, "in.json")):
            with open(os.path.join(case, "in.json"), encoding="utf-8") as f:
                valid.append((name, values(f.read())))
    return valid, invalid


TOML_VALID, TOML_INVALID = toml_cases()
YAML_VALID, YAML_INVALID = yaml_cases()


def valid_case(stury, argv, want):
    run = subprocess.run([stury, *argv], capture_output=True, timeout=20)
    assert run.returncode == 0, f"exit {run.returncode}: {run.stderr.decode(errors='replace').strip()}"
    try:
        got = values(run.stdout.decode())
    except ValueError:
        pytest.fail(f"output is not JSON: {run.stdout[:80]!r}")
    assert same(got, want), f"{run.stdout.decode()[:200].strip()} differs from {json.dumps(want)[:200]}"


def invalid_case(stury, fmt, path):
    run = subprocess.run([stury, "check", "--from", fmt, path], capture_output=True, timeout=20)
    assert run.returncode == EXIT_PARSE and run.stderr, f"check exits {run.returncode} with {len(run.stderr)} bytes of message, not {EXIT_PARSE} and a message"


@pytest.mark.parametrize("name, want", TOML_VALID, ids=[c[0] for c in TOML_VALID])
def test_toml_valid(stury, name, want):
    valid_case(stury, ["--from", "toml", "-c", TAGGED, os.path.join(TOML, name)], [want])


@pytest.mark.parametrize("name, want", YAML_VALID, ids=[c[0] for c in YAML_VALID])
def test_yaml_valid(stury, name, want):
    valid_case(stury, ["--from", "yaml", "-c", ".", os.path.join(YAML, name, "in.yaml")], want)


@pytest.mark.parametrize("name", TOML_INVALID[:REFUSED])
def test_toml_invalid(stury, name):
    invalid_case(stury, "toml", os.path.join(TOML, name))


@pytest.mark.parametrize("name", YAML_INVALID[:REFUSED])
def test_yaml_invalid(stury, name):
    invalid_case(stury, "yaml", os.path.join(YAML, name))
