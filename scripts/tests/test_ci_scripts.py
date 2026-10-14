import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("summary", ROOT / "scripts/summarize-xcresult.py")
summary_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary_module)


class XCTestSummaryTests(unittest.TestCase):
    def summary(self, **overrides):
        return {
            "result": "Passed", "totalTestCount": 7, "passedTests": 7,
            "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
            "testFailures": [], **overrides,
        }

    def testActualPassingCountsAreAccepted(self):
        summary_module.validate_summary(self.summary(), 7)

    def testZeroTestsCannotPass(self):
        with self.assertRaises(ValueError):
            summary_module.validate_summary(self.summary(totalTestCount=0, passedTests=0), 1)

    def testFailuresSkipsAndExpectedFailuresAreRejected(self):
        for key in ("failedTests", "skippedTests", "expectedFailures"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                summary_module.validate_summary(self.summary(**{key: 1}), 1)

    def testMissingAndBooleanCountsAreRejected(self):
        missing = self.summary()
        missing.pop("totalTestCount")
        missing_failures = self.summary()
        missing_failures.pop("testFailures")
        for payload in (missing, missing_failures, self.summary(totalTestCount=True)):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                summary_module.validate_summary(payload, 1)

    def testIncompleteOrFailedResultsCannotPass(self):
        for payload in (
            self.summary(result="Failed"), self.summary(passedTests=6),
            self.summary(testFailures=[{"message": "Runner crashed"}]),
        ):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                summary_module.validate_summary(payload, 1)

    def testMissingExpectedCasesCannotPass(self):
        with self.assertRaises(ValueError):
            summary_module.validate_summary(self.summary(totalTestCount=6, passedTests=6), 7)


class CommandDeadlineTests(unittest.TestCase):
    def command(self, program, seconds=2):
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/run-bounded.py"), str(seconds), sys.executable, "-c", program],
            capture_output=True, text=True, timeout=15,
        )

    def testCommandStatusIsPreserved(self):
        self.assertEqual(self.command("raise SystemExit(7)").returncode, 7)

    def testHungCommandFailsWithDeadlineStatus(self):
        result = self.command("import time; time.sleep(5)", seconds=1)
        self.assertEqual(result.returncode, 124)
        self.assertIn("exceeded", result.stderr)


if __name__ == "__main__":
    unittest.main()
