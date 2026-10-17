import AppKit
import SwiftUI

/// Native slider input and accessibility, with a quiet track for the island.
struct ThinSeekSlider: NSViewRepresentable {
    @Binding var value: Double
    var maximum: Double
    var tint: NSColor
    var enabled: Bool
    var editing: (Bool) -> Void

    func makeNSView(context: Context) -> SeekControl {
        let control = SeekControl()
        control.cell = SeekTrackCell()
        control.minValue = 0
        control.isContinuous = true
        control.target = control
        control.action = #selector(SeekControl.changed)
        control.setAccessibilityLabel(tr("播放进度"))
        return control
    }
    func updateNSView(_ view: SeekControl, context: Context) {
        view.maxValue = maximum
        view.isEnabled = enabled
        if !view.tracking { view.doubleValue = max(0, min(maximum, value)) }
        (view.cell as? SeekTrackCell)?.tint = tint
        view.onValue = { value = $0 }
        view.onEditing = editing
        view.needsDisplay = true
    }
}

final class SeekControl: NSSlider {
    var tracking = false
    var onValue: (Double) -> Void = { _ in }
    var onEditing: (Bool) -> Void = { _ in }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        tracking = true
        onEditing(true)
        super.mouseDown(with: event)
        onValue(doubleValue)
        tracking = false
        onEditing(false)
    }
    @objc func changed() {
        // Capture before SwiftUI's editing callback can refresh the native value.
        submit(doubleValue)
    }
    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return }
        submit(number.doubleValue)
    }
    private func submit(_ proposed: Double) {
        guard isEnabled, proposed.isFinite else { return }
        let targetValue = min(maxValue, max(minValue, proposed))
        let wasTracking = tracking
        if !wasTracking { tracking = true; onEditing(true) }
        doubleValue = targetValue
        onValue(targetValue)
        if !wasTracking { tracking = false; onEditing(false) }
    }
}

final class SeekTrackCell: NSSliderCell {
    var tint = NSColor.white
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        let fraction = maxValue > minValue ? max(0, min(1, (doubleValue - minValue) / (maxValue - minValue))) : 0
        tint.withAlphaComponent(isEnabled ? 0.9 : 0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        guard isHighlighted else { return }
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 4, y: knobRect.midY - 4, width: 8, height: 8)).fill()
    }
}
