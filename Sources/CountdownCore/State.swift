import Foundation

public enum NoteColor: String, Codable, CaseIterable {
    case yellow, mint, blue, pink, purple, neutral

    public var title: String {
        switch self {
        case .yellow: return "イエロー"
        case .mint: return "ミント"
        case .blue: return "ブルー"
        case .pink: return "ピンク"
        case .purple: return "パープル"
        case .neutral: return "ニュートラル"
        }
    }
}

public struct Appearance: Codable, Equatable {
    public var color: NoteColor = .yellow
    public var opacity = 0.7
    public var floating = true
    public init() {}
}

public enum CompactDoubleClickAction: String, Codable, CaseIterable {
    case clickedArea, time, label

    public var title: String {
        switch self {
        case .clickedArea: return "クリックした場所に合わせる"
        case .time: return "常に時間を編集"
        case .label: return "常にラベルを編集"
        }
    }

    public func editsLabel(clickedLabel: Bool) -> Bool {
        self == .label || (self == .clickedArea && clickedLabel)
    }
}

public struct Preferences: Codable {
    public var appearance = Appearance()
    public var showSeconds = false
    public var displayMode: TimeDisplayMode?
    public var effectiveDisplayMode: TimeDisplayMode { displayMode ?? (showSeconds ? .seconds : .minutes) }
    public var compactDoubleClickAction: CompactDoubleClickAction?
    public var effectiveCompactDoubleClickAction: CompactDoubleClickAction { compactDoubleClickAction ?? .clickedArea }
    public var pauseEnabled = false
    public var soundEnabled = false
    public var notificationsEnabled = false
    public var confettiEnabled = false
    public init() {}
}

public struct WindowFrame: Codable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct TimerNote: Codable, Identifiable {
    public var id = UUID()
    public var label = ""
    public var input: String?
    public var specification: TimeSpecification?
    public var deadline: Date?
    public var pausedRemaining: TimeInterval?
    public var completionHandled = false
    public var inputOrder = 0
    public var appearance: Appearance
    public var frame: WindowFrame?
    // Optional fields keep state files created by 0.1 readable.
    public var controlsHidden: Bool?
    public var expandedFrame: WindowFrame?
    public var automation: AutomationRun?

    public var isCompact: Bool { controlsHidden == true }
    public var canPause: Bool { automation == nil && specification?.canPause == true }

    public init(appearance: Appearance = Appearance()) { self.appearance = appearance }

    public func remaining(at now: Date) -> TimeInterval? {
        if let pausedRemaining { return pausedRemaining }
        return deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    public func isFinished(at now: Date) -> Bool {
        pausedRemaining == nil && deadline.map { $0 <= now } == true
    }

    public mutating func start(input: String, specification: TimeSpecification, now: Date, order: Int) throws {
        let end = try specification.deadline(from: now)
        self.input = input
        self.specification = specification
        automation = nil
        deadline = end
        pausedRemaining = nil
        completionHandled = false
        inputOrder = order
    }

    public mutating func pause(at now: Date) {
        guard canPause, pausedRemaining == nil,
              let deadline, deadline > now else { return }
        pausedRemaining = deadline.timeIntervalSince(now)
        self.deadline = nil
    }

    public mutating func resume(at now: Date) {
        guard let pausedRemaining else { return }
        deadline = now.addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
    }

    /// Returns true once per eligible completion, including automation boundaries.
    public mutating func completeIfNeeded(at now: Date, allowEffects: Bool) -> Bool {
        if automation != nil { return advanceAutomation(at: now, allowEffects: allowEffects) }
        guard isFinished(at: now), !completionHandled else { return false }
        completionHandled = true
        return allowEffects
    }

    public mutating func start(automation definition: AutomationDefinition, now: Date, order: Int,
                               calendar: Calendar = .current) throws {
        let run = try AutomationRun(definition: definition, now: now, calendar: calendar)
        automation = run
        input = definition.name
        specification = .date(run.deadlines.last!)
        pausedRemaining = nil
        completionHandled = false
        inputOrder = order
        _ = advanceAutomation(at: now, allowEffects: false)
    }

    public mutating func stopAutomation(at now: Date) {
        guard automation != nil else { return }
        automation?.stopped = true
        deadline = now
        completionHandled = true
    }

    private mutating func advanceAutomation(at now: Date, allowEffects: Bool) -> Bool {
        guard var run = automation, !run.stopped else { return false }
        let target = run.deadlines.firstIndex { $0 > now } ?? (run.deadlines.count - 1)
        let finished = now >= run.deadlines.last!
        let boundary = target > run.currentIndex || (finished && !completionHandled)
        run.currentIndex = target
        label = run.definition.steps[target].label
        deadline = run.deadlines[target]
        completionHandled = finished
        automation = run
        return boundary && allowEffects && (run.definition.completionEffect == .each
            || (run.definition.completionEffect == .last && finished))
    }
}

public struct AppState: Codable {
    public var version = 1
    public var preferences = Preferences()
    public var open: [TimerNote] = []
    public var closed: [TimerNote] = []
    public var sequence = 0
    public init() {}

    public var previous: TimerNote? {
        open.filter { $0.specification != nil }.max { $0.inputOrder < $1.inputOrder }
            ?? closed.last { $0.specification != nil }
    }

    public mutating func archive(_ id: UUID) {
        guard let index = open.firstIndex(where: { $0.id == id }) else { return }
        closed.append(open.remove(at: index))
        if closed.count > 30 { closed.removeFirst(closed.count - 30) }
    }

    public mutating func restoreLast() -> TimerNote? {
        guard let note = closed.popLast() else { return nil }
        open.append(note)
        return note
    }
}

public struct StateStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> AppState {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppState() }
        let state = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        for note in state.open + state.closed { try note.automation?.validate() }
        return state
    }

    public func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
