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
