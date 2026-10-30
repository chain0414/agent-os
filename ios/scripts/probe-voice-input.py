"""Build a disposable simulator harness using the real composer and fake ASR.

Does not log in, contact a Server, record audio or send any messages.
The supplied simulator must already be booted. Outputs remain outside Git.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    app = root / "ios/Agents Anywhere/Agents Anywhere"
    output = args.output.resolve()
    product = output / "VoiceInputProbe.app"
    product.mkdir(parents=True, exist_ok=True)
    sources = [
        root / "ios/Tests/VoiceInputProbe.swift",
        app / "Models/Chat/ComposerDraft.swift",
        app / "Models/Chat/ComposerVoiceInput.swift",
        app / "Models/Chat/AliyunSpeechProtocol.swift",
        app / "Domain/Speech/V2SpeechCredentials.swift",
        app / "Services/ComposerSpeechRecognizer.swift",
        app / "Views/AppTheme.swift",
        *[app / f"Views/Chat/Composer/{name}.swift" for name in (
            "ChatControlMetrics", "ComposerLayout", "NativeComposerEditor", "ChatComposer")],
    ]
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    command = ["xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-swift-version", "5",
               "-default-isolation", "MainActor", "-sdk", sdk,
               "-target", "arm64-apple-ios26.2-simulator", *map(str, sources),
               "-o", str(product / "VoiceInputProbe")]
    with (output / "build.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((output / "build.log").read_text())
        return result.returncode
    bundle = "com.agentsanywhere.voice-input-probe"
    (product / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle, "CFBundleExecutable": "VoiceInputProbe",
        "CFBundleName": "VoiceInputProbe", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "26.2", "UIDeviceFamily": [1, 2], "UILaunchScreen": {},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    }))
    subprocess.run(["codesign", "--force", "--sign", "-", str(product)], check=True, capture_output=True)
    subprocess.run(["xcrun", "simctl", "install", args.device, str(product)], check=True)
    print(json.dumps({"app": str(product), "bundle": bundle, "synthetic_asr": True, "real_microphone_verified": False}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
