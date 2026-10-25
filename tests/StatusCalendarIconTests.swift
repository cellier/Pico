import AppKit

@main struct StatusCalendarIconTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let utc = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date { formatter.date(from: value)! }
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = utc
        var nativeSymbolCount = 0
        for day in 1...31 {
            let value = gregorian.date(from: DateComponents(year: 2026, month: 1, day: day, hour: 12))!
            let name = StatusCalendarIcon.symbolName(for: value, timeZone: utc)
            precondition(name == "\(day).calendar")
            let image = StatusCalendarIcon.image(for: value, timeZone: utc)
            precondition(image.isTemplate && image.size.width > 0 && image.size.height > 0)
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { nativeSymbolCount += 1 }
            let bounds = NSRect(x: -9, y: -9, width: 18, height: 18)
            let fitted = StatusCalendarIcon.fittedRect(for: image, in: bounds)
            precondition(fitted.width <= bounds.width && fitted.height <= bounds.height)
            precondition(abs(fitted.midX - bounds.midX) < 0.0001 && abs(fitted.midY - bounds.midY) < 0.0001)
            precondition(abs(fitted.width / fitted.height - image.size.width / image.size.height) < 0.0001, "Native glyphs must retain their non-square aspect ratio")
        }
        for (stamp, expected) in [
            ("2026-01-31T23:59:59Z", "31.calendar"), ("2026-02-01T00:00:00Z", "1.calendar"),
            ("2026-02-28T23:59:59Z", "28.calendar"), ("2026-03-01T00:00:00Z", "1.calendar"),
            ("2026-12-31T23:59:59Z", "31.calendar"), ("2027-01-01T00:00:00Z", "1.calendar"),
            ("2028-02-28T23:59:59Z", "28.calendar"), ("2028-02-29T00:00:00Z", "29.calendar"),
            ("2028-03-01T00:00:00Z", "1.calendar")
        ] { precondition(StatusCalendarIcon.symbolName(for: date(stamp), timeZone: utc) == expected) }
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
        let sameInstant = date("2026-10-21T20:30:00Z")
        precondition(StatusCalendarIcon.symbolName(for: sameInstant, timeZone: utc) == "21.calendar")
        precondition(StatusCalendarIcon.symbolName(for: sameInstant, timeZone: shanghai) == "22.calendar")
        precondition(StatusCalendarIcon.symbolName(for: date("2026-01-01T02:00:00Z"), timeZone: honolulu) == "31.calendar")
        let offsetBounds = NSRect(x: 5, y: 9, width: 16, height: 16)
        precondition(StatusCalendarIcon.fittedRect(for: NSImage(size: NSSize(width: 40, height: 20)), in: offsetBounds) == NSRect(x: 5, y: 13, width: 16, height: 8))
        precondition(StatusCalendarIcon.fittedRect(for: NSImage(size: NSSize(width: 10, height: 20)), in: offsetBounds) == NSRect(x: 9, y: 9, width: 8, height: 16))

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let indicator = StatusActivityIndicator(button: button)
        indicator.update(count: 0, reduceMotion: true)
        precondition(indicator.iconFrame.width == 18 && indicator.iconFrame.height == 18)
        let event = CalendarMenuText(time: "All-day", title: "Unchanged multi-day event")
        let width = indicator.setEvent(event)
        button.setFrameSize(NSSize(width: width, height: 24)); indicator.layout()
        let beforeMidnight = date("2026-10-21T23:59:59Z"), afterMidnight = date("2026-10-22T00:00:00Z")
        indicator.updateDate(beforeMidnight, timeZone: utc)
        let before = indicator.renderedImageCount, oldImage = button.image!.tiffRepresentation!
        indicator.updateDate(afterMidnight, timeZone: utc)
        precondition(indicator.currentSymbolName == "22.calendar" && indicator.renderedImageCount == before + 1, "An idle, unchanged all-day event must redraw exactly once at midnight")
        precondition(button.image!.tiffRepresentation! != oldImage, "The rendered bitmap must actually change its day number")
        let updated = indicator.renderedImageCount
        for offset in 0..<100 { indicator.updateDate(afterMidnight.addingTimeInterval(Double(offset)), timeZone: utc) }
        precondition(indicator.renderedImageCount == updated, "Repeated same-day refreshes must reuse the native rendered image")
        indicator.updateDate(sameInstant, timeZone: utc)
        let zoneBefore = indicator.renderedImageCount
        indicator.updateDate(sameInstant, timeZone: shanghai)
        precondition(indicator.currentSymbolName == "22.calendar" && indicator.renderedImageCount == zoneBefore + 1, "A time-zone change must update the local date without needing a different event")
        let iconOnlyWidth = indicator.setEvent(nil)
        button.setFrameSize(NSSize(width: iconOnlyWidth, height: 24)); indicator.layout()
        indicator.updateDate(beforeMidnight, timeZone: utc)
        let noEventBefore = indicator.renderedImageCount
        indicator.updateDate(afterMidnight, timeZone: utc)
        precondition(indicator.currentSymbolName == "22.calendar" && indicator.renderedImageCount == noEventBefore + 1 && button.image != nil, "Date refresh must also work without Calendar events or authorization")

        // Active meetings/tasks keep their date legible and still roll over on time.
        for reduceMotion in [false, true] {
            _ = indicator.setEvent(event)
            indicator.update(count: 3, reduceMotion: reduceMotion)
            indicator.updateDate(date("2026-02-28T23:59:59Z"), timeZone: utc)
            let activeBefore = indicator.renderedImageCount
            indicator.updateDate(date("2026-03-01T00:00:00Z"), timeZone: utc)
            precondition(indicator.currentSymbolName == "1.calendar" && indicator.renderedImageCount == activeBefore + 1)
            precondition(indicator.iconView.rotationLayer.animation(forKey: StatusActivityIndicator.animationKey) == nil)
            precondition(CATransform3DIsIdentity(indicator.iconView.rotationLayer.transform))
            let settled = indicator.renderedImageCount
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            precondition(indicator.renderedImageCount == settled, "A running task must not keep rebuilding the numbered calendar")
        }

        if let path = CommandLine.arguments.dropFirst().first {
            let label = CalendarMenuText(time: "9:00 AM", title: "Design review")
            let width = indicator.setEvent(label)
            button.setFrameSize(NSSize(width: width, height: 24)); indicator.layout()
            let samples = [1, 21, 22, 31].map { day -> (String, NSImage) in
                indicator.updateDate(gregorian.date(from: DateComponents(year: 2026, month: 1, day: day, hour: 12))!, timeZone: utc)
                let source = button.image!.copy() as! NSImage
                let tinted = NSImage(size: source.size, flipped: false) { rect in
                    source.draw(in: rect)
                    NSColor.white.setFill(); rect.fill(using: .sourceIn)
                    return true
                }
                return ("\(day).calendar", tinted)
            }
            let sheet = NSImage(size: NSSize(width: 330, height: 184), flipped: false) { rect in
                NSColor(white: 0.12, alpha: 1).setFill(); rect.fill()
                for (index, sample) in samples.enumerated() {
                    let y = 146 - CGFloat(index) * 42
                    (sample.0 as NSString).draw(at: NSPoint(x: 12, y: y + 5), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
                    let target = NSRect(x: 110, y: y, width: sample.1.size.width, height: sample.1.size.height)
                    sample.1.draw(in: target)
                }
                return true
            }
            let bitmap = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        print("PASS numbered status calendars: 18-point size, 31 date mappings/images (\(nativeSymbolCount) native symbols), midnight cache invalidation, same-day reuse, month/year/leap boundaries, time zones, aspect fit, no-event refresh, static active rollover")
    }
}
