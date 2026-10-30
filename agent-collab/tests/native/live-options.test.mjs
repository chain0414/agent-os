import test from "node:test";
import assert from "node:assert/strict";
import { parseLiveOptions } from "../../native/live-options.mjs";
test("default report remains in working directory, not process executable", () =>
  assert.equal(
    parseLiveOptions(["--real-models"], "/tmp/test-work").report,
    "/tmp/test-work/live-flow-report.md",
  ));
test("missing opt-in and report value are rejected", () => {
  assert.throws(() => parseLiveOptions([]), /REAL_MODEL_OPT_IN_REQUIRED/);
  assert.throws(
    () => parseLiveOptions(["--real-models", "--report"]),
    /REPORT_PATH_REQUIRED/,
  );
});
