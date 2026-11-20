// Disposable GUI target for verifying `gvglact`'s pointer verbs end to end.
//
// Why a harness instead of a real app: scrolling someone's browser or dragging
// their window changes their work. This window owns its content, exposes a
// legacy scroll bar (so AXScrollBar carries a readable 0…1 value), a slider
// next to a button on the same row (so a drag has an observable value change),
// plus an editable field and a checkbox for background-isolation tests.
//
// `--no-activate` keeps the current frontmost app in front, so `gvglact` can
// be measured against a genuinely background window.
//
//   swiftc -O -o /tmp/gvgl-action-harness scripts/action_harness.swift
//   /tmp/gvgl-action-harness --no-activate &
//
//   # scroll — verified 0 → 0.089 (10 lines), --to top → 0.000, --to bottom → 1.000
//   .build/release/gvglact find --app pid:NNN --role AXScrollBar
//   .build/release/gvglact scroll --id <scrollbar> --down 10
//   .build/release/gvglact scroll --id <scrollbar> --to top
//   .build/release/gvglact text --id <scrollbar>
//
//   # drag — slider center to button center, same row; verified 0 → 1
//   .build/release/gvglact find --app pid:NNN --role AXSlider
//   .build/release/gvglact find --app pid:NNN --role AXButton
//   .build/release/gvglact drag --from <slider> --to <button>
//   .build/release/gvglact text --id <slider>

import AppKit

final class HarnessDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    @objc func toggle(_ sender: NSButton) {
        sender.state = sender.state == .on ? .off : .on
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 240, y: 240, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "GVGL ACTION HARNESS"

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 100, width: 720, height: 460))
        scroll.hasVerticalScroller = true
        // Legacy scrollers stay in the AX tree with a real value; overlay
        // scrollers usually do not, which is exactly the limitation documented
        // in DESIGN.md V6-8.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 20000))
        text.isEditable = false
        text.string = (1...200).map { "line \($0) — GVGL action harness" }.joined(separator: "\n")
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        scroll.documentView = text
        content.addSubview(scroll)

        let slider = NSSlider(value: 0, minValue: 0, maxValue: 1,
                              target: nil, action: nil)
        slider.frame = NSRect(x: 20, y: 44, width: 300, height: 24)
        content.addSubview(slider)

        let button = NSButton(title: "TARGET", target: nil, action: nil)
        button.frame = NSRect(x: 420, y: 40, width: 120, height: 32)
        button.bezelStyle = .rounded
        content.addSubview(button)

        // Background-isolation fixtures: an AXValue-settable field and a
        // checkbox whose AXPress flips state. Both change the AX tree without
        // requiring pointer or keyboard events.
        let field = NSTextField(frame: NSRect(x: 20, y: 4, width: 300, height: 24))
        field.stringValue = "background type"
        field.isEditable = true
        content.addSubview(field)

        let checkbox = NSButton(checkboxWithTitle: "BACKGROUND TEST",
                                target: self, action: #selector(toggle(_:)))
        checkbox.frame = NSRect(x: 340, y: 4, width: 220, height: 24)
        checkbox.state = .off
        content.addSubview(checkbox)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        self.window = window
        if !CommandLine.arguments.contains("--no-activate") {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

let app = NSApplication.shared
let delegate = HarnessDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
