import SwiftUI

struct CalendarList: View {
    @ObservedObject var calendar: CalendarStore
    var query: String
    var searching: Bool
    @Binding var search: String
    var topInset: CGFloat = 72
    var edgeTreatment: ScrollEdgeTreatment = .material
    var headerInset: CGFloat = 0
    var contentHorizontalInset: CGFloat = 26
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Next 7 days.").font(serif(32)).lineLimit(1).minimumScaleFactor(0.85).progressiveScrollBlur()
                    .padding(.horizontal, contentHorizontalInset).padding(.top, topInset + headerInset).padding(.bottom, 16)
                if searching { SearchField(text: $search).padding(.horizontal, max(0, contentHorizontalInset - 6)).padding(.bottom, 12) }
                if !calendar.authorized {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(calendar.requesting ? "Syncing Zoom events…" : "Connect your Zoom calendar").font(.system(size: 18, weight: .medium))
                        Text("Your upcoming events sync from the calendar connected to Zoom. This view does not change them. To create or change an event, ask Pico in Chat.").font(.system(size: 14)).foregroundStyle(.secondary)
                        if calendar.status == "disconnected" || calendar.needsSignIn {
                            Button(calendar.needsSignIn ? "Sign in to Zoom…" : "Connect Zoom") { calendar.requestAccess() }.disabled(calendar.requesting)
                        } else {
                            Button("Try again") { calendar.refresh(force: true) }.disabled(calendar.requesting)
                        }
                        if let error = calendar.error { Text(error).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }.padding(.horizontal, contentHorizontalInset + 2).padding(.top, 16)
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
                        if let error = calendar.error, query.isEmpty {
                            Text(error).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 16)
                            if let saved = calendar.lastSuccessfulSync {
                                Text("Showing saved events from " + saved.formatted(date: .abbreviated, time: .shortened) + ".")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Button(calendar.needsSignIn ? "Sign in to Zoom…" : "Retry sync") {
                                if calendar.needsSignIn { calendar.requestAccess() } else { calendar.refresh(force: true) }
                            }.disabled(calendar.requesting)
                        } else if sections.isEmpty { Text(query.isEmpty ? "No upcoming events in the next 7 days" : "No results").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 16) }
                    }.padding(.horizontal, contentHorizontalInset + 2).padding(.bottom, 32)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.hidden)
            .softScrollEdges(top: headerInset > 0 ? headerInset + 12 : (topInset == 72 ? 72 : 20), bottom: edgeTreatment == .contentFade ? 28 : 40, alwaysTop: headerInset > 0 || topInset == 72, treatment: headerInset > 0 ? .underHeader : edgeTreatment)
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["TELOS_PREVIEW_SCROLL"] == "bottom" ? .bottom : .top)
            .onAppear { calendar.refresh() }
    }
}
