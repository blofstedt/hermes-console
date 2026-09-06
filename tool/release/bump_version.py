#!/usr/bin/env python3
"""Bump the app version for an automatic release.

Increments the patch component and the build number in `pubspec.yaml`
(`1.2.10+4965` -> `1.2.11+4966`) and prepends a CHANGELOG entry listing the
commit subjects since the previous tag.

The build number is what Android compares when deciding whether an install is
an upgrade, so it must never repeat or go backwards.

Prints `tag=<v...>` and `version=<...>` in GitHub Actions output format when
`--github-output` is given.

Usage:
    python3 tool/release/bump_version.py [--subjects-from <file>] [--github-output]
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PUBSPEC = ROOT / "pubspec.yaml"
CHANGELOG = ROOT / "CHANGELOG.md"

VERSION_RE = re.compile(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$", re.M)


def read_version() -> tuple[int, int, int, int]:
    match = VERSION_RE.search(PUBSPEC.read_text(encoding="utf-8"))
    if not match:
        sys.exit("pubspec.yaml has no 'version: X.Y.Z+N' line")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def bump(major: int, minor: int, patch: int, build: int) -> tuple[str, str]:
    version = f"{major}.{minor}.{patch + 1}"
    return version, f"{version}+{build + 1}"


def write_pubspec(full: str) -> None:
    text = PUBSPEC.read_text(encoding="utf-8")
    text, count = VERSION_RE.subn(f"version: {full}", text, count=1)
    if count != 1:
        sys.exit("failed to rewrite the version line")
    PUBSPEC.write_text(text, encoding="utf-8")


def commit_subjects() -> list[str]:
    """Commit subjects since the previous tag, newest first."""
    try:
        previous = subprocess.run(
            ["git", "describe", "--tags", "--abbrev=0"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.strip()
        span = f"{previous}..HEAD"
    except subprocess.CalledProcessError:
        span = "HEAD"
    result = subprocess.run(
        ["git", "log", "--no-merges", "--format=%s", span],
        cwd=ROOT, capture_output=True, text=True, check=False,
    )
    seen: list[str] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        # Release commits are bookkeeping, not user-visible change.
        if line and not line.startswith("release:") and line not in seen:
            seen.append(line)
    return seen


def write_changelog(version: str, build: int, subjects: list[str]) -> None:
    body = "\n".join(f"- {s}" for s in subjects) or "- Maintenance release."
    entry = f"## {version} ({build})\n\n{body}\n\n"
    text = CHANGELOG.read_text(encoding="utf-8")
    anchor = "\n## "
    index = text.find(anchor)
    if index == -1:
        CHANGELOG.write_text(text.rstrip() + "\n\n" + entry, encoding="utf-8")
        return
    CHANGELOG.write_text(
        text[: index + 1] + entry + text[index + 1 :], encoding="utf-8"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--github-output", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    major, minor, patch, build = read_version()
    version, full = bump(major, minor, patch, build)
    tag = f"v{version}"

    if not args.dry_run:
        write_pubspec(full)
        write_changelog(version, build + 1, commit_subjects())

    print(f"{major}.{minor}.{patch}+{build} -> {full}  (tag {tag})")
    if args.github_output and (path := os.environ.get("GITHUB_OUTPUT")):
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"tag={tag}\nversion={full}\n")


if __name__ == "__main__":
    main()
