"""ProbeService: liest den echten Codec, das Pixelformat, die Bittiefe, die
Aufloesung und die Dauer mit ffprobe (NICHT nur die Datei-Endung) und
klassifiziert die Quelle: tauglich (Smart-Remux) vs. encode-noetig vs. ablehnen.

Spiegelt PLAN Abschnitt 5 und 10 (ProbeService).
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import config


class ProbeError(RuntimeError):
    """Wird geworfen, wenn ffprobe die Datei nicht lesen kann."""


@dataclass
class ProbeResult:
    """Strukturiertes Ergebnis eines ffprobe-Laufs auf der Eingabedatei."""

    path: str
    video_codec: str | None
    pix_fmt: str | None
    bit_depth: int | None        # 8, 10, 12 ... abgeleitet aus pix_fmt
    width: int | None
    height: int | None
    duration_seconds: float | None
    audio_codec: str | None
    container_format: str | None
    size_bytes: int | None
    raw: dict = field(default_factory=dict, repr=False)

    # Klassifikation
    decision: str = "encode"     # "remux" | "encode" | "reject"
    reject_reason: str | None = None

    @property
    def is_8bit_420(self) -> bool:
        return self.bit_depth == 8 and self.pix_fmt == config.CF_TAUGLICHES_PIXFMT

    @property
    def is_cf_tauglicher_codec(self) -> bool:
        return (self.video_codec or "") in config.CF_TAUGLICHE_CODECS


# pix_fmt -> Bittiefe. Liste deckt die in der Praxis relevanten Formate ab.
_PIXFMT_BITDEPTH = {
    "yuv420p": 8, "yuvj420p": 8, "yuv422p": 8, "yuvj422p": 8,
    "yuv444p": 8, "nv12": 8, "nv21": 8, "rgb24": 8, "bgr24": 8,
    "gbrp": 8,
    "yuv420p10le": 10, "yuv422p10le": 10, "yuv444p10le": 10,
    "yuv420p10be": 10, "yuv422p10be": 10, "p010le": 10, "gbrp10le": 10,
    "yuv420p12le": 12, "yuv422p12le": 12, "yuv444p12le": 12,
    "gbrp12le": 12, "yuv420p16le": 16, "yuv422p16le": 16,
}


def _bit_depth_from_pixfmt(pix_fmt: str | None) -> int | None:
    if not pix_fmt:
        return None
    if pix_fmt in _PIXFMT_BITDEPTH:
        return _PIXFMT_BITDEPTH[pix_fmt]
    # Heuristik fuer unbekannte Formate
    if "10" in pix_fmt:
        return 10
    if "12" in pix_fmt:
        return 12
    if "16" in pix_fmt:
        return 16
    return 8


def probe(path: str, ffprobe_bin: str = "ffprobe") -> ProbeResult:
    """Fuehrt `ffprobe -show_format -show_streams` aus und klassifiziert die Datei.

    PLAN: ffprobe auf die Eingabedatei (echten Codec, Pixelformat, Bittiefe,
    Aufloesung, Dauer lesen, NICHT nur die Datei-Endung).
    """
    p = Path(path)
    if not p.exists():
        raise ProbeError(f"Datei nicht gefunden: {path}")

    cmd = [
        ffprobe_bin, "-v", "error",
        "-print_format", "json",
        "-show_format", "-show_streams",
        str(p),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise ProbeError(
            f"ffprobe fehlgeschlagen (exit {proc.returncode}): {proc.stderr.strip()[:400]}"
        )
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise ProbeError(f"ffprobe-Ausgabe nicht parsebar: {e}") from None

    streams = data.get("streams", [])
    fmt = data.get("format", {})

    v_stream = next((s for s in streams if s.get("codec_type") == "video"), None)
    a_stream = next((s for s in streams if s.get("codec_type") == "audio"), None)

    video_codec = (v_stream or {}).get("codec_name")
    pix_fmt = (v_stream or {}).get("pix_fmt")
    width = _to_int((v_stream or {}).get("width"))
    height = _to_int((v_stream or {}).get("height"))
    audio_codec = (a_stream or {}).get("codec_name")

    # Dauer: bevorzugt aus dem Format, sonst aus dem Video-Stream.
    duration = _to_float(fmt.get("duration"))
    if duration is None and v_stream is not None:
        duration = _to_float(v_stream.get("duration"))

    size_bytes = _to_int(fmt.get("size"))
    bit_depth = _bit_depth_from_pixfmt(pix_fmt)

    result = ProbeResult(
        path=str(p),
        video_codec=video_codec,
        pix_fmt=pix_fmt,
        bit_depth=bit_depth,
        width=width,
        height=height,
        duration_seconds=duration,
        audio_codec=audio_codec,
        container_format=fmt.get("format_name"),
        size_bytes=size_bytes,
        raw=data,
    )
    _classify(result, p)
    return result


def _classify(r: ProbeResult, p: Path) -> None:
    """Setzt r.decision: remux | encode | reject (PLAN Abschnitt 5)."""
    # 1. Kein Video-Stream -> ablehnen (Bilddatei, Audio-only, kaputt).
    if r.video_codec is None:
        r.decision = "reject"
        r.reject_reason = "Kein Video-Stream gefunden (Bilddatei oder defekte Quelle)."
        return

    # 2. Proprietaere Raw-Codecs ohne SDK -> ablehnen.
    if r.video_codec in config.UNSUPPORTED_CODECS:
        r.decision = "reject"
        r.reject_reason = f"Codec '{r.video_codec}' braucht ein proprietaeres SDK (r3d/braw)."
        return

    # 3. Endung muss serverseitig erlaubt sein (sonst lehnt der r2-Pfad ab).
    if p.suffix.lower() not in config.ALLOWED_EXTENSIONS:
        r.decision = "reject"
        r.reject_reason = (
            f"Datei-Endung '{p.suffix.lower()}' wird vom Server nicht akzeptiert. "
            f"Erlaubt: {', '.join(sorted(config.ALLOWED_EXTENSIONS))}"
        )
        return

    # 4. Quelle schon CF-tauglich (H.264/HEVC, 8-bit, yuv420p) -> Smart-Remux.
    if r.is_cf_tauglicher_codec and r.is_8bit_420:
        r.decision = "remux"
        return

    # 5. sonst: echter Encode (ProRes, 10-bit, 4:2:2, exotisch, falsches pix_fmt).
    r.decision = "encode"


def _to_int(v) -> int | None:
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _to_float(v) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None
