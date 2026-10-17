import AppKit

@MainActor func runSeekControlTests() -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) { if !value { failures.append("Seek control: " + message) } }
    let control = SeekControl()
    control.minValue = 0; control.maxValue = 190; control.doubleValue = 129; control.isEnabled = true
    var values: [Double] = []; var edits: [Bool] = []
    control.onValue = { values.append($0) }; control.onEditing = { edits.append($0) }
    control.setAccessibilityValue(NSNumber(value: 30))
    check(control.doubleValue == 30 && values == [30] && edits == [true, false], "AX value change commits its real target exactly once")
    values = []; edits = []; control.doubleValue = 30
    control.onEditing = { started in
        edits.append(started)
        if started { control.doubleValue = 129 }
    }
    control.changed()
    check(values == [30] && control.doubleValue == 30, "editing callback refresh cannot replace requested30 with current129")
    check(edits == [true, false] && !control.tracking, "submission brackets editing and restores tracking")
    control.setAccessibilityValue(NSNumber(value: 250))
    check(values.last == 190, "AX upper bound is clamped")
    control.setAccessibilityValue(NSNumber(value: -10))
    check(values.last == 0, "AX lower bound is clamped")
    let count = values.count
    control.setAccessibilityValue(NSNumber(value: Double.nan)); control.setAccessibilityValue(NSNumber(value: true))
    check(values.count == count, "non-finite and boolean AX input cannot initiate seek")
    control.isEnabled = false
    control.setAccessibilityValue(NSNumber(value: 50)); control.changed()
    check(values.count == count, "disabled seek control cannot dispatch")
    control.isEnabled = true; control.tracking = true; control.doubleValue = 40; edits = []
    control.changed()
    check(values.last == 40 && edits.isEmpty && control.tracking, "drag value changes do not duplicate begin/end callbacks")
    return failures
}
