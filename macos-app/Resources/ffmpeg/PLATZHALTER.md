# ffmpeg / ffprobe ablegen (Platzhalter)

Dieser Ordner wird ins App-Bundle unter `Contents/Resources/ffmpeg/` kopiert.
Lege hier die beiden statischen Binaries ab, dann verschwindet dieser Platzhalter
in der Praxis (er stört den Build nicht).

## Was hier hingehoert

- `ffmpeg`  (statisch, arm64 oder universal2)
- `ffprobe` (statisch, arm64 oder universal2)

Beide müssen ausfuehrbar sein:

```
chmod +x ffmpeg ffprobe
```

Empfohlene Quelle für statische macOS-Builds: die offiziellen evermeet.cx- oder
osxexperts-Builds, oder ein eigener Build. Mit x264/x265 wird das Binary GPL
(siehe PLAN.md Abschnitt 13, Punkt 4). Für reinen Eigengebrauch egal, bei
spaeterer Weitergabe ist der GPL-Quellnachweis nötig.

Die App findet die Binaries zur Laufzeit über `Bundle.main.url(forResource:...)`
(siehe `Sources/Services/FFmpegLocator.swift`). Als Entwicklungs-Fallback, falls
hier noch nichts liegt, nutzt die App `/opt/homebrew/bin/ffmpeg` bzw.
`/opt/homebrew/bin/ffprobe`. Dieser Fallback ist NUR für die lokale Entwicklung,
nie für den Vertrieb.

## Codesigning: inside-out

Unter Hardened Runtime (Release) müssen die Binaries SEPARAT und VOR der App
signiert werden (inside-out), sonst startet der Child-Prozess nicht:

```
# 1) ffmpeg und ffprobe zuerst signieren, mit Hardened Runtime:
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: DEIN NAME (TEAMID)" \
  ffmpeg ffprobe

# 2) Danach die App-Build in Xcode signieren lassen (Release).
#    Xcode signiert das App-Bundle aussen herum.

# 3) Vor dem Vertrieb verifizieren:
codesign --verify --deep --strict --verbose=2 /Pfad/zur/BDropUploader.app
spctl --assess --type execute --verbose /Pfad/zur/BDropUploader.app
```

Hinweis: Wenn die Binaries mit einer anderen Identitaet signiert sind, sorgt das
Entitlement `com.apple.security.cs.disable-library-validation` (in
`Sources/App/BDropUploader.entitlements`) dafuer, dass sie trotzdem laufen.
