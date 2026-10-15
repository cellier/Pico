import AppKit
import SwiftUI
import PaperKit
import PencilKit

// Minimal host for testing the production PaperKit adapter without launching the task store.
@MainActor final class ScreenshotEditor: ObservableObject {
    var image = NSImage(size:NSSize(width:400,height:300))
    var size = CGSize(width:400,height:300)
    var annotations: [ScreenshotAnnotation] = []
    var busy = false
    var message = ""
    func rememberMarkup(_ previous: Any) {}
    func undo() {}
    func redo() {}
}
@main struct PaperKitScreenshotTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard #available(macOS 26.0, *) else { fatalError("PaperKit must be exercised") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1])
        let size = CGSize(width:800,height:600)
        let image = NSImage(size:size,flipped:true) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.blue.setFill(); CGRect(x:0,y:0,width:800,height:60).fill()
            NSColor.green.setFill(); CGRect(x:0,y:540,width:800,height:60).fill()
            ("PaperKit native test" as NSString).draw(at:CGPoint(x:40,y:130),withAttributes:[.font:NSFont.systemFont(ofSize:30),.foregroundColor:NSColor.black])
            return true
        }
        let base = ScreenshotRenderer.png(image:image,size:size,annotations:[])!
        try base.write(to:out.appendingPathComponent("fixture.png"))
        let empty = PaperMarkup(bounds:CGRect(origin:.zero,size:size))
        let unchanged = try await PaperScreenshotSession.render(background:base,size:size,markup:empty)
        precondition(unchanged == base)
        var markup = empty
        markup.insertNewShape(configuration:ShapeConfiguration(type:.rectangle,fillColor:NSColor.red.cgColor),frame:CGRect(x:80,y:100,width:100,height:80))
        markup.insertNewTextbox(attributedText:NSAttributedString(string:"你好 PaperKit",attributes:[.font:NSFont.systemFont(ofSize:32),.foregroundColor:NSColor.black]),frame:CGRect(x:220,y:220,width:350,height:80))
        let points = [CGPoint(x:80,y:380),CGPoint(x:160,y:420),CGPoint(x:250,y:380)].enumerated().map { i,p in
            PKStrokePoint(location:p,timeOffset:Double(i)*0.1,size:CGSize(width:8,height:8),opacity:1,force:1,azimuth:0,altitude:.pi/2)
        }
        markup.append(contentsOf:PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.purple),path:PKStrokePath(controlPoints:points,creationDate:Date()))]))
        let exported = try await PaperScreenshotSession.render(background:base,size:size,markup:markup)
        let rep = NSBitmapImageRep(data:exported)!
        precondition(rep.pixelsWide == 800 && rep.pixelsHigh == 600)
        precondition(rep.colorAt(x:10,y:10)!.blueComponent > 0.9,"Background must remain upright")
        precondition(rep.colorAt(x:10,y:590)!.greenComponent > 0.9)
        precondition(rep.colorAt(x:100,y:120)!.redComponent > 0.9 && rep.colorAt(x:100,y:120)!.greenComponent < 0.1,"Markup coordinates must match screenshot")
        let session = PaperScreenshotSession(size:size)
        session.insertShape(.rectangle)
        let snapshot = session.snapshot()
        precondition(session.elements.count == 1)
        session.clear()
        precondition(session.elements.isEmpty)
        session.restore(snapshot)
        precondition(session.elements.count == 1,"Restore editable PaperKit objects")
        let textElement = ScreenshotPaperElement(frame:CGRect(x:400,y:380,width:300,height:90),content:.text("PaperKit edit OK"),color:.black)
        let textPNG = try await PaperScreenshotSession.render(background:base,size:size,markup:textElement.markup(canvas:empty.bounds))
        let textPixels = NSBitmapImageRep(data:textPNG)!
        var left = 800, top = 600
        for y in 300..<500 { for x in 300..<790 {
            let c = textPixels.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            if max(c.redComponent,c.greenComponent,c.blueComponent) < 0.4 { left=min(left,x);top=min(top,y) }
        } }
        precondition((400...412).contains(left) && (380...396).contains(top),"PaperKit export must retain text's top-left position")
        try textPNG.write(to:out.appendingPathComponent("text-position.png"))
        session.clear();session.insertText()
        let textID=session.selectedID;session.endEditing();session.selectedID=textID
        session.replaceText("Styled text")
        let beforeStyle=session.snapshot()
        session.setTextStyle(family:"Helvetica",size:60,bold:true,italic:true)
        session.setColor(.blue)
        let styled=session.selected!
        precondition(styled.fontSize == 60 && styled.bold && styled.italic && styled.fontFamily == "Helvetica")
        let traits=NSFontManager.shared.traits(of:styled.font())
        precondition(traits.contains(.boldFontMask) && traits.contains(.italicFontMask))
        let styledPNG=try await session.png(background:base,size:size)
        let styledPixels=NSBitmapImageRep(data:styledPNG)!
        var blueTextPixels=0
        for y in 100..<500 { for x in 100..<750 {
            let c=styledPixels.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            if c.blueComponent>0.7 && c.redComponent<0.2 {blueTextPixels += 1}
        } }
        precondition(blueTextPixels>100,"Selected text color must reach PaperKit export")
        session.loadViewIfNeeded();session.view.frame=CGRect(x:0,y:0,width:1000,height:600)
        let framesBeforeZoom=session.elements.map(\.frame)
        let anchor=CGPoint(x:650,y:350)
        let anchored=session.canvasPoint(anchor)
        session.zoom(by:1,around:anchor)
        precondition(session.zoom == 2)
        precondition(hypot(session.displayPoint(anchored).x-anchor.x,session.displayPoint(anchored).y-anchor.y)<0.001,"Zoom must retain the point beneath the cursor")
        session.pan(by:CGPoint(x:-70,y:40))
        let modelPoint=CGPoint(x:400,y:300)
        let roundTrip=session.canvasPoint(session.displayPoint(modelPoint))
        precondition(hypot(roundTrip.x-modelPoint.x,roundTrip.y-modelPoint.y)<0.001,"Selection and drag coordinates must invert the zoom/pan transform")
        precondition(session.elements.map(\.frame) == framesBeforeZoom,"Viewport navigation must not modify annotations")
        let zoomedPNG=try await session.png(background:base,size:size)
        precondition(zoomedPNG == styledPNG,"Zoom/pan must not change exported pixels or resolution")
        session.fitCanvas();precondition(session.zoom == 1)
        print("PASS: zoom anchor, pan coordinate mapping, fit reset, unchanged PaperKit model and pixel-identical export")
        // Dragging uses cached per-object PaperKit images, not full screenshot rendering.
        await session.waitForPreview()
        let renders=session.previewRenderCount
        let beforeDrag=session.selected!.frame
        session.beginTransform()
        for step in 1...120 {session.replaceFrame(beforeDrag.offsetBy(dx:CGFloat(step)/3,dy:0))}
        session.finishTransform();await session.waitForPreview()
        precondition(session.previewRenderCount == renders,"Dragging must reuse the PaperKit image for every event, including mouse-up")
        let original=CGRect(x:100,y:100,width:200,height:100)
        let corner=ScreenshotResizeHandle.topLeft.resized(original,delta:CGPoint(x:-40,y:-20),proportional:true)
        precondition(corner.maxX == original.maxX && corner.maxY == original.maxY && corner.width/corner.height == 2,"Proportional corner resize anchors the opposite corner")
        let edge=ScreenshotResizeHandle.left.resized(original,delta:CGPoint(x:50,y:80),proportional:false)
        precondition(edge.maxX == original.maxX && edge.width == 150 && edge.height == original.height,"Text width handle changes width independently")
        let preview=try await PaperScreenshotSession.renderPreview(textElement)
        precondition(preview.size.width == textElement.frame.width+16)
        let previewPixels=NSBitmapImageRep(data:preview.tiffRepresentation!)!
        precondition(previewPixels.colorAt(x:0,y:0)!.alphaComponent == 0,"Object preview must be transparent outside the annotation")
        var inkLeft=previewPixels.pixelsWide,inkTop=previewPixels.pixelsHigh,inkCount=0
        for y in 0..<previewPixels.pixelsHigh {for x in 0..<previewPixels.pixelsWide {
            if previewPixels.colorAt(x:x,y:y)!.alphaComponent > 0.5 {inkLeft=min(inkLeft,x);inkTop=min(inkTop,y);inkCount += 1}
        }}
        precondition(inkCount>100 && (16...40).contains(inkLeft) && (16...48).contains(inkTop),"PaperKit object preview must contain upright text at its original local origin")
        print("PASS: 120 drag updates without rasterization; resize anchor/aspect/width; transparent PaperKit object preview")
        session.restore(beforeStyle)
        precondition(session.elements[0].fontSize == session.defaultFontSize && !session.elements[0].bold,"Style changes must restore with undo snapshot")
        print("PASS: text family, font size, bold/italic traits, color export and style snapshot restore")
        var aligned=ScreenshotPaperElement(frame:CGRect(x:100,y:200,width:400,height:120),content:.text("Align\nsecond"),color:.black)
        func leftInk(_ data:Data)->Int {
            let pixels=NSBitmapImageRep(data:data)!
            var left=800
            for y in 195..<320 {for x in 90..<520 {
                let c=pixels.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                if max(c.redComponent,c.greenComponent,c.blueComponent)<0.2 {left=min(left,x)}
            }}
            return left
        }
        let leftPNG=try await PaperScreenshotSession.render(background:base,size:size,markup:aligned.markup(canvas:empty.bounds))
        aligned.alignment = .right
        let rightPNG=try await PaperScreenshotSession.render(background:base,size:size,markup:aligned.markup(canvas:empty.bounds))
        precondition(leftInk(rightPNG)>leftInk(leftPNG)+200,"Alignment must change exported text position")
        aligned.underline=true;aligned.lineSpacing=8
        let decorated=try await PaperScreenshotSession.render(background:base,size:size,markup:aligned.markup(canvas:empty.bounds))
        precondition(decorated != rightPNG,"Underline and line spacing must affect PaperKit output")
        session.setListStyle(false)
        guard case .text(let list)=session.selected!.content else {fatalError()}
        precondition(list.hasPrefix("• "))
        session.setListStyle(nil)
        guard case .text(let plain)=session.selected!.content else {fatalError()}
        precondition(!plain.hasPrefix("• "))
        print("PASS: alignment coordinates, underline/spacing output, reversible list formatting")
        session.clear();session.insertText(at:CGPoint(x:100,y:300))
        let tag=session.selected!
        precondition(tag.fill == PaperScreenshotSession.tagColor && tag.color == .white && tag.frame.origin == CGPoint(x:100,y:300),"Text defaults to a white-on-red tag at the click point")
        session.endEditing()
        let tagPNG=try await session.png(background:base,size:size)
        try tagPNG.write(to:out.appendingPathComponent("tag-text.png"))
        let tagPixels=NSBitmapImageRep(data:tagPNG)!
        let tagFill=tagPixels.colorAt(x:Int(tag.frame.minX)+2,y:Int(tag.frame.midY))!.usingColorSpace(.deviceRGB)!
        precondition(tagFill.redComponent>0.8 && tagFill.greenComponent<0.4,"Tag background must reach PaperKit export")
        session.clear();session.insertShape(.line,from:CGPoint(x:600,y:100),to:CGPoint(x:200,y:400))
        let arrow=session.selected!
        precondition(arrow.frame == CGRect(x:200,y:100,width:400,height:300) && arrow.lineStart == CGPoint(x:600,y:100) && arrow.lineEnd == CGPoint(x:200,y:400),"Arrow keeps the dragged direction")
        session.insertShape(.ellipse,from:CGPoint(x:300,y:300),to:CGPoint(x:100,y:200))
        precondition(session.selected!.frame == CGRect(x:100,y:200,width:200,height:100),"Shapes fill the dragged rectangle")
        try await session.png(background:base,size:size).write(to:out.appendingPathComponent("drag-shapes.png"))
        print("PASS: tag text default, drag-created arrow direction and shape frame")
        try exported.write(to:out.appendingPathComponent("paperkit-render.png"))
        let bytes = try await markup.dataRepresentation()
        let decoded = try PaperMarkup(dataRepresentation:bytes)
        precondition(decoded == markup)
        print("PASS: real PaperKit drawing/text/shapes render; original pixel dimensions; upright background; annotation alignment; empty export; editable snapshot restore; serialization")
    }
}
