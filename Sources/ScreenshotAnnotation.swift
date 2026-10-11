import AppKit
import Vision

struct ScreenshotAnnotationDesign: Codable {
    var surface = "#172235"
    var ink = "#FFFFFF"
    var accent = "#526BEB"
    var connector = "curved"
    var typeScale: CGFloat = 1
    var weight = "medium"
    var width: CGFloat = 0.36
    var radius: CGFloat = 14
    var padding: CGFloat = 18
    var eyebrow = ""
    static func color(_ hex: String) -> NSColor {
        let rgb = UInt32(hex.dropFirst(),radix:16) ?? 0x172235
        return NSColor(calibratedRed:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
    }
}
struct ScreenshotAnnotation {
    let text: String
    let target: CGPoint
    let rect: CGRect
    let style: String
    var design = ScreenshotAnnotationDesign()
}
enum ScreenshotLayout {
    static func imageRect(image: CGSize, canvas: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(canvas.width/image.width,canvas.height/image.height)
        let size = CGSize(width:image.width*scale,height:image.height*scale)
        return CGRect(x:(canvas.width-size.width)/2,y:(canvas.height-size.height)/2,width:size.width,height:size.height)
    }
    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height)
    }
    static func label(size: CGSize, target: CGPoint, preferred: CGPoint, canvas: CGSize, obstacles: [CGRect]) -> CGRect {
        let margin: CGFloat = 8
        func box(_ center: CGPoint) -> CGRect {
            CGRect(x:min(max(margin,center.x-size.width/2),max(margin,canvas.width-size.width-margin)),y:min(max(margin,center.y-size.height/2),max(margin,canvas.height-size.height-margin)),width:size.width,height:size.height)
        }
        let targetArea = CGRect(x:target.x-20,y:target.y-20,width:40,height:40)
        var candidates = [box(preferred)]
        for x in stride(from:margin+size.width/2,through:max(margin+size.width/2,canvas.width-size.width/2-margin),by:max(12,canvas.width/18)) {
            for y in stride(from:margin+size.height/2,through:max(margin+size.height/2,canvas.height-size.height/2-margin),by:max(12,canvas.height/18)) { candidates.append(box(CGPoint(x:x,y:y))) }
        }
        func score(_ r: CGRect) -> CGFloat {
            let overlap = (obstacles+[targetArea]).reduce(CGFloat(0)) { value, obstacle in
                let i = r.insetBy(dx:-5,dy:-5).intersection(obstacle)
                return value + (i.isNull ? 0 : i.width*i.height)
            }
            return overlap*100+hypot(r.midX-preferred.x,r.midY-preferred.y)*0.2+hypot(r.midX-target.x,r.midY-target.y)*0.1
        }
        return candidates.min { score($0)<score($1) } ?? box(preferred)
    }
}
/// Display-only transform shared by drawing and pointer-to-image hit testing.
struct ScreenshotViewport {
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGPoint = .zero
    func rect(image: CGSize, canvas: CGSize) -> CGRect {
        let fitted = ScreenshotLayout.imageRect(image:image,canvas:canvas)
        let width = fitted.width*zoom, height = fitted.height*zoom
        let limitX = max(0,(width-canvas.width)/2), limitY = max(0,(height-canvas.height)/2)
        return CGRect(x:(canvas.width-width)/2 + min(limitX,max(-limitX,offset.x)),
                      y:(canvas.height-height)/2 + min(limitY,max(-limitY,offset.y)),width:width,height:height)
    }
    mutating func magnify(by delta: CGFloat, around anchor: CGPoint, image: CGSize, canvas: CGSize) {
        guard delta.isFinite else { return }
        let old = rect(image:image,canvas:canvas)
        guard old.width > 0, old.height > 0 else { return }
        let x = (anchor.x-old.minX)/old.width, y = (anchor.y-old.minY)/old.height
        zoom = min(8,max(0.25,zoom*(1+delta)))
        let fitted = ScreenshotLayout.imageRect(image:image,canvas:canvas)
        let width = fitted.width*zoom, height = fitted.height*zoom
        offset = CGPoint(x:anchor.x-x*width-(canvas.width-width)/2,
                         y:anchor.y-y*height-(canvas.height-height)/2)
        constrain(image:image,canvas:canvas)
    }
    mutating func pan(by delta: CGPoint, image: CGSize, canvas: CGSize) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        offset.x += delta.x; offset.y += delta.y
        constrain(image:image,canvas:canvas)
    }
    private mutating func constrain(image: CGSize, canvas: CGSize) {
        let r = rect(image:image,canvas:canvas)
        offset = CGPoint(x:r.midX-canvas.width/2,y:r.midY-canvas.height/2)
    }
}
enum ScreenshotRenderer {
    static func font(for size: CGSize) -> NSFont { .systemFont(ofSize:max(12,min(28,min(size.width,size.height)*0.027)),weight:.medium) }
    static func unit(for size: CGSize) -> CGFloat { max(0.75,min(2,min(size.width,size.height)/600)) }
    static func font(for size: CGSize, design: ScreenshotAnnotationDesign) -> NSFont {
        let weight: NSFont.Weight = design.weight == "semibold" ? .semibold : design.weight == "regular" ? .regular : .medium
        return .systemFont(ofSize:17*unit(for:size)*design.typeScale,weight:weight)
    }
    static func attributes(size: CGSize, design: ScreenshotAnnotationDesign) -> [NSAttributedString.Key:Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.lineSpacing = 3*unit(for:size)
        return [.font:font(for:size,design:design),.foregroundColor:ScreenshotAnnotationDesign.color(design.ink),.paragraphStyle:paragraph]
    }
    static func labelSize(text: String, size: CGSize, design: ScreenshotAnnotationDesign) -> CGSize {
        let unit = unit(for:size), pad = design.padding*unit
        let width = min(size.width-32,max(110,min(460*unit,size.width*design.width)))
        let measured = (text as NSString).boundingRect(with:CGSize(width:max(30,width-pad*2),height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes(size:size,design:design))
        let eyebrowWidth = (design.eyebrow as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:10*unit,weight:.semibold),.kern:0.8*unit]).width
        return CGSize(width:min(width,max(ceil(measured.width),eyebrowWidth)+pad*2),height:ceil(measured.height)+pad*2+(design.eyebrow.isEmpty ? 0 : 23*unit))
    }
    static func draw(image: NSImage, size: CGSize, annotations: [ScreenshotAnnotation]) {
        image.draw(in:CGRect(origin:.zero,size:size),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        let unit = unit(for:size)
        for a in annotations {
            let d = a.design, end = a.target
            let accent = ScreenshotAnnotationDesign.color(d.accent)
            let surface = ScreenshotAnnotationDesign.color(d.surface)
            let ink = ScreenshotAnnotationDesign.color(d.ink)
            let horizontal = abs(end.x-a.rect.midX)/a.rect.width > abs(end.y-a.rect.midY)/a.rect.height
            let start = horizontal ? CGPoint(x:end.x<a.rect.midX ? a.rect.minX : a.rect.maxX,y:a.rect.midY) : CGPoint(x:a.rect.midX,y:end.y<a.rect.midY ? a.rect.minY : a.rect.maxY)
            let dx = end.x-start.x, dy = end.y-start.y
            let line = NSBezierPath(); line.move(to:start)
            var tangent = start
            if d.connector == "curved" {
                let c1 = horizontal ? CGPoint(x:start.x+dx*0.5,y:start.y) : CGPoint(x:start.x,y:start.y+dy*0.5)
                let c2 = horizontal ? CGPoint(x:end.x-dx*0.22,y:end.y) : CGPoint(x:end.x,y:end.y-dy*0.22)
                line.curve(to:end,controlPoint1:c1,controlPoint2:c2); tangent = c2
            } else if d.connector == "elbow" {
                let corner = horizontal ? CGPoint(x:end.x,y:start.y) : CGPoint(x:start.x,y:end.y)
                line.line(to:corner); line.line(to:end); tangent = hypot(end.x-corner.x,end.y-corner.y)>1 ? corner : start
            } else { line.line(to:end) }
            if a.style != "note" {
                line.lineWidth = 2*unit; line.lineCapStyle = .round; line.lineJoinStyle = .round
                // A fine light halo keeps connectors legible across mixed screenshot content.
                NSColor.white.withAlphaComponent(0.88).setStroke(); line.lineWidth = 4*unit; line.stroke()
                accent.setStroke(); line.lineWidth = 2*unit; line.stroke()
                let angle = atan2(end.y-tangent.y,end.x-tangent.x), length = 9*unit
                let arrow = NSBezierPath(); arrow.move(to:end)
                arrow.line(to:CGPoint(x:end.x-length*cos(angle-0.38),y:end.y-length*sin(angle-0.38)))
                arrow.line(to:CGPoint(x:end.x-length*0.7*cos(angle),y:end.y-length*0.7*sin(angle)))
                arrow.line(to:CGPoint(x:end.x-length*cos(angle+0.38),y:end.y-length*sin(angle+0.38))); arrow.close()
                accent.setFill(); arrow.fill()
            }
            if a.style == "highlight" {
                let ring = NSBezierPath(roundedRect:CGRect(x:end.x-25*unit,y:end.y-17*unit,width:50*unit,height:34*unit),xRadius:7*unit,yRadius:7*unit)
                accent.withAlphaComponent(0.10).setFill(); ring.fill(); accent.withAlphaComponent(0.65).setStroke(); ring.lineWidth = unit; ring.stroke()
            }
            let card = NSBezierPath(roundedRect:a.rect,xRadius:d.radius*unit,yRadius:d.radius*unit)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor(calibratedWhite:0.05,alpha:0.17); shadow.shadowBlurRadius = 14*unit; shadow.shadowOffset = NSSize(width:0,height:4*unit); shadow.set()
            surface.setFill(); card.fill(); NSGraphicsContext.restoreGraphicsState()
            ink.withAlphaComponent(0.10).setStroke(); card.lineWidth = 0.6*unit; card.stroke()
            // A restrained leading accent replaces the wireframe-like colored outline.
            let pad = d.padding*unit
            accent.setFill(); NSBezierPath(roundedRect:CGRect(x:a.rect.minX,y:a.rect.minY+d.radius*unit,width:3*unit,height:max(4*unit,a.rect.height-d.radius*unit*2)),xRadius:1.5*unit,yRadius:1.5*unit).fill()
            var textRect = a.rect.insetBy(dx:pad,dy:pad)
            if !d.eyebrow.isEmpty {
                (d.eyebrow as NSString).draw(in:CGRect(x:textRect.minX,y:textRect.minY,width:textRect.width,height:16*unit),withAttributes:[.font:NSFont.systemFont(ofSize:10*unit,weight:.semibold),.foregroundColor:ink.withAlphaComponent(0.65),.kern:0.8*unit])
                textRect.origin.y += 23*unit; textRect.size.height -= 23*unit
            }
            (a.text as NSString).draw(in:textRect,withAttributes:attributes(size:size,design:d))
        }
    }
    static func png(image: NSImage, size: CGSize, annotations: [ScreenshotAnnotation]) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width),pixelsHigh:Int(size.height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0), let context = NSGraphicsContext(bitmapImageRep:rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.translateBy(x:0,y:size.height); context.cgContext.scaleBy(x:1,y:-1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context.cgContext,flipped:true)
        draw(image:image,size:size,annotations:annotations)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using:.png,properties:[:])
    }
    static func textRects(image: NSImage, size: CGSize) -> [CGRect] {
        guard let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return [] }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage:cg).perform([request])
        return (request.results ?? []).map { let r = $0.boundingBox; return CGRect(x:r.minX*size.width,y:(1-r.maxY)*size.height,width:r.width*size.width,height:r.height*size.height) }
    }
}
