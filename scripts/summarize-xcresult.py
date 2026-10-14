#!/usr/bin/env python3
"""Print and validate actual XCTest counts from a completed result bundle."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def validate_summary(summary, minimum_tests):
    keys = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
    for key in keys:
        value = summary.get(key)
        if type(value) is not int or value < 0:
            raise ValueError(f"XCTest summary field {key} must be a nonnegative integer.")
    if summary["totalTestCount"] < minimum_tests:
        raise ValueError(f"Expected at least {minimum_tests} XCTest cases; executed {summary['totalTestCount']}.")
    if summary.get("result") != "Passed":
        raise ValueError(f"XCTest result was {summary.get('result')!r}.")
    if summary["passedTests"] != summary["totalTestCount"]:
        raise ValueError("Every reported XCTest case must pass.")
    if any(summary[key] != 0 for key in ("failedTests", "skippedTests", "expectedFailures")):
        raise ValueError("Failed, skipped, and expected-failure XCTest cases cannot satisfy validation.")
    if type(summary.get("testFailures")) is not list:
        raise ValueError("XCTest summary must contain a testFailures list.")
    if summary["testFailures"]:
        raise ValueError("XCTest summary contains test failure details.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", type=Path)
    parser.add_argument("--minimum-tests", type=int, default=1)
    args = parser.parse_args()
    if args.minimum_tests < 1:
        parser.error("The minimum test count must be positive.")
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(args.result_bundle)],
        text=True, capture_output=True,
    )
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    summary = json.loads(result.stdout)
    summary_path = args.result_bundle.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    validate_summary(summary, args.minimum_tests)
    print(f"Verified {summary['passedTests']} XCTest cases passed with zero failures or skips.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"XCTest result validation failed: {error}", file=sys.stderr)
        sys.exit(1)
