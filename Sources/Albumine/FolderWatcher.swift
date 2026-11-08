import CoreServices
import Foundation

/// Watches the tracked folders (FSEvents) and reports when photos or videos
/// appear, disappear or are renamed. XMP, Picasa and hidden files are ignored.
final class FolderWatcher {
    /// Object handed to FSEvents (retained by the stream, released with it).
    private final class Handler {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping () -> Void) {
        guard !paths.isEmpty else { return }
        let handler = Unmanaged.passRetained(Handler(onChange))
        var context = FSEventStreamContext(
            version: 0, info: handler.toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<Handler>.fromOpaque(info).release() }
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes, paths arrive as a CFArray of CFString.
            let list = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            var relevant = false
            for i in 0..<min(count, list.count) {
                let path = list[i]
                if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                let isDir = flags[i] & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                let ext = (path as NSString).pathExtension.lowercased()
                if isDir || PhotoScanner.allExtensions.contains(ext) { relevant = true; break }
            }
            if relevant { DispatchQueue.main.async { handler.onChange() } }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                          FSEventStreamCreateFlags(flags)) else {
            handler.release()
            return
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream) // also releases the Handler (the context's "release" callback)
        }
    }
}
