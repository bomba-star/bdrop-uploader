"""ApiClient: duenner Wrapper um die CineReview/B-Drop-Admin-REST.

- Bearer-Token aus der Umgebung (BDROP_ADMIN_TOKEN), nie im Code hardcodiert.
- Unterscheidet 401 (Token weg) von 429 (Rate-Limit, 10 Auth/min) und 503
  (r2-stream-Semaphore voll).
- Nur Standardbibliothek (urllib), keine externen Abhaengigkeiten.

Endpoints der Admin-API:
  POST /api/admin/videos
  POST /api/admin/videos/{video_id}/versions/r2-stream  (roher Body + X-Upload-* Header)
  POST /api/admin/versions/{version_id}/cf-refresh
  GET  /api/admin/projects
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

from . import config


# --- Fehler-Typen, die das Fehler-Handling aus PLAN 9 sauber trennen ---------

# Cloudflare vor jonasbomba.com blockt den Default-Python-urllib-User-Agent mit
# error 1010 (403). Ein realer Client-UA kommt durch. Die spaetere URLSession-App
# sendet ohnehin einen Apple-UA; hier setzen wir einen expliziten.
USER_AGENT = "bdrop-encode/0.1 (+https://jonasbomba.com)"


class ApiError(RuntimeError):
    """Basis fuer alle API-Fehler. status traegt den HTTP-Code (oder None)."""

    def __init__(self, message: str, status: int | None = None, body: str | None = None):
        super().__init__(message)
        self.status = status
        self.body = body


class AuthError(ApiError):
    """401 - Token weg/ungueltig. App muss Token erneuern (NICHT Backoff)."""


class RateLimitError(ApiError):
    """429 - Auth-Rate-Limit (10/min). NICHT als 'Token erneuern' fehldeuten,
    sondern Exponential-Backoff + Retry."""


class ServiceBusyError(ApiError):
    """503 - r2-stream-Semaphore voll oder Dienst nicht konfiguriert. Backoff."""


# --- Token-Beschaffung -------------------------------------------------------

def get_token(token_from_memory: bool = False) -> str:
    """Liefert den Admin-Token aus der Umgebung (BDROP_ADMIN_TOKEN).

    Der Token wird NIE im Code hardcodiert. Der Parameter token_from_memory
    bleibt aus Kompatibilitaetsgruenden erhalten, hat aber keine Wirkung mehr.
    """
    env_token = os.environ.get("BDROP_ADMIN_TOKEN", "").strip()
    if env_token:
        return env_token
    raise AuthError("Kein Admin-Token. Setze die Umgebungsvariable BDROP_ADMIN_TOKEN.")


# --- Client ------------------------------------------------------------------

@dataclass
class ApiClient:
    """Bearer-Client gegen die Admin-API. Timeout grosszuegig fuer Uploads."""

    token: str
    base_url: str = config.DEFAULT_BASE_URL
    timeout: float = 60.0

    def _url(self, path: str) -> str:
        return self.base_url.rstrip("/") + path

    def _auth_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.token}",
            "User-Agent": USER_AGENT,
        }

    def _request(
        self,
        method: str,
        path: str,
        *,
        headers: dict[str, str] | None = None,
        data: bytes | None = None,
        timeout: float | None = None,
    ) -> tuple[int, dict | list | str]:
        """Fuehrt einen HTTP-Request aus und uebersetzt HTTP-Fehler in unsere Typen."""
        h = self._auth_headers()
        if headers:
            h.update(headers)
        req = urllib.request.Request(self._url(path), data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as resp:
                raw = resp.read().decode("utf-8", "replace")
                return resp.status, _maybe_json(raw)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace") if e.fp else ""
            self._raise_for_status(e.code, body)
            return e.code, _maybe_json(body)  # unreachable, _raise_for_status wirft
        except urllib.error.URLError as e:
            raise ApiError(f"Netzwerkfehler: {e.reason}") from None

    @staticmethod
    def _raise_for_status(status: int, body: str) -> None:
        if status == 401:
            raise AuthError("401: Admin-Token ungueltig oder abgelaufen.", status, body)
        if status == 429:
            raise RateLimitError(
                "429: Auth-Rate-Limit (10 Versuche/min) erreicht. Backoff + Retry.",
                status, body,
            )
        if status == 503:
            raise ServiceBusyError(
                "503: Dienst beschaeftigt (r2-stream-Semaphore voll oder nicht konfiguriert).",
                status, body,
            )
        if status >= 400:
            raise ApiError(f"HTTP {status}: {body[:300]}", status, body)

    # --- konkrete Endpoints --------------------------------------------------

    def list_projects(self) -> list:
        """GET /api/admin/projects -> Liste der Projekte (read-only)."""
        status, data = self._request("GET", "/api/admin/projects")
        if not isinstance(data, list):
            raise ApiError("Unerwartete Projektliste (kein Array).", status)
        return data

    def create_video(
        self,
        title: str,
        project_id: str | None = None,
        folder_id: str | None = None,
        description: str | None = None,
    ) -> dict:
        """POST /api/admin/videos -> {id, project_id, title, ...}.

        MUTIEREND. Legt einen leeren Video-Datensatz an.
        """
        payload = {"title": title}
        if project_id:
            payload["project_id"] = project_id
        if folder_id:
            payload["folder_id"] = folder_id
        if description:
            payload["description"] = description
        body = json.dumps(payload).encode("utf-8")
        status, data = self._request(
            "POST", "/api/admin/videos",
            headers={"Content-Type": "application/json"},
            data=body,
        )
        if not isinstance(data, dict) or "id" not in data:
            raise ApiError("create_video lieferte keine video id.", status)
        return data

    def r2_stream_upload(
        self,
        video_id: str,
        file_path: str,
        filename: str,
        content_type: str,
        max_duration_seconds: int,
        timeout: float = 3600.0,
    ) -> dict:
        """POST /api/admin/videos/{video_id}/versions/r2-stream.

        MUTIEREND. Roher File-Body. Header:
          X-Upload-Filename     (url-encoded, Pflicht)
          X-Upload-Content-Type (optional)
          X-Upload-Max-Duration (optional, server-seitig auf 1..21600 geklemmt)

        Antwort: {id (=version_id), video_id, cf_stream_uid, ...}.
        """
        with open(file_path, "rb") as f:
            body = f.read()
        max_dur = max(1, min(int(max_duration_seconds), config.MAX_DURATION_HARD_CAP))
        headers = {
            "X-Upload-Filename": urllib.parse.quote(filename, safe=""),
            "X-Upload-Content-Type": content_type,
            "X-Upload-Max-Duration": str(max_dur),
            "Content-Type": "application/octet-stream",
        }
        status, data = self._request(
            "POST", f"/api/admin/videos/{video_id}/versions/r2-stream",
            headers=headers, data=body, timeout=timeout,
        )
        if not isinstance(data, dict) or "id" not in data:
            raise ApiError("r2-stream lieferte keine version id.", status)
        return data

    def cf_refresh(self, version_id: str) -> dict:
        """POST /api/admin/versions/{version_id}/cf-refresh.

        Antwort: {id, ready_to_stream, storage_state, status, duration_seconds}.
        Idempotent: pollt nur den Status, mutiert keine neue Version.
        """
        status, data = self._request(
            "POST", f"/api/admin/versions/{version_id}/cf-refresh",
            headers={"Content-Type": "application/json"},
            data=b"",
        )
        if not isinstance(data, dict):
            raise ApiError("cf-refresh lieferte kein Objekt.", status)
        return data


def _maybe_json(raw: str):
    raw = raw.strip()
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw
