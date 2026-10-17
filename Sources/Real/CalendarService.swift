import AppKit
import Combine
import EventKit
import Foundation

struct CalendarEntry: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

struct ReminderEntry: Identifiable {
    let id: String
    let title: String
    let due: Date?
    let completed: Bool
}

struct CalendarSource: Identifiable {
    let id: String
    let title: String
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var events: [CalendarEntry] = []
    @Published private(set) var reminders: [ReminderEntry] = []
    @Published private(set) var status = tr("尚未请求日历访问权限。")
    @Published private(set) var availableCalendars: [CalendarSource] = []
    @Published var selectedCalendarIDs: Set<String> {
        didSet {
            guard selectedCalendarIDs != oldValue || !hasSavedSelection else { return }
            hasSavedSelection = true
            UserDefaults.standard.set(selectedCalendarIDs.sorted(), forKey: Self.selectionKey)
            refresh()
        }
    }
    @Published var includeCompleted: Bool {
        didSet {
            guard includeCompleted != oldValue else { return }
            UserDefaults.standard.set(includeCompleted, forKey: Self.completedKey)
            refresh()
        }
    }

    private static let selectionKey = "real.calendar.selectedIDs"
    private static let completedKey = "real.calendar.includeCompleted"
    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []
    private var requestInProgress = false
    private var permissionEpoch = UUID()
    private var isRunning = false
    private var fetchRequest: Any?
    private var refreshGeneration = 0
    private var hasSavedSelection: Bool

    init() {
        let selection = UserDefaults.standard.stringArray(forKey: Self.selectionKey)
        selectedCalendarIDs = Set(selection ?? [])
        hasSavedSelection = selection != nil
        includeCompleted = UserDefaults.standard.bool(forKey: Self.completedKey)
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSNotification.Name.NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    deinit {
        if let fetchRequest { store.cancelFetchRequest(fetchRequest) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
    }

    func stop() {
        permissionEpoch = UUID()
        isRunning = false
        refreshGeneration += 1
        if let fetchRequest { store.cancelFetchRequest(fetchRequest) }
        fetchRequest = nil
        events = []; reminders = []
    }

    func requestAccess() {
        guard !requestInProgress else { return }
        requestInProgress = true
        let requestEpoch = permissionEpoch
        status = tr("正在请求日历和提醒事项访问权限…")
        Task {
            defer { requestInProgress = false }
            var failures: [String] = []
            do { _ = try await store.requestFullAccessToEvents() }
            catch { failures.append(tr("日历：") + error.localizedDescription) }
            // Closing/ disabling the module while the first prompt is open must
            // not produce a second permission prompt after it has been stopped.
            guard permissionEpoch == requestEpoch else { return }
            do { _ = try await store.requestFullAccessToReminders() }
            catch { failures.append(tr("提醒事项：") + error.localizedDescription) }
            guard permissionEpoch == requestEpoch else { return }
            refresh()
            if !failures.isEmpty { status = failures.joined(separator: " · ") }
        }
    }

    func refresh() {
        guard isRunning else { return }
        if let fetchRequest { store.cancelFetchRequest(fetchRequest) }
        fetchRequest = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        let eventAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        let eventCalendars = eventAccess ? store.calendars(for: .event) : []
        let reminderCalendars = reminderAccess ? store.calendars(for: .reminder) : []
        availableCalendars = eventCalendars.map { CalendarSource(id: $0.calendarIdentifier, title: $0.title) }
            + reminderCalendars.map { CalendarSource(id: $0.calendarIdentifier, title: tr("提醒事项") + " · " + $0.title) }
        // The first authorized load selects every source. Subsequently, an empty
        // selection explicitly means no sources, including after app relaunch.
        if !hasSavedSelection && !availableCalendars.isEmpty {
            selectedCalendarIDs = Set(availableCalendars.map(\.id))
            return // The property's observer starts a refresh with the new selection.
        }
        let selectedEvents = eventCalendars.filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        let selectedReminders = reminderCalendars.filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        if eventAccess && !selectedEvents.isEmpty {
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 30, to: start)!
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selectedEvents)
            events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.map {
                // Recurring occurrences share the EventKit identifier; include their start.
                CalendarEntry(id: "\($0.calendarItemIdentifier):\($0.startDate.timeIntervalSince1970)",
                              title: $0.title ?? tr("无标题日程"), start: $0.startDate,
                              end: $0.endDate, isAllDay: $0.isAllDay)
            }
        } else { events = [] }
        status = [eventAccess ? tr("已连接日历") : tr("日历：") + accessDescription(for: .event),
                  reminderAccess ? tr("已连接提醒事项") : tr("提醒事项：") + accessDescription(for: .reminder)]
            .joined(separator: " · ")
        guard reminderAccess && !selectedReminders.isEmpty else { reminders = []; return }
        let predicate = includeCompleted
            ? store.predicateForReminders(in: selectedReminders)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: selectedReminders)
        let untitledReminder = tr("无标题提醒事项")
        fetchRequest = store.fetchReminders(matching: predicate) { [weak self] fetched in
            let entries = (fetched ?? []).map { reminder in
                ReminderEntry(id: reminder.calendarItemIdentifier, title: reminder.title ?? untitledReminder,
                              due: reminder.dueDateComponents.flatMap {
                                  ($0.calendar ?? Calendar.current).date(from: $0)
                              }, completed: reminder.isCompleted)
            }.sorted {
                if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            Task { @MainActor in
                guard let self, self.refreshGeneration == generation else { return }
                self.fetchRequest = nil
                self.reminders = entries
                if fetched == nil { self.status = tr("无法读取提醒事项，请尝试刷新。") }
            }
        }
    }

    func completeReminder(id: String, completed: Bool) {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            status = tr("此提醒事项不可用，或提醒事项访问权限已关闭。")
            return
        }
        let previous = reminder.isCompleted
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
            refresh()
        } catch {
            reminder.isCompleted = previous
            status = tr("无法更新提醒事项：") + error.localizedDescription
        }
    }

    private func accessDescription(for type: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: type) {
        case .notDetermined: return tr("尚未请求访问权限")
        case .restricted: return tr("访问受限")
        case .denied: return tr("系统设置中已拒绝访问")
        case .writeOnly: return tr("读取日程需要完整访问权限")
        case .fullAccess: return tr("已连接")
        @unknown default: return tr("访问不可用")
        }
    }
}
