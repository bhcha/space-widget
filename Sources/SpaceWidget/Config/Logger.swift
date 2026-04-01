import Foundation

/// Simple file + stderr logger for SpaceWidget.
/// Writes to ~/.config/space-dock/spacewidget.log
final class Logger {
    static let shared = Logger()

    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.spacewidget.logger", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let logURL = ConfigManager.configDir.appendingPathComponent("spacewidget.log")
        // Create or truncate log file on each launch
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        self.fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        fileHandle?.closeFile()
    }

    func log(_ tag: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(tag)] \(message)\n"

        // stderr (NSLog replacement)
        NSLog("[%@] %@", tag, message)

        // file
        if let data = line.data(using: .utf8) {
            queue.async { [weak self] in
                self?.fileHandle?.write(data)
            }
        }
    }
}

/// Convenience global function
func swLog(_ tag: String, _ message: String) {
    Logger.shared.log(tag, message)
}
