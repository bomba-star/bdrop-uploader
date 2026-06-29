"""Konstanten und Plattform-Erkennung fuer bdrop-encode.

Alle harten Server-Fakten beziehen sich auf die CineReview/B-Drop-Admin-API.
"""

from __future__ import annotations

import platform
import shutil

# --- Server-Fakten (PLAN Abschnitt 4, gegen Live-Code geprueft) -------------

# Base-URL der CineReview/B-Drop-Admin-API. Ueberschreibbar per Env BDROP_BASE_URL.
DEFAULT_BASE_URL = "https://jonasbomba.com"

# Harte serverseitige Obergrenze fuer max_duration_seconds (Pydantic le=21600).
# Filme ueber 6h sind aktuell gar nicht uploadbar.
MAX_DURATION_HARD_CAP = 21600

# r2-stream cappt serverseitig bei 32 GiB (413 darueber). Wir warnen vorher.
R2_STREAM_MAX_BYTES = 32 * 1024 * 1024 * 1024

# Server-Semaphore fuer r2-stream ist global 2. Bei voll -> 503.
R2_STREAM_MAX_CONCURRENT = 2

# Auth-Rate-Limit: 10 Auth-Versuche pro Minute pro IP -> 429 (NICHT 401).
AUTH_RATE_LIMIT_PER_MIN = 10

# Datei-Endungen, die der Server auf den r2-Pfaden akzeptiert
# (ALLOWED_EXTENSIONS in routes_admin_versions.py). Der Server prueft nur die
# Endung, NICHT den echten Codec - die Engine ist die einzige echte Codec-Schranke.
ALLOWED_EXTENSIONS = {
    ".mp4", ".mov", ".mxf", ".avi", ".mkv", ".webm", ".m4v",
    ".mpg", ".mpeg", ".ts", ".mts", ".m2ts", ".wmv", ".flv",
    ".3gp", ".ogv", ".dv",
}

# Codecs, die proprietaere SDKs brauchen und sofort abgelehnt werden.
UNSUPPORTED_CODECS = {"r3d", "braw"}

# Codecs, die fuer Cloudflare Stream direkt tauglich sind (Smart-Remux moeglich).
CF_TAUGLICHE_CODECS = {"h264", "hevc"}

# Pixelformat, das wir fuer den CF-tauglichen Smart-Remux verlangen.
CF_TAUGLICHES_PIXFMT = "yuv420p"


# --- Encode-Qualitaet --------------------------------------------------------

QUALITY_REVIEW = "review"      # schnell, akkuschonend (HW auf Mac, libx264 fast auf Linux)
QUALITY_ARCHIVE = "archive"    # libx264 -preset slow -crf 18, maximale Qualitaet pro Bit
QUALITY_CHOICES = (QUALITY_REVIEW, QUALITY_ARCHIVE)


# --- Plattform / Encoder-Wahl ------------------------------------------------

def is_macos() -> bool:
    """True auf macOS (Darwin). Dort steht h264_videotoolbox zur Verfuegung."""
    return platform.system() == "Darwin"


def has_encoder(ffmpeg_bin: str, encoder: str) -> bool:
    """Prueft, ob ffmpeg den genannten Encoder kennt (best effort)."""
    import subprocess

    try:
        out = subprocess.run(
            [ffmpeg_bin, "-hide_banner", "-encoders"],
            capture_output=True, text=True, timeout=15,
        )
        return f" {encoder} " in out.stdout or f" {encoder}\n" in out.stdout
    except Exception:
        return False


def choose_video_encoder(ffmpeg_bin: str = "ffmpeg", force_software: bool = False) -> str:
    """Waehlt den Video-Encoder gemaess PLAN Abschnitt 5.

    - macOS und videotoolbox vorhanden und nicht force_software -> h264_videotoolbox.
    - sonst (Linux, hier) -> libx264.

    Die Kommandos werden so gebaut, dass auf dem Mac spaeter automatisch
    videotoolbox genutzt wird, hier auf Linux faellt es auf libx264 zurueck.
    """
    if not force_software and is_macos() and has_encoder(ffmpeg_bin, "h264_videotoolbox"):
        return "h264_videotoolbox"
    return "libx264"


def find_binaries() -> tuple[str, str]:
    """Findet ffmpeg und ffprobe im PATH. Wirft, wenn eines fehlt."""
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if not ffmpeg:
        raise RuntimeError("ffmpeg nicht gefunden (PATH). Bitte ffmpeg installieren.")
    if not ffprobe:
        raise RuntimeError("ffprobe nicht gefunden (PATH). Bitte ffprobe installieren.")
    return ffmpeg, ffprobe
