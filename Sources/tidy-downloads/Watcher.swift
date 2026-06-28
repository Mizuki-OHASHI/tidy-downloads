import Foundation

/// Watches a single directory (non-recursive) and fires a debounced callback
/// whenever its contents change. Uses a DispatchSource vnode source on the
/// directory's file descriptor — simple and robust for one directory.
final class Watcher {
    private let dir: URL
    private let debounce: Double
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "jp.m-ohashi.tidy-downloads.watcher")
    private var pending: DispatchWorkItem?

    init(dir: URL, debounce: Double, onChange: @escaping () -> Void) {
        self.dir = dir
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() throws {
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { throw TidyError.cannotOpenDirectory(dir.path) }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scheduleRun() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
        }
        source = src
        src.resume()

        // Catch anything already sitting in the directory at startup.
        scheduleRun()
    }

    private func scheduleRun() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
