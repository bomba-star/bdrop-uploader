// ProcessRunner.swift
//
// Duenne, blockierende Process-Hilfe fuer Einmal-Aufrufe (ffprobe, df).
// Fuer den lang laufenden ffmpeg-Encode mit Live-Progress nutzt EncodeService
// einen eigenen, stream-basierten Process-Lauf (nicht diesen Helper).
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import Foundation

enum ProcessRunner {

    /// Fuehrt ein Executable synchron aus und sammelt stdout/stderr vollstaendig ein.
    /// Nur fuer kurze Aufrufe gedacht (ffprobe). Liest beide Pipes nebenlaeufig,
    /// um Deadlocks bei vollen Pipe-Puffern zu vermeiden.
    static func run(executable: URL, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Nebenlaeufiges Auslesen beider Pipes, damit grosse Outputs nicht blocken.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.jonasbomba.bdropuploader.processrunner", attributes: .concurrent)

        group.enter()
        ioQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}

extension String {
    /// Liefert die letzten `maxLines` Zeilen (fuer kompakte stderr-Tails in lastError).
    func trimmedTail(maxLines: Int = 8) -> String {
        let lines = self.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return self.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.suffix(maxLines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
