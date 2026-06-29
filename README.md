# B-Drop Uploader

Native macOS-App, die Videos lokal **umwandelt** (ffmpeg) und in den
B-Drop / CineReview Player hochlaedt. Zwei Pipelines:

- **Ziel A (Standard):** Smart-Remux oder H.264-Encode -> Upload zu Cloudflare
  Stream (Review-Flow, 1080p). Code-komplett im Skelett, noch nie gebaut.
- **Ziel B (4K-HLS):** Lokale adaptive HLS-Ladder (4K) -> Upload zu R2,
  Auslieferung über Cloudflare Worker. **Aktuell nur Platzhalter**
  (`macos-app/Sources/Services/HLSLadderBuilder.swift`), hängt zusaetzlich an
  der R2-HLS-Serverpipeline.

> Die Umwandlung ist Kernfunktion, nicht nur der Upload: `ProbeService` (ffprobe)
> + `EncodeService` (ffmpeg) erledigen Ziel A; `HLSLadderBuilder` ist für die
> 4K->HLS-Umwandlung (Ziel B) vorgesehen und muss noch ausprogrammiert werden.

## Stand

- **Architektur:** modulare Python-Referenz-Engine plus native macOS-App.
- **macOS-App:** SwiftUI + SwiftData (Swift 6, macOS 14+), XcodeGen-Setup. Skelett
  vollstaendig, aber auf Linux geschrieben und **nie auf einem Mac kompiliert**.
- **Referenz-Engine (`engine/`):** Python-CLI, auf Linux bis Dry-Run verifiziert.

## CI

`.github/workflows/macos-build.yml` baut die App auf einem gehosteten
macOS-Runner (Debug, **unsigniert**) - ein reiner Compile-Smoke-Test, um die
Fehler des nie-gebauten Codes iterativ abzuraeumen. Manuell ausloesbar
(`workflow_dispatch`) oder bei Push auf `macos-app/**`.

```
gh workflow run "macOS Build (Compile Smoke Test)"
```

## Lokal auf dem Mac bauen

```
brew install xcodegen ffmpeg
cd macos-app && xcodegen generate
cp "$(which ffmpeg)" "$(which ffprobe)" Resources/ffmpeg/   # nur fuer echten Lauf
open BDropUploader.xcodeproj
```

Details: `macos-app/README.md`.
