import AppKit
import SwiftUI
import ServiceManagement

// メニューバー常駐アプリ。
// SwiftUI の MenuBarExtra ではなく NSStatusItem を直接使う。
// (MenuBarExtra は環境によってアイコンが出ないことがあり、表示状態を検証しづらいため)
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var model: AppModel?
    private var resignActiveObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var appWindowClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        installMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "list.bullet.rectangle",
                accessibilityDescription: "Agent Recipes"
            )
            // シンボルが読めない環境でも必ず何か見えるようにしておく。
            if button.image == nil { button.title = "AR" }
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // ⌘ドラッグで動かした位置を次回以降も保持する。
        item.autosaveName = "AgentRecipesStatusItem"
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 330, height: 480)
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model) { [weak self] in
            self?.closePopover()
        })
        self.popover = popover
        installPopoverDismissalObservers()

        // `--manage` 付きで起動されたら、メニューバーを経由せず Recipe 一覧を開く。
        // (メニューバーが埋まっている環境でも確実に操作できる入口)
        let arguments = CommandLine.arguments
        if arguments.contains("--manage") || arguments.contains("--settings") {
            // 起動直後の activate は取りこぼすことがあるので 1 パス遅らせる。
            DispatchQueue.main.async {
                if arguments.contains("--settings") {
                    // `--settings skills` のようにタブ名を続けられる。
                    let tab = arguments.last.flatMap { SettingsView.Tab(rawValue: $0) } ?? .general
                    PanelPresenter.shared.showSettings(model: model, tab: tab)
                } else {
                    PanelPresenter.shared.showManager(model: model)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        // メニューバーが埋まっていると、アイコンがノッチの下に置かれて見えなくなる。
        // 黙って「起動していない」ように見えてしまうので、検出して知らせる。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.warnIfStatusItemIsHidden()
        }
    }

    /// ステータス項目がノッチの下など、見えない位置に置かれていないか判定する。
    private func isStatusItemVisible() -> Bool {
        guard let frame = statusItem?.button?.window?.frame else { return false }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else {
            return false
        }
        // ノッチのある画面では、メニューバーの使用可能域が左右に分かれる。
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return true // ノッチなし。位置に関わらず見えている。
        }
        // 縦方向はステータス項目の方が数 pt 大きいことがあるので、横位置だけで判定する。
        // (rect.contains で見ると、表示されていても隠れている扱いになってしまう)
        return frame.maxX <= left.maxX + 1 || frame.minX >= right.minX - 1
    }

    private func warnIfStatusItemIsHidden() {
        guard !isStatusItemVisible() else { return }
        NSLog("AgentRecipes: status item is hidden behind the notch (frame=\(statusItem?.button?.window?.frame ?? .zero))")

        let alert = NSAlert()
        alert.messageText = "メニューバーに空きがなく、アイコンが表示できません"
        alert.informativeText = """
        Agent Recipes は起動していますが、メニューバーが埋まっているため \
        アイコンがノッチの下に隠れています。

        システム設定 →「コントロールセンター」で項目を減らすか、\
        常駐アプリをひとつ終了すると表示されます。

        それまでは下のボタンから Recipe 一覧を開いて操作できます。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Recipe 一覧を開く")
        alert.addButton(withTitle: "閉じる")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let model {
            PanelPresenter.shared.showManager(model: model)
        }
    }

    /// accessory アプリはメニューバーを表示しないが、main menu が無いと
    /// ⌘A / ⌘C / ⌘V / ⌘Z などの標準ショートカットがテキスト入力に届かない。
    /// 表示されない前提で、キー割り当てのためだけの最小メニューを入れる。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "設定…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Agent Recipes を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Agent Recipes を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "削除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openSettingsFromMenu() {
        guard let model else { return }
        PanelPresenter.shared.showSettings(model: model)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        model?.reload()
        model?.refreshHerdr()
        // popover の hosting controller は使い回されるため onAppear が再発火しないことがある。
        // クリップボード由来の既定値が古いままになるので、開くたびに取り直す。
        model?.refreshClipboardSnapshot()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// accessory app では transient popover が外部クリックで残ることがあるため明示的に閉じる。
    private func installPopoverDismissalObservers() {
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }

        // global monitor は他アプリでのクリックだけを受ける。
        // app内のSwiftUI Menu操作は監視しないため、サブメニューを途中で閉じない。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }

        // Manage / Settings / Result など、このアプリ自身の通常windowをクリックした場合も閉じる。
        // popoverやSwiftUI Menuはtitled windowではないため、メニュー操作には干渉しない。
        appWindowClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if event.window?.styleMask.contains(.titled) == true {
                Task { @MainActor in self?.closePopover() }
            }
            return event
        }
    }

    private func closePopover() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let appWindowClickMonitor {
            NSEvent.removeMonitor(appWindowClickMonitor)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Launch at Login。SMAppService は .app として起動している場合のみ機能する。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at Login の切り替えに失敗しました: \(error.localizedDescription)")
        }
    }
}
