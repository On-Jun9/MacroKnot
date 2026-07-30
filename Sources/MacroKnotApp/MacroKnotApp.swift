import SwiftUI

@main
struct MacroKnotApp: App {
    @StateObject private var permissions = PermissionState()

    var body: some Scene {
        WindowGroup {
#if DEBUG
            DebugUISnapshotRoot(permissions: permissions)
#else
            ContentView(permissions: permissions)
#endif
        }
        .defaultSize(width: 1_100, height: 720)
        Settings {
            SettingsView(permissions: permissions)
        }
        .commands {
            DocumentMenuCommands()
        }
    }
}

struct DocumentFileCommands {
    let newDocument: () -> Void
    let openDocument: () -> Void
    let saveDocument: () -> Void
    let saveDocumentAs: () -> Void
}

private struct DocumentFileCommandsKey: FocusedValueKey {
    typealias Value = DocumentFileCommands
}

extension FocusedValues {
    var documentFileCommands: DocumentFileCommands? {
        get { self[DocumentFileCommandsKey.self] }
        set { self[DocumentFileCommandsKey.self] = newValue }
    }
}

private struct DocumentMenuCommands: Commands {
    @FocusedValue(\.documentFileCommands) private var documentCommands

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 매크로") {
                documentCommands?.newDocument()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(documentCommands == nil)

            Button("열기…") {
                documentCommands?.openDocument()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(documentCommands == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("저장") {
                documentCommands?.saveDocument()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(documentCommands == nil)

            Button("다른 이름으로 저장…") {
                documentCommands?.saveDocumentAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(documentCommands == nil)
        }
    }
}
