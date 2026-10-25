// Compile with Sources/PicoChatScrollController.swift only. This private native
// SwiftUI fixture verifies real LazyVStack ID lookup and row reestimation.
// It neither loads user data nor installs global hooks or posts pointer events.
import AppKit
import SwiftUI

@MainActor final class LazyAnchorFixtureModel: ObservableObject {
    @Published var first = 0
    @Published var end = 240
    let controller = PicoChatScrollController()
}
struct LazyAnchorFixture: View {
    @ObservedObject var model: LazyAnchorFixtureModel
    let paragraph = String(repeating: "中文 mixed English long paragraph for lazy layout.\n", count: 43)
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach((model.first..<model.end).map { "row\($0)" }, id: \.self) { index in
                        Text("BLOCK \(index)\n" + paragraph)
                            .font(.system(size: 13.5)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .id(index)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("timeline")) } action: {
                                model.controller.record(id: index, frame: $0)
                            }
                            .onDisappear { model.controller.remove(id: index) }
                    }
                    Color.clear.frame(height: 90).id("picoLatest")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("timeline")) } action: {
                            model.controller.record(id: "picoLatest", frame: $0)
                        }.onDisappear { model.controller.remove(id: "picoLatest") }
                }.scrollTargetLayout().padding(.top, 70)
                    .coordinateSpace(name: "timeline")
                    .background(PicoChatScrollProbe(controller: model.controller))
            }.defaultScrollAnchor(.bottom)
                .onAppear { model.controller.configure { id, anchor in proxy.scrollTo(id, anchor: anchor) } }
        }
    }
}
@main struct PicoChatLazyAnchorTests {
    @MainActor static func main() {
        setvbuf(stdout,nil,_IONBF,0)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let model = LazyAnchorFixtureModel()
        let host = NSHostingView(rootView: LazyAnchorFixture(model: model)); host.sizingOptions=[]; host.safeAreaRegions=[]
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:374,height:528),styleMask:[.borderless,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=host; window.center(); window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle(_ seconds:Double=0.8) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
        func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
        func scroll()->NSScrollView { descendants(host).compactMap {$0 as? NSScrollView}.first! }
        func snapshot(_ label:String) {
            let c=model.controller, s=scroll(), d=s.documentView!
            let rows=Mirror(reflecting:c).children.first {$0.label == "rows"}!.value as! [String:CGRect]
            let anchor=c.prepareForChange()
            print("NATIVE \(c.diagnosticSnapshot)")
            print("SNAP \(label) anchor=\(String(describing:anchor)) row=\(String(describing:anchor.flatMap{rows[$0.id]})) clip=\(s.contentView.bounds) doc=\(d.bounds) realized=\(rows.count)")
        }
        settle(1.0); snapshot("initial")
        let s=scroll(), d=s.documentView!
        NotificationCenter.default.post(name:NSScrollView.willStartLiveScrollNotification,object:s)
        s.contentView.scroll(to:NSPoint(x:0,y:(d.bounds.height-s.contentView.bounds.height)*0.55));s.reflectScrolledClipView(s.contentView)
        NotificationCenter.default.post(name:NSScrollView.didLiveScrollNotification,object:s)
        NotificationCenter.default.post(name:NSScrollView.didEndLiveScrollNotification,object:s)
        settle(); snapshot("middle")
        for size in [CGSize(width:560,height:720),CGSize(width:340,height:420),CGSize(width:374,height:528)] {
            let before=model.controller.prepareForChange(); let start=Date(); snapshot("before \(size)")
            window.setContentSize(size); print("setContentSize returned \(Date().timeIntervalSince(start))")
            settle(0.05)
            let deadline = Date().addingTimeInterval(6)
            func positioned() -> Bool {
                guard let before else { return false }
                let rows=Mirror(reflecting:model.controller).children.first {$0.label == "rows"}!.value as! [String:CGRect]
                guard let row=rows[before.id] else { return false }
                let y=scroll().contentView.bounds.minY
                return abs(y-row.minY-min(before.offset,max(0,row.height-1))) < 1
            }
            while !positioned(), Date()<deadline { settle(0.05) }
            settle(0.12); snapshot("after \(size),elapsed \(Date().timeIntervalSince(start))")
            precondition(positioned(), "Actual native offset did not settle")
            let after=model.controller.prepareForChange()
            precondition(before?.id==after?.id,"CHANGED ANCHOR \(String(describing:before)) -> \(String(describing:after))")
        }
        print("PASS real lazy resize")
    }
}
