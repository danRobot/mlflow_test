#!/usr/bin/env python3
"""Lleva los respaldos de MLflow entre la carpeta backup/ del bucket y Google Drive.

Corre en el runner de GitHub Actions (action gdrive), no en la EC2. Los datos
pasan por la memoria del runner, nunca por su disco. A Drive suben por un solo
flujo (Drive no admite mas para un archivo), en trozos de 128 MB, mientras el
siguiente trozo ya se lee de S3 por varias conexiones. De Drive a S3 bajan por
varias conexiones a la vez. Cada copia se comprueba con el MD5 que calcula
Drive, y cada 15 s sale una linea con lo copiado, la velocidad y lo que falta.

  check    comprueba las credenciales y la carpeta de Drive
  upload   sube a Drive cada backup/backup_mlflow_*.7z del bucket y, ya
           comprobado, lo borra de S3. Si ya estaba en Drive (mismo nombre y
           tamano), solo lo borra de S3.
  fetch    copia el respaldo mas reciente de Drive (por el nombre, que lleva
           la fecha) a backup/ del bucket

Entorno:
  GDRIVE_FOLDER_ID    ID de la carpeta de Drive (o su URL)
  GDRIVE_CREDENTIALS  JSON de las credenciales: el de tu usuario (type
                      authorized_user, de scripts/gdrive_token.py) o el de una
                      service account, que solo puede subir a unidades compartidas
  ARTIFACTS_BUCKET    bucket de MLflow, y las credenciales de AWS del workflow
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import threading
import time
from collections import deque
from concurrent.futures import Future, ThreadPoolExecutor

import boto3
import google.auth
import google.auth.exceptions
import requests
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from google.auth.transport.requests import AuthorizedSession, Request
from requests.adapters import HTTPAdapter

SCOPES = ["https://www.googleapis.com/auth/drive"]
API = os.environ.get("GDRIVE_API_ROOT", "https://www.googleapis.com").rstrip("/")
FOLDER_MIME = "application/vnd.google-apps.folder"
SEVENZ_MIME = "application/x-7z-compressed"
FILE_FIELDS = "id,name,size,md5Checksum,createdTime,webViewLink"
NAME_RE = re.compile(r"^backup_mlflow_[A-Za-z0-9._-]+\.7z$")
PREFIX = "backup/"
CHUNK = 128 * 1024 * 1024  # cada PUT a Drive (multiplo de 256 KiB): mas grande, menos pausas
PART = 32 * 1024 * 1024  # lo que lee o escribe cada conexion
WORKERS = 8  # conexiones a la vez con S3 o con Drive
PROGRESS_EVERY = 15  # segundos entre lineas de avance
RETRIES = 8
RETRY_STATUS = {408, 429, 500, 502, 503, 504}
RATE_REASONS = {"rateLimitExceeded", "userRateLimitExceeded", "backendError"}
# Fallos de red, tambien al renovar el token: se reintentan.
NET_ERRORS = (requests.RequestException, google.auth.exceptions.TransportError)


class Fail(Exception):
    """Error con un mensaje para la persona que lanzo el workflow."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class SessionLost(Exception):
    """La sesion de subida de Drive caduco: hay que empezar de nuevo."""


def mb(n: int) -> str:
    return f"{n / 1073741824:.1f} GB" if n >= 1073741824 else f"{n / 1048576:.1f} MB"


def hms(seconds: float) -> str:
    s = round(seconds)
    if s < 60:
        return f"{s} s"
    if s < 3600:
        return f"{s // 60} min {s % 60:02d} s"
    return f"{s // 3600} h {s % 3600 // 60:02d} min"


class Progress:
    """Avance de una copia: cada PROGRESS_EVERY s, lo copiado, la velocidad
    media y lo que falta a esa velocidad."""

    def __init__(self, total: int) -> None:
        self.total = total
        self.start = self.last = time.monotonic()

    def __call__(self, done: int) -> None:
        now = time.monotonic()
        if done >= self.total or now - self.last < PROGRESS_EVERY:
            return
        self.last = now
        speed = done / max(now - self.start, 0.001)
        left = f", faltan {hms((self.total - done) / speed)}" if speed else ""
        print(
            f"  {mb(done)} de {mb(self.total)} ({100 * done // self.total}%), {speed / 1048576:.1f} MB/s{left}"
        )

    def summary(self) -> str:
        took = max(time.monotonic() - self.start, 0.001)
        return f"en {hms(took)} ({self.total / 1048576 / took:.1f} MB/s)"


class Hasher:
    """MD5 en orden, en su propio hilo: no frena la subida (hashlib suelta el
    GIL con trozos grandes)."""

    def __init__(self) -> None:
        self.md5 = hashlib.md5()
        self.pool = ThreadPoolExecutor(1)

    def update(self, data: bytes | memoryview) -> None:
        self.pool.submit(self.md5.update, data)

    def hexdigest(self) -> str:
        self.pool.shutdown(wait=True)
        return self.md5.hexdigest()

    def close(self) -> None:
        self.pool.shutdown(wait=False, cancel_futures=True)


def gh_output(**values: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.writelines(f"{key}={value}\n" for key, value in values.items())


def wait(attempt: int, why: str) -> None:
    delay = min(2**attempt, 60)
    print(f"  reintento en {delay} s ({why})", file=sys.stderr)
    time.sleep(delay)


def retryable(r: requests.Response) -> bool:
    """Errores pasajeros de Google: se reintentan con espera creciente."""
    if r.status_code in RETRY_STATUS:
        return True
    if r.status_code == 403:
        try:
            return r.json()["error"]["errors"][0]["reason"] in RATE_REASONS
        except (ValueError, KeyError, IndexError, TypeError):
            return False
    return False


def api_error(r: requests.Response, service_account: bool) -> Fail:
    try:
        err = r.json()["error"]
        reason = (err.get("errors") or [{}])[0].get("reason", "")
        message = err.get("message", "")
    except (ValueError, KeyError, TypeError):
        reason, message = "", r.text[:300]
    if reason == "storageQuotaExceeded":
        if service_account:
            return Fail(
                "Google no deja que una service account suba archivos a un Drive personal: no tiene "
                "espacio propio. Usa una carpeta de una unidad compartida (Google Workspace) o las "
                "credenciales de tu usuario (scripts/gdrive_token.py, ver README).",
                r.status_code,
            )
        return Fail(
            "tu Google Drive esta lleno: libera espacio (los .7z viejos de la carpeta) y reintenta",
            r.status_code,
        )
    return Fail(f"Google Drive respondio {r.status_code}: {message or reason}", r.status_code)


def folder_id_from_env() -> str:
    raw = os.environ.get("GDRIVE_FOLDER_ID", "").strip()
    if not raw:
        raise Fail("falta el secret GDRIVE_FOLDER_ID (ver README)")
    # Tambien vale la URL de la carpeta: https://drive.google.com/drive/folders/<ID>?usp=...
    m = re.search(r"/folders/([A-Za-z0-9_-]+)", raw)
    folder = m.group(1) if m else raw
    if not re.fullmatch(r"[A-Za-z0-9_-]+", folder):
        raise Fail("GDRIVE_FOLDER_ID no parece un ID de carpeta: es lo que va despues de /folders/ en su URL")
    return folder


class Drive:
    def __init__(self) -> None:
        self.folder_id = folder_id_from_env()
        raw = os.environ.get("GDRIVE_CREDENTIALS", "").strip()
        if not raw:
            raise Fail("falta el secret GDRIVE_CREDENTIALS (ver README)")
        try:
            info = json.loads(raw)
        except json.JSONDecodeError as e:
            raise Fail(
                "GDRIVE_CREDENTIALS no es un JSON valido: pega el contenido completo del archivo"
            ) from e
        kind = info.get("type") if isinstance(info, dict) else None
        if kind not in ("service_account", "authorized_user"):
            raise Fail(
                "GDRIVE_CREDENTIALS debe ser la clave JSON de una service account o el JSON de "
                "scripts/gdrive_token.py (type authorized_user)"
            )
        self.service_account = kind == "service_account"
        try:
            creds, _ = google.auth.load_credentials_from_dict(info, scopes=SCOPES)
        except (google.auth.exceptions.GoogleAuthError, ValueError) as e:
            raise Fail(f"GDRIVE_CREDENTIALS esta incompleto ({e}): pega el JSON completo") from e
        try:
            creds.refresh(Request())
        except google.auth.exceptions.RefreshError as e:
            hint = (
                " Revisa que la clave de la service account siga activa."
                if self.service_account
                else " Pasa si la app OAuth esta en modo 'Testing' (el permiso caduca a los 7 dias: "
                "publicala, 'In production'), si revocaste el permiso o tras 6 meses sin usarlo. Vuelve "
                "a generar GDRIVE_CREDENTIALS con scripts/gdrive_token.py."
            )
            detail = e.args[0] if e.args and isinstance(e.args[0], str) else str(e)
            raise Fail(f"Google rechazo GDRIVE_CREDENTIALS ({detail.rstrip('.')}).{hint}") from e
        except google.auth.exceptions.TransportError as e:
            raise Fail(f"no se pudo contactar a Google para validar las credenciales ({e})") from e
        self.creds = creds
        self.lock = threading.Lock()
        self.s = AuthorizedSession(creds)
        # Varias descargas a la vez: que el pool de conexiones no las descarte.
        adapter = HTTPAdapter(pool_maxsize=2 * WORKERS)
        self.s.mount("https://", adapter)
        self.s.mount("http://", adapter)
        self.account = info.get("client_email", "")
        self.folder: dict = {}
        self.free: int | None = None  # espacio libre en Mi unidad (credenciales de usuario)

    # --- peticiones con reintentos ------------------------------------------
    def fresh(self) -> None:
        """Renueva el token una sola vez aunque lo necesiten varios hilos a la vez."""
        with self.lock:
            if not self.creds.valid:
                self.creds.refresh(Request())

    def call(self, method: str, url: str, ok=(200,), **kw) -> requests.Response:
        why = ""
        for attempt in range(RETRIES):
            try:
                r = self.s.request(method, url, timeout=(30, 600), **kw)
            except NET_ERRORS as e:
                why = type(e).__name__
            else:
                if r.status_code in ok:
                    return r
                if not retryable(r):
                    raise api_error(r, self.service_account)
                why = f"HTTP {r.status_code}"
            wait(attempt, why)
        raise Fail(f"Google Drive no responde tras {RETRIES} intentos ({why})")

    # --- carpeta ---------------------------------------------------------------
    def check(self) -> dict:
        who = self.account or "tu usuario"
        try:
            self.folder = self.call(
                "GET",
                f"{API}/drive/v3/files/{self.folder_id}",
                params={
                    "fields": "id,name,mimeType,driveId,trashed,capabilities(canAddChildren)",
                    "supportsAllDrives": "true",
                },
            ).json()
        except Fail as e:
            if e.status == 404:
                raise Fail(
                    f"no se encuentra la carpeta GDRIVE_FOLDER_ID, o {who} no tiene acceso: "
                    "compartela con esa cuenta como Editor"
                ) from e
            raise
        if self.folder.get("mimeType") != FOLDER_MIME:
            raise Fail("GDRIVE_FOLDER_ID es un archivo, no una carpeta")
        if self.folder.get("trashed"):
            raise Fail("la carpeta GDRIVE_FOLDER_ID esta en la papelera de Drive")
        if not self.folder.get("capabilities", {}).get("canAddChildren"):
            raise Fail(f"{who} no puede escribir en la carpeta: compartela como Editor")
        shared = bool(self.folder.get("driveId"))
        if self.service_account and not shared:
            raise Fail(
                f"la carpeta '{self.folder.get('name')}' esta en un Drive personal ('Mi unidad') y Google "
                "no deja que una service account suba archivos ahi (no tiene espacio propio). Usa una "
                "carpeta de una unidad compartida (Google Workspace) o las credenciales de tu usuario: "
                "scripts/gdrive_token.py, ver README."
            )
        where = "unidad compartida" if shared else "Mi unidad"
        if not self.service_account:
            about = self.call(
                "GET",
                f"{API}/drive/v3/about",
                params={"fields": "user(emailAddress),storageQuota(limit,usage)"},
            ).json()
            # Tu correo: los logs de Actions de un repo publico los ve cualquiera.
            email = about.get("user", {}).get("emailAddress", "")
            if email and os.environ.get("GITHUB_ACTIONS"):
                print(f"::add-mask::{email}")
            user, at, domain = email.partition("@")
            self.account = f"{user[:2]}***@{domain}" if at else "tu usuario"
            quota = about.get("storageQuota", {})
            if "limit" in quota and not shared:
                self.free = int(quota["limit"]) - int(quota.get("usage", 0))
                where += f", {mb(max(self.free, 0))} libres"
        print(f"Google Drive: carpeta '{self.folder.get('name')}' ({where}), cuenta {self.account}")
        return self.folder

    def list_backups(self) -> list[dict]:
        params = {
            "q": f"'{self.folder_id}' in parents and trashed = false and name contains 'backup_mlflow_'",
            "fields": f"nextPageToken,files({FILE_FIELDS})",
            "pageSize": "1000",
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
        }
        if self.folder.get("driveId"):
            params.update(corpora="drive", driveId=self.folder["driveId"])
        files: list[dict] = []
        while True:
            page = self.call("GET", f"{API}/drive/v3/files", params=params).json()
            files += [f for f in page.get("files", []) if NAME_RE.match(f.get("name", ""))]
            if not page.get("nextPageToken"):
                return files
            params["pageToken"] = page["nextPageToken"]

    def delete(self, file_id: str) -> None:
        self.call(
            "DELETE", f"{API}/drive/v3/files/{file_id}", ok=(200, 204), params={"supportsAllDrives": "true"}
        )

    # --- S3 -> Drive -------------------------------------------------------------
    def upload_from_s3(self, src: S3Chunks, name: str, progress: Progress) -> dict:
        meta = {"name": name, "parents": [self.folder_id], "mimeType": SEVENZ_MIME}
        for _ in range(3):
            r = self.call(
                "POST",
                f"{API}/upload/drive/v3/files",
                params={"uploadType": "resumable", "supportsAllDrives": "true", "fields": FILE_FIELDS},
                json=meta,
                headers={"X-Upload-Content-Type": SEVENZ_MIME, "X-Upload-Content-Length": str(src.size)},
            )
            try:
                return self._send(r.headers["Location"], src, progress)
            except SessionLost:
                print("  la sesion de subida de Drive se perdio: se empieza de nuevo", file=sys.stderr)
        raise Fail(f"no se pudo subir {name}: Drive perdio la sesion de subida 3 veces")

    def _status(self, url: str, size: int) -> tuple[int, dict | None]:
        """Cuanto recibio Drive de verdad: (bytes, archivo si ya esta completo)."""
        for attempt in range(RETRIES):
            try:
                r = self.s.put(url, headers={"Content-Range": f"bytes */{size}"}, data=b"", timeout=(30, 120))
            except NET_ERRORS as e:
                wait(attempt, type(e).__name__)
                continue
            if r.status_code in (200, 201):
                return size, r.json()
            if r.status_code == 308:
                return committed(r), None
            if r.status_code in (404, 410):
                raise SessionLost
            if not retryable(r):
                raise api_error(r, self.service_account)
            wait(attempt, f"HTTP {r.status_code}")
        raise Fail(f"Google Drive no responde tras {RETRIES} intentos")

    def _send(self, url: str, src: S3Chunks, progress: Progress) -> dict:
        """Un PUT por trozo, en orden: Drive no acepta partes en paralelo para
        un archivo. Mientras sube un trozo, el siguiente ya se lee de S3."""
        size = src.size
        md5 = Hasher()
        try:
            offset, failures, result = 0, 0, None
            while result is None:
                if offset >= size:
                    # Drive ya tiene todo (se corto la respuesta del ultimo trozo): pedir el archivo.
                    _, result = self._status(url, size)
                    if result is None:
                        raise SessionLost
                    break
                start = offset - offset % CHUNK
                end = min(start + CHUNK, size) - 1
                chunk = src.get(start)
                # Si Drive confirmo solo una parte del trozo, se manda lo que falta.
                data = chunk if offset == start else chunk[offset - start :]
                why = ""
                try:
                    r = self.s.put(
                        url,
                        data=data,
                        headers={"Content-Range": f"bytes {offset}-{end}/{size}"},
                        timeout=(30, 600),
                    )
                except NET_ERRORS as e:
                    why = type(e).__name__
                else:
                    if r.status_code in (200, 201):
                        md5.update(data)
                        result = r.json()
                        break
                    if r.status_code == 308:
                        done = committed(r)
                        if not offset <= done <= end + 1:
                            raise SessionLost
                        md5.update(memoryview(data)[: done - offset])
                        offset, failures = done, 0
                        progress(offset)
                        continue
                    if r.status_code in (404, 410):
                        raise SessionLost
                    if not retryable(r):
                        raise api_error(r, self.service_account)
                    why = f"HTTP {r.status_code}"
                failures += 1
                if failures > RETRIES:
                    raise Fail(f"Google Drive no acepta la subida tras {RETRIES} intentos ({why})")
                wait(failures, why)
                done, result = self._status(url, size)
                if not offset <= done <= end + 1:
                    raise SessionLost
                if done > offset:
                    failures = 0  # Drive avanzo: los fallos no se acumulan entre trozos
                md5.update(memoryview(data)[: done - offset])
                offset = done
            if int(result.get("size", -1)) != size or result.get("md5Checksum") != md5.hexdigest():
                self.delete(result["id"])
                raise Fail("la copia en Drive no coincide con la de S3 (tamano o MD5): se borro de Drive")
            return result
        finally:
            md5.close()

    # --- Drive -> S3 -------------------------------------------------------------
    def read_range(self, file_id: str, start: int, end: int) -> bytes:
        """Una parte del archivo de Drive. La llaman varios hilos a la vez."""
        why = ""
        for attempt in range(RETRIES):
            try:
                self.fresh()
                r = self.s.get(
                    f"{API}/drive/v3/files/{file_id}",
                    params={"alt": "media", "supportsAllDrives": "true"},
                    headers={"Range": f"bytes={start}-{end}"},
                    timeout=(30, 600),
                )
                if r.status_code in (200, 206) and len(r.content) == end - start + 1:
                    return r.content
                if r.status_code not in (200, 206) and not retryable(r):
                    raise api_error(r, self.service_account)
                why = f"HTTP {r.status_code}, {len(r.content)} bytes"
            except NET_ERRORS as e:
                why = type(e).__name__
            wait(attempt, why)
        raise Fail(f"no se pudo descargar de Drive tras {RETRIES} intentos ({why})")


def committed(r: requests.Response) -> int:
    """Bytes que Drive tiene guardados, segun la cabecera Range de un 308."""
    rng = r.headers.get("Range", "")
    m = re.fullmatch(r"bytes=0-(\d+)", rng)
    return int(m.group(1)) + 1 if m else 0


def s3_client():
    # Una conexion por hilo: varias lecturas o escrituras a la vez.
    return boto3.client("s3", config=Config(max_pool_connections=2 * WORKERS))


def read_s3(s3, bucket: str, key: str, start: int, end: int) -> bytes:
    why = ""
    for attempt in range(RETRIES):
        try:
            data = s3.get_object(Bucket=bucket, Key=key, Range=f"bytes={start}-{end}")["Body"].read()
            if len(data) == end - start + 1:
                return data
            why = f"{len(data)} bytes de {end - start + 1}"
        except Exception as e:  # noqa: BLE001 - red o S3: se reintenta igual
            why = f"{type(e).__name__}: {str(e)[:200]}"
        wait(attempt, why)
    raise Fail(f"no se pudo leer s3://{bucket}/{key} tras {RETRIES} intentos ({why})")


def write_s3_part(s3, bucket: str, key: str, upload_id: str, n: int, data: bytes) -> str:
    why = ""
    for attempt in range(RETRIES):
        try:
            return s3.upload_part(Bucket=bucket, Key=key, UploadId=upload_id, PartNumber=n, Body=data)["ETag"]
        except Exception as e:  # noqa: BLE001 - red o S3: se reintenta igual
            why = f"{type(e).__name__}: {str(e)[:200]}"
        wait(attempt, why)
    raise Fail(f"no se pudo escribir en s3://{bucket}/{key} tras {RETRIES} intentos ({why})")


class S3Chunks:
    """El objeto de S3 en trozos de CHUNK, cada uno leido en partes de PART a
    la vez. Al pedir un trozo ya empieza a leerse el siguiente: S3 no espera a
    que Drive termine con el actual."""

    def __init__(self, pool: ThreadPoolExecutor, s3, bucket: str, key: str, size: int) -> None:
        self.pool, self.s3, self.bucket, self.key, self.size = pool, s3, bucket, key, size
        self.reading: dict[int, list[Future]] = {}
        self.cached: tuple[int, bytes] | None = None

    def _read(self, start: int) -> None:
        if start >= self.size or start in self.reading or (self.cached and self.cached[0] == start):
            return
        end = min(start + CHUNK, self.size)
        self.reading[start] = [
            self.pool.submit(read_s3, self.s3, self.bucket, self.key, a, min(a + PART, end) - 1)
            for a in range(start, end, PART)
        ]

    def get(self, start: int) -> bytes:
        if not (self.cached and self.cached[0] == start):
            self._read(start)
            parts = self.reading.pop(start)
            self.cached = None  # suelta el trozo anterior antes de armar el nuevo
            self.cached = (start, b"".join(p.result() for p in parts))
        self._read(start + CHUNK)
        return self.cached[1]

    def close(self) -> None:
        for parts in self.reading.values():
            for p in parts:
                p.cancel()
        self.reading.clear()


def s3_backups(s3, bucket: str) -> list[tuple[str, int]]:
    found = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=PREFIX + "backup_mlflow_"):
        for obj in page.get("Contents", []):
            name = obj["Key"][len(PREFIX) :]
            if NAME_RE.match(name):
                found.append((obj["Key"], obj["Size"]))
    return sorted(found)


def upload(drive: Drive, bucket: str) -> None:
    s3 = s3_client()
    pending = s3_backups(s3, bucket)
    if not pending:
        print(f"No hay respaldos en s3://{bucket}/{PREFIX} para subir a Drive.")
        return
    in_drive = {(f["name"], int(f.get("size", -1))): f for f in drive.list_backups()}
    missing = sum(size for key, size in pending if (key[len(PREFIX) :], size) not in in_drive)
    if drive.free is not None and missing > drive.free:
        raise Fail(
            f"tu Google Drive no tiene espacio: hacen falta {mb(missing)} y quedan {mb(max(drive.free, 0))}"
        )
    with ThreadPoolExecutor(WORKERS) as pool:
        for key, size in pending:
            name = key[len(PREFIX) :]
            f = in_drive.get((name, size))
            if f:
                print(f"{name} ya estaba en Drive (mismo nombre y tamano)")
            else:
                print(f"Subiendo {name} ({mb(size)}) a Drive")
                progress = Progress(size)
                src = S3Chunks(pool, s3, bucket, key, size)
                try:
                    f = drive.upload_from_s3(src, name, progress)
                finally:
                    src.close()
                print(f"En Drive: {name} ({mb(size)}) {progress.summary()}, MD5 comprobado")
            s3.delete_object(Bucket=bucket, Key=key)
            print(f"Borrado de s3://{bucket}/{key}")
            gh_output(name=name, size=mb(size), link=f.get("webViewLink", ""))


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def fetch(drive: Drive, bucket: str) -> None:
    files = drive.list_backups()
    if not files:
        raise Fail(
            f"no hay respaldos (backup_mlflow_*.7z) en la carpeta de Drive '{drive.folder.get('name')}': "
            "lanza backup o sube ahi un .7z"
        )
    f = max(files, key=lambda x: (x["name"], x.get("createdTime", "")))
    name, size, expected = f["name"], int(f["size"]), f.get("md5Checksum")
    key = PREFIX + name
    print(f"Respaldo mas reciente en Drive: {name} ({mb(size)}), de {len(files)}")
    if size == 0:
        raise Fail(f"{name} esta vacio en Drive")
    s3 = s3_client()
    # S3 admite hasta 10.000 partes: con PART alcanza para 312 GB, y si no, partes mas grandes.
    part = max(PART, ceil_div(ceil_div(size, 10000), 1048576) * 1048576)
    todo = deque(enumerate(((a, min(a + part, size) - 1) for a in range(0, size, part)), 1))
    progress = Progress(size)
    md5 = hashlib.md5()
    upload_id = s3.create_multipart_upload(Bucket=bucket, Key=key, ContentType=SEVENZ_MIME)["UploadId"]

    def copy(n: int, start: int, end: int) -> tuple[bytes, dict]:
        data = drive.read_range(f["id"], start, end)
        return data, {"PartNumber": n, "ETag": write_s3_part(s3, bucket, key, upload_id, n, data)}

    try:
        parts, copied = [], 0
        with ThreadPoolExecutor(WORKERS) as pool:
            window: deque[Future] = deque()
            try:
                # Varias partes a la vez; el MD5 se calcula en orden al recogerlas.
                while todo or window:
                    while todo and len(window) < 2 * WORKERS:
                        n, (a, b) = todo.popleft()
                        window.append(pool.submit(copy, n, a, b))
                    data, info = window.popleft().result()
                    md5.update(data)
                    parts.append(info)
                    copied += len(data)
                    progress(copied)
            except BaseException:
                # Que terminen las partes en curso antes de abortar la subida multiparte.
                pool.shutdown(wait=True, cancel_futures=True)
                raise
        if expected and md5.hexdigest() != expected:
            raise Fail(f"{name} llego distinto de Drive (MD5): no se copio a S3")
        s3.complete_multipart_upload(
            Bucket=bucket, Key=key, UploadId=upload_id, MultipartUpload={"Parts": parts}
        )
    except BaseException:
        s3.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)
        raise
    print(f"Copiado a s3://{bucket}/{key} {progress.summary()}, MD5 comprobado")
    gh_output(name=name, size=mb(size), link=f.get("webViewLink", ""))


def main() -> None:
    # Una linea a la vez aunque la salida no sea una terminal: el avance se ve en vivo en Actions.
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("command", choices=["check", "upload", "fetch"])
    parser.add_argument("--bucket", default=os.environ.get("ARTIFACTS_BUCKET", ""))
    args = parser.parse_args()
    try:
        drive = Drive()
        drive.check()
        if args.command != "check":
            if not args.bucket:
                raise Fail("falta el bucket (--bucket o ARTIFACTS_BUCKET)")
            (upload if args.command == "upload" else fetch)(drive, args.bucket)
    except (Fail, google.auth.exceptions.RefreshError, BotoCoreError, ClientError) as e:
        if isinstance(e, Fail):
            msg = str(e)
        elif isinstance(e, google.auth.exceptions.RefreshError):
            msg = f"Google dejo de aceptar GDRIVE_CREDENTIALS durante la copia ({e})"
        else:
            msg = f"AWS respondio con un error ({e}). Si la sesion del lab termino, actualiza los secrets de AWS."
        print(f"::error::{msg}" if os.environ.get("GITHUB_ACTIONS") else f"ERROR: {msg}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
