import AppKit

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let file = directory.appendingPathComponent("history.plist")
let board = NSPasteboard.withUniqueName()
defer {
    board.releaseGlobally()
    try? FileManager.default.removeItem(at: directory)
}
let history = History(file: file)
let monitor = ClipboardMonitor(pasteboard: board, history: history)
for index in 1...101 {
    board.clearContents()
    precondition(board.setString("Copy \(index)", forType: .string))
    monitor.captureIfChanged()
}
precondition(history.clips.count == 100)
precondition(history.clips.last?.title == "Copy 2")
let older = history.clips[50]
precondition(monitor.restore(older))
precondition(board.string(forType: .string) == older.title)
precondition(history.clips.first == older)
precondition(history.clips.count == 100)
monitor.captureIfChanged()
precondition(history.clips.filter { $0.items == older.items }.count == 1)
history.finishSaving()
precondition(History(file: file).clips.first == older)
print("Passed sliding window, paste promotion, deduplication, and persistence.")

// Exercise saved copies through the same restore path used by the menu.
let styled = NSPasteboardItem()
let content = "Hello שלום\nSecond line"
styled.setString(content, forType: .string)
styled.setData(Data("{\\rtf1\\b Hello}".utf8), forType: .rtf)
styled.setString("<b>Hello</b>", forType: .html)
board.clearContents()
precondition(board.writeObjects([styled]))
monitor.captureIfChanged()
history.finishSaving()
let saved = History(file: file).clips[0]
precondition(monitor.restore(saved))
precondition(board.string(forType: .string) == content)
precondition(board.pasteboardItems?.first?.types == [.string])
precondition(history.clips.first == saved)

let richOnly = NSPasteboardItem()
richOnly.setData(Data("{\\rtf1\\ansi\\b Hello}".utf8), forType: .rtf)
board.clearContents()
precondition(board.writeObjects([richOnly]))
monitor.captureIfChanged()
precondition(monitor.restore(history.clips[0]))
precondition(board.string(forType: .string) == "Hello")
precondition(board.data(forType: .rtf) == nil)

board.clearContents()
precondition(board.writeObjects([NSURL(fileURLWithPath: "/tmp/copyshelf-example")]))
monitor.captureIfChanged()
precondition(monitor.restore(history.clips[0]))
precondition(board.string(forType: .fileURL) != nil)
history.finishSaving()
print("Passed plain-text restore for saved formatted copies, RTF-only content, and file references.")

// Some image sources include an empty rich-text fallback beside JPEG data.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
let imageItem = NSPasteboardItem()
let jpegType = NSPasteboard.PasteboardType("public.jpeg")
imageItem.setData(jpeg, forType: jpegType)
imageItem.setData(Data("{\\rtf1\\ansi }".utf8), forType: .rtf)
board.clearContents()
precondition(board.writeObjects([imageItem]))
monitor.captureIfChanged()
precondition(history.clips[0].title == "Image")
history.finishSaving()
let savedImage = History(file: file).clips[0]
precondition(monitor.restore(savedImage))
precondition(board.data(forType: jpegType) == jpeg)
precondition(board.string(forType: .string) == nil)
precondition(NSImage(pasteboard: board) != nil)
history.finishSaving()
print("Passed JPEG capture, image labeling, persistence, and image restoration with an RTF fallback.")

// Reproduce the empty text and RTF flavors published by Finder Quick Look.
func writeQuickLookFallback() {
    let item = NSPasteboardItem()
    item.setData(Data(), forType: .string)
    item.setData(Data("{\\rtf1\\ansi }".utf8), forType: .rtf)
    board.clearContents()
    precondition(board.writeObjects([item]))
}

let png = bitmap.representation(using: .png, properties: [:])!
let expectedImage = Clip(image: png, type: .png)
var recoveries = 0
let quickLook = ClipboardMonitor(pasteboard: board, history: history) {
    recoveries += 1
    return expectedImage
}
writeQuickLookFallback()
quickLook.captureIfChanged()
// Read the board directly, without selecting or restoring a history entry.
precondition(NSImage(pasteboard: board) != nil)
precondition(board.data(forType: .png) == png)
precondition(board.string(forType: .string) == nil)
precondition(history.clips.first == expectedImage)
quickLook.captureIfChanged()
precondition(recoveries == 1)

let selectedText = NSPasteboardItem()
selectedText.setString("Text selected in the preview", forType: .string)
selectedText.setData(Data("{\\rtf1 selected}".utf8), forType: .rtf)
board.clearContents()
precondition(board.writeObjects([selectedText]))
let before = board.changeCount
quickLook.captureIfChanged()
precondition(board.changeCount == before && recoveries == 1)
precondition(history.clips.first?.title == "Text selected in the preview")

let racing = ClipboardMonitor(pasteboard: board, history: history) {
    board.clearContents()
    precondition(board.setString("Newer copy", forType: .string))
    return expectedImage
}
writeQuickLookFallback()
racing.captureIfChanged()
precondition(board.string(forType: .string) == "Newer copy")
racing.captureIfChanged()
precondition(history.clips.first?.title == "Newer copy")
history.finishSaving()
print("Passed system clipboard image recovery, selected text, and a newer copy during recovery.")
