import SwiftUI

/// Scoped to one conversation, so dismissing a notice editor cannot affect a
/// different scene or a system sheet's first responder.
@MainActor final class ChatKeyboardDismissalRouter {
    weak var activeEditor: ComposerEditorController?

    func dismiss() { activeEditor?.finishEditing() }

    func editingEnded(_ editor: ComposerEditorController) {
        if activeEditor === editor { activeEditor = nil }
    }
}

extension EnvironmentValues {
    @Entry var chatKeyboardDismissalRouter: ChatKeyboardDismissalRouter? = nil
}
