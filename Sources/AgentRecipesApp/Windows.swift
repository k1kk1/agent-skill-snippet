import AppKit
import SwiftUI

/// MenuBar 常駐アプリなので、ウィンドウは必要になった時点で AppKit 側から出す。
@MainActor
final class PanelPresenter {
    static let shared = PanelPresenter()

    private var runWindow: NSWindow?
    private var managerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var resultWindow: NSWindow?

    private init() {}

    func showRunForm(model: AppModel) {
        let window = runWindow ?? makeWindow(
            title: "Run Recipe",
            size: NSSize(width: 500, height: 520),
            content: RunFormView(model: model)
        )
        runWindow = window
        present(window)
    }

    func closeRunForm() {
        runWindow?.close()
    }

    func showManager(model: AppModel) {
        let window = managerWindow ?? makeWindow(
            title: "Manage Recipes",
            size: NSSize(width: 1_180, height: 620),
            minimumSize: NSSize(width: 1_100, height: 540),
            content: RecipeManagerView(model: model)
        )
        managerWindow = window
        present(window)
    }

    func showSettings(model: AppModel, tab: SettingsView.Tab = .general) {
        let window: NSWindow
        if let existing = settingsWindow {
            // @State の初期値は既存 View には再適用されないため、起動引数で
            // 指定されたタブを確実に反映できるよう rootView を差し替える。
            let controller = NSHostingController(rootView: SettingsView(model: model, selection: tab))
            controller.sizingOptions = []
            existing.contentViewController = controller
            window = existing
        } else {
            window = makeWindow(
                title: "Settings",
                size: NSSize(width: 620, height: 560),
                content: SettingsView(model: model, selection: tab)
            )
        }
        settingsWindow = window
        present(window)
    }

    /// Submit の応答結果を出す。
    func showResult(model: AppModel) {
        let window = resultWindow ?? makeWindow(
            title: "Result",
            size: NSSize(width: 620, height: 480),
            content: ResultView(model: model)
        )
        resultWindow = window
        present(window)
    }

    private func makeWindow(
        title: String,
        size: NSSize,
        minimumSize: NSSize? = nil,
        content: some View
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentMinSize = minimumSize ?? NSSize(width: 360, height: 320)
        // SwiftUI のビューを contentView に直接入れると、macOS 26 では
        // titlebar の safe area が伝播せず、先頭のフォームやツールバーが
        // ウィンドウタイトルと重なることがある。NSHostingController 経由に
        // すると通常のコンテンツ領域（contentLayoutRect）でレイアウトされる。
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: content)
        // rootView の内容が切り替わるたびに preferredContentSize を更新すると、
        // NavigationSplitView の詳細表示で NSWindow のサイズ／位置まで動いてしまう。
        // 初期サイズは呼び出し元で決め、以降は利用者のリサイズだけを反映する。
        controller.sizingOptions = []
        window.contentViewController = controller
        // contentViewController の設定時に SwiftUI の ideal size へ縮むことがあるため、
        // 呼び出し元が指定した初期サイズを最後に適用する。
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        // accessory アプリは他アプリからフォーカスを奪えないことがあるため、
        // activate だけに頼らず前面に出す。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// 送信結果の通知。例: "Review Diff — Sent to ComposerSketch / Codex"
/// 通知センターは bundle / 認可に依存するため、自前の HUD で出す。
@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()
    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ toast: Toast) {
        dismissTask?.cancel()

        let hosting = NSHostingView(rootView: ToastView(toast: toast))
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: hosting.fittingSize.height)

        let window = self.window ?? {
            let w = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.level = .statusBar
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            return w
        }()
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)

        if let frame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(
                x: frame.maxX - window.frame.width - 16,
                y: frame.maxY - window.frame.height - 16
            ))
        }
        window.alphaValue = 1
        window.orderFrontRegardless()
        self.window = window

        let target = window
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: toast.isError ? 4_500_000_000 : 2_500_000_000)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                target.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { target.orderOut(nil) }
            }
        }
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "paperplane.fill")
                .foregroundStyle(toast.isError ? .orange : .green)
            Text(toast.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
