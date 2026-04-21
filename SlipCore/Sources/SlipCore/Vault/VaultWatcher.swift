import Foundation
import CoreServices

/// Watches a vault directory for file system changes using FSEvents.
///
/// FSEvents is the right primitive here:
/// - Recursive by default, no per-directory setup
/// - Coalesces rapid events with a latency window
/// - Works across APFS, HFS+, and iCloud Drive
/// - Low overhead — kernel-mediated, not polling
///
/// Lifecycle:
///   let watcher = VaultWatcher(root: vault.root) { changedURLs in … }
///   try watcher.start()
///   // … later …
///   watcher.stop()
///
/// Thread safety: `handler` is invoked on the main queue so consumers can
/// touch `@MainActor` state directly. Internal FSEventStream runs on a
/// dedicated dispatch queue.
public final class VaultWatcher {

    public typealias Handler = ([URL]) -> Void

    public enum WatcherError: Error {
        case couldNotCreate
    }

    private let root: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.devkoan.Slip.VaultWatcher")
    private var stream: FSEventStreamRef?

    public init(root: URL, handler: @escaping Handler) {
        self.root = root
        self.handler = handler
    }

    public func start() throws {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(clientInfo).takeUnretainedValue()

            // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray
            // of CFStrings.
            let cfPointer = UnsafeRawPointer(eventPaths)
            let cfArray = Unmanaged<CFArray>.fromOpaque(cfPointer).takeUnretainedValue()
            guard let paths = cfArray as? [String] else { return }

            let urls = paths.prefix(numEvents).map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async {
                watcher.handler(urls)
            }
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,        // 500ms coalescing — feels instant, avoids thrash on multi-file saves
            flags
        ) else {
            throw WatcherError.couldNotCreate
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        self.stream = created
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
