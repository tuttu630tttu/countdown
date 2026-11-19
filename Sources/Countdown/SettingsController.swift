import AppKit
import CountdownCore

final class SettingsController: NSWindowController {
    unowned let app: AppController
    let noteID: UUID?
    private let colors = NSPopUpButton()
    private let opacity = NSSlider(value: 0.7, minValue: 0.15, maxValue: 1, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "")
    private let floating = NSButton(checkboxWithTitle: "最前面に表示", target: nil, action: nil)
    private let displayMode = NSPopUpButton()
    private let doubleClickAction = NSPopUpButton()
    private let pause = NSButton(checkboxWithTitle: "相対時間の一時停止を有効にする", target: nil, action: nil)
    private let sound = NSButton(checkboxWithTitle: "終了時に短い音を鳴らす", target: nil, action: nil)
    private let notifications = NSButton(checkboxWithTitle: "終了時にシステム通知を出す", target: nil, action: nil)
    private let confetti = NSButton(checkboxWithTitle: "終了時に窓の中へ紙吹雪を出す", target: nil, action: nil)

    init(app: AppController, noteID: UUID?) {
        self.app = app
        self.noteID = noteID
        let height: CGFloat = noteID == nil ? 564 : 206
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = noteID == nil ? "設定" : "このタイマーの外観"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let title = NSTextField(labelWithString: noteID == nil ? "新しいタイマーの初期設定" : "この窓だけに適用")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)
        colors.addItems(withTitles: NoteColor.allCases.map(\.title))
        let colorRow = NSStackView(views: [NSTextField(labelWithString: "色"), colors])
        colorRow.spacing = 16
        stack.addArrangedSubview(colorRow)
        let opacityRow = NSStackView(views: [opacityLabel, opacity])
        opacityRow.spacing = 12
        opacity.widthAnchor.constraint(equalToConstant: 156).isActive = true
        opacityLabel.widthAnchor.constraint(equalToConstant: 145).isActive = true
        stack.addArrangedSubview(opacityRow)
        stack.addArrangedSubview(floating)
        if noteID == nil {
            let heading = NSTextField(labelWithString: "すべてのタイマーに適用")
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            stack.addArrangedSubview(heading)
            displayMode.addItems(withTitles: TimeDisplayMode.allCases.map(\.title))
            displayMode.setAccessibilityLabel("残り時間の表示")
            let displayRow = NSStackView(views: [NSTextField(labelWithString: "残り時間の表示"), displayMode])
            displayRow.spacing = 16
            stack.addArrangedSubview(displayRow)
            doubleClickAction.addItems(withTitles: CompactDoubleClickAction.allCases.map(\.title))
            doubleClickAction.setAccessibilityLabel("小窓のダブルクリック動作")
            doubleClickAction.toolTip = "オートメーションの実行中はラベルが自動更新されるため、時間の編集を開きます。"
            let clickRow = NSStackView(views: [NSTextField(labelWithString: "小窓の操作"), doubleClickAction])
            clickRow.spacing = 12
            stack.addArrangedSubview(clickRow)
            for control in [pause, sound, notifications, confetti] { stack.addArrangedSubview(control) }
            let footer = NSTextField(wrappingLabelWithString: "音・通知・紙吹雪は初期OFFです。\nスリープ中に終了した場合は、復帰後の終了表示のみ。")
            footer.font = .systemFont(ofSize: 11)
            footer.textColor = .secondaryLabelColor
            stack.addArrangedSubview(footer)
            let automations = NSButton(title: "オートメーションを作成・管理…", target: app, action: #selector(AppController.showAutomations(_:)))
            automations.bezelStyle = .rounded
            stack.addArrangedSubview(automations)
        }
        for control in [colors, opacity, floating, displayMode, doubleClickAction, pause, sound, notifications, confetti] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        opacity.isContinuous = true
        opacity.setAccessibilityLabel("背景の不透明度")
        colors.setAccessibilityLabel("背景色")
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        let prefs = app.state.preferences
        let look = noteID.flatMap { app.note($0)?.appearance } ?? prefs.appearance
        colors.selectItem(at: NoteColor.allCases.firstIndex(of: look.color) ?? 0)
        opacity.doubleValue = look.opacity
        opacityLabel.stringValue = String(format: "背景の不透明度 %.2f", look.opacity)
        floating.state = look.floating ? .on : .off
        if noteID == nil {
            displayMode.selectItem(at: TimeDisplayMode.allCases.firstIndex(of: prefs.effectiveDisplayMode) ?? 0)
            doubleClickAction.selectItem(at: CompactDoubleClickAction.allCases.firstIndex(of: prefs.effectiveCompactDoubleClickAction) ?? 0)
        }
        pause.state = prefs.pauseEnabled ? .on : .off
        sound.state = prefs.soundEnabled ? .on : .off
        notifications.state = prefs.notificationsEnabled ? .on : .off
        confetti.state = prefs.confettiEnabled ? .on : .off
    }

    @objc private func changed(_ sender: NSControl) {
        var look = Appearance()
        look.color = NoteColor.allCases[max(0, colors.indexOfSelectedItem)]
        look.opacity = opacity.doubleValue
        look.floating = floating.state == .on
        opacityLabel.stringValue = String(format: "背景の不透明度 %.2f", look.opacity)
        if let noteID {
            app.modify(noteID) { $0.appearance = look }
            app.controllers[noteID]?.applyAppearance(look)
        } else {
            var prefs = app.state.preferences
            prefs.appearance = look
            prefs.displayMode = TimeDisplayMode.allCases[max(0, displayMode.indexOfSelectedItem)]
            prefs.showSeconds = prefs.displayMode == .seconds
            prefs.compactDoubleClickAction = CompactDoubleClickAction.allCases[max(0, doubleClickAction.indexOfSelectedItem)]
            prefs.pauseEnabled = pause.state == .on
            prefs.soundEnabled = sound.state == .on
            prefs.confettiEnabled = confetti.state == .on
            app.preferencesChanged(prefs)
            if sender === notifications { app.requestNotifications(notifications.state == .on) }
        }
    }
}
