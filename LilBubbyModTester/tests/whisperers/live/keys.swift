// Holds mac virtual key codes down for N seconds: keys <seconds> <code>...
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let secs = Double(a[1])!
let codes = a.dropFirst(2).map { CGKeyCode(UInt16($0)!) }
let src = CGEventSource(stateID: .hidSystemState)
for c in codes { CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: true)?.post(tap: .cghidEventTap); usleep(50000) }
usleep(useconds_t(secs * 1_000_000))
for c in codes.reversed() { CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: false)?.post(tap: .cghidEventTap); usleep(50000) }
