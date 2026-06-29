"""bdrop-encode: Referenz-Engine fuer den B-Drop Uploader.

Bildet die Pipeline Ziel A (CF-Stream-Weg) aus dem PLAN ab:
ffprobe -> Smart-Remux vs. Encode -> Upload via r2-stream -> cf-refresh-Polling.

Modular aufgebaut, damit die spaetere SwiftUI-App dieselbe Logik 1:1 nachbaut.
"""

__version__ = "0.1.0"
