#!/usr/bin/env python3
"""Fails when Core coverage in luacov.report.out drops below the §12 target.

    python3 .github/scripts/coverage_gate.py luacov.report.out
"""

import re
import sys

TARGET = 95.0
GATED = re.compile(r"^addon/Corkboard/Core/(Util|Sanitise|Merge|Digest)\.lua$|^Total$")


def main(path: str) -> int:
    text = open(path, encoding="utf-8").read()
    summary = text[text.index("Summary"):]
    failures, seen = [], 0
    for line in summary.splitlines():
        parts = line.split()
        if len(parts) == 4 and GATED.match(parts[0]) and parts[3].endswith("%"):
            seen += 1
            if float(parts[3][:-1]) < TARGET:
                failures.append(line)
    print(summary)
    if seen < 5:
        print(f"coverage gate: expected 5 gated lines, found {seen}")
        return 1
    for line in failures:
        print(f"coverage below {TARGET}%: {line}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
