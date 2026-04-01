import Foundation

/// Watches individual config files for changes and triggers ConfigManager reloads.
///
/// Uses a polling approach (1-second interval) to detect all write patterns reliably,
/// including atomic/rename-based writes (vim, scripts) that don't update the directory entry.
/// Also watches the directory so newly-created files are picked up immediately.
final class FileWatcher {

    private let dirURL: URL
    private weak var configManager: ConfigManager?

    /// File names to watch within the config directory (state.json is our output — skip it).
    private static let watchedFiles = ["ignored_apps.json", "space_labels.json", "app_actions.json"]

    private var dirDescriptor: Int32 = -1
    private var dirSource: DispatchSourceFileSystemObject?

    private var fileDescriptors: [String: Int32] = [:]
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]

    private var pollTimer: DispatchSourceTimer?
    private var lastModDates: [String: Date] = [:]

    private var debounceWorkItem: DispatchWorkItem?

    private let queue = DispatchQueue(label: "com.spacedock.filewatcher", qos: .utility)

    init(url: URL, configManager: ConfigManager) {
        self.dirURL = url
        self.configManager = configManager
    }

    // MARK: - Start / Stop

    func start() {
        queue.async { [weak self] in
            self?.startInternal()
        }
    }

    private func startInternal() {
        // Watch the directory for new file creation (.write on dir entry)
        let fd = open(dirURL.path, O_EVTONLY)
        if fd >= 0 {
            dirDescriptor = fd
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: queue
            )
            src.setEventHandler { [weak self] in
                self?.handleChange()
            }
            src.setCancelHandler { [weak self] in
                guard let self = self, self.dirDescriptor >= 0 else { return }
                close(self.dirDescriptor)
                self.dirDescriptor = -1
            }
            src.resume()
            dirSource = src
        } else {
            NSLog("[FileWatcher] Directory not yet available, will rely on polling: %@", dirURL.path)
        }

        // Snapshot current mod dates
        snapshotModDates()

        // Per-file DispatchSource watchers for fast notification on in-place writes
        for name in Self.watchedFiles {
            openFileSource(name: name)
        }

        // Polling fallback: catches atomic/rename writes that bypass per-file kqueue events
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.pollForChanges()
        }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pollTimer?.cancel()
        pollTimer = nil
        dirSource?.cancel()
        dirSource = nil
        for src in fileSources.values { src.cancel() }
        fileSources.removeAll()
        fileDescriptors.removeAll()
    }

    deinit {
        stop()
    }

    // MARK: - Per-file DispatchSource

    private func openFileSource(name: String) {
        let fileURL = dirURL.appendingPathComponent(name)
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        fileDescriptors[name] = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let data = src.data
            if data.contains(.delete) || data.contains(.rename) {
                // Atomic write: file was replaced; close old fd and re-open after a brief pause
                self.fileSources.removeValue(forKey: name)?.cancel()
                self.fileDescriptors.removeValue(forKey: name)
                self.queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.openFileSource(name: name)
                }
            }
            self.handleChange()
        }
        src.setCancelHandler {
            close(fd)
        }
        src.resume()
        fileSources[name] = src
    }

    // MARK: - Polling

    private func snapshotModDates() {
        for name in Self.watchedFiles {
            let path = dirURL.appendingPathComponent(name).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date {
                lastModDates[name] = mod
            }
        }
    }

    private func pollForChanges() {
        for name in Self.watchedFiles {
            let path = dirURL.appendingPathComponent(name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mod = attrs[.modificationDate] as? Date else { continue }

            if lastModDates[name] != mod {
                lastModDates[name] = mod
                handleChange()
                return  // debounce will cover remaining files in same tick
            }
        }
    }

    // MARK: - Change Handling

    private func handleChange() {
        // Debounce: cancel any pending reload and schedule a new one
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.configManager?.reload()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
