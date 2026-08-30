import Foundation

struct Prefs: Codable, Equatable, Sendable {
    var voice = "minimax:Chinese (Mandarin)_Radio_Host|default"
    var rate = 50                 // 百分比整数,和界面步进器一致
    var playbackSpeed = 1.0
    var stripMarkdown = true
    var skipCode = true
    var mpvBin = "/opt/homebrew/bin/mpv"
    var ffmpegBin = "/opt/homebrew/bin/ffmpeg"
    var cacheLimitMB = 512
    var cacheDays = 14
    var launchAtLogin = false
    var menuBarOnly = false
    var hotkeyChime = true
    var hkReadSelection = HotkeySpec.readSelection
    var hkReadClipboard = HotkeySpec.readClipboard
    var hkTogglePause = HotkeySpec.togglePause

    func hotkey(_ a: HotkeyAction) -> HotkeySpec {
        switch a {
        case .readSelection: return hkReadSelection
        case .readClipboard: return hkReadClipboard
        case .togglePause: return hkTogglePause
        }
    }

    mutating func setHotkey(_ a: HotkeyAction, _ spec: HotkeySpec) {
        switch a {
        case .readSelection: hkReadSelection = spec
        case .readClipboard: hkReadClipboard = spec
        case .togglePause: hkTogglePause = spec
        }
    }
}

/// 用户数据落 ~/Library/Application Support/Aloud/。
/// 注意别跟旧版 edge-tts-app 的目录混,那是另一个 app 的数据。
enum Store {
    struct Operations: Sendable {
        let dir: URL
        let cacheDir: URL
        let runtimeDir: URL
        let read: @Sendable (URL) -> Data?
        let write: @Sendable (Data, URL) throws -> Void

        static let inMemory = Operations(
            dir: URL(fileURLWithPath: "/in-memory/store"),
            cacheDir: URL(fileURLWithPath: "/in-memory/cache"),
            runtimeDir: URL(fileURLWithPath: "/in-memory/runtime"),
            read: { _ in nil },
            write: { _, _ in }
        )
    }

    @TaskLocal private static var operationsOverride: Operations?

    static func withOperations<Value>(_ operations: Operations, operation: () throws -> Value) rethrows -> Value {
        try $operationsOverride.withValue(operations, operation: operation)
    }

    private static let resolvedDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Aloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let resolvedCacheDir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let resolvedRuntimeDir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var dir: URL {
        withPathPreviewAccessAudit(
            auditedValue: URL(fileURLWithPath: "/preview-audit/store"),
            perform: { operationsOverride?.dir ?? resolvedDir }
        )
    }

    static var cacheDir: URL {
        withPathPreviewAccessAudit(
            auditedValue: URL(fileURLWithPath: "/preview-audit/cache"),
            perform: { operationsOverride?.cacheDir ?? resolvedCacheDir }
        )
    }

    static var runtimeDir: URL {
        withPathPreviewAccessAudit(
            auditedValue: URL(fileURLWithPath: "/preview-audit/runtime"),
            perform: { operationsOverride?.runtimeDir ?? resolvedRuntimeDir }
        )
    }

    static func withPathPreviewAccessAudit<Value>(
        auditedValue: @autoclosure () -> Value,
        perform: () -> Value
    ) -> Value {
        PreviewAccessAudit.access(
            .fileManagerPathSelection,
            auditedValue: auditedValue(),
            perform: perform
        )
    }

    static func withPreviewAccessAudit<Value>(
        auditedValue: @autoclosure () -> Value,
        perform: () -> Value
    ) -> Value {
        PreviewAccessAudit.access(.store, auditedValue: auditedValue(), perform: perform)
    }

    static func load<V: Decodable>(_ name: String, default fallback: V) -> V {
        withPreviewAccessAudit(auditedValue: fallback) {
            let url = dir.appendingPathComponent(name)
            let data: Data?
            if let operationsOverride {
                data = operationsOverride.read(url)
            } else {
                data = try? Data(contentsOf: url)
            }
            guard let data,
                  let value = try? JSONDecoder().decode(V.self, from: data) else { return fallback }
            return value
        }
    }

    static func save<V: Encodable>(_ name: String, _ value: V) {
        withPreviewAccessAudit(auditedValue: ()) {
            let url = dir.appendingPathComponent(name)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try enc.encode(value)
                if let operationsOverride {
                    try operationsOverride.write(data, url)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                _ = error
                NSLog("Aloud: persistence failed")
            }
        }
    }
}

/// 诊断日志。热键和读选中出问题时,先看这个文件,别靠猜。
enum Diag {
    static let file = Store.dir.appendingPathComponent("diag.log")
    static let diagnostics = PrivacySafeDiagnostics()

    static func record(_ event: DiagnosticEvent) {
        diagnostics.record(event)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] \(PrivacySafeDiagnostics.render(event))\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            // 封顶 64KB,别让它无声无息涨成大文件
            if (try? h.seekToEnd()) ?? 0 > 64_000 {
                try? Data(entry.utf8).write(to: file, options: .atomic)
                return
            }
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }
}

enum AloudError: LocalizedError {
    case noKey
    case auth(String)
    case api(String)
    case network(String)
    case binaryMissing(String)
    case commandFailed(String, Int)

    var errorDescription: String? {
        switch self {
        case .noKey: return "还没设置 MiniMax Key，去设置里导入"
        case .auth: return "MiniMax 凭据不可用，请检查后重试"
        case .api: return "MiniMax 服务请求失败，请稍后重试"
        case .network: return "网络请求失败，请稍后重试"
        case .binaryMissing(let b): return "找不到 \(b)，在设置 → 高级里指定路径"
        case .commandFailed(let b, let c): return "\(b) 退出码 \(c)"
        }
    }
}
