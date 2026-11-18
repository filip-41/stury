#!/usr/bin/env python3
"""The packages a published release goes out in, written from its archives (release.yml's stury-VERSION-OS-ARCH.tar.gz and
.zip, each beside its .sha256).

`python3 tools/packages.py wheels DIST OUT` writes a PyPI wheel per archive in DIST into OUT: the binary as the wheel's
script and the manual page under share/man. `python3 tools/packages.py formula DIST` prints the Homebrew formula of
the darwin and linux archives.
"""

import base64
import hashlib
import os
import re
import struct
import sys
import tarfile
import zipfile

REPOSITORY = "filip-41/stury"
SUMMARY = "A query engine and a lossless editing tool for jq filters across eleven formats"
# Homebrew refuses a description that opens on an article.
DESC = "Query engine and lossless editing tool for jq filters across eleven formats"
ARCHIVE = re.compile(r"stury-(\d+\.\d+\.\d+)-(darwin|linux|windows)-(amd64|arm64)\.(tar\.gz|zip)")
MACHINE = {"amd64": "x86_64", "arm64": "aarch64"}
MACOS_ARCH = {"amd64": "x86_64", "arm64": "arm64"}
# The release Homebrew names each macOS major by, for `depends_on macos:`.
MACOS_NAMES = {11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe"}
LC_BUILD_VERSION = 0x32
# Every entry of a wheel takes one time, so the same archive writes the same wheel.
EPOCH = (1980, 1, 1, 0, 0, 0)


class Archive:
    """One release archive: its version, OS and architecture, and its files by their path under the archive's folder."""

    def __init__(self, path):
        found = ARCHIVE.fullmatch(os.path.basename(path))
        if not found:
            raise ValueError(f"{path} is not a release archive")
        self.path = path
        self.version, self.os, self.arch = found.group(1), found.group(2), found.group(3)
        self.files = read_archive(path)
        with open(path + ".sha256", encoding="utf-8") as file:
            self.sha256 = file.read().split()[0]

    @property
    def binary(self):
        return "stury.exe" if self.os == "windows" else "stury"

    def url(self):
        return f"https://github.com/{REPOSITORY}/releases/download/v{self.version}/{os.path.basename(self.path)}"


def read_archive(path):
    """The files of a release archive by their path under its one top folder."""
    files = {}
    if path.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                if not info.is_dir():
                    files[info.filename.split("/", 1)[1]] = z.read(info)
    else:
        with tarfile.open(path) as t:
            for member in t.getmembers():
                if member.isfile():
                    files[member.name.split("/", 1)[1]] = t.extractfile(member).read()
    return files


def archives(dist):
    found = [Archive(os.path.join(dist, name)) for name in sorted(os.listdir(dist)) if ARCHIVE.fullmatch(name)]
    if not found:
        raise SystemExit(f"{dist} holds no release archive")
    versions = {a.version for a in found}
    if len(versions) != 1:
        raise SystemExit(f"{dist} holds archives of more than one version: {sorted(versions)}")
    return found


def macos_floor(binary):
    """The macOS major a Mach-O binary's LC_BUILD_VERSION names as its least."""
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", binary)
    if magic != 0xFEEDFACF:
        raise ValueError("not a 64-bit little-endian Mach-O binary")
    at = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", binary, at)
        if cmd == LC_BUILD_VERSION:
            minos = struct.unpack_from("<I", binary, at + 12)[0]
            return minos >> 16, (minos >> 8) & 0xFF
        at += size
    raise ValueError("the binary names no LC_BUILD_VERSION")


def glibc_floor(binary):
    """The newest glibc symbol version an ELF binary takes."""
    versions = {tuple(map(int, v.split(b"."))) for v in re.findall(rb"GLIBC_(\d+\.\d+)(?![.\d])", binary)}
    if not versions:
        raise ValueError("the binary takes no versioned glibc symbol")
    return max(versions)


def platform_tag(a):
    binary = a.files[a.binary]
    if a.os == "darwin":
        major, minor = macos_floor(binary)
        return f"macosx_{major}_{minor}_{MACOS_ARCH[a.arch]}"
    if a.os == "linux":
        major, minor = glibc_floor(binary)
        return f"manylinux_{major}_{minor}_{MACHINE[a.arch]}"
    if a.arch != "amd64":
        raise ValueError(f"no wheel tag for windows-{a.arch}")
    return "win_amd64"


def description(readme, version):
    """The README as PyPI shows it: a path into the repository, which PyPI cannot follow, made a link to the tag."""
    raw = f"https://raw.githubusercontent.com/{REPOSITORY}/v{version}/"
    blob = f"https://github.com/{REPOSITORY}/blob/v{version}/"
    text = re.sub(r"(!\[[^\]]*\]\()(?!https?:)([^)\s]+)\)", lambda m: f"{m.group(1)}{raw}{m.group(2)})", readme)
    return re.sub(r"(?<!!)(\[[^\]]*\]\()(?!https?:|#|mailto:)([^)\s]+)\)", lambda m: f"{m.group(1)}{blob}{m.group(2)})", text)


def metadata(a):
    readme = a.files["README.md"].decode("utf-8").replace("\r\n", "\n")
    head = [
        "Metadata-Version: 2.4",
        "Name: stury",
        f"Version: {a.version}",
        f"Summary: {SUMMARY}",
        "License-Expression: MIT",
        "License-File: LICENSE",
        "License-File: THIRD_PARTY_NOTICES",
        f"Project-URL: Homepage, https://github.com/{REPOSITORY}",
        f"Project-URL: Changelog, https://github.com/{REPOSITORY}/blob/v{a.version}/CHANGELOG.md",
        "Description-Content-Type: text/markdown",
    ]
    return ("\n".join(head) + "\n\n" + description(readme, a.version)).encode("utf-8")


def record_hash(data):
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()


def write_wheel(a, out):
    """The wheel of archive `a`, written into `out`, and its path."""
    tag = platform_tag(a)
    data, info = f"stury-{a.version}.data", f"stury-{a.version}.dist-info"
    wheel = f"Wheel-Version: 1.0\nGenerator: stury tools/packages.py\nRoot-Is-Purelib: false\nTag: py3-none-{tag}\n"
    entries = [
        (f"{data}/scripts/{a.binary}", a.files[a.binary], 0o755),
        (f"{data}/data/share/man/man1/stury.1", a.files["docs/stury.1"], 0o644),
        (f"{info}/METADATA", metadata(a), 0o644),
        (f"{info}/WHEEL", wheel.encode(), 0o644),
        (f"{info}/licenses/LICENSE", a.files["LICENSE"], 0o644),
        (f"{info}/licenses/THIRD_PARTY_NOTICES", a.files["THIRD_PARTY_NOTICES"], 0o644),
    ]
    record = "".join(f"{name},{record_hash(body)},{len(body)}\n" for name, body, _ in entries) + f"{info}/RECORD,,\n"
    entries.append((f"{info}/RECORD", record.encode(), 0o644))
    path = os.path.join(out, f"stury-{a.version}-py3-none-{tag}.whl")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, body, mode in entries:
            entry = zipfile.ZipInfo(name, EPOCH)
            entry.external_attr = (0o100000 | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(entry, body)
    return path


def formula(found):
    """The Homebrew formula of the darwin and linux archives, which must all be there."""
    by = {(a.os, a.arch): a for a in found}
    missing = [f"{o}-{c}" for o in ("darwin", "linux") for c in ("arm64", "amd64") if (o, c) not in by]
    if missing:
        raise SystemExit(f"the formula needs the archives of {', '.join(missing)}")
    floors = {macos_floor(by["darwin", c].files["stury"])[0] for c in ("arm64", "amd64")}
    floor = MACOS_NAMES.get(max(floors))
    if floor is None:
        raise SystemExit(f"no Homebrew name for macOS {max(floors)}")

    def source(o, c, indent):
        a = by[o, c]
        pad = " " * indent
        return f'{pad}url "{a.url()}"\n{pad}sha256 "{a.sha256}"\n'

    version = found[0].version
    return (
        "class Stury < Formula\n"
        f'  desc "{DESC}"\n'
        f'  homepage "https://github.com/{REPOSITORY}"\n'
        f'  version "{version}"\n'
        '  license "MIT"\n'
        "\n"
        "  on_macos do\n"
        f"    depends_on macos: :{floor}\n"
        "    on_arm do\n" + source("darwin", "arm64", 6) + "    end\n"
        "    on_intel do\n" + source("darwin", "amd64", 6) + "    end\n"
        "  end\n"
        "\n"
        "  on_linux do\n"
        "    on_arm do\n" + source("linux", "arm64", 6) + "    end\n"
        "    on_intel do\n" + source("linux", "amd64", 6) + "    end\n"
        "  end\n"
        "\n"
        "  def install\n"
        '    bin.install "stury"\n'
        '    man1.install "docs/stury.1"\n'
        "  end\n"
        "\n"
        "  test do\n"
        '    assert_equal "stury-#{version}", shell_output("#{bin}/stury --version").strip\n'
        '    assert_equal "2", pipe_output("#{bin}/stury .a", \'{"a":2}\').strip\n'
        "  end\n"
        "end\n"
    )


def main(argv):
    if len(argv) == 3 and argv[0] == "wheels":
        os.makedirs(argv[2], exist_ok=True)
        for a in archives(argv[1]):
            print(write_wheel(a, argv[2]))
    elif len(argv) == 2 and argv[0] == "formula":
        sys.stdout.write(formula(archives(argv[1])))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
