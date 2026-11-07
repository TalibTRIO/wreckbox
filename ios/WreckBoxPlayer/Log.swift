import Foundation
import os

/// The test log: shown on screen and appended to Documents/test.log, which the Mac reads over the cable
/// (`xcrun devicectl device copy from … --domain-type appDataContainer`).
@MainActor
final class Log: ObservableObject {
    static let shared = Log()
    @Published private(set) var lines: [String] = []

    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("test.log")
    private let os = Logger(subsystem: "local.wreckbox.player", category: "test")
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func write(_ s: String) {
        let line = "\(clock.string(from: Date())) \(s)"
        os.log("\(line, privacy: .public)")
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: file)
        }
    }
}
