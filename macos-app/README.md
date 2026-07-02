# B-Drop Uploader (macOS-App)

Native SwiftUI-App (Swift 6, macOS 14+), die Videos per Drag-and-Drop entgegennimmt,
sie ffmpeg-seitig CF-tauglich macht (Smart-Remux oder H.264-Encode), in eine
persistente Queue legt und über die B-Drop/CineReview Admin-API zu Cloudflare
Stream hochlaedt (Ziel A). Uploads laufen über eine Background-URLSession weiter,
auch wenn die App geschlossen wird.

Diese Quell-Struktur setzt **Ziel A (CF-Stream-Weg)** um. **Ziel B (4K-HLS auf
R2)** ist app-seitig ebenfalls implementiert: `HLSLadderBuilder` baut die
adaptive HLS-Leiter, `R2Uploader` laedt sie SigV4-signiert in den privaten
R2-Bucket. Die serverseitige Auslieferung (`r2_hls_path`) ist teilweise live
(Track B).

---

## Wichtig: auf Linux nicht baubar, ungetestet

Dieser Code wurde auf einem Linux-VPS aus dem Editor geschrieben und konnte dort
**nicht kompiliert oder getestet werden** (Swift 6, SwiftUI, SwiftData,
Security.framework und Background-URLSession brauchen macOS/Xcode). Rechne beim
ersten Build mit kleineren Anpassungen, vor allem an:

- den Feldnamen der Server-DTOs (`ProjectDTO`, `FolderDTO`, `CreateVideoResponse`,
  `VersionResponse`) - die echten JSON-Keys der Admin-API gegenpruefen und ggf.
  in `Sources/Services/ApiClient.swift` anpassen,
- Swift-6-Strict-Concurrency-Warnungen rund um die `@Sendable`-Closures und den
  `UploadService`-Delegate (kann je nach Xcode-Version ein paar Annotationen
  verlangen),
- dem genauen Verhalten von `URL(resolvingBookmarkData:)` mit `.withSecurityScope`
  ausserhalb der Sandbox.

Die Architektur, die Endpoint-Pfade, die Limits und die ffmpeg-Befehle folgen 1:1
dem verifizierten Plan.

---

## Build-Schritte auf dem Mac (5 Zeilen)

```
brew install xcodegen ffmpeg          # XcodeGen + (fuer den Entwicklungs-Fallback) ffmpeg
cd macos-app && xcodegen generate      # erzeugt BDropUploader.xcodeproj aus project.yml
cp $(which ffmpeg) $(which ffprobe) Resources/ffmpeg/   # statische Binaries ins Bundle legen (siehe PLATZHALTER.md)
open BDropUploader.xcodeproj           # in Xcode oeffnen, Signing-Team im Target setzen
# dann in Xcode: Scheme BDropUploader -> Run
```

Hinweis: Für den Vertrieb (DMG) statt der Homebrew-Binaries echte **statische**
ffmpeg/ffprobe-Builds ablegen und inside-out signieren (siehe
`Resources/ffmpeg/PLATZHALTER.md`). Für den ersten Run reicht der
Homebrew-Fallback unter `/opt/homebrew/bin`.

Beim ersten Start: Einstellungen öffnen (Cmd-,), Admin-Bearer-Token eintragen
(landet in der Keychain), Zielprojekt/-ordner wählen, dann Videos in das
Hauptfenster ziehen.

---

## Erststart mit dem CI-Artifact (unsigniert)

Der GitHub-Actions-Workflow (`macos-build.yml`) baut die App unsigniert und
nicht notarisiert. macOS versieht heruntergeladene Dateien mit dem
Quarantäne-Attribut; Gatekeeper verweigert unsignierten Apps dann den Start
(Meldung "beschädigt" oder "kann nicht überprüft werden"). Deshalb:

1. Im Actions-Lauf das Artifact **`BDropUploader-app`** herunterladen und
   entpacken (ergibt `BDropUploader.app`).
2. Quarantäne entfernen:

   ```
   xattr -dr com.apple.quarantine "BDropUploader.app"
   ```

3. Danach normal per Doppelklick starten und wie oben Token/Projekt einrichten.

---

## Datei-zu-PLAN.md-Mapping

| Datei | PLAN.md-Abschnitt | Rolle |
|---|---|---|
| `project.yml` | 3, 12 (M0) | XcodeGen-Definition, ein App-Target, Sandbox aus, Hardened Runtime im Release |
| `Sources/App/BDropUploaderApp.swift` | 10, 11 | App-Entry (@main), verdrahtet alle Dienste, startet Crash-Recovery |
| `Sources/App/AppConfig.swift` | 4, 5 | Base-URL, Limits (6h/21600, ~10 GB r2-stream, 32 GiB r2-init), Encode-Defaults |
| `Sources/App/Info.plist` / `.entitlements` | 3 | Bundle-Metadaten, Entitlements für ffmpeg-Child unter Hardened Runtime |
| `Sources/Models/QueueItem.swift` | 8 | SwiftData @Model mit allen Feldern inkl. Idempotenz-Klammer |
| `Sources/Models/ItemStatus.swift` | 2, 8 | Status-Enum, Ziel A/B, Encode-Qualität (deutsche Labels) |
| `Sources/Models/EncodeSettings.swift` | 5, 8 | Eingefrorener Encode-Plan-Snapshot (JSON-persistiert) |
| `Sources/Services/ProbeService.swift` | 5, 4, 10 | ffprobe, Klassifikation tauglich/encode/ablehnen (einzige Codec-Schranke) |
| `Sources/Services/EncodeService.swift` | 5, 8, 9, 10 | ffmpeg-Befehlsbau, -progress-Parsing, ein Slot, VideoToolbox-Fallback |
| `Sources/Services/HLSLadderBuilder.swift` | 6, 7 | Ziel B: adaptive 4K-HLS-Leiter (ffmpeg-Argumentbau) |
| `Sources/Services/R2Uploader.swift` | 6, 7 | Ziel B: SigV4-Upload der HLS-Leiter in den privaten R2-Bucket |
| `Sources/Services/ApiClient.swift` | 4, 7, 9, 10 | Admin-REST-Wrapper, Bearer, 401/429/503-Unterscheidung |
| `Sources/Services/UploadService.swift` | 7, 8, 10 | r2-stream via Background-URLSession, cf-refresh-Backoff, Re-Attach |
| `Sources/Services/TokenStore.swift` | 4, 10 | Admin-Token (+ optionale R2-Creds) in der Keychain |
| `Sources/Services/QueueStore.swift` | 8, 9, 11 | @Observable Orchestrator, zwei Stufen, Crash-Recovery, Idempotenz |
| `Sources/Services/FFmpegLocator.swift` | 10 | Binary-Aufloesung Bundle -> Homebrew-Fallback |
| `Sources/Services/ProcessRunner.swift` | 5, 10 | Process-Helfer für kurze Aufrufe (ffprobe) |
| `Sources/Views/ContentView.swift` | 10, 11 | Hauptfenster, Token-Banner, Drop-Zone + Queue |
| `Sources/Views/DropZoneView.swift` | 10, 11 | .onDrop, Security-Scoped Bookmarks, Item-Erzeugung |
| `Sources/Views/QueueListView.swift` | 10 | Zeile pro Item: Name, Phase-Badge, Progress, Retry/Pause/Remove |
| `Sources/Views/SettingsView.swift` | 10 | Token-Eingabe, Default-Qualität, Projekt/Ordner-Dropdown |
| `Resources/ffmpeg/PLATZHALTER.md` | 3, 10, 13 | Anleitung: Binaries ablegen + inside-out signieren |

---

## Was bewusst noch fehlt (Caveats)

- **Ziel B (4K-HLS auf R2):** app-seitig implementiert (Leiter + R2-Upload);
  die serverseitige Auslieferung (`r2_hls_path` im Player) ist erst teilweise
  live - die Aktivierung setzt die App deshalb nur best effort.
- **Multipart-Fallback (r2-init/r2-complete):** für Dateien über ~10 GB. Nur
  TODO-Stub in `ApiClient`/`UploadService`. Default-Pfad ist r2-stream.
- **HDR/Rec.2020-Tonemapping:** kein Default. HEVC-10-bit-Quellen werden nach
  yuv420p 8-bit gezwungen, ohne korrektes Tonemapping (PLAN.md Abschnitt 13.1).
- **Server-DTO-Felder ungeprueft:** die JSON-Keys sind defensiv geraten und beim
  ersten echten Call zu verifizieren.
- **MenuBarExtra:** als TODO auskommentiert in `BDropUploaderApp.swift`.
