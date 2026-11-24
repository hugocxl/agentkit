#!/usr/bin/env python3
"""Bound AppKit fixture accumulation while retaining every discovered XCTest."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent.parent
output = root / "build" / "validation"
output.mkdir(parents=True, exist_ok=True)
listing = subprocess.run(
    ["swift", "test", "list", "--skip-build", "--disable-swift-testing"],
    cwd=root, check=True, capture_output=True, text=True,
).stdout
(output / "test-list.txt").write_text(listing)
tests = [line for line in listing.splitlines() if re.fullmatch(r"\w+\.\w+/\w+", line)]
if not tests:
    raise SystemExit("No XCTest methods discovered")
modules = sorted({test.split(".", 1)[0] for test in tests})
for module in modules:
    suites = sorted({test.split("/", 1)[0] for test in tests if test.startswith(module + ".")})
    size = 20 if module == "AgentUITests" else len(suites)
    for start in range(0, len(suites), size):
        selected = suites[start:start + size]
        pattern = "^(" + "|".join(re.escape(suite) + "/" for suite in selected) + ")"
        print(f"Running {module} suites {start + 1}-{start + len(selected)} of {len(suites)}", flush=True)
        subprocess.run(["swift", "test", "--skip-build", "--disable-swift-testing", "--filter", pattern],
                       cwd=root, check=True)
print(f"Completed all {len(tests)} discovered XCTest methods", flush=True)
