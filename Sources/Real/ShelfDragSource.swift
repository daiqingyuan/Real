import AppKit
import SwiftUI

/// Native drag handle for the icon/title part of a shelf row. Keep share/remove
/// buttons outside this view, and do not also attach SwiftUI's .onDrag to it.
struct ShelfDragHandle: NSViewRepresentable {
    let item: ShelfFile
    let service: ShelfService
    @ObservedObject var preferences: Preferences

    func makeNSView(context: Context) -> ShelfDragHandleView {
        let view = ShelfDragHandleView()
        view.configure(item: item, service: service, preferences: preferences)
        return view
    }

    func updateNSView(_ view: ShelfDragHandleView, context: Context) {
        view.configure(item: item, service: service, preferences: preferences)
    }
}

/// Pure decision boundary, kept separate from AppKit sessions for helper tests.
enum ShelfDragPolicy {
    @MainActor static var isDraggingFromShelf: Bool { ShelfFileDragSession.hasActiveSession }

    static func allowedOperations(copyOnly: Bool) -> NSDragOperation {
        copyOnly ? .copy : [.copy, .move]
    }

    static func shouldRemove(operation: NSDragOperation, copyOnly: Bool, removeAfterUse: Bool) -> Bool {
        guard removeAfterUse else { return false }
        // Require a single confirmed operation we actually advertised. A cancel,
        // link, delete, generic operation, or ambiguous mask is not success.
        return operation == .copy || (!copyOnly && operation == .move)
    }
}

@MainActor
final class ShelfDragHandleView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var item: ShelfFile?
    private weak var service: ShelfService?
    private weak var preferences: Preferences?
    private var pressPoint: NSPoint?
    private var startedDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 28) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(item: ShelfFile, service: ShelfService, preferences: Preferences) {
        if self.item?.url != item.url {
            let accessed = item.url.startAccessingSecurityScopedResource()
            icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
            if accessed { item.url.stopAccessingSecurityScopedResource() }
        }
        self.item = item
        self.service = service
        self.preferences = preferences
        label.stringValue = item.name
        toolTip = item.name
        setAccessibilityLabel(item.name)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressPoint = convert(event.locationInWindow, from: nil)
        startedDrag = false
        if event.clickCount == 2, let item {
            pressPoint = nil
            service?.open(id: item.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDrag, let pressPoint, let item, let service, let preferences else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= 4 else { return }
        let copyOnly = preferences.enabled("shelfCopy")
        let removeAfterUse = preferences.enabled("shelfRemove")
        guard let source = ShelfFileDragSession(item: item, service: service,
                                               copyOnly: copyOnly, removeAfterUse: removeAfterUse) else { return }
        startedDrag = true
        self.pressPoint = nil
        source.retainUntilFinished()
        let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        let image = icon.image ?? NSWorkspace.shared.icon(forFile: item.url.path)
        draggingItem.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        pressPoint = nil
        startedDrag = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, let item { service?.preview(id: item.id) }
        else { super.keyDown(with: event) }
    }
}

/// AppKit can outlive or remove the source row while dragging. An explicit
/// registry keeps this scope owner alive until the real native end callback.
@MainActor
private final class ShelfFileDragSession: NSObject, NSDraggingSource {
    private static var active: [UUID: ShelfFileDragSession] = [:]
    static var hasActiveSession: Bool { !active.isEmpty }
    private let token = UUID()
    private let item: ShelfFile
    private weak var service: ShelfService?
    private let copyOnly: Bool
    private let removeAfterUse: Bool
    private var accessing: Bool
    private var finished = false

    init?(item: ShelfFile, service: ShelfService, copyOnly: Bool, removeAfterUse: Bool) {
        let accessed = item.url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            if accessed { item.url.stopAccessingSecurityScopedResource() }
            return nil
        }
        self.item = item
        self.service = service
        self.copyOnly = copyOnly
        self.removeAfterUse = removeAfterUse
        self.accessing = accessed
        super.init()
    }

    func retainUntilFinished() { Self.active[token] = self }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        ShelfDragPolicy.allowedOperations(copyOnly: copyOnly)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard !finished else { return }
        finished = true
        if ShelfDragPolicy.shouldRemove(operation: operation, copyOnly: copyOnly, removeAfterUse: removeAfterUse) {
            service?.remove(id: item.id) // Removes only the saved reference, never the file.
        }
        if accessing { item.url.stopAccessingSecurityScopedResource(); accessing = false }
        Self.active.removeValue(forKey: token)
    }

    deinit { if accessing { item.url.stopAccessingSecurityScopedResource() } }
}

/// No file operations, real dragging, or user settings are needed for these cases.
func runShelfDragPolicyTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) { if !condition { failures.append("Shelf drag: " + message) } }
    check(ShelfDragPolicy.allowedOperations(copyOnly: true) == .copy, "copy preference advertises only copy")
    check(ShelfDragPolicy.allowedOperations(copyOnly: false) == [.copy, .move], "non-copy preference permits copy or move")
    check(ShelfDragPolicy.shouldRemove(operation: .copy, copyOnly: true, removeAfterUse: true), "confirmed copy removes reference when enabled")
    check(ShelfDragPolicy.shouldRemove(operation: .move, copyOnly: false, removeAfterUse: true), "confirmed allowed move removes reference")
    check(!ShelfDragPolicy.shouldRemove(operation: .move, copyOnly: true, removeAfterUse: true), "unexpected move does not remove a copy-only source")
    check(!ShelfDragPolicy.shouldRemove(operation: .copy, copyOnly: false, removeAfterUse: false), "disabled removal preserves successful copies")
    for operation: NSDragOperation in [[], .link, .delete, .generic, .private, [.copy, .move]] {
        check(!ShelfDragPolicy.shouldRemove(operation: operation, copyOnly: false, removeAfterUse: true), "cancel or unconfirmed operation \(operation.rawValue) preserves source")
    }
    return failures
}

#if SHELF_DRAG_STANDALONE
@main
struct ShelfDragPolicyRunner {
    static func main() {
        let failures = runShelfDragPolicyTests()
        if failures.isEmpty { print("PASS: shelf drag operation policy") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
