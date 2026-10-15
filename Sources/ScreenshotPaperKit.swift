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
    var tagPadding:CGSize { CGSize(width:ceil(fontSize*0.3),height:ceil(fontSize*0.12)) }
    var renderOutset:CGFloat {
        if isText, fill != nil { return max(tagPadding.width,tagPadding.height)+8 }
        if case .shape(.line) = content { return 16 }
        return 8
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
        case .text(let text):
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineSpacing = lineSpacing
            if let fill {
                let pad=tagPadding
                value.insertNewShape(configuration:ShapeConfiguration(type:.roundedRectangle,fillColor:fill.cgColor,strokeColor:nil,lineWidth:0),frame:frame.insetBy(dx:-pad.width,dy:-pad.height))
            }
            let attributed = NSAttributedString(string:text,attributes:[.font:font(),.foregroundColor:color,.paragraphStyle:paragraph,.underlineStyle:underline ? NSUnderlineStyle.single.rawValue : 0])
            // Lay out lines with AppKit, then preserve their exact origins in PaperKit.
            // PaperKit centers a multiline textbox inside its frame; separate tight
            // line frames keep editing, alignment controls and export consistent.
            let storage=NSTextStorage(attributedString:attributed)
            let layout=NSLayoutManager()
            let container=NSTextContainer(size:CGSize(width:max(1,frame.width-8),height:CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding=0;layout.addTextContainer(container);storage.addLayoutManager(layout)
            layout.ensureLayout(for:container)
            layout.enumerateLineFragments(forGlyphRange:layout.glyphRange(for:container)) { _,used,_,glyphs,_ in
                let characters=layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
                let text=(attributed.string as NSString).substring(with:characters).trimmingCharacters(in:.newlines)
                guard !text.isEmpty else {return}
                let lineParagraph=NSMutableParagraphStyle();lineParagraph.alignment = .left
                let line=NSAttributedString(string:text,attributes:[.font:font(),.foregroundColor:color,.paragraphStyle:lineParagraph,.underlineStyle:underline ? NSUnderlineStyle.single.rawValue : 0])
                let width=ceil(line.size().width)+8
                let lineFrame=CGRect(x:frame.minX+used.minX,y:frame.minY+used.minY,width:max(8,width),height:max(fontSize+4,ceil(used.height)+4))
                value.insertNewTextbox(attributedText:line,frame:lineFrame)
            }
        case .shape(let shape):
            let config = ShapeConfiguration(type:shape,fillColor:nil,strokeColor:color.cgColor,lineWidth:3)
            if shape == .line { value.insertNewLine(configuration:config,from:lineStart,to:lineEnd,endMarker:true) }
            else { value.insertNewShape(configuration:config,frame:frame) }
        case .drawing(let drawing,let original):
            value.append(contentsOf:drawing)
            let sx = frame.width/max(1,original.width), sy = frame.height/max(1,original.height)
            value.transformContent(CGAffineTransform(a:sx,b:0,c:0,d:sy,tx:frame.minX-original.minX*sx,ty:frame.minY-original.minY*sy))
        }
        return value
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
            // During a resize, transform the cached PaperKit image immediately.
            // Render the final geometry once when the gesture ends.
            let original=preview.rendered?.frame.size ?? item.frame.size
            let sx=item.frame.width/max(1,original.width), sy=item.frame.height/max(1,original.height)
            let outset=preview.rendered?.renderOutset ?? item.renderOutset
            let rect=item.frame.insetBy(dx:-outset*sx,dy:-outset*sy)
            preview.view.frame=CGRect(origin:displayPoint(rect.origin),size:CGSize(width:rect.width*displayScale,height:rect.height*displayScale))
            preview.view.isHidden=item.id == editingID
        }
        if let selected {
            let rect=CGRect(origin:displayPoint(selected.frame.origin),size:CGSize(width:selected.frame.width*displayScale,height:selected.frame.height*displayScale))
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
    func beginTransform() { transformingID=selectedID;isTransforming=true }
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
    /// Text defaults to a white-on-red tag. With no origin it is centered on the canvas.
    func insertText(at origin:CGPoint? = nil) {
        focusCanvas(); checkpoint()
        let fontSize=min(28,canvas.height*0.1)
        let width=min(ceil(("Text" as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:fontSize)]).width)+8,canvas.width*0.7),height=ceil(fontSize*1.3)+4
        var frame=CGRect(x:(canvas.width-width)/2,y:(canvas.height-height)/2,width:width,height:height)
        if let origin {
            frame.origin=CGPoint(x:min(max(0,origin.x),max(0,canvas.width-width)),y:min(max(0,origin.y),max(0,canvas.height-height)))
        }
        let element=ScreenshotPaperElement(frame:frame,content:.text("Text"),color:.white,fontSize:fontSize,fill:Self.tagColor)
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
            elements[i].frame.size.width=min(max(30,ceil(width)+8),canvas.width*0.7)
        }
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=elements[i].lineSpacing
        let measured=(text as NSString).boundingRect(with:CGSize(width:max(1,elements[i].frame.width-8),height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:elements[i].font(),.paragraphStyle:paragraph]).height
        elements[i].frame.size.height=max(32,ceil(measured)+8)
        rebuild()
    }
    func deleteSelection() { guard let i=selectedIndex else {return};checkpoint();elements.remove(at:i);selectedID=nil;rebuild() }
    func element(at point:CGPoint)->ScreenshotPaperElement? {
        elements.reversed().first { $0.frame.insetBy(dx:-6/displayScale,dy:-6/displayScale).contains(point) }
    }
    func addStroke(_ points:[CGPoint]) {
        guard points.count > 1 else {return};checkpoint()
        let width:CGFloat=ink == .marker ? 14 : 3
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
        var width=x == 0.5 ? rect.width : max(30,rect.width+(x == 0 ? -delta.x : delta.x))
        var height=y == 0.5 ? rect.height : max(30,rect.height+(y == 0 ? -delta.y : delta.y))
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
            let rect=displayRectForMarkup(item.frame)
            NSColor.controlAccentColor.setStroke();let path=NSBezierPath(rect:rect);path.lineWidth=1;path.stroke()
            for handle in handles(for:item) {
                let p=handle.point(in:rect)
                let dot=NSBezierPath(ovalIn:CGRect(x:p.x-3.5,y:p.y-3.5,width:7,height:7))
                (item.isText && handle.isCorner ? NSColor.systemGreen : NSColor.controlAccentColor).setFill();dot.fill()
                NSColor.white.setStroke();dot.lineWidth=0.75;dot.stroke()
            }
        }
        if stroke.count>1 {
            session.color.setStroke();let path=NSBezierPath();path.move(to:session.displayPoint(stroke[0]))
            for p in stroke.dropFirst(){path.line(to:session.displayPoint(p))};path.lineWidth=(session.ink == .marker ? 14 : 3)*scale;path.lineCapStyle = .round;path.stroke()
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
            path=NSBezierPath();path.move(to:a);path.line(to:b)
            let angle=atan2(b.y-a.y,b.x-a.x),head=min(16*scale,hypot(b.x-a.x,b.y-a.y)*0.4)
            for side in [CGFloat.pi*0.82,-CGFloat.pi*0.82] {path.move(to:b);path.line(to:CGPoint(x:b.x+cos(angle+side)*head,y:b.y+sin(angle+side)*head))}
        default:
            NSColor.controlAccentColor.setStroke();let box=NSBezierPath(rect:rect);box.lineWidth=1;box.setLineDash([4,3],count:2,phase:0);box.stroke();return
        }
        color.setStroke();path.lineWidth=3*scale;path.lineCapStyle = .round;path.lineJoinStyle = .round;path.stroke()
    }
    private func handles(for item:ScreenshotPaperElement)->[ScreenshotResizeHandle] {
        item.isText ? [.left,.right,.bottomRight] : ScreenshotResizeHandle.allCases
    }
    private func handle(at point:CGPoint,item:ScreenshotPaperElement)->ScreenshotResizeHandle? {
        handles(for:item).first { let p=$0.point(in:item.frame);return hypot(point.x-p.x,point.y-p.y)<7/scale }
    }
    override func resetCursorRects() {
        guard let session else {return}
        if session.tool != .selection {addCursorRect(bounds,cursor:.crosshair);return}
        for item in session.elements {
            let rect=displayRectForMarkup(item.frame).intersection(bounds)
            if !rect.isNull {addCursorRect(rect,cursor:.openHand)}
        }
        if let item=session.selected {
            for handle in handles(for:item) {
                let p=handle.point(in:displayRectForMarkup(item.frame))
                addCursorRect(CGRect(x:p.x-7,y:p.y-7,width:14,height:14).intersection(bounds),cursor:handle.x == 0.5 ? .resizeUpDown : handle.y == 0.5 ? .resizeLeftRight : .crosshair)
            }
        }
    }
    override func mouseDown(with event:NSEvent) {
        guard let session, session.editor?.busy != true else{return}
        commitText();window?.makeFirstResponder(self)
        let p=point(event);moving=false;startingFrame=nil;origin=nil;creating=nil;erasing=false
        resizeHandle=nil
        let tool=session.tool
        if tool == .selection || tool.createsObject, let item=session.selected, let handle=handle(at:p,item:item) {
            resizeHandle=handle;startingFrame=item.frame;startingFontSize=item.fontSize;origin=p;return
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
        if !moving {session.checkpoint();session.beginTransform();moving=true}
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
        origin=nil;startingFrame=nil;moving=false;resizeHandle=nil;creating=nil;erasing=false
        needsDisplay=true;window?.invalidateCursorRects(for:self)
    }
    private func finishCreation(from start:CGPoint,to end:CGPoint) {
        guard let session else {return}
        let dragged=hypot(end.x-start.x,end.y-start.y)*scale >= 4
        switch session.tool {
        case .text:
            let height=ceil(min(28,session.canvasBounds.height*0.1)*1.3)+4
            session.insertText(at:dragged ? CGPoint(x:min(start.x,end.x),y:min(start.y,end.y)) : CGPoint(x:start.x,y:start.y-height/2))
        case .arrow where dragged: session.insertShape(.line,from:start,to:end)
        case .rectangle where dragged: session.insertShape(.rectangle,from:start,to:end)
        case .ellipse where dragged: session.insertShape(.ellipse,from:start,to:end)
        default: break
        }
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
        editor.isRichText=false;editor.drawsBackground=false;editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding=0;editor.isHorizontallyResizable=false;editor.isVerticallyResizable=true
        editor.font=selected.font(scale:scale);editor.textColor=selected.color
        if let fill=selected.fill {
            editor.drawsBackground=true;editor.backgroundColor=fill;editor.insertionPointColor=selected.color
            editor.wantsLayer=true;editor.layer?.cornerRadius=4*scale
        }
        let paragraph=NSMutableParagraphStyle();paragraph.alignment=selected.alignment;paragraph.lineSpacing=selected.lineSpacing*scale
        editor.defaultParagraphStyle=paragraph;editor.alignment=selected.alignment
        editor.string=text
        editor.textStorage?.setAttributes([.font:selected.font(scale:scale),.foregroundColor:selected.color,.paragraphStyle:paragraph,.underlineStyle:selected.underline ? NSUnderlineStyle.single.rawValue : 0],range:NSRange(location:0,length:(text as NSString).length))
        editor.delegate=self;editor.allowsUndo=false
        editor.setAccessibilityLabel("Annotation text")
        textView=editor;addSubview(editor);session.rebuild();window?.makeFirstResponder(editor);editor.selectAll(nil)
    }
    func layoutText() {
        guard let selected=session?.selected,let textView else{return}
        let rect=displayRectForMarkup(selected.frame)
        textView.frame=CGRect(origin:rect.origin,size:CGSize(width:rect.width,height:max(rect.height,textView.frame.height)))
        textView.font=selected.font(scale:scale)
    }
    func textDidChange(_ notification:Notification) {
        guard let textView,let session else{return}
        // Input stays in an AppKit text view until committed; the PaperKit preview omits this one element.
        textView.needsDisplay=true
        if let manager=textView.layoutManager,let container=textView.textContainer {
            manager.ensureLayout(for:container)
            let needed=max(session.selected?.frame.height ?? 32,(manager.usedRect(for:container).height+8)/scale)
            textView.setFrameSize(CGSize(width:textView.frame.width,height:needed*scale))
        }
    }
    func textDidEndEditing(_ notification:Notification) {commitText()}
    func commitText() {
        guard let textView,let session else{return}
        let text=textView.string;let height=textView.frame.height/scale
        self.textView=nil;textView.delegate=nil;textView.removeFromSuperview();session.editingID=nil
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {session.deleteSelection();return}
        if text != textBefore {session.checkpoint();session.replaceText(text,height:height)}else{session.rebuild()}
    }
    func cancelText() {textView?.delegate=nil;textView?.removeFromSuperview();textView=nil;session?.editingID=nil}
}

@available(macOS 26.0, *)
struct PaperScreenshotCanvas:NSViewControllerRepresentable {
    let session:PaperScreenshotSession
    @ObservedObject var editor:ScreenshotEditor
    func makeNSViewController(context:Context)->PaperScreenshotSession {session.update(editor:editor);return session}
    func updateNSViewController(_ controller:PaperScreenshotSession,context:Context){controller.update(editor:editor)}
}
