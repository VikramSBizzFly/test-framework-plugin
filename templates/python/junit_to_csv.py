#!/usr/bin/env python3
"""Convert pytest's JUnit report into the framework's results CSV:
id,type,role,route,expected,actual,verdict,ms

Standard library only (xml.etree.ElementTree, csv, re, sys) -- no lxml, no
extra dependency of any kind.

Usage: python junit_to_csv.py tests/results/junit.xml tests/results/run-<ts>.csv
"""
import csv
import re
import sys
import xml.etree.ElementTree as ET

# skills/test-codegen/references/python.md's naming convention: a case id
# like INV-014 is encoded in the test function name as INV__014 (hyphen ->
# double underscore, since a hyphen is not a legal Python identifier). This
# reverses it.
# Multi-segment prefixes are real: `tf.sh rbac` emits RBAC-USER-002,
# which codegen writes as test_RBAC_USER__002_...
ID_RE = re.compile(r"test_([A-Z][A-Z0-9]*(?:_[A-Z][A-Z0-9]*)*)__(\d+)")


def recover_id(name: str) -> str | None:
    m = ID_RE.search(name)
    if not m:
        return None
    # Single underscores separate prefix segments and must become hyphens
    # again: test_RBAC_USER__002 -> RBAC-USER-002.
    return f"{m.group(1).replace('_', '-')}-{m.group(2)}"


def main(in_path: str, out_path: str) -> None:
    tree = ET.parse(in_path)
    root = tree.getroot()
    # pytest's junit-xml wraps one or more <testsuite>; be tolerant of both
    # a bare <testsuite> root and a <testsuites> wrapper.
    suites = [root] if root.tag == "testsuite" else list(root)

    rows = []
    for suite in suites:
        for case in suite.findall("testcase"):
            name = case.get("name", "")
            case_id = recover_id(name)
            if case_id is None:
                continue  # not one of ours (e.g. a fixture-only node)

            ms = round(float(case.get("time", "0")) * 1000)
            failure = case.find("failure")
            error = case.find("error")
            skipped = case.find("skipped")
            if error is not None:
                verdict, actual = "ERROR", error.get("message", "")
            elif failure is not None:
                verdict, actual = "FAIL", failure.get("message", "")
            elif skipped is not None:
                verdict, actual = "SKIP", skipped.get("message", "")
            else:
                verdict, actual = "PASS", "ok"

            # type/role/route are not present in JUnit output -- only the id
            # was stamped into the test name. The caller folds those back in
            # from testcases.csv by id; this adapter's job is verdict+timing.
            rows.append([case_id, "ui", "", "", "", actual, verdict, ms])

    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "type", "role", "route", "expected", "actual", "verdict", "ms"])
        w.writerows(rows)

    print(f"junit_to_csv: wrote {len(rows)} rows to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: junit_to_csv.py <junit.xml> <out.csv>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
