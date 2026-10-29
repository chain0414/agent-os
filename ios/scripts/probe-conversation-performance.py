"""Build and run a disposable, offline Release conversation layout probe.

Uses production ChatTimelineContent and message renderers with synthetic fixtures.
Measures synchronous layout at controlled widths, not physical-device rotation FPS.
No account, server, keychain, signing team or production app is used.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def run(*args: str, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Git revision for baseline; omit for current tracked Swift sources")
    parser.add_argument("--simulator", required=True, help="An already booted simulator UUID")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--bundle-id", default="com.agentsanywhere.probe.conversation")
    parser.add_argument("--review", action="store_true", help="Open the real session UI against synthetic, intercepted HTTP fixtures")
    parser.add_argument("--stress", action="store_true", help="Measure one 50k user input paired with one 50k Markdown response")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aa-conversation-probe-") as temporary:
        root = Path(temporary)
        archive = subprocess.Popen(["git", "-C", str(repo), "archive", args.revision or "HEAD", "ios"], stdout=subprocess.PIPE)
        run("tar", "-x", "-C", str(root), stdin=archive.stdout)
        archive.stdout.close()
        if archive.wait() != 0:
            raise RuntimeError("Unable to snapshot iOS sources")
        if not args.revision:
            # Overlay only Swift source; never copy credentials or environment files.
            for folder in ["Agents Anywhere/Agents Anywhere", "Packages/Textual/Sources"]:
                for source in (repo / "ios" / folder).rglob("*.swift"):
                    destination = root / source.relative_to(repo)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, destination)
            for source in (repo / "ios/Agents Anywhere/Agents Anywhere/Resources").rglob("*.xcstrings"):
                destination = root / source.relative_to(repo)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
        app = root / "ios/Agents Anywhere/Agents Anywhere"
        timeline = app / "Views/Chat/ChatTimelineView.swift"
        source = timeline.read_text()
        if "private struct ChatTimelineContent" not in source:
            raise RuntimeError("Update the probe's timeline access hook")
        timeline.write_text(source.replace("private struct ChatTimelineContent", "struct ChatTimelineContent"))
        shutil.copyfile(repo / "ios/Tests/ConversationPerformanceProbe.swift", app / "App/AgentsAnywhereApp.swift")
        shutil.copyfile(root / "ios/Tests/ClientCoreTests/Fixtures/backend.json", app / "Resources/ConversationProbeFixtures.json")
        command = ["xcodebuild", "-project", str(root / "ios/Agents Anywhere/Agents Anywhere.xcodeproj"), "-scheme", "Agents Anywhere", "-configuration", "Release", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(args.derived_data.resolve()), "-jobs", "4", "IPHONEOS_DEPLOYMENT_TARGET=26.2", "PRODUCT_BUNDLE_IDENTIFIER=" + args.bundle_id, "CODE_SIGNING_ALLOWED=NO", "build"]
        # Build diagnostics contain only this isolated source tree and synthetic input.
        with (args.output / "build.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        product = args.derived_data / "Build/Products/Release-iphonesimulator/Agents Anywhere.app"
        run("xcrun", "simctl", "install", args.simulator, str(product))
        subprocess.run(["xcrun", "simctl", "terminate", args.simulator, args.bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, args.bundle_id, "data"], text=True).strip())
        result = container / "Documents/conversation-performance.json"
        result.unlink(missing_ok=True)
        partial = container / "Documents/conversation-performance-partial.json"
        partial.unlink(missing_ok=True)
        launch_args = ["--review"] if args.review else (["--stress"] if args.stress else [])
        run("xcrun", "simctl", "launch", args.simulator, args.bundle_id, *launch_args, stdout=subprocess.DEVNULL)
        if args.review:
            print("PASS: launched synthetic review UI; all HTTP requests are intercepted, WebSocket ticket requests fail locally")
            return
        try:
            for _ in range(180):
                if result.exists():
                    payload = json.loads(result.read_text())
                    payload["revision"] = args.revision or "working-tree"
                    (args.output / "result.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
                    run("xcrun", "simctl", "io", args.simulator, "screenshot", str(args.output / "completed.png"), stdout=subprocess.DEVNULL)
                    print("PASS: synthetic Release simulator layout probe completed")
                    return
                time.sleep(1)
            if partial.exists():
                shutil.copyfile(partial, args.output / "partial-result.json")
            raise RuntimeError("Probe did not write a completed result within 180 seconds")
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", args.simulator, args.bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
