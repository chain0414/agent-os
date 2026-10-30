// Offline Catalyst probe. The runner injects keyboard visibility into a temporary
// copy of ChatComposer for rendering only; no physical keyboard gesture is tested.
import SwiftUI
import UIKit
import Foundation

// Attachment networking/preview dependencies are not exercised by this probe.
nonisolated struct V2AttachmentReference: Codable, Equatable {}
nonisolated struct V2LocalAttachment {
    init(fileId: String, name: String, mediaType: String, data: Data, sha256: String?) {}
}
struct ChatComposerAttachment: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void
    var body: some View { Text(attachment.name) }
}

@main @MainActor struct ComposerInteractionProbe {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let draft = ComposerDraft()
        let controller = ComposerEditorController()
        let native = ComposerTextView(frame: CGRect(x: 0, y: 0, width: 340, height: 100))
        controller.textView = native; controller.draft = draft
        native.text = "保留草稿 draft"
        controller.synchronize()
        let representable = NativeComposerEditor(draft: draft, controller: controller, maximumHeight: 120, onCommandSend: {})
        let delegate = representable.makeCoordinator()
        native.delegate = delegate
        let acceptsReturn = delegate.textView(native, shouldChangeTextIn: NSRange(location: native.text.utf16.count, length: 0), replacementText: "\n")
        precondition(acceptsReturn)
        native.selectedRange = NSRange(location: native.text.utf16.count, length: 0)
        native.insertText("\n")
        controller.synchronize()
        precondition(draft.text.hasSuffix("\n"))
        native.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        controller.synchronize()
        let markedBefore = native.markedTextRange != nil
        precondition(markedBefore && draft.isComposing)
        let markedSend = await controller.committedTextForSend()
        precondition(markedSend == nil && native.markedTextRange != nil)
        native.unmarkText(); controller.synchronize()
        let before = draft.text
        draft.attachments = [ChatAttachment(name: "sample.txt", data: Data([1]), mediaType: "text/plain")]
        draft.isFocused = true
        controller.finishEditing()
        let dismissalPreservedDraft = !draft.isFocused && draft.text == before && draft.attachments.count == 1
        precondition(dismissalPreservedDraft)
        let other = ComposerDraft(); other.text = "other editor"; other.isFocused = true
        let router = ChatKeyboardDismissalRouter()
        router.activeEditor = controller; draft.isFocused = true
        router.dismiss()
        precondition(!draft.isFocused && other.isFocused && other.text == "other editor")
        router.editingEnded(controller)
        precondition(router.activeEditor == nil)

        // Fixed synthetic render. Visibility is injected by the runner, and the
        // editor is deliberately represented headlessly by ImageRenderer.
        draft.attachments = []; draft.text = "合成草稿：收起键盘后仍然保留。"; draft.isFocused = true
        let composer = ChatComposer(draft: draft, editor: controller, isStreaming: false,
            maximumEditorHeight: 120, controls: ChatControlMetrics(bodyLineHeight: 22), onSend: {}, onStop: {}, onOptions: {})
        let renderer = ImageRenderer(content: composer.frame(width: 390).padding(.vertical, 16).background(Color.white))
        renderer.scale = 2
        guard let image = renderer.uiImage, let png = image.pngData() else { fatalError("Unable to render composer") }
        try png.write(to: output.appendingPathComponent("keyboard-control-injected.png"))
        let report: [String: Any] = ["kind": "offline_catalyst_composer_probe", "physical_device": false,
            "physical_keyboard_gesture": false, "keyboard_visibility_injected_for_render_only": true,
            "glass_styling_omitted_for_host_compatibility": true,
            "editor_replaced_by_text_for_headless_render_only": true,
            "return_inserts_newline": acceptsReturn && before.contains("\n"),
            "native_marked_text_observed": markedBefore, "marked_send_blocked": markedSend == nil,
            "dismiss_preserves_draft_and_attachment": dismissalPreservedDraft,
            "router_does_not_affect_other_editor": other.isFocused,
            "system_keyboard_dismiss_symbol_exists": UIImage(systemName: "keyboard.chevron.compact.down") != nil]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("PASS: native editor IME/Return/draft/router checks; keyboard visibility injected for headless composer rendering")
    }
}
