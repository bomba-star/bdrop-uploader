// EncodeService.swift
//
// Baut den ffmpeg-Befehl gemaess PLAN.md Abschnitt 5 und startet ffmpeg via Process.
// Parst `-progress pipe:1 -nostats` (out_time_us gegen die geprobte Dauer -> Prozent).
// Ein serieller Encode-Slot (vom QueueStore erzwungen). SIGSTOP/SIGCONT-Pause optional.
// Setzt PLAN.md Abschnitt 5 (ffmpeg-Templates), Abschnitt 8 (ein Slot) und 10 (EncodeService) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import Foundation

/// Resultat eines Encode-Laufs.
struct EncodeOutput: Sendable {
    /// Pfad der erzeugten Datei im Scratch.
    var outputURL: URL
    /// Der tatsaechlich angewandte Plan (kann durch VideoToolbox-Fallback abweichen).
    var appliedSettings: EncodeSettings
}

enum EncodeError: LocalizedError {
    case binaryNotFound
    case nonZeroExit(code: Int32, stderrTail: String)
    case cancelled
    case scratchUnavailable

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "ffmpeg wurde nicht gefunden (weder im Bundle noch unter /opt/homebrew/bin)."
        case .nonZeroExit(let code, let tail):
            return "ffmpeg endete mit Code \(code): \(tail)"
        case .cancelled:
            return "Encode wurde abgebrochen."
        case .scratchUnavailable:
            return "Der Scratch-Ordner konnte nicht angelegt werden."
        }
    }
}

/// Encodiert eine Quelle in einen CF-tauglichen H.264-Master (Ziel A).
///
/// Der Aufrufer (QueueStore) garantiert die Serialitaet (genau ein aktiver Slot).
/// Diese Klasse ist ein Aktor, damit der laufende Process-Handle threadsicher
/// gestoppt/fortgesetzt/abgebrochen werden kann.
actor EncodeService {

    private var currentProcess: Process?
    /// Vom Cancel gesetzt: unterscheidet einen gewollten Abbruch von echten Fehlern.
    /// ffmpeg faengt SIGTERM ab und endet teils mit Code 1 (nicht 15) - deshalb
    /// reicht die Signal-Code-Pruefung allein nicht aus (Fix 1).
    private var cancelRequested = false

    // MARK: - Plan-Auswahl

    /// Leitet aus dem Probe-Ergebnis und der Nutzer-Wunschqualitaet den Encode-Plan ab.
    /// (PLAN.md Abschnitt 5: smart statt stur)
    static func plan(for probe: ProbeResult, quality: EncodeQuality) -> EncodeSettings {
        let compatible: Bool = {
            if case .compatible = probe.classification { return true }
            return false
        }()
        // MP4-native Audio-Codecs koennen ohne Neucodierung in den MP4-Container.
        // Alles andere (z.B. pcm_*, opus, vorbis, dts) muss beim Remux nach AAC (Fix 9).
        let mp4NativeAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]
        let audioTranscode = probe.audioCodec.map { !mp4NativeAudio.contains($0.lowercased()) } ?? false
        // Smart-Remux nur, wenn die Quelle tauglich ist UND die Stufe keine
        // Skalierung verlangt (z.B. 4K-Master). Sonst echter Encode mit Cap.
        if compatible && quality.allowRemux {
            let tag = probe.codec == "hevc" ? "hvc1" : "avc1"
            return EncodeSettings(plan: .smartRemux, quality: quality, sourceWasCompatible: true, videoTag: tag, audioNeedsTranscode: audioTranscode)
        }
        let plan: EncodePlan = quality.usesHardware ? .hardwareH264 : .softwareX264
        return EncodeSettings(plan: plan, quality: quality, sourceWasCompatible: compatible, videoTag: "avc1", audioNeedsTranscode: audioTranscode)
    }

    /// Liefert das -vf-Scale-Argument fuer die Aufloesungs-Obergrenze der Stufe.
    /// Skaliert nur herunter (min(maxW,iw)), nie hoch.
    private static func scaleArgs(for quality: EncodeQuality) -> [String] {
        guard let w = quality.maxWidth else {
            // Auch ohne Cap (archiveBest) beide Dimensionen auf gerade Werte
            // truncaten: libx264 mit yuv420p scheitert hart an ungeraden Quell-
            // massen, und archiveBest hat keinen Hardware-Fallback (Fix H3).
            // Fuer gerade Quellen reicht scale die Frames unveraendert durch
            // (Passthrough), es gibt keinen Qualitaetsverlust.
            return ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        }
        // Breite auf gerade Zahl abrunden (trunc(.../2)*2), sonst scheitern manche
        // Encoder / yuv420p an ungerader Breite (Fix 5).
        return ["-vf", "scale='trunc(min(\(w),iw)/2)*2':-2:flags=lanczos"]
    }

    // MARK: - ffmpeg-Argumente (PLAN.md Abschnitt 5)

    /// Baut die ffmpeg-Argumentliste fuer den gegebenen Plan.
    static func arguments(input: URL, output: URL, settings: EncodeSettings) -> [String] {
        // Gemeinsame Progress-Flags. -progress auf stdout, -nostats unterdrueckt das
        // normale stderr-Geplapper. -y ueberschreibt den (von uns kontrollierten) Output.
        let progress = ["-progress", "pipe:1", "-nostats", "-y"]

        switch settings.plan {
        case .smartRemux:
            // Schneller Faststart-Remux ohne Generationsverlust (PLAN.md Abschnitt 5).
            // Video immer kopieren; Audio nur kopieren, wenn es MP4-nativ ist, sonst
            // nach AAC umcodieren - `-c copy` wuerde inkompatibles Audio mitschleppen (Fix 6).
            let audioArgs: [String] = settings.audioNeedsTranscode
                ? ["-c:a", "aac", "-b:a", AppConfig.audioBitrate]
                : ["-c:a", "copy"]
            // Akkumulator statt langer +-Kette: vermeidet den Swift-Type-Checker-Timeout.
            var args: [String] = ["-i", input.path, "-c:v", "copy"]
            args += audioArgs
            args += ["-movflags", "+faststart", "-tag:v", settings.videoTag]
            args += progress
            args.append(output.path)
            return args

        case .hardwareH264:
            // Review-Master, Hardware, akkuschonend. Optionaler Aufloesungs-Cap.
            return ["-i", input.path]
                + scaleArgs(for: settings.quality)
                + ["-c:v", "h264_videotoolbox", "-profile:v", "high",
                   "-q:v", "\(AppConfig.videotoolboxQuality)", "-pix_fmt", "yuv420p",
                   "-tag:v", "avc1",
                   "-c:a", "aac", "-b:a", AppConfig.audioBitrate,
                   "-movflags", "+faststart"]
                + progress
                + [output.path]

        case .softwareX264:
            // Software, maximale Qualitaet pro Bit. Optionaler Aufloesungs-Cap.
            return ["-i", input.path]
                + scaleArgs(for: settings.quality)
                + ["-c:v", "libx264", "-preset", "slow", "-crf", "\(AppConfig.x264CRF)",
                   "-pix_fmt", "yuv420p",
                   "-tag:v", "avc1",
                   "-c:a", "aac", "-b:a", AppConfig.audioBitrate,
                   "-movflags", "+faststart"]
                + progress
                + [output.path]

        case .hlsLadder:
            // HLS laeuft ueber encodeHLS()/HLSLadderBuilder, nicht ueber arguments() (Fix 4).
            assertionFailure("hlsLadder nutzt encodeHLS, nicht arguments()")
            return []
        }
    }

    // MARK: - Ausfuehrung mit Live-Progress

    /// Fuehrt den Encode aus. `onProgress` liefert 0.0..1.0 (auf Basis der geprobten Dauer).
    /// Wirft EncodeError bei Nicht-Null-Exit, mit automatischem libx264-Fallback,
    /// wenn h264_videotoolbox scheitert (PLAN.md Abschnitt 9: VideoToolbox-Fehler).
    func encode(
        input: URL,
        scratchDir: URL,
        itemID: UUID,
        durationSeconds: Double,
        settings: EncodeSettings,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> EncodeOutput {

        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let output = scratchDir.appendingPathComponent("\(itemID.uuidString).mp4")
        // Vorherigen Teil-Output verwerfen (ffmpeg ist nicht frame-resumierbar).
        try? FileManager.default.removeItem(at: output)

        do {
            try await runFFmpegArgs(Self.arguments(input: input, output: output, settings: settings), durationSeconds: durationSeconds, onProgress: onProgress)
            return EncodeOutput(outputURL: output, appliedSettings: settings)
        } catch EncodeError.nonZeroExit(let code, let tail) where settings.plan == .hardwareH264 {
            // VideoToolbox-Fehler (exotisches Pixelformat) -> Fallback auf libx264.
            var fallback = settings
            fallback.plan = .softwareX264
            try? FileManager.default.removeItem(at: output)
            do {
                try await runFFmpegArgs(Self.arguments(input: input, output: output, settings: fallback), durationSeconds: durationSeconds, onProgress: onProgress)
                return EncodeOutput(outputURL: output, appliedSettings: fallback)
            } catch {
                // Wenn auch der Fallback scheitert, den urspruenglichen Fehler weiterreichen.
                throw EncodeError.nonZeroExit(code: code, stderrTail: tail)
            }
        }
    }

    /// Encodiert die Quelle in eine lokale adaptive HLS-Leiter (Ziel B, 4K).
    /// Ausgabe ist ein Ordner <id>-hls/ mit master.m3u8 + pro Sprosse einem
    /// Unterordner (init.mp4 + seg_*.m4s + index.m3u8). yuv420p 8-bit, AAC.
    func encodeHLS(
        input: URL,
        scratchDir: URL,
        itemID: UUID,
        durationSeconds: Double,
        sourceWidth: Int,
        hasAudio: Bool,
        maxWidth: Int? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let outputDir = scratchDir.appendingPathComponent("\(itemID.uuidString)-hls", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        // ffmpeg legt die Varianten-Unterordner nicht selbst an.
        for name in HLSLadderBuilder.variantNames(forSourceWidth: sourceWidth, maxWidth: maxWidth) {
            try FileManager.default.createDirectory(
                at: outputDir.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let args = HLSLadderBuilder.ffmpegArguments(
            input: input, outputDir: outputDir, sourceWidth: sourceWidth, hasAudio: hasAudio, maxWidth: maxWidth)
        try await runFFmpegArgs(args, durationSeconds: durationSeconds, onProgress: onProgress)
        return outputDir
    }

    /// Startet ffmpeg mit beliebigen Argumenten, liest stdout zeilenweise und parst
    /// die -progress-Eintraege. Gemeinsam genutzt vom Einzeldatei- und HLS-Pfad.
    private func runFFmpegArgs(
        _ args: [String],
        durationSeconds: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        cancelRequested = false
        let ffmpeg = try FFmpegLocator.ffmpegURL()

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        currentProcess = process

        // stderr im Hintergrund einsammeln (fuer den Fehler-Tail).
        let stderrActor = StderrCollector()

        try process.run()

        // Handler ERST nach erfolgreichem run() setzen, sonst bleibt bei einem
        // run()-Throw ein readabilityHandler am FileHandle haengen (Fix 3).
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                Task { await stderrActor.append(s) }
            }
        }

        // stdout zeilenweise lesen und out_time_us extrahieren.
        // ffmpeg schreibt -progress als key=value-Bloecke, getrennt durch
        // Zeilen "progress=continue" bzw. "progress=end".
        let durationUs = max(durationSeconds, 0.001) * 1_000_000
        await readProgress(from: stdoutPipe.fileHandleForReading, durationUs: durationUs, onProgress: onProgress)

        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        // Cancel hat Vorrang: ffmpeg faengt SIGTERM ab und endet teils mit Code 1,
        // deshalb am gemerkten Cancel-Wunsch festmachen, nicht nur am Signal (Fix 1).
        if cancelRequested {
            cancelRequested = false
            throw EncodeError.cancelled
        }

        let code = process.terminationStatus
        if code != 0 {
            let tail = await stderrActor.tail()
            // Signal-Exit (SIGTERM/SIGKILL) OHNE Nutzer-Cancel ist ein echter Fehler,
            // z.B. ein OOM-Kill durch macOS - kein .cancelled. Nur so greift der
            // VideoToolbox-zu-libx264-Fallback in encode(), und das Item landet nicht
            // in einer stillen Requeue-Schleife (Fix K3). Der echte Nutzer-Cancel ist
            // oben bereits ueber cancelRequested abgefangen.
            if code == 15 || code == 9 {
                let hint = "ffmpeg wurde vom System beendet (Exit-Code \(code))."
                let combined = tail.isEmpty ? hint : "\(hint) \(tail)"
                throw EncodeError.nonZeroExit(code: code, stderrTail: combined)
            }
            throw EncodeError.nonZeroExit(code: code, stderrTail: tail)
        }
        onProgress(1.0)
    }

    /// Liest den -progress-Stream zeilenweise und ruft onProgress mit 0..1.
    private func readProgress(
        from handle: FileHandle,
        durationUs: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async {
        var buffer = Data()
        // bytes(of:) gibt es nicht fuer FileHandle synchron; wir lesen blockweise.
        // availableData blockt bis Daten da sind und liefert leer bei EOF.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF
                    buffer.append(chunk)

                    // Vollstaendige Zeilen verarbeiten.
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                        buffer.removeSubrange(buffer.startIndex...nl)
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        if let us = Self.parseOutTimeUs(line) {
                            let pct = min(max(us / durationUs, 0), 0.999)
                            onProgress(pct)
                        }
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Extrahiert out_time_us aus einer -progress-Zeile, falls vorhanden.
    static func parseOutTimeUs(_ line: String) -> Double? {
        // Format: "out_time_us=12345678"
        guard line.hasPrefix("out_time_us=") else { return nil }
        let value = line.dropFirst("out_time_us=".count).trimmingCharacters(in: .whitespaces)
        // ffmpeg liefert gelegentlich "N/A" am Anfang.
        return Double(value)
    }

    // MARK: - Smart-Thumbnail (Poster-Frame)

    /// Extrahiert einen einzelnen Frame als JPG (Poster). Best effort: liefert nil,
    /// wenn ffmpeg fehlt oder der Frame nicht erzeugt werden konnte. Der blockierende
    /// ffmpeg-Lauf wird auf eine Hintergrund-Queue ausgelagert, damit der Aktor-Thread
    /// waehrend waitUntilExit() nicht blockiert (Fix 2).
    func generateThumbnail(input: URL, scratchDir: URL, itemID: UUID, atSeconds: Double) async -> URL? {
        guard let ffmpeg = try? FFmpegLocator.ffmpegURL() else { return nil }
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let out = scratchDir.appendingPathComponent("\(itemID.uuidString)-thumb.jpg")
        try? FileManager.default.removeItem(at: out)

        let args = [
            "-ss", String(format: "%.2f", max(0, atSeconds)),
            "-i", input.path,
            "-frames:v", "1",
            "-vf", "scale=480:-2",
            "-y", out.path,
        ]

        // Den blockierenden Prozess auf eine Utility-Queue auslagern; der Aktor gibt
        // seinen Thread waehrend des await frei (Fix 2). Alle gefangenen Werte
        // (ffmpeg, args, out) sind Sendable.
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = ffmpeg
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let ok = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path)
                continuation.resume(returning: ok ? out : nil)
            }
        }
    }

    // MARK: - Pause / Resume / Cancel

    /// Encode-Pause ueber SIGSTOP (Fix H8, vom QueueStore.pause() gerufen).
    /// Der laufende encode()-await haengt dann einfach; das Progress-Lesen
    /// blockt derweil in availableData. Fortsetzen via resume().
    func pause() {
        guard let pid = currentProcess?.processIdentifier else { return }
        kill(pid, SIGSTOP)
    }

    /// Encode fortsetzen ueber SIGCONT (Fix H8, vom QueueStore.retry() gerufen).
    func resume() {
        guard let pid = currentProcess?.processIdentifier else { return }
        kill(pid, SIGCONT)
    }

    /// Harter Abbruch (Item geht zurueck auf queued, Teil-Output wird verworfen).
    /// Ein per SIGSTOP pausierter Prozess bekommt SIGTERM nicht zugestellt und
    /// bliebe im T-State haengen - deshalb vor terminate() SIGCONT senden (Fix K4).
    /// Reagiert ffmpeg nicht binnen ~5 Sekunden, eskaliert ein Hintergrund-Task
    /// auf SIGKILL, ohne den Aktor zu blockieren.
    func cancel() {
        cancelRequested = true
        guard let process = currentProcess else { return }
        let pid = process.processIdentifier
        kill(pid, SIGCONT)
        process.terminate()
        // Eskalation: nur die Sendable-PID in den Task fangen, die Pruefung
        // laeuft actor-isoliert in escalateKill.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.escalateKill(pid: pid)
        }
    }

    /// SIGKILL-Eskalation nach einem Cancel: nur wenn der aktuelle Prozess noch
    /// derselbe ist und weiterhin laeuft (sonst hat SIGTERM bereits gewirkt).
    private func escalateKill(pid: pid_t) {
        guard let process = currentProcess,
              process.processIdentifier == pid,
              process.isRunning else { return }
        kill(pid, SIGKILL)
    }
}

/// Kleiner Aktor, der stderr-Fragmente sammelt und am Ende den Tail liefert.
private actor StderrCollector {
    private var buffer = ""
    func append(_ s: String) { buffer += s }
    func tail() -> String { buffer.trimmedTail() }
}
