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
