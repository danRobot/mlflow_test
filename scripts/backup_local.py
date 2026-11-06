#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     # La misma version que el servidor (infra/mlflow-server/Dockerfile).
#     "mlflow-skinny==3.18.0",
#     "tqdm==4.70.1",
# ]
# ///
"""Respaldo de MLflow en tu computador, solo con la API de MLflow.

Descarga del servidor todo lo necesario para conservar el trabajo, a una
carpeta local fuera de AWS (no gasta credito del lab mas alla de la
transferencia de los artefactos):

  - experimentos, con sus tags
  - corridas: parametros, tags, datasets de entrada y el historial completo
    de cada metrica (todos los pasos, no solo el ultimo valor)
  - artefactos de cada corrida
  - logged models (MLflow 3), con sus artefactos
  - modelos registrados, con versiones, alias y tags

No usa mlflow-export-import: en PyPI esta deprecado (ultima version de
2023) y MLflow no trae un export completo, asi que se arma con MlflowClient.

Uso (la URL sale en el resumen del deploy):

  uv run scripts/backup_local.py --tracking-uri http://IP:8080

  o, sin uv:
  pip install mlflow-skinny==3.18.0 tqdm==4.70.1
  python scripts/backup_local.py --tracking-uri http://IP:8080

Opciones:
  --tracking-uri URL   servidor MLflow (por defecto, MLFLOW_TRACKING_URI)
  --dest DIR           carpeta de respaldos (por defecto ~/mlflow-backups,
                       fuera del repo)
  --keep N             respaldos a conservar (5; 0 = todos)
  --no-artifacts       solo metadatos: rapido y sin transferencia de S3

Resultado:
  ~/mlflow-backups/mlflow-backup-AAAAMMDD-HHMMSS/   (hora UTC)
    manifest.json                       fecha, servidor, versiones y conteos
    experiments/<id>/experiment.json
    experiments/<id>/runs/<run_id>/run.json
    experiments/<id>/runs/<run_id>/artifacts/...
    experiments/<id>/models/<model_id>/model.json
    experiments/<id>/models/<model_id>/artifacts/...
    registered_models/<nombre>.json     modelo, versiones y alias

Muestra dos barras de progreso: metadatos (corridas y modelos leidos) y
artefactos (bytes descargados, velocidad y tiempo restante).

Notas:
  - Se escribe en una carpeta .partial que solo se renombra al terminar
    bien: nunca queda un respaldo a medias con aspecto de completo.
  - Los artefactos que no cambiaron desde el respaldo anterior (mismos
    archivos y tamanos en el servidor) no se vuelven a descargar: se enlazan
    desde el anterior (hard link), asi que tampoco ocupan disco dos veces.
  - Solo experimentos y corridas activos: lo que esta en la papelera de
    MLflow (borrado sin 'mlflow gc') no se respalda. Tampoco las trazas de
    GenAI ni los prompts.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import enum
import json
import os
import posixpath
import re
import shutil
import signal
import sys
import tempfile
import threading
import time
from pathlib import Path

# Un respaldo no tiene por que mandar telemetria a terceros.
os.environ.setdefault("MLFLOW_DISABLE_TELEMETRY", "true")
# Las barras de MLflow (una por corrida y archivo) las reemplaza la barra general.
os.environ.setdefault("MLFLOW_ENABLE_ARTIFACTS_PROGRESS_BAR", "false")
# MLflow baja cada archivo del bucket en partes de 100 MB y la barra avanza con
# cada parte terminada: con 8 MB avanza seguido.
os.environ.setdefault("MLFLOW_MULTIPART_DOWNLOAD_CHUNK_SIZE", str(8 * 1024 * 1024))

import mlflow  # noqa: E402
import requests  # noqa: E402
from mlflow import MlflowClient  # noqa: E402
from mlflow.entities import ViewType  # noqa: E402
from mlflow.store.artifact import http_artifact_repo  # noqa: E402
from tqdm import tqdm  # noqa: E402

NAME_RE = re.compile(r"^mlflow-backup-\d{8}-\d{6}$")


def log(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def abort(msg: str) -> None:
    """Como die, pero sin esperar a las descargas que MLflow siga haciendo en
    otros hilos: al salir normal, Python esperaria a que terminen."""
    sys.stdout.flush()
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    os._exit(1)


def to_json(obj):
    """Entidades de MLflow a tipos JSON (dict, list, str, numeros)."""
    if obj is None or isinstance(obj, (str, int, float, bool)):
        return obj
    if isinstance(obj, enum.Enum):
        return obj.name
    if isinstance(obj, dict):
        return {str(k): to_json(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple, set)):
        return [to_json(v) for v in obj]
    if hasattr(obj, "to_dictionary"):
        return to_json(obj.to_dictionary())
    try:  # _MlflowObject: se recorre como pares (propiedad, valor)
        return {k: to_json(v) for k, v in obj}
    except TypeError:
        return str(obj)


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(to_json(data), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def paged(search, **kwargs):
    """Recorre todas las paginas de un search_* de MlflowClient."""
    token = None
    while True:
        page = search(**kwargs, page_token=token)
        yield from page
        token = page.token
        if not token:
            return


def safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("_") or "modelo"


class Progress:
    """Barra de bytes que pueden avanzar varios hilos a la vez."""

    def __init__(self, bar: tqdm):
        self.bar = bar
        self.done = 0
        self._lock = threading.Lock()

    def add(self, n: int) -> None:
        with self._lock:
            self.done += n
            self.bar.update(n)


@contextlib.contextmanager
def chunk_progress(bar: tqdm):
    """Suma a la barra cada parte de archivo que MLflow termina de bajar.

    Con S3 detras, MLflow 3 baja cada archivo directo del bucket (URL
    prefirmada), en partes paralelas, y no informa del avance: mientras dura el
    bloque se envuelve su funcion que baja cada parte.
    """
    progress = Progress(bar)
    original = getattr(http_artifact_repo, "download_chunk", None)
    if original is None:  # otra version de MLflow: la barra avanza por corrida
        yield progress
        return

    def download_chunk(*args, **kwargs):
        original(*args, **kwargs)
        start, end = kwargs.get("range_start"), kwargs.get("range_end")
        if start is not None and end is not None:
            progress.add(end - start + 1)

    http_artifact_repo.download_chunk = download_chunk
    try:
        yield progress
    finally:
        http_artifact_repo.download_chunk = original


class Artifacts:
    """Artefactos: primero se listan (y se enlazan los que no cambiaron), despues
    se descargan los demas con una sola barra de bytes."""

    def __init__(self, tracking_uri: str, previous: Path | None):
        self.tracking_uri = tracking_uri
        self.previous = previous
        self.pending: list[tuple[str, Path, dict[str, int], str]] = []
        self.downloaded = self.reused = 0
        self.bytes_downloaded = self.bytes_reused = 0

    def remote_files(self, uri: str, prefix: str = "") -> dict[str, int]:
        """Archivos bajo `uri` como {ruta relativa: tamano}."""
        files: dict[str, int] = {}
        for info in mlflow.artifacts.list_artifacts(artifact_uri=uri, tracking_uri=self.tracking_uri):
            name = posixpath.basename(info.path.rstrip("/"))
            rel = posixpath.join(prefix, name) if prefix else name
            if info.is_dir:
                files.update(self.remote_files(f"{uri.rstrip('/')}/{name}", rel))
            else:
                files[rel] = info.file_size or 0
        return files

    @staticmethod
    def local_files(root: Path) -> dict[str, int]:
        if not root.is_dir():
            return {}
        return {p.relative_to(root).as_posix(): p.stat().st_size for p in root.rglob("*") if p.is_file()}

    def plan(self, uri: str, dest: Path, rel_dir: str, label: str) -> int:
        """Enlaza ya los artefactos sin cambios o deja la descarga pendiente.
        Devuelve cuantos archivos hay."""
        remote = self.remote_files(uri)
        if not remote:
            return 0
        old = self.previous / rel_dir if self.previous else None
        if old is not None and self.local_files(old) == remote:
            shutil.copytree(old, dest, copy_function=link_or_copy)
            self.reused += len(remote)
            self.bytes_reused += sum(remote.values())
        else:
            self.pending.append((uri, dest, remote, label))
        return len(remote)

    def download_pending(self) -> None:
        if not self.pending:
            return
        total = sum(sum(remote.values()) for _, _, remote, _ in self.pending)
        bar = tqdm(total=total, desc="Descargando", unit="B", unit_scale=True, unit_divisor=1024)
        with bar, chunk_progress(bar) as progress:
            for uri, dest, remote, label in self.pending:
                bar.set_postfix_str(label, refresh=False)
                size = sum(remote.values())
                before = progress.done
                # download_artifacts crea una carpeta con el ultimo tramo de la URI.
                tmp = Path(tempfile.mkdtemp(dir=dest.parent))
                got = Path(
                    mlflow.artifacts.download_artifacts(
                        artifact_uri=uri, dst_path=str(tmp), tracking_uri=self.tracking_uri
                    )
                )
                # Lo que no llego por partes (a traves del servidor) se suma al terminar.
                progress.add(size - (progress.done - before))
                got.rename(dest)
                shutil.rmtree(tmp)
                if self.local_files(dest) != remote:
                    raise RuntimeError(f"la descarga de {uri} no coincide con lo que hay en el servidor")
                self.downloaded += len(remote)
                self.bytes_downloaded += size


def link_or_copy(src: str, dst: str) -> None:
    try:
        os.link(src, dst)
    except OSError:  # otro disco o sistema de archivos sin hard links
        shutil.copy2(src, dst)


def check_server(tracking_uri: str) -> str:
    try:
        requests.get(f"{tracking_uri}/health", timeout=15).raise_for_status()
        # Con autenticacion, /version (como toda la API) pide usuario y clave:
        # las mismas variables de entorno que usa MLflow.
        user = os.environ.get("MLFLOW_TRACKING_USERNAME")
        auth = (user, os.environ.get("MLFLOW_TRACKING_PASSWORD", "")) if user else None
        resp = requests.get(f"{tracking_uri}/version", auth=auth, timeout=15)
    except requests.RequestException as e:
        die(f"no se puede contactar {tracking_uri} ({e}). ¿Esta encendida la EC2 y es la IP correcta?")
    if resp.status_code == 401:
        die(
            "usuario o clave incorrectos (MLFLOW_TRACKING_USERNAME y MLFLOW_TRACKING_PASSWORD)"
            if user
            else "el servidor pide usuario y clave: define MLFLOW_TRACKING_USERNAME y "
            "MLFLOW_TRACKING_PASSWORD"
        )
    server_version = resp.text.strip() if resp.ok else "desconocida"
    if server_version not in ("desconocida", mlflow.__version__):
        print(
            f"AVISO: el servidor es MLflow {server_version} y este cliente {mlflow.__version__}.",
            file=sys.stderr,
        )
    return server_version


def short(text: str, width: int = 28) -> str:
    return text if len(text) <= width else text[: width - 1] + "…"


def backup(
    client: MlflowClient, tracking_uri: str, work: Path, previous: Path | None, with_artifacts: bool
) -> tuple[dict, list[str]]:
    arts = Artifacts(tracking_uri, previous)
    counts = {
        "experiments": 0,
        "runs": 0,
        "metric_points": 0,
        "logged_models": 0,
        "registered_models": 0,
        "model_versions": 0,
        "artifact_files": 0,
    }

    # Que hay que respaldar: se lista primero para que la barra sepa el total.
    experiments = list(paged(client.search_experiments, view_type=ViewType.ACTIVE_ONLY))
    items = []
    per_exp: dict[str, list[int]] = {}
    for exp in experiments:
        write_json(work / "experiments" / exp.experiment_id / "experiment.json", exp)
        per_exp[exp.experiment_id] = [0, 0, 0]  # corridas, modelos, archivos
        runs = paged(
            client.search_runs, experiment_ids=[exp.experiment_id], run_view_type=ViewType.ACTIVE_ONLY
        )
        items += [("run", exp, run) for run in runs]
        items += [
            ("model", exp, m) for m in paged(client.search_logged_models, experiment_ids=[exp.experiment_id])
        ]
        counts["experiments"] += 1

    with tqdm(total=len(items), desc="Metadatos", unit=" elem") as bar:
        for kind, exp, obj in items:
            exp_dir = work / "experiments" / exp.experiment_id
            stats = per_exp[exp.experiment_id]
            if kind == "run":
                run_id = obj.info.run_id
                label = f"{exp.name}/{obj.info.run_name or run_id[:8]}"
                bar.set_postfix_str(short(label), refresh=False)
                data = to_json(obj)
                history = {}
                for key in obj.data.metrics:
                    points = client.get_metric_history(run_id, key)
                    history[key] = [
                        {"value": m.value, "timestamp": m.timestamp, "step": m.step} for m in points
                    ]
                    counts["metric_points"] += len(points)
                data["metric_history"] = history
                run_dir = exp_dir / "runs" / run_id
                write_json(run_dir / "run.json", data)
                if with_artifacts:
                    stats[2] += arts.plan(
                        obj.info.artifact_uri,
                        run_dir / "artifacts",
                        f"experiments/{exp.experiment_id}/runs/{run_id}/artifacts",
                        short(label),
                    )
                stats[0] += 1
                counts["runs"] += 1
            else:
                label = f"{exp.name}/{obj.name or obj.model_id}"
                bar.set_postfix_str(short(label), refresh=False)
                model_dir = exp_dir / "models" / obj.model_id
                data = to_json(obj)
                data["status"] = to_json(obj.status)  # to_dictionary() lo deja como numero
                write_json(model_dir / "model.json", data)
                if with_artifacts and obj.artifact_location:
                    stats[2] += arts.plan(
                        obj.artifact_location,
                        model_dir / "artifacts",
                        f"experiments/{exp.experiment_id}/models/{obj.model_id}/artifacts",
                        short(label),
                    )
                stats[1] += 1
                counts["logged_models"] += 1
            bar.update()
        bar.set_postfix_str("", refresh=True)

    arts.download_pending()

    for rm in paged(client.search_registered_models):
        versions = list(paged(client.search_model_versions, filter_string=f"name='{rm.name}'"))
        data = to_json(rm)
        data["versions"] = to_json(versions)
        path = work / "registered_models" / f"{safe_name(rm.name)}.json"
        n = 2
        while path.exists():  # dos nombres que quedan iguales al limpiarlos
            path = path.with_name(f"{safe_name(rm.name)}-{n}.json")
            n += 1
        write_json(path, data)
        counts["registered_models"] += 1
        counts["model_versions"] += len(versions)

    counts["artifact_files"] = sum(stats[2] for stats in per_exp.values())
    counts["artifacts_downloaded"] = arts.downloaded
    counts["artifacts_reused"] = arts.reused
    counts["bytes_downloaded"] = arts.bytes_downloaded
    counts["bytes_reused"] = arts.bytes_reused
    lines = [
        f"    {exp.name} (id {exp.experiment_id}): {per_exp[exp.experiment_id][0]} corridas, "
        f"{per_exp[exp.experiment_id][1]} logged models, {per_exp[exp.experiment_id][2]} archivos"
        for exp in experiments
    ]
    return counts, lines


def complete_backups(dest: Path) -> list[Path]:
    """Respaldos completos, del mas nuevo al mas viejo POR NOMBRE (lleva la fecha)."""
    found = [p for p in dest.iterdir() if p.is_dir() and NAME_RE.match(p.name)] if dest.is_dir() else []
    return sorted(found, key=lambda p: p.name, reverse=True)


def last_with_artifacts(dest: Path) -> Path | None:
    """El respaldo mas reciente que tiene artefactos (no uno de --no-artifacts)."""
    for path in complete_backups(dest):
        try:
            if json.loads((path / "manifest.json").read_text(encoding="utf-8")).get("artifacts"):
                return path
        except (OSError, ValueError):
            continue
    return None


def mb(n: int) -> str:
    return f"{n / 1024 / 1024:.1f} MB"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Respaldo de MLflow en tu computador (experimentos, corridas, metricas, "
        "artefactos y modelos), con la API de MLflow."
    )
    parser.add_argument(
        "--tracking-uri",
        default=os.environ.get("MLFLOW_TRACKING_URI"),
        help="servidor MLflow, p. ej. http://IP:8080 (por defecto MLFLOW_TRACKING_URI)",
    )
    parser.add_argument(
        "--dest",
        default=str(Path.home() / "mlflow-backups"),
        help="carpeta de respaldos (por defecto ~/mlflow-backups)",
    )
    parser.add_argument("--keep", type=int, default=5, help="respaldos a conservar (0 = todos)")
    parser.add_argument(
        "--no-artifacts", action="store_true", help="solo metadatos, sin descargar artefactos"
    )
    args = parser.parse_args()

    if not args.tracking_uri:
        die("falta el servidor: usa --tracking-uri http://IP:8080 (la IP sale en el resumen del deploy)")
    tracking_uri = args.tracking_uri.rstrip("/")
    if not tracking_uri.startswith(("http://", "https://")):
        die(f"--tracking-uri debe ser una URL http(s)://, no '{tracking_uri}'")

    server_version = check_server(tracking_uri)
    mlflow.set_tracking_uri(tracking_uri)
    client = MlflowClient(tracking_uri)

    dest = Path(args.dest).expanduser().resolve()
    dest.mkdir(parents=True, exist_ok=True)
    # Restos de un respaldo cortado de golpe (kill -9, apagon).
    for stale in dest.glob("mlflow-backup-*.partial"):
        log(f"Eliminando respaldo a medias {stale.name}")
        shutil.rmtree(stale, ignore_errors=True)
    previous = last_with_artifacts(dest)
    name = "mlflow-backup-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
    final = dest / name
    work = dest / f"{name}.partial"
    work.mkdir()

    # SIGTERM (cerrar la terminal, timeout, kill) como excepcion, para limpiar.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    log(f"Respaldando {tracking_uri} (MLflow {server_version}) en {final}")
    if previous and not args.no_artifacts:
        log(f"Los artefactos sin cambios se enlazan desde {previous.name}")
    start = time.time()
    try:
        counts, lines = backup(client, tracking_uri, work, previous, not args.no_artifacts)
        write_json(
            work / "manifest.json",
            {
                "created_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                "tracking_uri": tracking_uri,
                "server_mlflow_version": server_version,
                "client_mlflow_version": mlflow.__version__,
                "artifacts": not args.no_artifacts,
                "duration_seconds": round(time.time() - start, 1),
                "counts": counts,
            },
        )
        work.rename(final)
    except BaseException as e:  # tambien Ctrl+C y SIGTERM: nunca queda un .partial
        shutil.rmtree(work, ignore_errors=True)
        if isinstance(e, (KeyboardInterrupt, SystemExit)):
            abort("interrumpido; no se creo ningun respaldo")
        abort(f"respaldo FALLIDO, no se creo ningun respaldo: {e}")

    # Retencion. Los enlaces (hard links) hacen que borrar un respaldo viejo no
    # afecte a los nuevos que comparten artefactos con el.
    if args.keep > 0:
        for old in complete_backups(dest)[args.keep :]:
            log(f"Eliminando respaldo antiguo {old.name}")
            shutil.rmtree(old)

    c = counts
    print()
    print(f"Respaldo completo: {final}")
    print("\n".join(lines))
    print(
        f"  experimentos={c['experiments']} corridas={c['runs']} puntos de metricas={c['metric_points']}"
        f" logged models={c['logged_models']} modelos registrados={c['registered_models']}"
        f" ({c['model_versions']} versiones)"
    )
    if not args.no_artifacts:
        print(
            f"  artefactos: {c['artifacts_downloaded']} descargados ({mb(c['bytes_downloaded'])}),"
            f" {c['artifacts_reused']} reutilizados del respaldo anterior ({mb(c['bytes_reused'])})"
        )
    print(f"  {time.time() - start:.0f} s")


if __name__ == "__main__":
    main()
