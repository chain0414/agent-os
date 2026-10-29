"""Offline Catalyst checks of real composer/editor behavior; no simulator or account.

Keyboard visibility is injected only into a disposable ChatComposer source copy
to render the system dismiss icon. This does not verify physical keyboard gestures.
Attachment preview/network domain types are minimal probe-only stand-ins.
"""
import argparse
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
        # Host Catalyst SwiftUI lacks the SDK's GlassEffectContainer symbol.
        # Omit glass styling only in this temporary rendering copy.
        composer = composer.replace("GlassEffectContainer(spacing: 12)", "VStack(spacing: 12)")
        # ImageRenderer cannot draw UIViewRepresentable. Native editor behavior
        # is checked separately; this snapshot verifies only composer controls.
        editor = "NativeComposerEditor(draft: draft, controller: editor, maximumHeight: maximumEditorHeight, onCommandSend: onSend)"
        assert composer.count(editor) == 1
        composer = composer.replace(editor, "Text(draft.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)")
        composer = "\n".join(line for line in composer.splitlines()
                             if ".glassEffect(" not in line and ".glassEffectID(" not in line)
        (temporary / "ChatComposer.swift").write_text(composer)
        sources = ["Views/Chat/Composer/NativeComposerEditor.swift", "Views/Chat/Composer/ComposerLayout.swift",
                   "Views/Chat/Composer/ChatControlMetrics.swift", "Views/Chat/Composer/ChatKeyboardDismissalRouter.swift",
                   "Models/Chat/ComposerDraft.swift", "Views/AppTheme.swift", "Views/Components/AppSymbol.swift",
                   "Views/Components/AppSymbolAssets.swift"]
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
                   "-target", f"{platform.machine()}-apple-ios26.0-macabi", "-sdk", sdk,
                   "-F", f"{sdk}/System/iOSSupport/System/Library/Frameworks",
                   str(temporary / "ChatComposer.swift"), *(str(app / s) for s in sources),
                   str(ios / "Tests/ComposerInteractionProbe.swift"), "-o", str(temporary / "probe")]
        with (output / "build.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        with (output / "run.log").open("w") as log:
            subprocess.run([str(temporary / "probe"), str(output)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        print("PASS: offline Catalyst composer checks; see result.json and injected-visibility rendering")


if __name__ == "__main__":
    main()
