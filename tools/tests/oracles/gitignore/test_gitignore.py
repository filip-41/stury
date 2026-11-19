"""Seeded random trees and ignore files walked by stury and listed by `git ls-files --others --exclude-standard`, which
names the files git does not ignore, reporting where the two differ. The patterns are of each family gitignore(5)
describes, in .gitignore files at several levels, the repository's info/exclude and the user's excludes file, the
last named by ~/.gitconfig or found under XDG_CONFIG_HOME."""

import os
import random
import shutil
import subprocess

import pytest

CASES = 300
DIRS = ["a", "b", "A", "n", "a/b", "a/b/c", "b/a", "n/a", "a/n"]
FILES = ["a.json", "b.json", "B.json", "ab.json", "#c.json", "!d.json", "e f.json", "c.json"]
PATTERNS = ["a.json", "*.json", "/a.json", "a/", "b/", "A/", "a", "/a", "a/b", "a/*.json", "?.json", "[a-b].json",
            "[!a].json", "**/b", "**/b.json", "a/**", "a/**/c", "a/**/b.json", "**/a/*.json", "\\#c.json", "#c.json",
            "\\!d.json", "!a.json", "!b/", "!*.json", "!a/b.json", "!/a", "!c.json", "e f.json", "e\\ f.json",
            "ab.json   ", "b.json\\ ", "*", "n/", "/n/a", "*/", "a*", "B.json", "c.json", "b/c.json", "a/b/", "/a/b/c/"]

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


def ignore_file(rng):
    lines = rng.sample(PATTERNS, rng.randint(1, 4)) + (["# a comment"] if rng.random() < 0.2 else [])
    rng.shuffle(lines)
    return ("\r\n" if rng.random() < 0.3 else "\n").join(lines) + "\n"


def make_case(rng, root, home):
    """Writes a tree with its ignore files under `root` and the user's excludes under `home`. Returns the walk's root."""
    dirs = rng.sample(DIRS, rng.randint(2, len(DIRS)))
    for d in [""] + dirs:
        os.makedirs(os.path.join(root, d), exist_ok=True)
        for name in rng.sample(FILES, rng.randint(1, 4)):
            with open(os.path.join(root, d, name), "w") as f:
                f.write("1")
        if rng.random() < 0.5:
            with open(os.path.join(root, d, ".gitignore"), "w", newline="") as f:
                f.write(ignore_file(rng))
    if rng.random() < 0.3:
        with open(os.path.join(root, ".git", "info", "exclude"), "w", newline="") as f:
            f.write(ignore_file(rng))
    if rng.random() < 0.3:
        excludes = os.path.join(home, "excludes")
        if rng.random() < 0.5:
            with open(os.path.join(home, ".gitconfig"), "w") as f:
                f.write("[user]\n\tname = x\n[core]\n\texcludesFile = ~/excludes\n")
        else:
            excludes = os.path.join(home, "xdg", "git", "ignore")
            os.makedirs(os.path.dirname(excludes))
        with open(excludes, "w", newline="") as f:
            f.write(ignore_file(rng))
    # A root spelled as its directory is, which git's pathspec needs on a case-blind file system.
    return rng.choice(["."] + [d for d in dirs if os.path.basename(d) in os.listdir(root / os.path.dirname(d))])


@pytest.mark.parametrize("case", range(CASES))
def test_walk_ignores_as_git(stury, tmp_path, case):
    rng = random.Random(case)
    root, home = tmp_path / "r", tmp_path / "home"
    os.makedirs(home)
    env = {**os.environ, "HOME": str(home), "USERPROFILE": str(home), "XDG_CONFIG_HOME": str(home / "xdg"),
           "GIT_CONFIG_NOSYSTEM": "1"}
    subprocess.run(["git", "init", "-q", str(root)], env=env, check=True)
    top = make_case(rng, root, home)
    git = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "-z", "--", top], cwd=root, env=env,
                         capture_output=True, check=True).stdout.decode().split("\0")
    want = sorted(p for p in git if p.endswith(".json"))
    out = subprocess.run([stury, "-j", 'input_filename, "\\u0000"', top], cwd=root, env=env, capture_output=True)
    got = sorted(p.removeprefix("./") for p in out.stdout.decode().split("\0") if p)
    files = {os.path.relpath(os.path.join(b, f), tmp_path).replace(os.sep, "/"): open(os.path.join(b, f), newline="").read()
             for b, _, fs in os.walk(tmp_path) for f in fs if f in ("ignore", "excludes", ".gitignore", "exclude")}
    assert got == want, (top, files)
