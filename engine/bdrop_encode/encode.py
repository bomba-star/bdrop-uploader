"""EncodeService: baut den ffmpeg-Befehl (Smart-Remux / HW-H.264 / x264) und
fuehrt ihn aus, parst -progress (out_time_us gegen die geprobte Dauer).

Spiegelt PLAN Abschnitt 5 und die ffmpeg-Templates Ziel A.

Die HLS-Ladder (Ziel B) ist hier bewusst NICHT enthalten - der Auftrag deckt
Ziel A (CF-Stream-Weg) ab.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import config
from .probe import ProbeResult


@dataclass
class EncodePlan:
    """Beschreibt, was die Engine mit der Datei vorhat (vor der Ausfuehrung)."""

    mode: str                 # "remux" | "encode"
    encoder: str | None       # None bei remux, sonst h264_videotoolbox / libx264
    quality: str | None       # review | archive (nur bei encode)
    cmd: list[str]
    output_path: str
    note: str = ""


def build_plan(
    probe_result: ProbeResult,
    output_path: str,
    quality: str = config.QUALITY_REVIEW,
    ffmpeg_bin: str = "ffmpeg",
    force_software: bool = False,
) -> EncodePlan:
    """Baut den ffmpeg-Befehl gemaess Entscheidung aus dem ProbeResult.

    - decision == 'remux' -> Smart-Remux: -c copy -movflags +faststart.
    - decision == 'encode' -> Encode mit gewaehltem Encoder, immer pix_fmt yuv420p,
      tag avc1, aac 192k, faststart.
    """
    if quality not in config.QUALITY_CHOICES:
        raise ValueError(f"quality muss eines von {config.QUALITY_CHOICES} sein, war '{quality}'")

    in_path = probe_result.path

    if probe_result.decision == "remux":
        cmd = [
            ffmpeg_bin, "-hide_banner", "-y",
            "-i", in_path,
            "-c", "copy",
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            output_path,
        ]
        return EncodePlan(
            mode="remux", encoder=None, quality=None, cmd=cmd,
            output_path=output_path,
            note="Quelle bereits H.264/HEVC, 8-bit, yuv420p -> Smart-Remux (kein Re-Encode).",
        )

    # --- Encode ---
    # archive erzwingt libx264 (Software, maximale Qualitaet). review nutzt den
    # plattformabhaengigen Encoder (Mac: videotoolbox, Linux: libx264).
    if quality == config.QUALITY_ARCHIVE:
        encoder = "libx264"
    else:
        encoder = config.choose_video_encoder(ffmpeg_bin, force_software=force_software)

    cmd = [ffmpeg_bin, "-hide_banner", "-y", "-i", in_path, "-c:v", encoder]

    if encoder == "h264_videotoolbox":
        # Mac-Hardware-Pfad (review). q:v 60 wie im PLAN-Template.
        cmd += ["-profile:v", "high", "-q:v", "60"]
        note = "Encode mit h264_videotoolbox (Mac-Hardware, Review-schnell)."
    else:  # libx264
        if quality == config.QUALITY_ARCHIVE:
            cmd += ["-preset", "slow", "-crf", "18"]
            note = "Encode mit libx264 -preset slow -crf 18 (Archive, maximale Qualitaet)."
        else:
            # Linux-Fallback fuer review: schnell und brauchbar.
            cmd += ["-preset", "veryfast", "-crf", "23"]
            note = "Encode mit libx264 (Review-schnell, Linux-Fallback fuer videotoolbox)."

    # Pflicht-Details, fest verdrahtet (PLAN): yuv420p erzwingen, avc1-Tag,
    # AAC 192k, faststart, Fortschritt ueber -progress.
    cmd += [
        "-pix_fmt", "yuv420p",
        "-tag:v", "avc1",
        "-c:a", "aac", "-b:a", "192k",
        "-movflags", "+faststart",
        "-progress", "pipe:1", "-nostats",
        output_path,
    ]

    return EncodePlan(
        mode="encode", encoder=encoder, quality=quality, cmd=cmd,
        output_path=output_path, note=note,
    )


def run(
    plan: EncodePlan,
    total_duration: float | None,
    on_progress: Callable[[float], None] | None = None,
) -> None:
    """Fuehrt den ffmpeg-Plan aus und parst -progress (out_time_us / total).

    on_progress bekommt einen Wert 0.0..1.0 (oder None-sicher uebersprungen,
    wenn die Dauer unbekannt ist). Wirft RuntimeError bei Exit-Code != 0.
    """
    Path(plan.output_path).parent.mkdir(parents=True, exist_ok=True)

    proc = subprocess.Popen(
        plan.cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    stderr_tail: list[str] = []
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            if line.startswith("out_time_us=") and total_duration and on_progress:
                try:
                    us = int(line.split("=", 1)[1])
                    frac = max(0.0, min(1.0, (us / 1_000_000.0) / total_duration))
                    on_progress(frac)
                except (ValueError, ZeroDivisionError):
                    pass
            elif line == "progress=end" and on_progress:
                on_progress(1.0)
    finally:
        proc.wait()
        if proc.stderr is not None:
            tail = proc.stderr.read()
            if tail:
                stderr_tail = tail.strip().splitlines()[-15:]

    if proc.returncode != 0:
        raise RuntimeError(
            f"ffmpeg fehlgeschlagen (exit {proc.returncode}):\n" + "\n".join(stderr_tail)
        )
