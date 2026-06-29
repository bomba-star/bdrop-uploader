"""bdrop-encode CLI - Referenz-Engine fuer den B-Drop Uploader (Ziel A, CF-Stream).

Subcommands:
  probe   <datei>                ffprobe + Klassifikation (remux/encode/reject).
  encode  <datei> -o <out>       Smart-Remux oder Encode nach Plan.
  upload  <datei> [...]          Kompletter Ziel-A-Flow (dry-run Default).
  process <datei> ...            probe -> encode -> upload in einem Lauf.
  projects                       GET /api/admin/projects (read-only Verifikation).
  doctor                         Prueft ffmpeg/ffprobe/python.

Token: NIE im Code hardcodiert. Per Umgebungsvariable BDROP_ADMIN_TOKEN.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

from . import __version__, config
from .api import ApiClient, ApiError, get_token
from .encode import build_plan, run as run_encode
from .probe import ProbeError, probe
from .upload import UploadState, upload_master


def _eprint(*a):
    print(*a, file=sys.stderr)


# --- doctor ------------------------------------------------------------------

def cmd_doctor(_args) -> int:
    import platform
    import shutil
    import subprocess

    ok = True
    print(f"bdrop-encode {__version__}")
    print(f"Plattform: {platform.system()} {platform.machine()}")
    print(f"Python: {sys.version.split()[0]}")
    for tool in ("ffmpeg", "ffprobe"):
        path = shutil.which(tool)
        if path:
            ver = subprocess.run([tool, "-version"], capture_output=True, text=True).stdout.splitlines()[0]
            print(f"OK  {tool}: {path}\n    {ver}")
        else:
            print(f"FEHLT {tool}: nicht im PATH")
            ok = False
    if shutil.which("ffmpeg"):
        enc = config.choose_video_encoder(shutil.which("ffmpeg"))
        print(f"Gewaehlter Video-Encoder auf dieser Plattform: {enc}")
        if not config.is_macos():
            print("    (Auf macOS wird stattdessen h264_videotoolbox genutzt, falls verfuegbar.)")
    return 0 if ok else 1


# --- probe -------------------------------------------------------------------

def cmd_probe(args) -> int:
    _, ffprobe_bin = config.find_binaries()
    try:
        r = probe(args.input, ffprobe_bin)
    except ProbeError as e:
        _eprint(f"FEHLER: {e}")
        return 2
    out = {
        "path": r.path,
        "video_codec": r.video_codec,
        "pix_fmt": r.pix_fmt,
        "bit_depth": r.bit_depth,
        "width": r.width,
        "height": r.height,
        "duration_seconds": r.duration_seconds,
        "audio_codec": r.audio_codec,
        "container_format": r.container_format,
        "size_bytes": r.size_bytes,
        "decision": r.decision,
        "reject_reason": r.reject_reason,
    }
    if args.json:
        print(json.dumps(out, indent=2, ensure_ascii=False))
    else:
        for k, v in out.items():
            print(f"{k:18}: {v}")
    return 0 if r.decision != "reject" else 3


# --- encode ------------------------------------------------------------------

def cmd_encode(args) -> int:
    ffmpeg_bin, ffprobe_bin = config.find_binaries()
    try:
        r = probe(args.input, ffprobe_bin)
    except ProbeError as e:
        _eprint(f"FEHLER beim Proben: {e}")
        return 2
    if r.decision == "reject":
        _eprint(f"ABGELEHNT: {r.reject_reason}")
        return 3

    plan = build_plan(
        r, args.output, quality=args.quality,
        ffmpeg_bin=ffmpeg_bin, force_software=args.force_software,
    )
    print(f"Modus: {plan.mode}  Encoder: {plan.encoder or '-'}  Qualitaet: {plan.quality or '-'}")
    print(f"Hinweis: {plan.note}")
    print("ffmpeg-Befehl:")
    print("  " + " ".join(plan.cmd))
    if args.print_only:
        return 0

    def progress(frac: float):
        bar = int(frac * 30)
        print(f"\r  [{'#' * bar}{'.' * (30 - bar)}] {frac * 100:5.1f}%", end="", flush=True)

    try:
        run_encode(plan, r.duration_seconds, on_progress=progress)
    except RuntimeError as e:
        print()
        _eprint(f"FEHLER: {e}")
        return 4
    print("\nFertig:", plan.output_path)
    return 0


# --- projects (read-only API-Verifikation) -----------------------------------

def cmd_projects(args) -> int:
    try:
        token = get_token(token_from_memory=args.token_from_memory)
    except ApiError as e:
        _eprint(f"FEHLER: {e}")
        return 2
    client = ApiClient(token=token, base_url=args.base_url)
    try:
        projects = client.list_projects()
    except ApiError as e:
        _eprint(f"API-FEHLER (status={e.status}): {e}")
        return 2
    print(f"HTTP 200 - {len(projects)} Projekte (Bearer-Auth, nativer Client).")
    if args.names:
        for p in projects:
            print(f"  - {p.get('name', '?')} (id={p.get('id', '?')})")
    return 0


# --- upload ------------------------------------------------------------------

def cmd_upload(args) -> int:
    _, ffprobe_bin = config.find_binaries()
    try:
        r = probe(args.input, ffprobe_bin)
    except ProbeError as e:
        _eprint(f"FEHLER beim Proben: {e}")
        return 2

    try:
        token = get_token(token_from_memory=args.token_from_memory)
    except ApiError as e:
        _eprint(f"FEHLER: {e}")
        return 2
    client = ApiClient(token=token, base_url=args.base_url)

    state = UploadState()
    if args.video_id:
        state.video_id = args.video_id
    if args.version_id:
        state.version_id = args.version_id

    try:
        result = upload_master(
            client, args.input,
            probe_duration=r.duration_seconds,
            project_id=args.project_id,
            folder_id=args.folder_id,
            title=args.title,
            state=state,
            dry_run=not args.execute,
            on_log=print,
        )
    except ApiError as e:
        _eprint(f"API-FEHLER (status={e.status}): {e}")
        return 2
    except (RuntimeError, TimeoutError, FileNotFoundError) as e:
        _eprint(f"FEHLER: {e}")
        return 4

    if result.dry_run:
        print("\n(dry-run: nichts wurde im Live-System angelegt. Mit --execute echt ausfuehren.)")
    else:
        print(f"\nFertig. video_id={result.state.video_id} version_id={result.state.version_id} "
              f"ready={result.state.ready}")
    return 0


# --- process (probe -> encode -> upload) -------------------------------------

def cmd_process(args) -> int:
    ffmpeg_bin, ffprobe_bin = config.find_binaries()
    try:
        r = probe(args.input, ffprobe_bin)
    except ProbeError as e:
        _eprint(f"FEHLER beim Proben: {e}")
        return 2
    print(f"Probe: codec={r.video_codec} pix_fmt={r.pix_fmt} bit_depth={r.bit_depth} "
          f"{r.width}x{r.height} dauer={r.duration_seconds}s -> Entscheidung: {r.decision}")
    if r.decision == "reject":
        _eprint(f"ABGELEHNT: {r.reject_reason}")
        return 3

    scratch = args.scratch or tempfile.mkdtemp(prefix="bdrop-encode-")
    Path(scratch).mkdir(parents=True, exist_ok=True)
    out_path = str(Path(scratch) / (Path(args.input).stem + "_master.mp4"))

    plan = build_plan(
        r, out_path, quality=args.quality,
        ffmpeg_bin=ffmpeg_bin, force_software=args.force_software,
    )
    print(f"Encode-Plan: {plan.mode} ({plan.note})")

    def progress(frac: float):
        bar = int(frac * 30)
        print(f"\r  [{'#' * bar}{'.' * (30 - bar)}] {frac * 100:5.1f}%", end="", flush=True)

    try:
        run_encode(plan, r.duration_seconds, on_progress=progress)
    except RuntimeError as e:
        print()
        _eprint(f"ENCODE-FEHLER: {e}")
        return 4
    print(f"\nMaster: {out_path}")

    # Upload-Phase
    try:
        token = get_token(token_from_memory=args.token_from_memory)
    except ApiError as e:
        _eprint(f"FEHLER (Token): {e}")
        return 2
    client = ApiClient(token=token, base_url=args.base_url)

    # Dauer des Outputs erneut proben (bei Remux identisch, bei Encode evtl. minimal anders).
    try:
        out_probe = probe(out_path, ffprobe_bin)
        dur = out_probe.duration_seconds or r.duration_seconds
    except ProbeError:
        dur = r.duration_seconds

    try:
        result = upload_master(
            client, out_path,
            probe_duration=dur,
            project_id=args.project_id,
            folder_id=args.folder_id,
            title=args.title or Path(args.input).name,
            dry_run=not args.execute,
            on_log=print,
        )
    except ApiError as e:
        _eprint(f"API-FEHLER (status={e.status}): {e}")
        return 2
    except (RuntimeError, TimeoutError, FileNotFoundError) as e:
        _eprint(f"FEHLER: {e}")
        return 4

    if result.dry_run:
        print("\n(dry-run: nichts wurde im Live-System angelegt. Mit --execute echt ausfuehren.)")
    return 0


# --- argparse ----------------------------------------------------------------

def _add_token_args(sp):
    sp.add_argument("--base-url", default=os.environ.get("BDROP_BASE_URL", config.DEFAULT_BASE_URL),
                    help="Admin-API Base-URL (Default jonasbomba.com).")
    sp.add_argument("--token-from-memory", action="store_true",
                    help="(veraltet, ohne Wirkung) Token kommt aus BDROP_ADMIN_TOKEN.")


def _add_upload_target_args(sp):
    sp.add_argument("--project-id", help="Ziel-Projekt-ID.")
    sp.add_argument("--folder-id", help="Ziel-Ordner-ID (muss zum Projekt gehoeren).")
    sp.add_argument("--title", help="Titel des Video-Datensatzes (Default: Dateiname).")
    sp.add_argument("--execute", action="store_true",
                    help="Echten Upload ausfuehren. OHNE diesen Schalter: dry-run.")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="bdrop-encode",
        description="Referenz-Engine fuer den B-Drop Uploader (Ziel A, CF-Stream).",
    )
    p.add_argument("--version", action="version", version=f"bdrop-encode {__version__}")
    sub = p.add_subparsers(dest="command", required=True)

    # doctor
    sp = sub.add_parser("doctor", help="ffmpeg/ffprobe/python pruefen.")
    sp.set_defaults(func=cmd_doctor)

    # probe
    sp = sub.add_parser("probe", help="ffprobe + Klassifikation.")
    sp.add_argument("input")
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_probe)

    # encode
    sp = sub.add_parser("encode", help="Smart-Remux oder Encode.")
    sp.add_argument("input")
    sp.add_argument("-o", "--output", required=True)
    sp.add_argument("--quality", choices=config.QUALITY_CHOICES, default=config.QUALITY_REVIEW)
    sp.add_argument("--force-software", action="store_true",
                    help="libx264 statt videotoolbox erzwingen.")
    sp.add_argument("--print-only", action="store_true", help="Nur den Befehl zeigen, nicht ausfuehren.")
    sp.set_defaults(func=cmd_encode)

    # projects
    sp = sub.add_parser("projects", help="GET /api/admin/projects (read-only).")
    sp.add_argument("--names", action="store_true", help="Projektnamen mit ausgeben.")
    _add_token_args(sp)
    sp.set_defaults(func=cmd_projects)

    # upload
    sp = sub.add_parser("upload", help="Ziel-A-Upload (dry-run Default).")
    sp.add_argument("input")
    sp.add_argument("--quality", choices=config.QUALITY_CHOICES, default=config.QUALITY_REVIEW)
    sp.add_argument("--video-id", help="Idempotenz: bestehende video_id wiederverwenden.")
    sp.add_argument("--version-id", help="Idempotenz: bestehende version_id, r2-stream ueberspringen.")
    _add_upload_target_args(sp)
    _add_token_args(sp)
    sp.set_defaults(func=cmd_upload)

    # process
    sp = sub.add_parser("process", help="probe -> encode -> upload in einem Lauf.")
    sp.add_argument("input")
    sp.add_argument("--quality", choices=config.QUALITY_CHOICES, default=config.QUALITY_REVIEW)
    sp.add_argument("--force-software", action="store_true")
    sp.add_argument("--scratch", help="Scratch-Ordner fuer den Master (Default: tempdir).")
    _add_upload_target_args(sp)
    _add_token_args(sp)
    sp.set_defaults(func=cmd_process)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
