import AppKit
import SwiftUI

/// The short-lived send animation uses Chat's bubble shape and typography too.
/// Once landed, the message is rendered by PicoChatTimelineRow.
struct PicoTaskDetailBubble: View {
    let text: String
    var fullText: String? = nil
    var isFirst = true
    var isLast = true
    var body: some View {
        MessageText(text: text, markdown: false, copyText: fullText)
            .font(.system(size: PicoMessageMetrics.fontSize))
            .foregroundStyle(TelosTheme.primary).multilineTextAlignment(.leading)
            .lineSpacing(PicoMessageMetrics.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, isFirst ? PicoMessageMetrics.verticalPadding : 0)
            .padding(.bottom, isLast ? PicoMessageMetrics.verticalPadding : 0)
            .background {
                PicoBubbleShape(isUser: true, isFirst: isFirst,
                                isLast: isLast, showsTail: isLast)
            }
    }
}

struct PicoTaskDetailFlightOverlay: View {
    let flight: SendFlight
    let finished: () -> Void
    @State private var progress: CGFloat = 0
    var body: some View {
        PicoTaskDetailBubble(text: String(flight.text.prefix(240))).lineLimit(2)
            .modifier(FlightMotion(progress: progress, source: flight.source, destination: flight.destination))
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear {
                withAnimation(.spring(response: 0.48, dampingFraction: 0.82), completionCriteria: .logicallyComplete) {
                    progress = 1
                } completion: { finished() }
            }
    }
}
