import SwiftUI
import EventKit

struct CalendarList: View {
    @ObservedObject var calendar: CalendarStore
    var query: String
    var searching: Bool
    @Binding var search: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Next 7 days.").font(serif(32)).lineLimit(1).minimumScaleFactor(0.85).progressiveScrollBlur()
                    .padding(.horizontal, 26).padding(.top, 72).padding(.bottom, 16)
                if searching { SearchField(text: $search).padding(.horizontal, 20).padding(.bottom, 12) }
                if !calendar.authorized {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Connect your Mac calendar").font(.system(size: 18, weight: .medium))
                        Text("Show your upcoming events here and in the menu bar. Telos does not send your calendar data to AI.").font(.system(size: 14)).foregroundStyle(.secondary)
                        if calendar.status == .denied || calendar.status == .restricted {
                            Button("Open Calendar Permissions") { calendar.openSettings() }
                        } else {
                            Button(calendar.requesting ? "Connecting…" : "Connect Calendar") { calendar.requestAccess() }.disabled(calendar.requesting)
                        }
                        Text("macOS calls this Full Access. Telos only reads your events; it does not create or change them.").font(.system(size: 12)).foregroundStyle(.secondary)
                        if let error = calendar.error { Text(error).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 28).padding(.top, 16)
                } else {
                    let sections = calendar.days.map { CalendarDay(date: $0.date, events: $0.events.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) }.filter { !$0.events.isEmpty }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(sections) { day in
                            Text(CalendarSchedule.dayTitle(day.date, now: calendar.now)).font(.system(size: 12, weight: .medium)).foregroundStyle(TelosTheme.secondary).frame(height: 20).padding(.top, 16).accessibilityAddTraits(.isHeader).progressiveScrollBlur()
                            ForEach(day.events) { event in
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    RoundedRectangle(cornerRadius: 4).fill(TelosTheme.primary).frame(width: 2, height: 9).alignmentGuide(.firstTextBaseline) { _ in 9 }
                                    Text("\(CalendarSchedule.time(event)) · \(event.title)").font(.system(size: 14, weight: .medium)).foregroundStyle(TelosTheme.shade(0.1, 0.92)).fixedSize(horizontal: false, vertical: true)
                                }.frame(minHeight: 18).progressiveScrollBlur()
                            }
                        }
                        if sections.isEmpty { Text(query.isEmpty ? "No upcoming events in the next 7 days" : "No results").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 16) }
                    }.padding(.horizontal, 28).padding(.bottom, 32)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.hidden)
            .softScrollEdges(top: 72, bottom: 40, alwaysTop: true)
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["TELOS_PREVIEW_SCROLL"] == "bottom" ? .bottom : .top)
            .onAppear { calendar.refresh() }
    }
}
