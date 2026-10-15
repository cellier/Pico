import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PaperKit
import PencilKit

@MainActor protocol ScreenshotMarkupSession: AnyObject {
    func snapshot() -> Any
    func restore(_ snapshot: Any?)
    func clear()
    func png(background: Data, size: CGSize) async throws -> Data
}

/// AppKit owns input because the macOS 26 PaperKit remote view can discard
/// mouse events. Every editable object is rendered/exported by public PaperKit APIs.
@available(macOS 26.0, *)
struct ScreenshotPaperElement {
    enum Content { case text(String), shape(ShapeConfiguration.Shape), drawing(PKDrawing, CGRect) }
    var id = UUID()
    var frame: CGRect
    var content: Content
    var color: NSColor
    var fontSize: CGFloat = 28
    var fontFamily = "System"
    var bold = false
    var italic = false
    var autoTextWidth = true
    var underline = false
    var alignment:NSTextAlignment = .left
    var lineSpacing:CGFloat = 0
    /// Tag-style text draws on a rounded fill; arrows remember which corner they start from.
    var fill:NSColor? = nil
    var lineFromMaxX = false
    var lineFromMaxY = true
    static let tagPadding:CGFloat = 20
    static let tagCornerRadius:CGFloat = 20
    var isArrow:Bool { if case .shape(.line) = content {return true};return false }
    /// What the user sees and grabs: the tag background for tags, the frame otherwise.
    var visualFrame:CGRect { tagRect ?? frame }
    /// Tag background: glyph bounds of every line plus equal padding on all sides.
    var tagRect:CGRect? {
        guard fill != nil else {return nil}
        let ink=textLines().reduce(CGRect.null) { $0.union($1.ink) }
        return (ink.isNull ? frame : ink).insetBy(dx:-Self.tagPadding,dy:-Self.tagPadding)
    }
    var renderOutset:CGFloat {
        if let tagRect {
            return ceil(max(frame.minX-tagRect.minX,tagRect.maxX-frame.maxX,frame.minY-tagRect.minY,tagRect.maxY-frame.maxY,0))+8
        }
        if isArrow { return ceil(ScreenshotArrow.headLength(width:PaperScreenshotSession.shapeLineWidth))+8 }
        if case .shape = content { return PaperScreenshotSession.shapeLineWidth*3 }
        return 8
    }
    /// Whether `point` grabs this element; arrows only respond near their stroke.
    func contains(_ point:CGPoint,tolerance:CGFloat)->Bool {
        guard isArrow else { return visualFrame.insetBy(dx:-tolerance,dy:-tolerance).contains(point) }
        let a=lineStart,b=lineEnd,dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
        let t=length == 0 ? 0 : min(1,max(0,((point.x-a.x)*dx+(point.y-a.y)*dy)/length))
        let distance=hypot(point.x-(a.x+t*dx),point.y-(a.y+t*dy))
        return distance <= max(PaperScreenshotSession.shapeLineWidth*1.5,tolerance)+(t > 0.7 ? ScreenshotArrow.headLength(width:PaperScreenshotSession.shapeLineWidth)*0.4 : 0)
    }
    var lineStart:CGPoint { CGPoint(x:lineFromMaxX ? frame.maxX : frame.minX,y:lineFromMaxY ? frame.maxY : frame.minY) }
    var lineEnd:CGPoint { CGPoint(x:lineFromMaxX ? frame.minX : frame.maxX,y:lineFromMaxY ? frame.minY : frame.maxY) }
    func font(scale: CGFloat = 1) -> NSFont {
        let size = fontSize * scale
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let base = fontFamily == "System" ? NSFont.systemFont(ofSize:size,weight:bold ? .bold : .regular) :
            (NSFontManager.shared.font(withFamily:fontFamily,traits:traits,weight:bold ? 9 : 5,size:size) ?? NSFont.systemFont(ofSize:size))
        return NSFontManager.shared.convert(base,toHaveTrait:traits)
    }
    var isText:Bool { if case .text = content {return true};return false }
    func hasSameAppearance(as other:Self)->Bool {
        guard frame.size == other.frame.size, color == other.color, fill == other.fill, lineFromMaxX == other.lineFromMaxX, lineFromMaxY == other.lineFromMaxY, fontSize == other.fontSize,
              fontFamily == other.fontFamily, bold == other.bold, italic == other.italic, underline == other.underline, alignment == other.alignment, lineSpacing == other.lineSpacing else {return false}
        switch (content,other.content) {
        case (.text(let a),.text(let b)): return a == b
        case (.shape(let a),.shape(let b)): return a == b
        case (.drawing(let a,let ar),.drawing(let b,let br)): return a == b && ar == br
        default: return false
        }
    }
    func markup(canvas: CGRect) -> PaperMarkup {
        var value = PaperMarkup(bounds:canvas)
        switch content {
        case .text:
            if let fill,let tagRect,let image=ScreenshotVectorImage.make(rect:tagRect,draw:{ context in
                context.setFillColor(fill.cgColor)
                let radius=min(Self.tagCornerRadius,tagRect.height/2,tagRect.width/2)
                context.addPath(CGPath(roundedRect:tagRect,cornerWidth:radius,cornerHeight:radius,transform:nil));context.fillPath()
            }) { value.insertNewImage(image,frame:tagRect) }
            for line in textLines() { value.insertNewTextbox(attributedText:line.text,frame:line.frame) }
        case .shape(let shape):
            if shape == .line {
                // A filled, tapered arrow: PaperKit lines have a uniform width and a small head.
                let path=ScreenshotArrow.path(from:lineStart,to:lineEnd,width:PaperScreenshotSession.shapeLineWidth)
                if !path.isEmpty,let image=ScreenshotVectorImage.make(rect:path.boundingBoxOfPath.insetBy(dx:-2,dy:-2),draw:{ context in
                    context.setFillColor(color.cgColor);context.addPath(path);context.fillPath()
                }) { value.insertNewImage(image,frame:path.boundingBoxOfPath.insetBy(dx:-2,dy:-2)) }
            } else {
                let config = ShapeConfiguration(type:shape,fillColor:nil,strokeColor:color.cgColor,lineWidth:PaperScreenshotSession.shapeLineWidth)
                value.insertNewShape(configuration:config,frame:frame)
            }
        case .drawing(let drawing,let original):
            value.append(contentsOf:drawing)
            let sx = frame.width/max(1,original.width), sy = frame.height/max(1,original.height)
            value.transformContent(CGAffineTransform(a:sx,b:0,c:0,d:sy,tx:frame.minX-original.minX*sx,ty:frame.minY-original.minY*sy))
        }
        return value
    }
    /// Lays out lines with AppKit, then preserves their exact origins in PaperKit.
    /// PaperKit centers a multiline textbox inside its frame; separate tight
    /// line frames keep editing, alignment controls and export consistent.
    /// `ink` is each line's glyph bounds where PaperKit draws it (4px inset, baseline at top + 2 + ascender).
    func textLines() -> [(text:NSAttributedString,frame:CGRect,ink:CGRect)] {
        guard case .text(let text)=content else {return []}
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = lineSpacing
        let font=font()
        let attributed = NSAttributedString(string:text,attributes:[.font:font,.foregroundColor:color,.paragraphStyle:paragraph,.underlineStyle:underline ? NSUnderlineStyle.single.rawValue : 0])
        let storage=NSTextStorage(attributedString:attributed)
        let layout=NSLayoutManager()
        let container=NSTextContainer(size:CGSize(width:max(1,frame.width-8),height:CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding=0;layout.addTextContainer(container);storage.addLayoutManager(layout)
        layout.ensureLayout(for:container)
        var lines:[(text:NSAttributedString,frame:CGRect,ink:CGRect)]=[]
        layout.enumerateLineFragments(forGlyphRange:layout.glyphRange(for:container)) { _,used,_,glyphs,_ in
            let characters=layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            let text=(attributed.string as NSString).substring(with:characters).trimmingCharacters(in:.newlines)
            guard !text.isEmpty else {return}
            let lineParagraph=NSMutableParagraphStyle();lineParagraph.alignment = .left
            let line=NSAttributedString(string:text,attributes:[.font:font,.foregroundColor:color,.paragraphStyle:lineParagraph,.underlineStyle:underline ? NSUnderlineStyle.single.rawValue : 0])
            let width=ceil(line.size().width)+8
            let lineFrame=CGRect(x:frame.minX+used.minX,y:frame.minY+used.minY,width:max(8,width),height:max(fontSize+4,ceil(used.height)+4))
            var ink=CGRect.null
            let glyphs=CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(line),.useGlyphPathBounds)
            if !glyphs.isEmpty {
                let baseline=CGPoint(x:lineFrame.minX+4,y:lineFrame.minY+2+font.ascender)
                ink=CGRect(x:baseline.x+glyphs.minX,y:baseline.y-glyphs.maxY,width:glyphs.width,height:glyphs.height)
            }
            lines.append((line,lineFrame,ink))
        }
        return lines
    }
}

/// Tapered arrow: a thin rounded tail widening toward a large swept head.
enum ScreenshotArrow {
    static func headLength(width:CGFloat)->CGFloat { width*7 }
    static func path(from a:CGPoint,to b:CGPoint,width:CGFloat)->CGPath {
        let path=CGMutablePath()
        let length=hypot(b.x-a.x,b.y-a.y)
        guard length >= 1 else {return path}
        let u=CGPoint(x:(b.x-a.x)/length,y:(b.y-a.y)/length),n=CGPoint(x:-u.y,y:u.x)
        func at(_ along:CGFloat,_ across:CGFloat)->CGPoint { CGPoint(x:a.x+u.x*along+n.x*across,y:a.y+u.y*along+n.y*across) }
        let head=min(headLength(width:width),length*0.6),halfHead=head*0.5
        let neck=length-head*0.8,tail=width*0.15,shaft=width*0.7
        path.move(to:at(0,tail))
        path.addLine(to:at(neck,shaft));path.addLine(to:at(length-head,halfHead))
        path.addLine(to:b)
        path.addLine(to:at(length-head,-halfHead));path.addLine(to:at(neck,-shaft))
        path.addLine(to:at(0,-tail))
        path.addArc(center:a,radius:tail,startAngle:atan2(-n.y,-n.x),endAngle:atan2(n.y,n.x),clockwise:false)
        path.closeSubpath()
        return path
    }
}

/// Rasterizes vector art at 2× for insertion into PaperMarkup in canvas (y-down) coordinates.
enum ScreenshotVectorImage {
    static func make(rect:CGRect,scale:CGFloat=2,draw:(CGContext)->Void)->CGImage? {
        let width=max(1,Int(ceil(rect.width*scale))),height=max(1,Int(ceil(rect.height*scale)))
        guard width*height <= 40_000_000,let space=CGColorSpace(name:CGColorSpace.sRGB),
              let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:CGFloat(width)/rect.width,y:-CGFloat(height)/rect.height)
        context.translateBy(x:-rect.minX,y:-rect.minY)
        draw(context)
        return context.makeImage()
    }
}

@available(macOS 26.0, *)
@MainActor final class PaperScreenshotSession: NSViewController, ScreenshotMarkupSession, ObservableObject {
    private let background = ScreenshotPaperBackground()
    private let input = ScreenshotPaperInput()
    private var basePNG: Data?
    private var baseImageID:ObjectIdentifier?
    private var annotationKey=""
    @MainActor private final class ObjectPreview {
        let view=ScreenshotPaperBackground()
        var rendered:ScreenshotPaperElement?
        init() { view.imageScaling = .scaleAxesIndependently }
    }
    private var previews:[UUID:ObjectPreview]=[:]
    private(set) var previewRenderCount=0
    private var transformingID:UUID?
    @Published private(set) var selectionDisplayFrame:CGRect = .zero
    @Published private(set) var isTransforming=false
    private var viewport = ScreenshotViewport()
    private let canvas: CGRect
    private(set) var elements: [ScreenshotPaperElement] = []
    var selectedID: UUID? { didSet { if oldValue != selectedID { editor?.objectWillChange.send() } } }
    var editingID: UUID?
    var color = NSColor.red
    enum Tool: CaseIterable { case selection, pen, marker, eraser, arrow, rectangle, ellipse, text
        var isDrawing:Bool { self == .pen || self == .marker }
        /// Tools that create an object from a drag rectangle.
        var createsObject:Bool { [.arrow,.rectangle,.ellipse,.text].contains(self) }
    }
    var tool = Tool.selection {
        didSet { if oldValue != tool { editor?.objectWillChange.send();view.window?.invalidateCursorRects(for:input) } }
    }
    var ink:PKInkingTool.InkType { tool == .marker ? .marker : .pen }
    weak var editor: ScreenshotEditor?
    init(size: CGSize) {
        canvas = CGRect(origin:.zero,size:size)
        super.init(nibName:nil,bundle:nil)
        input.session = self
    }
    required init?(coder:NSCoder) { nil }
    override func loadView() { view = ScreenshotPaperContainer(frame:CGRect(x:0,y:0,width:800,height:600)) }
    override func viewDidLoad() {
        super.viewDidLoad()
        background.imageScaling = .scaleAxesIndependently
        view.wantsLayer=true;view.layer?.masksToBounds=true
        view.addSubview(background)
        input.autoresizingMask=[.width,.height];input.frame=view.bounds;view.addSubview(input)
        layoutViewport()
    }

    func update(editor:ScreenshotEditor) {
        self.editor = editor
        let key=editor.annotations.map { item in
            "\(item.text)|\(item.target)|\(item.rect)|\(item.style)|\((try? JSONEncoder().encode(item.design).base64EncodedString()) ?? "")"
        }.joined(separator:"\n")
        if baseImageID != ObjectIdentifier(editor.image) || key != annotationKey {
            if let png=ScreenshotRenderer.png(image:editor.image,size:editor.size,annotations:editor.annotations) {
                basePNG=png;background.image=NSImage(data:png)
                baseImageID=ObjectIdentifier(editor.image);annotationKey=key
            }
        }
        loadViewIfNeeded()
        input.needsDisplay = true
    }
    override func viewDidLayout() { super.viewDidLayout(); layoutViewport() }
    var imageRect:CGRect { viewport.rect(image:canvas.size,canvas:view.bounds.size) }
    var displayScale:CGFloat { imageRect.width/max(1,canvas.width) }
    var zoom:CGFloat { viewport.zoom }
    func displayPoint(_ point:CGPoint)->CGPoint { CGPoint(x:imageRect.minX+point.x*displayScale,y:imageRect.minY+point.y*displayScale) }
    func canvasPoint(_ point:CGPoint)->CGPoint { CGPoint(x:(point.x-imageRect.minX)/displayScale,y:(point.y-imageRect.minY)/displayScale) }
    func zoom(by delta:CGFloat,around anchor:CGPoint? = nil) {
        input.commitText()
        viewport.magnify(by:delta,around:anchor ?? CGPoint(x:view.bounds.midX,y:view.bounds.midY),image:canvas.size,canvas:view.bounds.size)
        layoutViewport();editor?.objectWillChange.send()
    }
    func fitCanvas() { input.commitText();viewport=ScreenshotViewport();layoutViewport();editor?.objectWillChange.send() }
    func pan(by delta:CGPoint) {
        input.commitText();viewport.pan(by:delta,image:canvas.size,canvas:view.bounds.size);layoutViewport()
    }
    private func layoutViewport() {
        background.frame=imageRect
        for item in elements {
            guard let preview=previews[item.id] else {continue}
            // Never stretch a cached image: line widths and text would distort.
            // Moves reuse it at its rendered size; resizes re-render it.
            let rendered=preview.rendered ?? item,outset=rendered.renderOutset
            let rect=CGRect(x:item.frame.minX-outset,y:item.frame.minY-outset,width:ceil(rendered.frame.width)+outset*2,height:ceil(rendered.frame.height)+outset*2)
            preview.view.frame=CGRect(origin:displayPoint(rect.origin),size:CGSize(width:rect.width*displayScale,height:rect.height*displayScale))
            preview.view.isHidden=item.id == editingID
        }
        if let selected {
            let visual=selected.visualFrame
            let rect=CGRect(origin:displayPoint(visual.origin),size:CGSize(width:visual.width*displayScale,height:visual.height*displayScale))
            if selectionDisplayFrame != rect {selectionDisplayFrame=rect}
        }
        input.layoutText();input.needsDisplay=true;view.window?.invalidateCursorRects(for:input)
    }
    private var renderTask:Task<Void,Never>?
    private var renderRevision=0
    private func refreshPreview() {
        loadViewIfNeeded()
        let ids=Set(elements.map(\.id))
        for id in Array(previews.keys) where !ids.contains(id) {previews.removeValue(forKey:id)?.view.removeFromSuperview()}
        for item in elements {
            let preview=previews[item.id] ?? ObjectPreview();previews[item.id]=preview
            view.addSubview(preview.view,positioned:.below,relativeTo:input)
        }
        layoutViewport();renderRevision += 1
        guard renderTask == nil else {return}
        renderTask=Task { [weak self] in
            guard let self else {return}
            defer {self.renderTask=nil}
            while true {
                let revision=self.renderRevision
                for item in self.elements {
                    guard item.id != self.editingID, item.id != self.transformingID,
                          let preview=self.previews[item.id], preview.rendered?.hasSameAppearance(as:item) != true else {continue}
                    do {
                        let image=try await Self.renderPreview(item)
                        guard let current=self.elements.first(where:{$0.id == item.id}),current.hasSameAppearance(as:item) else {continue}
                        preview.view.image=image;preview.rendered=item;self.previewRenderCount += 1
                        self.layoutViewport()
                    } catch {self.editor?.message="PaperKit preview failed: \(error.localizedDescription)"}
                }
                if revision == self.renderRevision {return}
            }
        }
    }
    static func renderPreview(_ item:ScreenshotPaperElement) async throws -> NSImage {
        let outset=item.renderOutset
        var local=item;local.frame.origin=CGPoint(x:outset,y:outset)
        let size=CGSize(width:ceil(item.frame.width)+outset*2,height:ceil(item.frame.height)+outset*2)
        // Preserve Retina quality without allocating a screenshot-sized bitmap per object.
        let scale:CGFloat=min(2,4096/max(size.width,size.height))
        let width=max(1,Int(ceil(size.width*scale))),height=max(1,Int(ceil(size.height*scale)))
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw CocoaError(.fileWriteUnknown)}
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:scale,y:-scale)
        let bounds=CGRect(origin:.zero,size:size)
        await local.markup(canvas:bounds).draw(in:context,frame:bounds)
        guard let image=context.makeImage() else {throw CocoaError(.fileWriteUnknown)}
        return NSImage(cgImage:image,size:size)
    }
    /// Moves reuse the cached image; resizes (`live`) keep re-rendering at the true size.
    func beginTransform(live:Bool = false) { transformingID=live ? nil : selectedID;isTransforming=true }
    func finishTransform() {
        transformingID=nil;isTransforming=false
        if let i=selectedIndex,case .text(let text)=elements[i].content {
            let item=elements[i]
            let height=(text as NSString).boundingRect(with:CGSize(width:max(1,item.frame.width-8),height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:item.font()]).height
            elements[i].frame.size.height=max(item.frame.height,ceil(height)+8)
        }
        rebuild()
    }
    func waitForPreview() async { await renderTask?.value }
    func endEditing() { input.commitText(); selectedID=nil; input.needsDisplay=true; view.window?.makeFirstResponder(input) }
    func focusCanvas() { input.commitText(); view.window?.makeFirstResponder(input) }
    func select() { tool = .selection; focusCanvas() }
    func setTool(_ value:Tool) {
        focusCanvas();tool=value
        if value != .selection { selectedID=nil }
        input.needsDisplay=true
    }
    static let tagColor=NSColor.systemRed
    // Widths and sizes are in screenshot pixels (2× on Retina).
    nonisolated static let shapeLineWidth:CGFloat=8
    static func strokeWidth(_ ink:PKInkingTool.InkType)->CGFloat { ink == .marker ? 24 : 7 }
    var defaultFontSize:CGFloat { min(80,max(16,canvas.height*0.15)) }
    /// Text defaults to a bold, centered, white-on-red tag centered on `center` (or the canvas).
    func insertText(centeredAt center:CGPoint? = nil) {
        focusCanvas(); checkpoint()
        var element=ScreenshotPaperElement(frame:.zero,content:.text("Text"),color:.white,fontSize:defaultFontSize,bold:true,alignment:.center,fill:Self.tagColor)
        let width=min(ceil(("Text" as NSString).size(withAttributes:[.font:element.font()]).width)+8,canvas.width*0.7),height=ceil(element.fontSize*1.3)+4
        let point=center ?? CGPoint(x:canvas.midX,y:canvas.midY)
        element.frame=CGRect(x:min(max(0,point.x-width/2),max(0,canvas.width-width)),y:min(max(0,point.y-height/2),max(0,canvas.height-height)),width:width,height:height)
        elements.append(element);selectedID=element.id;rebuild();input.beginText()
    }
    /// Creates a shape covering the dragged rectangle; arrows point from `start` to `end`.
    func insertShape(_ shape:ShapeConfiguration.Shape,from start:CGPoint? = nil,to end:CGPoint? = nil) {
        focusCanvas();checkpoint()
        var element:ScreenshotPaperElement
        if let start,let end {
            let frame=CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y))
            element=ScreenshotPaperElement(frame:frame,content:.shape(shape),color:color)
            element.lineFromMaxX=start.x>end.x;element.lineFromMaxY=start.y>end.y
        } else {
            let side=min(180,min(canvas.width,canvas.height)*0.4)
            element=ScreenshotPaperElement(frame:CGRect(x:(canvas.width-side)/2,y:(canvas.height-side)/2,width:side,height:side),content:.shape(shape),color:color)
        }
        elements.append(element);selectedID=element.id;rebuild()
    }
    func setColor(_ value:NSColor) {
        guard let i=selectedIndex else { color=value;return }
        input.commitText();checkpoint()
        if elements[i].isText,elements[i].fill != nil {
            // Tags recolor their fill and keep the text legible on light fills.
            elements[i].fill=value
            elements[i].color=[NSColor.white,.systemYellow].contains(value) ? .black : .white
            rebuild();return
        }
        color=value;elements[i].color=value
        if case .drawing(let drawing,let original) = elements[i].content {
            let strokes=drawing.strokes.map { stroke -> PKStroke in
                var changed=stroke; changed.ink=PKInk(stroke.ink.inkType,color:value);return changed
            }
            elements[i].content = .drawing(PKDrawing(strokes:strokes),original)
        }
        rebuild()
    }
    func setTextStyle(family:String? = nil, size:CGFloat? = nil, bold:Bool? = nil, italic:Bool? = nil, underline:Bool? = nil, alignment:NSTextAlignment? = nil, lineSpacing:CGFloat? = nil) {
        input.commitText()
        guard let i=selectedIndex, case .text(let text)=elements[i].content else { return }
        checkpoint()
        if let family { elements[i].fontFamily=family }
        if let size, size.isFinite { elements[i].fontSize=min(240,max(8,size)) }
        if let bold { elements[i].bold=bold }
        if let italic { elements[i].italic=italic }
        if let underline {elements[i].underline=underline}
        if let alignment {elements[i].alignment=alignment}
        if let lineSpacing {elements[i].lineSpacing=lineSpacing}
        let item=elements[i]
        let height=(text as NSString).boundingRect(with:CGSize(width:max(1,item.frame.width-8),height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:item.font()]).height
        elements[i].frame.size.height=max(item.frame.height,ceil(height)+8)
        rebuild()
    }
    func setListStyle(_ numbered:Bool?) {
        input.commitText()
        guard let item=selected,case .text(let text)=item.content else {return}
        checkpoint()
        let lines=text.components(separatedBy:"\n").enumerated().map { index,line in
            let clean=line.replacingOccurrences(of:"^(?:• |[0-9]+\\. )",with:"",options:.regularExpression)
            guard let numbered else {return clean}
            return (numbered ? "\(index+1). " : "• ")+clean
        }
        replaceText(lines.joined(separator:"\n"))
    }
    var selectedIndex:Int? { elements.firstIndex { $0.id == selectedID } }
    var selected:ScreenshotPaperElement? { selectedIndex.map { elements[$0] } }
    var canvasBounds:CGRect { canvas }
    func checkpoint() { editor?.rememberMarkup(elements) }
    func snapshot() -> Any { elements }
    func restore(_ snapshot:Any?) {
        input.cancelText(); elements=snapshot as? [ScreenshotPaperElement] ?? []
        if !elements.contains(where: { $0.id == selectedID }) { selectedID=nil };rebuild()
    }
    func clear() { restore([ScreenshotPaperElement]()) }
    func model(excluding:UUID? = nil) -> PaperMarkup {
        var result=PaperMarkup(bounds:canvas)
        for element in elements where element.id != excluding { result.append(contentsOf:element.markup(canvas:canvas)) }
        return result
    }
    func rebuild() {
        refreshPreview()
        input.needsDisplay=true;editor?.objectWillChange.send()
    }
    func replaceFrame(_ frame:CGRect,fontSize:CGFloat? = nil) {
        guard let i=selectedIndex else {return}
        if elements[i].frame.size != frame.size {elements[i].autoTextWidth=false}
        elements[i].frame=frame
        if let fontSize {elements[i].fontSize=min(240,max(8,fontSize))}
        if transformingID != nil {layoutViewport()} else {rebuild()}
    }
    func replaceText(_ text:String,height:CGFloat? = nil) {
        guard let i=selectedIndex else {return};elements[i].content = .text(text)
        if elements[i].autoTextWidth {
            let width=text.components(separatedBy:"\n").map {($0 as NSString).size(withAttributes:[.font:elements[i].font()]).width}.max() ?? 30
            let midX=elements[i].frame.midX
            elements[i].frame.size.width=min(max(30,ceil(width)+8),canvas.width*0.7)
            // Centered text grows from its center.
            if elements[i].alignment == .center { elements[i].frame.origin.x=midX-elements[i].frame.width/2 }
        }
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=elements[i].lineSpacing
        let measured=(text as NSString).boundingRect(with:CGSize(width:max(1,elements[i].frame.width-8),height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:elements[i].font(),.paragraphStyle:paragraph]).height
        elements[i].frame.size.height=max(32,ceil(measured)+8)
        rebuild()
    }
    func deleteSelection() { guard let i=selectedIndex else {return};checkpoint();elements.remove(at:i);selectedID=nil;rebuild() }
    func element(at point:CGPoint)->ScreenshotPaperElement? {
        elements.reversed().first { $0.contains(point,tolerance:6/displayScale) }
    }
    /// Moves one end of the selected arrow.
    func replaceLine(from start:CGPoint,to end:CGPoint) {
        guard let i=selectedIndex else {return}
        elements[i].frame=CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y))
        elements[i].lineFromMaxX=start.x>end.x;elements[i].lineFromMaxY=start.y>end.y
        rebuild()
    }
    func addStroke(_ points:[CGPoint]) {
        guard points.count > 1 else {return};checkpoint()
        let width=Self.strokeWidth(ink)
        let strokePoints=points.enumerated().map { i,p in PKStrokePoint(location:p,timeOffset:Double(i)*0.01,size:CGSize(width:width,height:width),opacity:ink == .marker ? 0.45 : 1,force:1,azimuth:0,altitude:.pi/2) }
        let drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(ink,color:color),path:PKStrokePath(controlPoints:strokePoints,creationDate:Date()))])
        elements.append(ScreenshotPaperElement(frame:drawing.bounds,content:.drawing(drawing,drawing.bounds),color:color))
        rebuild()
    }
    func png(background:Data,size:CGSize) async throws -> Data { try await Self.render(background:background,size:size,markup:model()) }
    static func render(background: Data, size: CGSize, markup: PaperMarkup) async throws -> Data {
        guard let source = CGImageSourceCreateWithData(background as CFData,nil),
              let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CocoaError(.fileReadCorruptFile) }
        if markup.contentsRenderFrame.isEmpty || markup.contentsRenderFrame.isNull { return background }
        guard image.width <= 80_000_000 / max(1,image.height),
              let space = CGColorSpace(name:CGColorSpace.sRGB),
              let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        // Background and markup share PaperKit's coordinates and rendering transform.
        // The original is never a selectable item in the editing canvas.
        var composite = PaperMarkup(bounds:CGRect(origin:.zero,size:size))
        composite.insertNewImage(image,frame:composite.bounds)
        composite.append(contentsOf:markup)
        let pixels = CGRect(x:0,y:0,width:image.width,height:image.height)
        context.clip(to:pixels)
        context.translateBy(x:0,y:CGFloat(image.height))
        context.scaleBy(x:1,y:-1)
        await composite.draw(in:context,frame:pixels)
        guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination,output,nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

enum ScreenshotResizeHandle:CaseIterable {
    case topLeft,top,topRight,right,bottomRight,bottom,bottomLeft,left
    var x:CGFloat { switch self {case .topLeft,.left,.bottomLeft:return 0;case .top,.bottom:return 0.5;default:return 1} }
    var y:CGFloat { switch self {case .topLeft,.top,.topRight:return 0;case .left,.right:return 0.5;default:return 1} }
    var isCorner:Bool { x != 0.5 && y != 0.5 }
    func point(in rect:CGRect)->CGPoint {CGPoint(x:rect.minX+x*rect.width,y:rect.minY+y*rect.height)}
    func resized(_ rect:CGRect,delta:CGPoint,proportional:Bool)->CGRect {
        var width=x == 0.5 ? rect.width : max(8,rect.width+(x == 0 ? -delta.x : delta.x))
        var height=y == 0.5 ? rect.height : max(8,rect.height+(y == 0 ? -delta.y : delta.y))
        if proportional && isCorner {
            let factor=max(width/rect.width,height/rect.height)
            width=rect.width*factor;height=rect.height*factor
        }
        return CGRect(x:x == 0 ? rect.maxX-width : rect.minX,y:y == 0 ? rect.maxY-height : rect.minY,width:width,height:height)
    }
}

private final class ScreenshotPaperContainer:NSView { override var isFlipped:Bool { true } }

@available(macOS 26.0, *)
private final class ScreenshotPaperBackground:NSImageView {
    override var intrinsicContentSize:NSSize { NSSize(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric) }
    override func hitTest(_ point:NSPoint)->NSView? { nil }
}

@available(macOS 26.0, *)
@MainActor private final class ScreenshotPaperInput:NSView,NSTextViewDelegate {
    weak var session:PaperScreenshotSession?
    private var textView:NSTextView?
    private var textBefore=""
    private var origin:CGPoint?
    private var startingFrame:CGRect?
    private var resizeHandle:ScreenshotResizeHandle?
    /// Arrow end being dragged (`true` = head) and the end that stays put.
    private var arrowEnd:Bool?
    private var arrowAnchor:CGPoint = .zero
    private var tagView:NSView?
    private var editingMidX:CGFloat=0
    private var startingFontSize:CGFloat=28
    private var moving=false
    private var stroke:[CGPoint]=[]
    /// Current point of a drag that creates an arrow, shape or text.
    private var creating:CGPoint?
    private var erasing=false
    override var isFlipped:Bool {true}
    override var acceptsFirstResponder:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    private var scale:CGFloat { session?.displayScale ?? 1 }
    private func point(_ event:NSEvent)->CGPoint { session?.canvasPoint(convert(event.locationInWindow,from:nil)) ?? .zero }
    private func displayRectForMarkup(_ rect:CGRect)->CGRect { CGRect(origin:session?.displayPoint(rect.origin) ?? .zero,size:CGSize(width:rect.width*scale,height:rect.height*scale)) }
    override func magnify(with event:NSEvent) {
        guard origin == nil else {return}
        session?.zoom(by:event.magnification,around:convert(event.locationInWindow,from:nil))
    }
    override func scrollWheel(with event:NSEvent) {
        guard origin == nil else {return}
        let factor:CGFloat=event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.command) {
            session?.zoom(by:exp(event.scrollingDeltaY*factor*0.01)-1,around:convert(event.locationInWindow,from:nil))
        } else { session?.pan(by:CGPoint(x:event.scrollingDeltaX*factor,y:event.scrollingDeltaY*factor)) }
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let session else{return}
        NSBezierPath(rect:session.imageRect.intersection(bounds)).addClip()
        if let item=session.selected, session.editingID == nil {
            func dot(_ p:CGPoint,_ color:NSColor) {
                let dot=NSBezierPath(ovalIn:CGRect(x:p.x-3.5,y:p.y-3.5,width:7,height:7))
                color.setFill();dot.fill();NSColor.white.setStroke();dot.lineWidth=0.75;dot.stroke()
            }
            if item.isArrow {
                dot(session.displayPoint(item.lineStart),.controlAccentColor);dot(session.displayPoint(item.lineEnd),.controlAccentColor)
            } else {
                let rect=displayRectForMarkup(item.visualFrame)
                NSColor.controlAccentColor.setStroke();let path=NSBezierPath(rect:rect);path.lineWidth=1;path.stroke()
                for handle in handles(for:item) { dot(handle.point(in:rect),item.isText && handle.isCorner ? .systemGreen : .controlAccentColor) }
            }
        }
        if stroke.count>1 {
            session.color.setStroke();let path=NSBezierPath();path.move(to:session.displayPoint(stroke[0]))
            for p in stroke.dropFirst(){path.line(to:session.displayPoint(p))};path.lineWidth=PaperScreenshotSession.strokeWidth(session.ink)*scale;path.lineCapStyle = .round;path.stroke()
        }
        if let origin,let creating {drawCreation(from:session.displayPoint(origin),to:session.displayPoint(creating),tool:session.tool,color:session.color)}
    }
    private func drawCreation(from a:CGPoint,to b:CGPoint,tool:PaperScreenshotSession.Tool,color:NSColor) {
        let rect=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y))
        let path:NSBezierPath
        switch tool {
        case .rectangle: path=NSBezierPath(rect:rect)
        case .ellipse: path=NSBezierPath(ovalIn:rect)
        case .arrow:
            guard let context=NSGraphicsContext.current?.cgContext else {return}
            context.setFillColor(color.cgColor);context.addPath(ScreenshotArrow.path(from:a,to:b,width:PaperScreenshotSession.shapeLineWidth*scale));context.fillPath();return
        default:
            NSColor.controlAccentColor.setStroke();let box=NSBezierPath(rect:rect);box.lineWidth=1;box.setLineDash([4,3],count:2,phase:0);box.stroke();return
        }
        color.setStroke();path.lineWidth=PaperScreenshotSession.shapeLineWidth*scale;path.lineCapStyle = .round;path.lineJoinStyle = .round;path.stroke()
    }
    /// Arrows use endpoint handles instead. Edge handles are dropped on objects too
    /// small to separate them from corners, so pressing the object moves it.
    private func handles(for item:ScreenshotPaperElement)->[ScreenshotResizeHandle] {
        if item.isArrow { return [] }
        let size=CGSize(width:item.visualFrame.width*scale,height:item.visualFrame.height*scale)
        return (item.isText ? [.left,.right,.bottomRight] : ScreenshotResizeHandle.allCases).filter {
            !($0.x == 0.5 && size.width < 40) && !($0.y == 0.5 && size.height < 40)
        }
    }
    private func handle(at point:CGPoint,item:ScreenshotPaperElement)->ScreenshotResizeHandle? {
        handles(for:item).first { let p=$0.point(in:item.visualFrame);return hypot(point.x-p.x,point.y-p.y)<6/scale }
    }
    private func arrowEnd(at point:CGPoint,item:ScreenshotPaperElement)->Bool? {
        guard item.isArrow else {return nil}
        if hypot(point.x-item.lineEnd.x,point.y-item.lineEnd.y)<8/scale {return true}
        if hypot(point.x-item.lineStart.x,point.y-item.lineStart.y)<8/scale {return false}
        return nil
    }
    override func resetCursorRects() {
        guard let session else {return}
        if session.tool != .selection {addCursorRect(bounds,cursor:.crosshair);return}
        for item in session.elements {
            let rect=displayRectForMarkup(item.visualFrame).intersection(bounds)
            if !rect.isNull {addCursorRect(rect,cursor:.openHand)}
        }
        if let item=session.selected {
            for end in item.isArrow ? [item.lineStart,item.lineEnd] : [] {
                let p=session.displayPoint(end);addCursorRect(CGRect(x:p.x-8,y:p.y-8,width:16,height:16).intersection(bounds),cursor:.crosshair)
            }
            for handle in handles(for:item) {
                let p=handle.point(in:displayRectForMarkup(item.visualFrame))
                addCursorRect(CGRect(x:p.x-7,y:p.y-7,width:14,height:14).intersection(bounds),cursor:handle.x == 0.5 ? .resizeUpDown : handle.y == 0.5 ? .resizeLeftRight : .crosshair)
            }
        }
    }
    override func mouseDown(with event:NSEvent) {
        guard let session, session.editor?.busy != true else{return}
        commitText();window?.makeFirstResponder(self)
        let p=point(event);moving=false;startingFrame=nil;origin=nil;creating=nil;erasing=false
        resizeHandle=nil;arrowEnd=nil
        let tool=session.tool
        if tool == .selection || tool.createsObject, let item=session.selected {
            if let end=arrowEnd(at:p,item:item) {
                arrowEnd=end;arrowAnchor=end ? item.lineStart : item.lineEnd;startingFrame=item.frame;origin=p;return
            }
            if let handle=handle(at:p,item:item) {
                resizeHandle=handle;startingFrame=item.frame;startingFontSize=item.fontSize;origin=p;return
            }
        }
        guard session.canvasBounds.contains(p) else {session.selectedID=nil;needsDisplay=true;return}
        origin=p
        if tool.isDrawing {stroke=[p];needsDisplay=true;return}
        if tool == .eraser {erasing=true;erase(at:p);return}
        let hit=session.element(at:p)
        // Creation tools drag out a new object; pressing on an existing one still selects and moves it.
        if tool.createsObject, hit == nil {session.selectedID=nil;creating=p;needsDisplay=true;return}
        session.selectedID=hit?.id
        startingFrame=session.selected?.frame;startingFontSize=session.selected?.fontSize ?? 28;needsDisplay=true
        window?.invalidateCursorRects(for:self)
        if event.clickCount>=2, let item=session.selected, case .text = item.content {beginText()}
    }
    override func mouseDragged(with event:NSEvent) {
        guard let session,let origin else{return}
        let raw=point(event)
        let p=CGPoint(x:min(max(raw.x,0),session.canvasBounds.maxX),y:min(max(raw.y,0),session.canvasBounds.maxY))
        if session.tool.isDrawing {stroke.append(p);needsDisplay=true;return}
        if erasing {erase(at:p);return}
        if creating != nil {creating=p;needsDisplay=true;return}
        guard let original=startingFrame else{return}
        let dx=p.x-origin.x,dy=p.y-origin.y
        guard moving || hypot(dx,dy)*scale >= 3 else {return}
        if !moving {session.checkpoint();session.beginTransform(live:resizeHandle != nil || arrowEnd != nil);moving=true}
        if let end=arrowEnd {
            if end {session.replaceLine(from:arrowAnchor,to:p)} else {session.replaceLine(from:p,to:arrowAnchor)}
            return
        }
        var frame=original
        var fontSize:CGFloat?
        if let handle=resizeHandle {
            let proportional=(session.selected?.isText == true && handle.isCorner) || event.modifierFlags.contains(.shift)
            frame=handle.resized(original,delta:CGPoint(x:dx,y:dy),proportional:proportional)
            if session.selected?.isText == true,handle.isCorner {fontSize=startingFontSize*frame.width/original.width}
        } else {
            frame.origin=CGPoint(x:original.minX+dx,y:original.minY+dy);NSCursor.closedHand.set()
        }
        frame.origin.x=min(max(0,frame.minX),max(0,session.canvasBounds.width-frame.width))
        frame.origin.y=min(max(0,frame.minY),max(0,session.canvasBounds.height-frame.height))
        session.replaceFrame(frame,fontSize:fontSize)
    }
    override func mouseUp(with event:NSEvent) {
        if !stroke.isEmpty {session?.addStroke(stroke);stroke=[];needsDisplay=true}
        if moving {session?.finishTransform()}
        if let start=origin,let end=creating {finishCreation(from:start,to:end)}
        origin=nil;startingFrame=nil;moving=false;resizeHandle=nil;arrowEnd=nil;creating=nil;erasing=false
        needsDisplay=true;window?.invalidateCursorRects(for:self)
    }
    private func finishCreation(from start:CGPoint,to end:CGPoint) {
        guard let session else {return}
        let dragged=hypot(end.x-start.x,end.y-start.y)*scale >= 4
        switch session.tool {
        case .text:
            session.insertText(centeredAt:dragged ? CGPoint(x:(start.x+end.x)/2,y:(start.y+end.y)/2) : start)
        case .arrow where dragged: session.insertShape(.line,from:start,to:end)
        case .rectangle where dragged: session.insertShape(.rectangle,from:start,to:end)
        case .ellipse where dragged: session.insertShape(.ellipse,from:start,to:end)
        default: return
        }
        session.tool = .selection
    }
    private func erase(at p:CGPoint) {
        guard let session,let hit=session.element(at:p) else {return}
        session.selectedID=hit.id;session.deleteSelection()
    }
    override func keyDown(with event:NSEvent) {
        guard let session else{return}
        if event.modifierFlags.contains(.command),event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift){session.editor?.redo()}else{session.editor?.undo()};return
        }
        if event.keyCode==51 || event.keyCode==117 {session.deleteSelection();return}
        if event.keyCode==36 {beginText();return}
        if event.keyCode==53 {session.select();session.selectedID=nil;needsDisplay=true;window?.invalidateCursorRects(for:self);return}
        if let selected=session.selected, [123,124,125,126].contains(event.keyCode) {
            session.checkpoint();let step:CGFloat=event.modifierFlags.contains(.shift) ? 10 : 1
            let dx:CGFloat=event.keyCode==123 ? -step : event.keyCode==124 ? step : 0
            let dy:CGFloat=event.keyCode==126 ? -step : event.keyCode==125 ? step : 0
            session.replaceFrame(selected.frame.offsetBy(dx:dx,dy:dy));return
        }
        super.keyDown(with:event)
    }
    func beginText() {
        guard let session,let selected=session.selected,case .text(let text)=selected.content else{return}
        commitText();session.selectedID=selected.id;session.editingID=selected.id;textBefore=text
        let editor=NSTextView(frame:displayRectForMarkup(selected.frame))
        // Match PaperKit's text inset so typed text sits where it will render.
        editor.isRichText=false;editor.drawsBackground=false;editor.textContainerInset=NSSize(width:4*scale,height:2*scale)
        editor.textContainer?.lineFragmentPadding=0;editor.isHorizontallyResizable=false;editor.isVerticallyResizable=true
        editor.font=selected.font(scale:scale);editor.textColor=selected.color;editor.insertionPointColor=selected.color
        editingMidX=selected.frame.midX
        if let fill=selected.fill {
            let tag=NSView();tag.wantsLayer=true;tag.layer?.backgroundColor=fill.cgColor
            addSubview(tag);tagView=tag
        }
        let paragraph=NSMutableParagraphStyle();paragraph.alignment=selected.alignment;paragraph.lineSpacing=selected.lineSpacing*scale
        editor.defaultParagraphStyle=paragraph;editor.alignment=selected.alignment
        editor.string=text
        editor.textStorage?.setAttributes([.font:selected.font(scale:scale),.foregroundColor:selected.color,.paragraphStyle:paragraph,.underlineStyle:selected.underline ? NSUnderlineStyle.single.rawValue : 0],range:NSRange(location:0,length:(text as NSString).length))
        editor.delegate=self;editor.allowsUndo=false
        editor.setAccessibilityLabel("Annotation text")
        textView=editor;addSubview(editor);session.rebuild();window?.makeFirstResponder(editor);editor.selectAll(nil)
        layoutText()
    }
    /// The selected text element as it would look with the text typed so far.
    private func editingElement()->ScreenshotPaperElement? {
        guard let session,var item=session.selected,let textView else {return nil}
        let text=textView.string
        item.content = .text(text)
        if item.autoTextWidth {
            let width=text.components(separatedBy:"\n").map {($0 as NSString).size(withAttributes:[.font:item.font()]).width}.max() ?? 30
            item.frame.size.width=min(max(30,ceil(width)+8),session.canvasBounds.width*0.7)
            if item.alignment == .center { item.frame.origin.x=editingMidX-item.frame.width/2 }
        }
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=item.lineSpacing
        let measured=(text as NSString).boundingRect(with:CGSize(width:max(1,item.frame.width-8),height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:item.font(),.paragraphStyle:paragraph]).height
        item.frame.size.height=max(item.frame.height,ceil(measured)+8)
        return item
    }
    func layoutText() {
        guard let item=editingElement(),let textView else{return}
        textView.frame=displayRectForMarkup(item.frame)
        textView.font=item.font(scale:scale)
        textView.textContainerInset=NSSize(width:4*scale,height:2*scale)
        if let tagView,let tagRect=item.tagRect {
            tagView.frame=displayRectForMarkup(tagRect)
            tagView.layer?.cornerRadius=min(ScreenshotPaperElement.tagCornerRadius,tagRect.height/2,tagRect.width/2)*scale
        }
    }
    func textDidChange(_ notification:Notification) {
        // Input stays in an AppKit text view until committed; the PaperKit preview omits this one element.
        textView?.needsDisplay=true;layoutText()
    }
    func textDidEndEditing(_ notification:Notification) {commitText()}
    func commitText() {
        guard let textView,let session else{return}
        let text=textView.string;let height=textView.frame.height/scale
        self.textView=nil;textView.delegate=nil;textView.removeFromSuperview();session.editingID=nil
        tagView?.removeFromSuperview();tagView=nil
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {session.deleteSelection();return}
        if text != textBefore {session.checkpoint();session.replaceText(text,height:height)}else{session.rebuild()}
    }
    func cancelText() {textView?.delegate=nil;textView?.removeFromSuperview();textView=nil;tagView?.removeFromSuperview();tagView=nil;session?.editingID=nil}
}

@available(macOS 26.0, *)
struct PaperScreenshotCanvas:NSViewControllerRepresentable {
    let session:PaperScreenshotSession
    @ObservedObject var editor:ScreenshotEditor
    func makeNSViewController(context:Context)->PaperScreenshotSession {session.update(editor:editor);return session}
    func updateNSViewController(_ controller:PaperScreenshotSession,context:Context){controller.update(editor:editor)}
}
