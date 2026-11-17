import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class MixerRowDragPreview: ObservableObject {
    weak var rowView: NSView?
}

struct MixerRowDragSurface: NSViewRepresentable {
    let id: String
    let preview: MixerRowDragPreview
    var isRowBackground = false

    func makeNSView(context: Context) -> MixerRowDragView {
        MixerRowDragView()
    }

    func updateNSView(_ view: MixerRowDragView, context: Context) {
        view.rowID = id
        view.preview = preview
        if isRowBackground {
            preview.rowView = view
        }
    }
}

final class MixerRowDragView: NSView, NSDraggingSource {
    static let rowType = UTType(exportedAs: "com.maxo.mixer-row")

    var rowID = ""
    weak var preview: MixerRowDragPreview?
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let row = preview?.rowView else { return }
        let grabPoint = convert(down.locationInWindow, from: nil)
        let pointer = convert(event.locationInWindow, from: nil)
        let offset = CGPoint(x: pointer.x - grabPoint.x, y: pointer.y - grabPoint.y)
        guard hypot(offset.x, offset.y) >= 4, let image = Self.snapshot(of: row) else { return }
        mouseDownEvent = nil

        let payload = NSPasteboardItem()
        payload.setData(Data(rowID.utf8), forType: NSPasteboard.PasteboardType(Self.rowType.identifier))
        let item = NSDraggingItem(pasteboardWriter: payload)
        let frame = convert(row.bounds, from: row).offsetBy(dx: offset.x, dy: offset.y)
        item.setDraggingFrame(frame, contents: image)

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    static func snapshot(of row: NSView) -> NSImage? {
        guard let content = row.window?.contentView, !row.bounds.isEmpty else { return nil }
        let rect = content.convert(row.bounds, from: row)
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }
}

struct MixerRowDrop: DropDelegate {
    let target: String
    let model: MixerModel

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        let type = MixerRowDragView.rowType.identifier
        guard let item = info.itemProviders(for: [type]).first else { return false }
        item.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let id = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in model.move(id, to: target) }
        }
        return true
    }
}
