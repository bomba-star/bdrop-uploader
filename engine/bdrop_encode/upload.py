"""UploadService: orchestriert den Ziel-A-Upload (CF-Stream-Weg) ueber r2-stream.

Ablauf (PLAN Abschnitt 7):
  1. ggf. POST /api/admin/videos (Video anlegen)
  2. POST .../versions/r2-stream (roher Body) -> version_id sofort merken
  3. POST .../versions/{version_id}/cf-refresh pollen (Exponential-Backoff)
     bis ready_to_stream.

Idempotenz (PLAN Abschnitt 8): die version_id aus der ersten Antwort wird sofort
gemerkt. Ein Retry ruft NIE ein zweites r2-stream fuer dasselbe Item, sondern
pollt cf-refresh auf genau diese ID weiter.

dry-run (Default an): spielt alles bis VOR die erste mutierende Anfrage durch und
gibt die geplanten Requests (Methode, URL, Header-Keys, Body-Groesse) aus, ohne
real etwas im Live-System anzulegen.
"""

from __future__ import annotations

import mimetypes
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import config
from .api import ApiClient, RateLimitError, ServiceBusyError


@dataclass
class PlannedRequest:
    """Ein geplanter Request fuer den dry-run (keine Header-WERTE, nur Keys)."""

    method: str
    url: str
    header_keys: list[str]
    body_bytes: int
    note: str = ""

    def describe(self) -> str:
        return (
            f"{self.method} {self.url}\n"
            f"    Header-Keys: {', '.join(self.header_keys) or '-'}\n"
            f"    Body-Groesse: {self.body_bytes} Bytes\n"
            f"    {self.note}"
        )


@dataclass
class UploadState:
    """Idempotenz-Klammer. Persistiert die IDs aus den ersten Antworten.

    Die spaetere SwiftUI-App haelt das pro QueueItem in SwiftData
    (serverVideoId, serverVersionId).
    """

    video_id: str | None = None
    version_id: str | None = None
    cf_stream_uid: str | None = None
    ready: bool = False
    last_storage_state: str | None = None


@dataclass
class UploadResult:
    state: UploadState
    dry_run: bool
    planned: list[PlannedRequest] = field(default_factory=list)


def derive_max_duration(probe_duration: float | None) -> int:
    """Leitet max_duration_seconds aus der ffprobe-Dauer ab, hart auf 21600 gedeckelt.

    Fallback auf den Hard-Cap, wenn die Dauer unbekannt ist (Server klemmt ohnehin).
    """
    if probe_duration is None or probe_duration <= 0:
        return config.MAX_DURATION_HARD_CAP
    # etwas Puffer (CF-Dauer kann minimal abweichen), dann Hard-Cap.
    return min(int(probe_duration) + 5, config.MAX_DURATION_HARD_CAP)


def upload_master(
    client: ApiClient,
    file_path: str,
    *,
    probe_duration: float | None,
    project_id: str | None = None,
    folder_id: str | None = None,
    title: str | None = None,
    state: UploadState | None = None,
    dry_run: bool = True,
    on_log: Callable[[str], None] | None = None,
    poll_max_seconds: float = 600.0,
) -> UploadResult:
    """Fuehrt den kompletten Ziel-A-Upload aus (oder plant ihn im dry-run).

    state: vorhandener UploadState fuer Idempotenz/Retry. Wenn version_id schon
    gesetzt ist, wird r2-stream uebersprungen und direkt weiter gepollt.
    """
    log = on_log or (lambda *_: None)
    st = state or UploadState()
    planned: list[PlannedRequest] = []

    p = Path(file_path)
    if not p.exists():
        raise FileNotFoundError(f"Upload-Datei nicht gefunden: {file_path}")
    size = p.stat().st_size
    filename = p.name
    content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    max_dur = derive_max_duration(probe_duration)

    if size > config.R2_STREAM_MAX_BYTES:
        log(
            f"WARNUNG: Datei {size} Bytes ueberschreitet das r2-stream-Limit "
            f"({config.R2_STREAM_MAX_BYTES} Bytes). Server antwortet 413."
        )

    base = client.base_url.rstrip("/")

    # --- Schritt 1: Video anlegen (nur falls noch keine video_id bekannt) ----
    need_create = st.video_id is None
    if need_create:
        body = _create_video_body(title or filename, project_id, folder_id)
        planned.append(PlannedRequest(
            method="POST",
            url=f"{base}/api/admin/videos",
            header_keys=["Authorization", "Content-Type"],
            body_bytes=len(body),
            note="MUTIEREND: legt einen leeren Video-Datensatz an.",
        ))

    # --- Schritt 2: r2-stream (nur falls noch keine version_id bekannt) ------
    need_stream = st.version_id is None
    if need_stream:
        planned.append(PlannedRequest(
            method="POST",
            url=f"{base}/api/admin/videos/{{video_id}}/versions/r2-stream",
            header_keys=[
                "Authorization", "Content-Type",
                "X-Upload-Filename", "X-Upload-Content-Type", "X-Upload-Max-Duration",
            ],
            body_bytes=size,
            note=(
                f"MUTIEREND: roher File-Body. X-Upload-Filename="
                f"{urllib.parse.quote(filename, safe='')}, "
                f"X-Upload-Max-Duration={max_dur}, Content-Type des Objekts={content_type}."
            ),
        ))
    else:
        log(f"Idempotenz: version_id {st.version_id} bereits vorhanden, r2-stream uebersprungen.")

    # --- Schritt 3: cf-refresh-Polling (immer) -------------------------------
    planned.append(PlannedRequest(
        method="POST",
        url=f"{base}/api/admin/versions/{{version_id}}/cf-refresh",
        header_keys=["Authorization", "Content-Type"],
        body_bytes=0,
        note="Polling (Exponential-Backoff) bis ready_to_stream. Idempotent.",
    ))

    if dry_run:
        log("--- DRY-RUN: keine mutierende Anfrage wird ausgefuehrt ---")
        for pr in planned:
            log(pr.describe())
        return UploadResult(state=st, dry_run=True, planned=planned)

    # ===================== ECHTE AUSFUEHRUNG (--execute) =====================

    if need_create:
        log(f"POST /api/admin/videos (title={title or filename!r}) ...")
        video = client.create_video(
            title=title or filename,
            project_id=project_id,
            folder_id=folder_id,
        )
        st.video_id = video["id"]
        log(f"  -> video_id={st.video_id}")

    if st.version_id is None:
        log(f"POST .../videos/{st.video_id}/versions/r2-stream ({size} Bytes) ...")
        resp = client.r2_stream_upload(
            video_id=st.video_id,
            file_path=file_path,
            filename=filename,
            content_type=content_type,
            max_duration_seconds=max_dur,
        )
        # Idempotenz-Klammer: version_id SOFORT merken.
        st.version_id = resp["id"]
        st.cf_stream_uid = resp.get("cf_stream_uid")
        log(f"  -> version_id={st.version_id} (gemerkt fuer Idempotenz)")

    # cf-refresh pollen
    _poll_cf_refresh(client, st, log, poll_max_seconds)

    return UploadResult(state=st, dry_run=False, planned=planned)


def _poll_cf_refresh(
    client: ApiClient,
    st: UploadState,
    log: Callable[[str], None],
    poll_max_seconds: float,
) -> None:
    """Pollt cf-refresh mit Exponential-Backoff bis ready_to_stream oder Fehler."""
    delay = 2.0
    deadline = time.monotonic() + poll_max_seconds
    while True:
        try:
            r = client.cf_refresh(st.version_id)
        except RateLimitError:
            log("  429 Rate-Limit beim cf-refresh -> Backoff.")
            r = None
        except ServiceBusyError:
            log("  503 beim cf-refresh -> Backoff.")
            r = None

        if r is not None:
            st.ready = bool(r.get("ready_to_stream"))
            st.last_storage_state = r.get("storage_state")
            log(f"  cf-refresh: storage_state={st.last_storage_state}, ready={st.ready}")
            if st.ready:
                log("  -> ready_to_stream. Fertig.")
                return
            if st.last_storage_state == "error":
                raise RuntimeError(
                    f"Cloudflare meldet state=error fuer Version {st.version_id}."
                )

        if time.monotonic() > deadline:
            raise TimeoutError(
                f"cf-refresh nicht ready nach {poll_max_seconds}s "
                f"(letzter Status: {st.last_storage_state})."
            )
        time.sleep(delay)
        delay = min(delay * 2, 30.0)  # Exponential-Backoff, Deckel 30s


def _create_video_body(title: str, project_id: str | None, folder_id: str | None) -> bytes:
    import json

    payload = {"title": title}
    if project_id:
        payload["project_id"] = project_id
    if folder_id:
        payload["folder_id"] = folder_id
    return json.dumps(payload).encode("utf-8")
