// Export and import of game saves as ZIP files: from the game's long-press menu and from
// Settings > System and content. The ZIP work happens in the core; this file picks the file,
// asks before replacing saves and reports the result.
import SwiftUI
import Vita3KCore
import UniformTypeIdentifiers

enum SaveTransferRequest: Identifiable, Equatable {
    /// `titleId` nil = every game.
    case export(titleId: String?, name: String?)
    case importSaves(titleId: String?, name: String?)

    var id: String {
        switch self {
        case .export(let t, _): "export-\(t ?? "all")"
        case .importSaves(let t, _): "import-\(t ?? "all")"
        }
    }
}

enum SaveTransferCore {
    private static let capacity = 2048

    /// Returns the core's code and its text (the game ids on success, the reason otherwise).
    static func export(titleId: String?, to url: URL) -> (Int32, String) {
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr in
            vita3k_ios_saves_export(titleId ?? "", url.path, ptr.baseAddress!, capacity)
        }
        return (rc, Vita3KCore.CText.string(buffer))
    }

    static func importSaves(titleId: String?, from url: URL) -> (Int32, String) {
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr in
            vita3k_ios_saves_import(titleId ?? "", url.path, ptr.baseAddress!, capacity)
        }
        return (rc, Vita3KCore.CText.string(buffer))
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SaveTransferHost: ViewModifier {
    @Binding var request: SaveTransferRequest?

    @State private var working = false
    @State private var showImporter = false
    @State private var importTarget: (titleId: String?, name: String?)?
    @State private var pendingFile: URL?
    @State private var share: ShareItem?
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, new in
                guard let new else { return }
                request = nil
                begin(new)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { stage(url) }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .sheet(item: $share, onDismiss: cleanTemporary) { item in
                ActivitySheet(url: item.url) { share = nil }
                    .presentationDetents([.medium, .large])
            }
            .alert(L10n.text("Importar saves?"), isPresented: Binding(get: { pendingFile != nil }, set: { if !$0 { discardPending() } })) {
                Button(L10n.text("Cancelar"), role: .cancel) { discardPending() }
                Button(L10n.text("Importar")) { runImport() }
            } message: {
                Text(confirmMessage)
            }
            .alert(L10n.text("Saves"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .overlay {
                if working {
                    ProgressView().controlSize(.large).padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
    }

    private var confirmMessage: String {
        if let name = importTarget?.name {
            return L10n.format("Os saves de %@ neste aparelho serão substituídos pelos do arquivo. Os atuais ficam guardados na pasta Save Backups.", name)
        }
        return L10n.text("Os saves dos jogos que estão no arquivo substituirão os deste aparelho. Os atuais ficam guardados na pasta Save Backups.")
    }

    private func begin(_ request: SaveTransferRequest) {
        guard !working else { return }
        switch request {
        case .export(let titleId, let name):
            runExport(titleId: titleId, name: name)
        case .importSaves(let titleId, let name):
            importTarget = (titleId, name)
            showImporter = true
        }
    }

    // MARK: Export

    private var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Flowyr Saves", isDirectory: true)
    }

    private func cleanTemporary() {
        try? FileManager.default.removeItem(at: temporaryFolder)
    }

    private func fileName(titleId: String?, name: String?) -> String {
        guard let titleId else { return "Flowyr saves (all games).zip" }
        let cleaned = (name ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "\(titleId) saves.zip" : "\(cleaned) - \(titleId) saves.zip"
    }

    private func runExport(titleId: String?, name: String?) {
        working = true
        let folder = temporaryFolder
        let target = folder.appendingPathComponent(fileName(titleId: titleId, name: name))
        Task.detached {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (code, text) = SaveTransferCore.export(titleId: titleId, to: target)
            await MainActor.run {
                working = false
                if code > 0 {
                    share = ShareItem(url: target)
                } else {
                    message = failureText(code, text, exporting: true)
                }
            }
        }
    }

    // MARK: Import

    /// Copies the picked file out of the Files sandbox, then asks before touching any save.
    private func stage(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = temporaryFolder
        let copy = folder.appendingPathComponent("import.zip")
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            pendingFile = copy
        } catch {
            message = error.localizedDescription
        }
    }

    private func discardPending() {
        pendingFile = nil
        cleanTemporary()
    }

    private func runImport() {
        guard let file = pendingFile, let target = importTarget else { return }
        pendingFile = nil
        working = true
        Task.detached {
            let (code, text) = SaveTransferCore.importSaves(titleId: target.titleId, from: file)
            await MainActor.run {
                working = false
                cleanTemporary()
                if code > 0 {
                    let games = text.split(separator: ",").joined(separator: ", ")
                    message = L10n.format("Saves importados: %@.", games)
                } else {
                    message = failureText(code, text, exporting: false)
                }
            }
        }
    }

    private func failureText(_ code: Int32, _ text: String, exporting: Bool) -> String {
        switch code {
        case -5: L10n.text("Feche o jogo em execução antes de exportar ou importar saves.")
        case -2: L10n.text("Não há saves para exportar.")
        case -1: L10n.text("O núcleo ainda não está pronto. Tente de novo em instantes.")
        default: text.isEmpty
            ? L10n.text(exporting ? "Não foi possível exportar os saves." : "Não foi possível importar os saves.")
            : L10n.text(text)
        }
    }
}

extension View {
    /// Handles export and import requests set on `request`: share sheet, file picker, confirmation and result.
    func saveTransfer(_ request: Binding<SaveTransferRequest?>) -> some View {
        modifier(SaveTransferHost(request: request))
    }
}
