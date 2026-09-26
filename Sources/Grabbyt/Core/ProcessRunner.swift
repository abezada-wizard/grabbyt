import Foundation

/// Ejecuta un binario y entrega su salida línea por línea (stdout y stderr).
public final class ProcessRunner: @unchecked Sendable {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let output: String      // stdout + stderr completo, para clasificar errores
        public let wasCancelled: Bool
    }

    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Result {
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, stream: 0) }
        errPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, stream: 1) }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                process.terminationHandler = { [lock] p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), stream: 0)
                    collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), stream: 1)
                    collector.flush()
                    lock.lock(); let wasCancelled = self.cancelled; lock.unlock()
                    cont.resume(returning: Result(exitCode: p.terminationStatus, output: collector.all, wasCancelled: wasCancelled))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: Result(exitCode: -1, output: "ERROR: no se pudo ejecutar \(executable.path): \(error.localizedDescription)", wasCancelled: false))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }
}

/// Junta bytes en líneas completas por stream y guarda todo el texto.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Int: Data] = [0: Data(), 1: Data()]
    private var lines: [String] = []
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    var all: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func append(_ data: Data, stream: Int) {
        guard !data.isEmpty else { return }
        var emitted: [String] = []
        lock.lock()
        var buffer = buffers[stream, default: Data()]
        buffer.append(data)
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line); emitted.append(line)
            }
        }
        buffers[stream] = buffer
        lock.unlock()
        emitted.forEach(onLine)
    }

    func flush() {
        var emitted: [String] = []
        lock.lock()
        for (key, buffer) in buffers where !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                lines.append(line); emitted.append(line)
            }
            buffers[key] = Data()
        }
        lock.unlock()
        emitted.forEach(onLine)
    }
}
