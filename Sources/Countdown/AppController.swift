import AppKit
import UserNotifications
import CountdownCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    var state = AppState()
    var controllers: [UUID: NoteWindowController] = [:]
    private var settings: SettingsController?
    private var appearanceWindows: [UUID: SettingsController] = [:]
    private var automationWindow: AutomationSettingsController?
    private(set) var automations = AutomationLibrary()
    private(set) var automationData: Data?
    private(set) var automationError: String?
    private var lastAutomationErrorShown: String?
    let automationStore: AutomationStore
    private var ticker: Timer?
    private var pendingSave: DispatchWorkItem?
    private var lastTick = Date()
    private var sleeping = false
    private var terminating = false
    private var saveErrorShown = false
    private var canSave = false
    private let store: StateStore

    init(dataDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = dataDirectory ?? support.appendingPathComponent("Countdown")
        store = StateStore(url: directory.appendingPathComponent("state.json"))
        automationStore = AutomationStore(url: directory.appendingPathComponent("automations.json"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        UNUserNotificationCenter.current().delegate = self
        do { state = try store.load(); canSave = true }
        catch {
            let alert = NSAlert()
            alert.messageText = "保存したタイマーを読み込めませんでした"
            alert.informativeText = "元のデータは上書きしません。\n\(store.url.path)\n\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        reloadAutomations()
        let now = Date()
        for index in state.open.indices {
            _ = state.open[index].completeIfNeeded(at: now, allowEffects: false)
        }
        for note in state.open { openWindow(note, focus: false) }
        if state.open.isEmpty && state.closed.isEmpty { newTimer(nil) }
        else if let controller = controllers.values.first {
            controller.window?.makeKeyAndOrderFront(nil)
            if controller.app.note(controller.id)?.deadline == nil || controller.app.note(controller.id)?.isFinished(at: now) == true {
                controller.focusInput()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
        saveSoon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let controller = automationWindow, let window = controller.window,
           !controller.windowShouldClose(window) { return .terminateCancel }
        return .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if canSave { reloadAutomations() }
    }

    func reloadAutomations() {
        do {
            let data = try automationStore.data()
            let library = try data.map { try AutomationLibrary.decode($0) } ?? AutomationLibrary()
            automations = library
            automationData = data
            automationError = nil
            lastAutomationErrorShown = nil
        } catch { automationError = error.localizedDescription }
        automationWindow?.showLoadError(automationError)
        if let message = automationError, message != lastAutomationErrorShown,
           automationWindow?.window?.isVisible != true {
            lastAutomationErrorShown = message
            showError("オートメーションのJSONを読み込めませんでした。\n\(message)\n\n実行中のタイマーは継続します。\n\(automationStore.url.path)")
        }
    }

    func saveAutomations(_ library: AutomationLibrary, replacing expected: Data?) throws {
        automationData = try automationStore.save(library, replacing: expected)
        automations = library
        automationError = nil
        for controller in controllers.values { controller.reloadSuggestions() }
    }

    @objc func showAutomations(_ sender: Any?) {
        reloadAutomations()
        if automationWindow == nil { automationWindow = AutomationSettingsController(app: self) }
        automationWindow?.refreshIfUnedited()
        automationWindow?.showWindow(nil)
        automationWindow?.window?.makeKeyAndOrderFront(nil)
        automationWindow?.showLoadError(automationError)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty { newTimer(nil) }
        else {
            for controller in controllers.values { controller.window?.deminiaturize(nil); controller.window?.orderFront(nil) }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        ticker?.invalidate()
        pendingSave?.cancel()
        saveNow()
    }

    func note(_ id: UUID) -> TimerNote? { state.open.first { $0.id == id } }

    func modify(_ id: UUID, _ update: (inout TimerNote) -> Void) {
        guard let index = state.open.firstIndex(where: { $0.id == id }) else { return }
        update(&state.open[index])
        saveSoon()
    }

    private func openWindow(_ note: TimerNote, focus: Bool) {
        let controller = NoteWindowController(note: note, app: self)
        controllers[note.id] = controller
        controller.window?.makeKeyAndOrderFront(nil)
        if let window = controller.window { NSApp.addWindowsItem(window, title: window.title, filename: false) }
        controller.saveFrame()
        if focus { controller.focusInput() }
    }

    @objc func newTimer(_ sender: Any?) {
        let note = TimerNote(appearance: state.preferences.appearance)
        state.open.append(note)
        openWindow(note, focus: true)
        saveSoon()
    }

    @objc func restoreTimer(_ sender: Any?) {
        guard var note = state.restoreLast() else { return }
        _ = note.completeIfNeeded(at: Date(), allowEffects: false)
        if let index = state.open.firstIndex(where: { $0.id == note.id }) { state.open[index] = note }
        openWindow(note, focus: note.deadline == nil || note.isFinished(at: Date()))
        refresh()
        saveSoon()
    }

    func close(_ id: UUID) {
        guard !terminating else { return }
        controllers[id]?.saveFrame()
        if let window = controllers[id]?.window { NSApp.removeWindowsItem(window) }
        state.archive(id)
        appearanceWindows.removeValue(forKey: id)?.close()
        controllers.removeValue(forKey: id)
        refresh()
        saveSoon()
    }

    func start(_ id: UUID, raw: String) throws {
        reloadAutomations()
        let request = try TimerRequest.resolve(raw, previous: state.previous, library: automations)
        switch request {
        case .timer(let input, let spec): try start(id, input: input, specification: spec)
        case .automation(let definition):
            guard let index = state.open.firstIndex(where: { $0.id == id }) else { return }
            let order = state.sequence + 1
            try state.open[index].start(automation: definition, now: Date(), order: order)
            state.sequence = order
            saveSoon()
            refresh()
        }
    }

    private func start(_ id: UUID, input: String, specification: TimeSpecification) throws {
        guard let index = state.open.firstIndex(where: { $0.id == id }) else { return }
        let order = state.sequence + 1
        try state.open[index].start(input: input, specification: specification, now: Date(), order: order)
        state.sequence = order
        saveSoon()
        refresh()
    }

    func togglePause(_ id: UUID) {
        guard let note = note(id) else { return }
        if note.pausedRemaining != nil { modify(id) { $0.resume(at: Date()) } }
        else if state.preferences.pauseEnabled { modify(id) { $0.pause(at: Date()) } }
        refresh()
    }

    func stopAutomation(_ id: UUID) {
        modify(id) { $0.stopAutomation(at: Date()) }
        refresh()
    }

    private func tick(allowEffects: Bool? = nil) {
        let now = Date()
        let effects = allowEffects ?? (!sleeping && now.timeIntervalSince(lastTick) < 3)
        lastTick = now
        var completed: [(TimerNote, Bool)] = []
        var changed = false
        for index in state.open.indices {
            let old = state.open[index]
            if state.open[index].completeIfNeeded(at: now, allowEffects: effects) {
                completed.append((old, state.open[index].isFinished(at: now)))
            }
            if old.completionHandled != state.open[index].completionHandled
                || old.automation?.currentIndex != state.open[index].automation?.currentIndex { changed = true }
        }
        for (note, final) in completed { finish(note, final: final) }
        refresh(at: now)
        if changed { saveSoon() }
    }

    func refresh(at now: Date = Date()) {
        for controller in controllers.values { controller.update(at: now) }
    }

    @objc private func willSleep(_ notification: Notification) { sleeping = true; saveNow() }
    @objc private func didWake(_ notification: Notification) { tick(allowEffects: false); sleeping = false; lastTick = Date() }

    private func finish(_ note: TimerNote, final: Bool) {
        if state.preferences.soundEnabled { NSSound(named: "Glass")?.play() }
        if state.preferences.confettiEnabled { controllers[note.id]?.celebrate() }
        if state.preferences.notificationsEnabled {
            let content = UNMutableNotificationContent()
            content.title = note.label.isEmpty ? (note.automation?.definition.name ?? "タイマー") : note.label
            content.body = final ? "終了しました" : "この区間が終了し、次の区間へ進みました"
            // Sound is an independent opt-in and is played above, once.
            let request = UNNotificationRequest(identifier: note.id.uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { NSLog("Notification: %@", error.localizedDescription) }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func deadlineDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm:ss"
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) { day = "今日" }
        else if calendar.isDateInTomorrow(date) { day = "明日" }
        else { let f = DateFormatter(); f.dateFormat = "M/d"; day = f.string(from: date) }
        return "\(day) \(formatter.string(from: date))"
    }

    func showDatePicker(for id: UUID) {
        guard let window = controllers[id]?.window else { return }
        let alert = NSAlert()
        alert.messageText = "終了日時を指定"
        alert.informativeText = "開始すると、現在のタイマーをこの日時に置き換えます。"
        alert.addButton(withTitle: "開始")
        alert.addButton(withTitle: "キャンセル")
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.dateValue = note(id)?.deadline.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(180)
        picker.minDate = Date()
        alert.accessoryView = picker
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
                try self.start(id, input: formatter.string(from: picker.dateValue), specification: .date(picker.dateValue))
                self.controllers[id]?.editing = false
                self.controllers[id]?.inputField.stringValue = ""
                self.controllers[id]?.window?.makeFirstResponder(nil)
                self.refresh()
            } catch { self.showError(error.localizedDescription) }
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsController(app: self, noteID: nil) }
        settings?.reload()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    func showAppearance(for id: UUID) {
        if appearanceWindows[id] == nil { appearanceWindows[id] = SettingsController(app: self, noteID: id) }
        appearanceWindows[id]?.reload()
        appearanceWindows[id]?.showWindow(nil)
        appearanceWindows[id]?.window?.makeKeyAndOrderFront(nil)
    }

    func preferencesChanged(_ preferences: Preferences) {
        state.preferences = preferences
        refresh()
        saveSoon()
    }

    func requestNotifications(_ enabled: Bool) {
        guard enabled else { state.preferences.notificationsEnabled = false; saveSoon(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.preferences.notificationsEnabled = granted
                self.saveSoon()
                self.settings?.reload()
                if !granted { self.showError(error?.localizedDescription ?? "通知が許可されていません。macOSのシステム設定でCountdownの通知を確認してください。") }
            }
        }
    }

    private func saveSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func saveNow() {
        guard canSave else { return }
        do { try store.save(state) }
        catch {
            guard !saveErrorShown else { return }
            saveErrorShown = true
            showError("タイマーを保存できませんでした。\n\(error.localizedDescription)")
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Countdown"
        alert.informativeText = message
        alert.runModal()
    }

    private var active: NoteWindowController? {
        if let selected = NSApp.keyWindow ?? NSApp.mainWindow {
            return controllers.values.first { $0.window === selected }
        }
        // A borderless timer can be visible without a key or main window after
        // changing its style mask. Keep menu actions bound to the front timer.
        for window in NSApp.orderedWindows where window.isVisible && !window.isMiniaturized {
            if let controller = controllers.values.first(where: { $0.window === window }) { return controller }
        }
        return nil
    }

    @objc private func editActive(_ sender: Any?) { active?.editTime() }
    @objc private func detailsActive(_ sender: Any?) { active?.showDetails() }
    @objc private func appearanceActive(_ sender: Any?) { active?.showAppearance() }
    @objc private func labelActive(_ sender: Any?) { active?.editLabel() }
    @objc private func controlsActive(_ sender: Any?) { active?.toggleControls() }
    @objc private func pauseActive(_ sender: Any?) { active?.togglePause() }
    @objc private func stopAutomationActive(_ sender: Any?) { if let active { stopAutomation(active.id) } }
    private var commandWindow: NSWindow? { NSApp.keyWindow ?? active?.window }

    @objc private func closeKeyWindow(_ sender: Any?) {
        guard NSApp.modalWindow == nil, let window = commandWindow,
              window.attachedSheet == nil, !window.isSheet else { return }
        // Auxiliary windows also use Cmd-W, including their unsaved-changes prompt.
        window.performClose(nil)
    }
    @objc private func miniaturizeActive(_ sender: Any?) {
        guard NSApp.modalWindow == nil, let window = commandWindow, window.styleMask.contains(.miniaturizable),
              window.attachedSheet == nil, !window.isSheet else { return }
        window.miniaturize(nil)
    }
    @objc private func floatActive(_ sender: Any?) {
        guard let active else { return }
        modify(active.id) { $0.appearance.floating.toggle() }
        if let note = note(active.id) { active.applyAppearance(note.appearance) }
    }
    @objc private func resizeActive(_ sender: NSMenuItem) {
        guard let active, let window = active.window else { return }
        let compact = note(active.id)?.isCompact == true
        let size: NSSize = sender.tag == 0 ? (compact ? NSSize(width: 120, height: 60) : NSSize(width: 220, height: 164))
            : sender.tag == 1 ? NSSize(width: 320, height: 220) : NSSize(width: 480, height: 300)
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    @objc private func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "時間の付箋を置く"
        alert.informativeText = "17:45 / 1745 / 17 / 9:5:3 → 次に来るその時刻\n3m / 1h30m / 90s → 今からその長さ\n保存したオートメーション名 → 区間を順番に実行\n名前の候補は↑↓とEnterで選択\n⌘, の「オートメーションを作成・管理…」で編集\n\n空欄でEnter → 前回の指定を再利用\nラベル欄でEnter → 未設定なら時間入力／実行中は編集終了\n数字をダブルクリック → 時間を変更\nカレンダーボタン → 終了日時を指定\nスライダーボタン → この窓の外観\n\n⌘N 新規　⌘W 閉じる　⇧⌘T 復元\n⇧⌘U 操作UIの表示切り替え\n⌘M 最小化　⌘H アプリを隠す\n⌘, 設定　⌘Q 保存して終了\n\n設定で表示を分・時:分:秒・自動から選べます。\n小窓でもラベルがあれば表示します。\n小窓のダブルクリック動作は設定で選べます。\n最小化やスリープでも時間は進みます。\n\n閉じた窓は直近30件まで復元できます。\n閉じた窓は通知せず、復元時に元の締切から表示します。"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeKeyWindow(_:)):
            guard NSApp.modalWindow == nil, let window = commandWindow else { return false }
            return window.attachedSheet == nil && !window.isSheet
        case #selector(miniaturizeActive(_:)):
            guard NSApp.modalWindow == nil, let window = commandWindow, window.styleMask.contains(.miniaturizable) else { return false }
            return window.attachedSheet == nil && !window.isSheet
        case #selector(restoreTimer(_:)): return !state.closed.isEmpty
        case #selector(editActive(_:)), #selector(detailsActive(_:)), #selector(appearanceActive(_:)), #selector(labelActive(_:)), #selector(resizeActive(_:)):
            return active != nil
        case #selector(floatActive(_:)):
            item.state = active.flatMap { note($0.id)?.appearance.floating } == true ? .on : .off
            return active != nil
        case #selector(controlsActive(_:)):
            item.title = active.flatMap { note($0.id)?.isCompact } == true ? "操作UIを表示" : "操作UIを隠す"
            return active != nil
        case #selector(pauseActive(_:)):
            guard let active, let note = note(active.id) else { return false }
            item.title = note.pausedRemaining == nil ? "一時停止" : "再開"
            return note.pausedRemaining != nil || (state.preferences.pauseEnabled && note.canPause && (note.remaining(at: Date()) ?? 0) > 0)
        case #selector(stopAutomationActive(_:)):
            return active.flatMap { note($0.id) }.map { $0.automation != nil && !$0.isFinished(at: Date()) } ?? false
        default: return true
        }
    }

    private func makeMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        func section(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        @discardableResult func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil, shift: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = shift ? [.command, .shift] : .command
            menu.addItem(item)
            return item
        }
        let app = section("Countdown")
        add(app, "Countdownについて", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "設定…", #selector(showSettings(_:)), ",", target: self)
        add(app, "オートメーション…", #selector(showAutomations(_:)), target: self)
        app.addItem(.separator())
        add(app, "Countdownを隠す", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "すべてを表示", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Countdownを終了", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = section("ファイル")
        add(file, "新規タイマー", #selector(newTimer(_:)), "n", target: self)
        add(file, "ウィンドウを閉じる", #selector(closeKeyWindow(_:)), "w", target: self)
        add(file, "最後に閉じたタイマーを復元", #selector(restoreTimer(_:)), "t", target: self, shift: true)
        let edit = section("編集")
        add(edit, "取り消す", Selector(("undo:")), "z")
        add(edit, "やり直す", Selector(("redo:")), "z", shift: true)
        edit.addItem(.separator())
        add(edit, "カット", #selector(NSText.cut(_:)), "x")
        add(edit, "コピー", #selector(NSText.copy(_:)), "c")
        add(edit, "ペースト", #selector(NSText.paste(_:)), "v")
        add(edit, "すべてを選択", #selector(NSText.selectAll(_:)), "a")
        let timer = section("タイマー")
        add(timer, "時間を設定…", #selector(editActive(_:)), target: self)
        add(timer, "終了日時を指定…", #selector(detailsActive(_:)), target: self)
        add(timer, "ラベルを編集…", #selector(labelActive(_:)), target: self)
        add(timer, "一時停止", #selector(pauseActive(_:)), target: self)
        add(timer, "オートメーションを中止", #selector(stopAutomationActive(_:)), target: self)
        let view = section("表示")
        add(view, "操作UIを隠す", #selector(controlsActive(_:)), "u", target: self, shift: true)
        add(view, "最前面に表示", #selector(floatActive(_:)), target: self)
        add(view, "このタイマーの外観…", #selector(appearanceActive(_:)), target: self)
        for (index, title) in ["小さく", "標準サイズ", "大きく"].enumerated() {
            add(view, title, #selector(resizeActive(_:)), target: self).tag = index
        }
        let windows = section("ウィンドウ")
        add(windows, "最小化", #selector(miniaturizeActive(_:)), "m", target: self)
        add(windows, "すべてを手前に移動", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = windows
        let help = section("ヘルプ")
        add(help, "使い方", #selector(showHelp(_:)), target: self)
        NSApp.helpMenu = help
    }
}
