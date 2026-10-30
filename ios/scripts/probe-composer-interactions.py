"""Offline Catalyst checks of real composer/editor behavior; no simulator or account.

Keyboard and command visibility are injected only into a disposable ChatComposer source copy
to render the system dismiss icon. This does not verify physical keyboard gestures.
Attachment preview/network domain types are minimal probe-only stand-ins.
Speech recognition is a failure-only stub; this probe never records or contacts ASR.
App-owned icon assets use system-symbol stand-ins with the same view frames.
"""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    ios = Path(__file__).resolve().parents[1]
    app = ios / "Agents Anywhere/Agents Anywhere"
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="aa-composer-interactions-") as folder:
        temporary = Path(folder)
        composer = (app / "Views/Chat/Composer/ChatComposer.swift").read_text()
        hook = "@State private var softwareKeyboardVisible = false"
        assert composer.count(hook) == 1, "Update keyboard-visibility injection hook"
        composer = composer.replace(hook, hook.replace("false", "true"))
        # Exercise the widest action row: voice, runtime commands and keyboard dismissal.
        command_hook = "showsCommands: Bool = false"
        assert composer.count(command_hook) == 1, "Update command-visibility injection hook"
        composer = composer.replace(command_hook, command_hook.replace("false", "true"))
        # Host Catalyst SwiftUI lacks the SDK's GlassEffectContainer symbol.
        # Omit glass styling only in this temporary rendering copy.
        composer = composer.replace("GlassEffectContainer(spacing: 12)", "VStack(spacing: 12)")
        # ImageRenderer cannot draw UIViewRepresentable. Native editor behavior
        # is checked separately; this snapshot verifies only composer controls.
        editor = "NativeComposerEditor(draft: draft, controller: editor, maximumHeight: maximumEditorHeight, onCommandSend: sendIfReady)"
        assert composer.count(editor) == 1
        composer = composer.replace(editor, "Text(draft.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)")
        composer = "\n".join(line for line in composer.splitlines()
                             if ".glassEffect(" not in line and ".glassEffectID(" not in line)
        (temporary / "ChatComposer.swift").write_text(composer)
        # This editor/layout probe never exercises ASR. Its failure-only adapter
        # avoids compiling iOS audio capture against Catalyst's different SDK.
        recognizer = """import Foundation
@MainActor final class ComposerSpeechRecognizer: ComposerSpeechRecognizing {
    init(credentials: @escaping @MainActor @Sendable () async throws -> V2SpeechCredentials = { throw ComposerSpeechFailure.unavailable }) {}
    func start(locale: Locale, onEvent: @escaping @MainActor (ComposerSpeechEvent) -> Void) async throws {
        throw ComposerSpeechFailure.unavailable
    }
    func finish() async throws {}
    func cancel() {}
}
"""
        (temporary / "ComposerSpeechRecognizer.swift").write_text(recognizer)
        # A command-line executable has no app asset catalog. Preserve symbol
        # frames while rendering visible stand-ins for plus/send/command.
        (temporary / "AppSymbol.swift").write_text("""import SwiftUI
struct AppSymbol: View {
    let name: String
    let size: CGFloat
    init(_ name: String, size: CGFloat = 20) { self.name = name; self.size = size }
    var body: some View { Image(systemName: name).resizable().scaledToFit().frame(width: size, height: size) }
}
""")
        sources = ["Views/Chat/Composer/NativeComposerEditor.swift", "Views/Chat/Composer/ComposerLayout.swift",
                   "Views/Chat/Composer/ChatControlMetrics.swift", "Views/Chat/Composer/ChatKeyboardDismissalRouter.swift",
                   "Models/Chat/ComposerDraft.swift", "Models/Chat/ComposerVoiceInput.swift",
                   "Domain/Speech/V2SpeechCredentials.swift",
                   "Views/AppTheme.swift"]
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
                   "-target", f"{platform.machine()}-apple-ios26.0-macabi", "-sdk", sdk,
                   "-F", f"{sdk}/System/iOSSupport/System/Library/Frameworks",
                   str(temporary / "ChatComposer.swift"), str(temporary / "ComposerSpeechRecognizer.swift"),
                   str(temporary / "AppSymbol.swift"),
                   *(str(app / s) for s in sources),
                   str(ios / "Tests/ComposerInteractionProbe.swift"), "-o", str(temporary / "probe")]
        with (output / "build.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        with (output / "run.log").open("w") as log:
            subprocess.run([str(temporary / "probe"), str(output)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        report_path = output / "result.json"
        report = json.loads(report_path.read_text())
        report.update({"speech_recognition_stubbed": True, "real_asr_verified": False,
                       "command_visibility_injected_for_render_only": True,
                       "app_owned_symbol_art_replaced_for_headless_render_only": True})
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print("PASS: offline Catalyst composer/IME/router checks and voice/command/keyboard rendering; ASR not exercised")


if __name__ == "__main__":
    main()
