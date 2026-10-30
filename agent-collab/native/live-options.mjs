import { resolve } from "node:path";
export function parseLiveOptions(args, cwd = process.cwd()) {
  if (!args.includes("--real-models"))
    throw new Error("REAL_MODEL_OPT_IN_REQUIRED");
  let report = "live-flow-report.md";
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--real-models") continue;
    if (args[i] !== "--report") throw new Error("UNKNOWN_OPTION");
    const value = args[++i];
    if (!value || value.startsWith("--"))
      throw new Error("REPORT_PATH_REQUIRED");
    report = value;
  }
  return { report: resolve(cwd, report) };
}
