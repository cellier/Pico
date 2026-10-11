import AppKit
@main struct ScreenshotAnnotationTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let rect = ScreenshotLayout.imageRect(image:CGSize(width:600,height:1200),canvas:CGSize(width:1000,height:720))
        precondition(rect == CGRect(x:320,y:0,width:360,height:720))
        precondition(ScreenshotLayout.normalized(CGPoint(x:500,y:360),in:rect) == CGPoint(x:0.5,y:0.5))
        precondition(ScreenshotLayout.normalized(CGPoint(x:100,y:360),in:rect) == nil)
        var viewport = ScreenshotViewport()
        let imageSize = CGSize(width:800,height:600), canvasSize = CGSize(width:1000,height:720)
        let anchor = CGPoint(x:650,y:450)
        let before = ScreenshotLayout.normalized(anchor,in:viewport.rect(image:imageSize,canvas:canvasSize))!
        viewport.magnify(by:1,around:anchor,image:imageSize,canvas:canvasSize)
        let after = ScreenshotLayout.normalized(anchor,in:viewport.rect(image:imageSize,canvas:canvasSize))!
        precondition(abs(before.x-after.x)<0.0001 && abs(before.y-after.y)<0.0001, "Zoom preserves the point under the fingers")
        viewport.pan(by:CGPoint(x:80,y:-50),image:imageSize,canvas:canvasSize)
        let moved = viewport.rect(image:imageSize,canvas:canvasSize)
        let screenPoint = CGPoint(x:moved.minX+0.4*moved.width,y:moved.minY+0.6*moved.height)
        let recovered = ScreenshotLayout.normalized(screenPoint,in:moved)!
        precondition(abs(recovered.x-0.4)<0.0001 && abs(recovered.y-0.6)<0.0001, "Annotation target remains in original image coordinates")
        viewport.pan(by:CGPoint(x:100000,y:-100000),image:imageSize,canvas:canvasSize)
        precondition(viewport.rect(image:imageSize,canvas:canvasSize).contains(CGRect(origin:.zero,size:canvasSize)), "Panning must not lose an enlarged image")
        viewport.magnify(by:100,around:anchor,image:imageSize,canvas:canvasSize)
        precondition(viewport.zoom == 8)
        viewport.magnify(by:-100,around:anchor,image:imageSize,canvas:canvasSize)
        precondition(viewport.zoom == 0.25)
        let small = viewport.rect(image:imageSize,canvas:canvasSize)
        precondition(small.midX == canvasSize.width/2 && small.midY == canvasSize.height/2, "Small images stay centered")
        viewport.magnify(by:.nan,around:anchor,image:imageSize,canvas:canvasSize)
        precondition(viewport.zoom == 0.25)
        let obstacle = CGRect(x:250,y:200,width:200,height:150)
        let label = ScreenshotLayout.label(size:CGSize(width:150,height:60),target:CGPoint(x:400,y:400),preferred:CGPoint(x:300,y:260),canvas:CGSize(width:800,height:600),obstacles:[obstacle])
        precondition(!label.intersects(obstacle))
        precondition(CGRect(x:0,y:0,width:800,height:600).contains(label))
        let image = NSImage(size:CGSize(width:800,height:600),flipped:true) { r in
            NSColor.white.setFill(); r.fill()
            NSColor.systemBlue.setFill(); CGRect(x:0,y:0,width:800,height:60).fill()
            ("Screenshot review" as NSString).draw(at:CGPoint(x:50,y:100),withAttributes:[.font:NSFont.systemFont(ofSize:30),.foregroundColor:NSColor.black])
            ("Overlapping text" as NSString).draw(at:CGPoint(x:300,y:290),withAttributes:[.font:NSFont.systemFont(ofSize:24),.foregroundColor:NSColor.black])
            ("Overlapping text" as NSString).draw(at:CGPoint(x:330,y:298),withAttributes:[.font:NSFont.systemFont(ofSize:24),.foregroundColor:NSColor.black]); return true
        }
        let raw = ScreenshotRenderer.png(image:image,size:image.size,annotations:[])!
        let rawRep = NSBitmapImageRep(data:raw)!
        precondition(rawRep.pixelsWide == 800 && rawRep.pixelsHigh == 600)
        precondition(rawRep.colorAt(x:10,y:10)!.blueComponent > 0.5, "Keep the image upright")
        let a = ScreenshotAnnotation(text:"这里有明显重叠的文字",target:CGPoint(x:400,y:310),rect:CGRect(x:490,y:200,width:220,height:65),style:"arrow")
        let annotated = ScreenshotRenderer.png(image:image,size:image.size,annotations:[a])!
        let out = URL(fileURLWithPath:CommandLine.arguments[1])
        try raw.write(to:out.appendingPathComponent("annotation-fixture.png"))
        try annotated.write(to:out.appendingPathComponent("annotation-render.png"))
        print("PASS: zoom anchor, pan bounds, zoom limits, zoomed annotation coordinates, coordinate mapping, letterbox rejection, collision avoidance, PNG size and upright rendering")
    }
}
