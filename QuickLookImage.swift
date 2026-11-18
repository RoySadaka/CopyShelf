import AppKit
import UniformTypeIdentifiers

enum QuickLookImage {
    // Quick Look's Live Text layer can publish empty text for Command-C.
    // Recover only the single image whose filename matches the visible preview.
    static func capture() throws -> Clip? {
        guard AXIsProcessTrusted(),
              let finder = NSWorkspace.shared.frontmostApplication,
              finder.bundleIdentifier == "com.apple.finder" else { return nil }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let preview = windows.first(where: {
            attribute($0, kAXSubroleAttribute) as? String == "Quick Look"
                || attribute($0, kAXTitleAttribute) as? String == "Quick Look"
        }), let name = previewFilename(preview, depth: 0) else { return nil }

        guard let window = windows.first(where: {
            attribute($0, kAXMainAttribute) as? Bool == true
        }) else { return nil }
        let candidates = selectedURLs(window, depth: 0).filter {
            $0.lastPathComponent == name
        }
        let unique = Set(candidates)
        guard unique.count == 1, let url = unique.first else { return nil }
        return try readImage(at: url)
    }

    struct FolderAccessError: Error {
        let folder: String

        init?(reading url: URL, error: NSError) {
            let denied = (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code))
            guard denied else { return nil }

            let path = url.standardizedFileURL.path
            for directory in [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory] {
                if let root = FileManager.default.urls(for: directory, in: .userDomainMask).first,
                   path.hasPrefix(root.standardizedFileURL.path + "/") {
                    folder = root.lastPathComponent
                    return
                }
            }
            return nil
        }
    }

    static func readImage(at url: URL) throws -> Clip? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= Clip.byteLimit else { return nil }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: Clip.byteLimit + 1),
                  data.count <= Clip.byteLimit, NSImage(data: data) != nil else { return nil }
            return Clip(image: data, type: type)
        } catch {
            if let denial = FolderAccessError(reading: url, error: error as NSError) { throw denial }
            return nil
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func previewFilename(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        if let identifier = attribute(element, kAXIdentifierAttribute) as? String,
           identifier.hasPrefix("Image Preview: ") {
            return String(identifier.dropFirst("Image Preview: ".count))
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let name = previewFilename(child, depth: depth + 1) { return name }
        }
        return nil
    }

    private static func selectedURLs(_ element: AXUIElement, depth: Int) -> [URL] {
        guard depth < 8 else { return [] }
        for key in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
            guard let selected = attribute(element, key) as? [AXUIElement] else { continue }
            if selected.count > 1 { return [] }
            if let single = selected.first {
                let urls = fileURLs(single, depth: 0)
                if !urls.isEmpty { return urls }
            }
            // A row container can have thousands of unselected children.
            if key == kAXSelectedRowsAttribute { return [] }
        }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .flatMap { selectedURLs($0, depth: depth + 1) }
    }

    private static func fileURLs(_ element: AXUIElement, depth: Int) -> [URL] {
        guard depth < 5 else { return [] }
        if let url = attribute(element, kAXURLAttribute) as? URL, url.isFileURL { return [url] }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .flatMap { fileURLs($0, depth: depth + 1) }
    }
}
