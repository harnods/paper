import AppIntents

struct AddToPaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Paper"
    static let description = IntentDescription("Puts text on a new paper.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Paper")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PaperData.store.addPaper(with: text)
        return .result(dialog: "Added to Paper.")
    }
}

struct PaperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToPaperIntent(),
            phrases: [
                "Put it in \(.applicationName)",
                "Add to \(.applicationName)",
                "Save to \(.applicationName)",
                "Write in \(.applicationName)",
            ],
            shortTitle: "Add to Paper",
            systemImageName: "doc.text"
        )
    }
}
