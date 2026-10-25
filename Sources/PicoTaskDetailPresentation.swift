import SwiftUI
import AppKit

/// Figma 349:5711. The sheet belongs to the window, above its floating header.
enum PicoTaskDetailMetrics {
    static let topInset: CGFloat = 56
    static let topCornerRadius: CGFloat = 40
    static let handleHeight: CGFloat = 25
    static let horizontalContentInset: CGFloat = 24
    static let contentTopInset: CGFloat = 32
    static let backdropBlur: CGFloat = 6
    static let backdropOpacity: Double = 0.08
    static let surface = TelosTheme.shade(0.985, 4.0 / 255)
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.88)
    }
}

struct PicoTaskDetailPresentation: View {
    @ObservedObject var store: TaskStore
    var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0
    @State private var retainedTask: Todo?
    @State private var raised = false
    @State private var generation = UUID()
    private let shape = UnevenRoundedRectangle(topLeadingRadius: PicoTaskDetailMetrics.topCornerRadius,
                                               topTrailingRadius: PicoTaskDetailMetrics.topCornerRadius,
                                               style: .continuous)
    private var animation: Animation? { PicoTaskDetailMetrics.animation(reduceMotion: reduceMotion) }
    private var targetID: UUID? { isPresented ? store.selectedTask?.id : nil }
    private var visibleTask: Todo? {
        guard let retainedTask else { return nil }
        // Keep live updates while open, but freeze the last content for its exit.
        return !raised && targetID == nil ? retainedTask : store.tasks.first { $0.id == retainedTask.id } ?? retainedTask
    }

    var body: some View {
        GeometryReader { geometry in
          ZStack(alignment: .bottom) {
           if let todo = visibleTask {
            // A real button spans the full shell, including the header and its
            // margins. The card above owns only its visible rounded hit region.
            Button(action: dismiss) {
                Rectangle().fill(TelosTheme.bubbleTint.opacity(PicoTaskDetailMetrics.backdropOpacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Close task details")
                .accessibilityIdentifier("taskDetailBackdrop")
                .opacity(raised ? 1 : 0)

            detail(todo)
                .frame(width: geometry.size.width, height: max(0, geometry.size.height - PicoTaskDetailMetrics.topInset))
                .background(PicoTaskDetailMetrics.surface, in: shape)
                .overlay(alignment: .top) { handle }
                // The handle's full-width gradient belongs inside this clip.
                // Clipping before its overlay paints square corners over the arc.
                .clipShape(shape)
                .contentShape(shape)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                // Freeze the complete, final-size card before translating it.
                // Applying this only to detail(todo) leaves its frame, clip and
                // native scroll viewport inside the parent's opening spring.
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("taskDetailSheet")
                .allowsHitTesting(isPresented)
                .modifier(PicoTaskDetailSlide(displacement: raised ? drag : max(0, geometry.size.height - PicoTaskDetailMetrics.topInset) + 1))
                .transition(.identity)
           }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: "picoTaskDetailPresentation")
        .allowsHitTesting(retainedTask != nil)
        .accessibilityHidden(retainedTask == nil)
        .onAppear(perform: synchronize)
        .onChange(of: targetID) { _, _ in synchronize() }
        .onExitCommand(perform: dismiss)
    }

    @ViewBuilder private func detail(_ todo: Todo) -> some View {
        if let meetingID = todo.meetingID, let session = store.meetings[meetingID] {
            MeetingDetailView(store: store, session: session)
                .padding(.top, PicoTaskDetailMetrics.handleHeight)
                .id(meetingID)
        } else {
            TaskDetail(store: store, todo: todo).id(todo.id)
        }
    }

    private var handle: some View {
        Capsule().fill(TelosTheme.primary.opacity(0.4)).frame(width: 30, height: 5)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background {
                LinearGradient(colors: [PicoTaskDetailMetrics.surface, PicoTaskDetailMetrics.surface.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .overlay {
                PicoTaskDetailGrabArea(changed: { drag = $0 }, ended: { distance, predicted in
                    if distance > 90 || predicted > 180 { dismiss() }
                    else { withAnimation(animation) { drag = 0 } }
                }).frame(width: 90, height: PicoTaskDetailMetrics.handleHeight)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Dismiss task details")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { dismiss() }
    }

    private func dismiss() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        store.selected = nil
    }

    private func synchronize() {
        let ticket = UUID()
        generation = ticket
        if let id = targetID, let task = store.tasks.first(where: { $0.id == id }) {
            if retainedTask != nil {
                retainedTask = task
                withAnimation(animation) { raised = true; drag = 0 }
            } else {
                // Install at the bottom with its final width and height first.
                // Only its position moves; text and native editors never scale.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { retainedTask = task; raised = false; drag = 0 }
                if reduceMotion { raised = true; return }
                DispatchQueue.main.async {
                    guard generation == ticket, targetID == id else { return }
                    withAnimation(animation) { raised = true }
                }
            }
        } else if let retainedTask {
            self.retainedTask = store.tasks.first { $0.id == retainedTask.id } ?? retainedTask
            NSApp.keyWindow?.makeFirstResponder(nil)
            if reduceMotion {
                raised = false; drag = 0; self.retainedTask = nil
                return
            }
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                raised = false
            } completion: {
                guard generation == ticket, targetID == nil else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.retainedTask = nil; drag = 0 }
            }
        }
    }
}

/// Interpolate the card's position outside its frozen layout transaction.
/// A plain offset relies on descendant native-view animations, which the fixed
/// text/scroll layout intentionally disables. Driving the displacement itself
/// keeps the native editor, transcript, surface and handle moving together.
private struct PicoTaskDetailSlide: AnimatableModifier {
    var displacement: CGFloat
    var animatableData: CGFloat {
        get { displacement }
        set { displacement = newValue }
    }
    func body(content: Content) -> some View {
        content.offset(y: displacement)
    }
}
