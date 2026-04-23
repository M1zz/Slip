import AppKit
import SwiftUI

/// A floating, focus-preserving capture panel invoked by the global hotkey.
///
/// Key choices:
/// - `NSPanel` with `.nonactivatingPanel`: appearing doesn't switch the user
///   away from their frontmost app. They stay in Xcode/Chrome/whatever.
/// - `.hudWindow` style: the translucent vibrant look users recognize from
///   Spotlight-adjacent tools.
/// - `.canJoinAllSpaces` + `.fullScreenAuxiliary`: follows the user across
///   desktops, works over fullscreen apps.
/// - Dismisses on Escape or when it loses key status.
final class QuickCapturePanel: NSPanel {

    private let onCommit: (String) -> Void
    private let hostingController: NSHostingController<QuickCaptureView>
    private let viewModel = QuickCaptureViewModel()

    init(
        tagsProvider: @escaping () -> [String] = { [] },
        onCommit: @escaping (String) -> Void
    ) {
        self.onCommit = onCommit
        self.hostingController = NSHostingController(
            rootView: QuickCaptureView(viewModel: viewModel, tagsProvider: tagsProvider, onCommit: { _ in })
        )

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 180),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false

        // Rebuild the SwiftUI view with a real commit closure now that self exists.
        hostingController.rootView = QuickCaptureView(
            viewModel: viewModel,
            tagsProvider: tagsProvider,
            onCommit: { [weak self] text in
                self?.commit(text)
            }
        )
        contentViewController = hostingController
    }

    func present() {
        viewModel.reset()
        centerOnScreen()
        orderFrontRegardless()
        makeKey()
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY + size.height / 2  // a touch above center feels right
        )
        setFrameTopLeftPoint(origin)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { close(); return }
        onCommit(trimmed)
        close()
    }
}

// MARK: - SwiftUI content

final class QuickCaptureViewModel: ObservableObject {
    @Published var text: String = ""
    func reset() { text = "" }
}

struct QuickCaptureView: View {
    @ObservedObject var viewModel: QuickCaptureViewModel
    let tagsProvider: () -> [String]
    let onCommit: (String) -> Void
    @FocusState private var focused: Bool

    /// Partial tag the user is currently typing at the end of the text, if any.
    /// Matches `#<chars>` that aren't followed by whitespace or another `#`.
    private var tagPartial: String? {
        let last = viewModel.text
            .components(separatedBy: .whitespacesAndNewlines)
            .last ?? ""
        guard last.hasPrefix("#"), last.count >= 1 else { return nil }
        let partial = String(last.dropFirst())
        // Don't suggest once the user has moved on with a second `#` or other symbol.
        guard !partial.contains("#") else { return nil }
        return partial
    }

    private var suggestions: [String] {
        guard let partial = tagPartial else { return [] }
        let all = tagsProvider()
        if partial.isEmpty {
            return Array(all.prefix(6))
        }
        let lowered = partial.lowercased()
        return all
            .filter { $0.lowercased().hasPrefix(lowered) && $0.lowercased() != lowered }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.scribble")
                    .foregroundStyle(.secondary)
                Text("Quick Capture")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⏎ save · ⎋ cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            ZStack(alignment: .topLeading) {
                if viewModel.text.isEmpty {
                    Text("What are you thinking?")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                        .padding(.leading, 4)
                }
                TextEditor(text: $viewModel.text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { onCommit(viewModel.text) }
            }
            .frame(minHeight: 90)

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { tag in
                            Button { accept(tag: tag) } label: {
                                Text("#\(tag)")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .transition(.opacity)
            }

            HStack {
                Spacer()
                Button("Save") { onCommit(viewModel.text) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .onExitCommand { viewModel.reset() }
    }

    private func accept(tag: String) {
        var text = viewModel.text
        // Replace the trailing `#partial` with the selected tag followed by a space.
        if let hashRange = text.range(of: "#", options: .backwards) {
            text.replaceSubrange(hashRange.lowerBound..<text.endIndex, with: "#\(tag) ")
            viewModel.text = text
        }
    }
}
