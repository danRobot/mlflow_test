#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     # La misma version que el servidor (infra/mlflow-server/Dockerfile).
#     "mlflow-skinny==3.17.0",
#     "tqdm==4.70.1",
# ]
# ///
"""Carga en un MLflow limpio un respaldo de scripts/backup_local.py.

Recrea, solo con la API de MLflow:

  - experimentos, con sus tags
  - corridas con su nombre, usuario, fechas, estado, parametros, tags,
    datasets de entrada y el historial completo de cada metrica
  - artefactos de cada corrida
  - logged models (MLflow 3), con sus artefactos y la corrida que los creo
  - modelos registrados, con versiones, alias y tags

MLflow no deja elegir los IDs: experimentos, corridas y logged models
reciben IDs nuevos. La correspondencia viejo -> nuevo queda en
id-map-AAAAMMDD-HHMMSS.json dentro de la carpeta del respaldo. Lo que use
nombres (experimentos, modelos registrados, alias como models:/x@champion)
sigue funcionando igual.

Uso, con el servidor recien desplegado (vacio):

  uv run scripts/restore_local.py --tracking-uri http://IP:8080
  uv run scripts/restore_local.py --tracking-uri http://IP:8080 ~/mlflow-backups/mlflow-backup-AAAAMMDD-HHMMSS

  o, sin uv:
  pip install mlflow-skinny==3.17.0 tqdm==4.70.1
  python scripts/restore_local.py --tracking-uri http://IP:8080

Muestra dos barras de progreso: metadatos (corridas y modelos creados) y
artefactos (bytes subidos, velocidad y tiempo restante).

Sin ruta, usa el respaldo mas reciente de ~/mlflow-backups (--dest cambia la
carpeta). Si el servidor ya tiene datos (corridas, experimentos aparte de
Default o modelos registrados) no hace nada: cargar encima duplicaria todo.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import os
import posixpath
import re
import sys
import threading
import time
from pathlib import Path

# Un respaldo no tiene por que mandar telemetria a terceros.
os.environ.setdefault("MLFLOW_DISABLE_TELEMETRY", "true")
# Sin el "View run at ..." que MLflow escribe por cada corrida terminada.
os.environ.setdefault("MLFLOW_SUPPRESS_PRINTING_URL_TO_STDOUT", "true")
# Las barras de MLflow (una por archivo) las reemplaza la barra general.
os.environ.setdefault("MLFLOW_ENABLE_ARTIFACTS_PROGRESS_BAR", "false")

import mlflow  # noqa: E402
import requests  # noqa: E402
from mlflow import MlflowClient  # noqa: E402
from mlflow.entities import (  # noqa: E402
    Dataset,
    DatasetInput,
    InputTag,
    LoggedModelOutput,
    Metric,
    Param,
    ViewType,
)
from mlflow.environment_variables import MLFLOW_MULTIPART_UPLOAD_MINIMUM_FILE_SIZE  # noqa: E402
from mlflow.store.artifact.artifact_repository_registry import get_artifact_repository  # noqa: E402
from mlflow.store.artifact.http_artifact_repo import HttpArtifactRepository  # noqa: E402
from mlflow.utils.credentials import get_default_host_creds  # noqa: E402
from mlflow.utils.mime_type_utils import _guess_mime_type  # noqa: E402
from mlflow.utils.rest_utils import augmented_raise_for_status, http_request  # noqa: E402
from tqdm import tqdm  # noqa: E402

NAME_RE = re.compile(r"^mlflow-backup-\d{8}-\d{6}$")
TERMINATED = {"FINISHED", "FAILED", "KILLED"}
# Tags que MLflow pone solo y que apuntan a IDs viejos: se recalculan.
SKIP_MODEL_TAGS = {"mlflow.modelVersions"}


def log(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def abort(msg: str) -> None:
    """Como die, pero sin esperar a las subidas que MLflow siga haciendo en
    otros hilos: al salir normal, Python esperaria a que terminen."""
    sys.stdout.flush()
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    os._exit(1)


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def chunks(items: list, size: int):
    for i in range(0, len(items), size):
        yield items[i : i + size]


def find_backup(arg: str | None, dest: Path) -> Path:
    if arg:
        path = Path(arg).expanduser().resolve()
    else:
        found = sorted(
            (p for p in dest.iterdir() if p.is_dir() and NAME_RE.match(p.name)) if dest.is_dir() else [],
            key=lambda p: p.name,
            reverse=True,
        )
        if not found:
            die(f"no hay respaldos en {dest} (indica la ruta del respaldo)")
        path = found[0]
    if path.name.endswith(".partial"):
        die(f"{path.name} es un respaldo a medias: no se puede usar")
    if not (path / "manifest.json").is_file():
        die(f"{path} no es un respaldo de backup_local.py (falta manifest.json)")
    return path


def check_server(tracking_uri: str) -> str:
    try:
        requests.get(f"{tracking_uri}/health", timeout=15).raise_for_status()
        resp = requests.get(f"{tracking_uri}/version", timeout=15)
    except requests.RequestException as e:
        die(f"no se puede contactar {tracking_uri} ({e}). ¿Esta encendida la EC2 y es la IP correcta?")
    return resp.text.strip() if resp.ok else "desconocida"


def check_empty(client: MlflowClient) -> None:
    """El destino debe ser un MLflow recien creado: solo el experimento Default, vacio."""
    exps = client.search_experiments(view_type=ViewType.ALL)
    others = [e.name for e in exps if e.name != "Default"]
    runs = client.search_runs([e.experiment_id for e in exps], run_view_type=ViewType.ALL, max_results=1)
    models = client.search_registered_models(max_results=1)
    if others or runs or models:
        die(
            "el servidor ya tiene datos"
            + (f" (experimentos: {', '.join(others[:5])})" if others else "")
            + ". Cargar encima duplicaria todo: usa un MLflow recien desplegado."
        )


def short(text: str, width: int = 28) -> str:
    return text if len(text) <= width else text[: width - 1] + "…"


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


class ProgressFile:
    """El archivo que sube requests: suma a la barra lo que va leyendo."""

    def __init__(self, f, progress: Progress):
        self._f, self._progress = f, progress
        self._pos = f.tell()

    def _advance(self) -> None:
        pos = self._f.tell()
        self._progress.add(pos - self._pos)  # negativo si requests rebobina para reintentar
        self._pos = pos

    def read(self, size: int = -1) -> bytes:
        data = self._f.read(size)
        self._advance()
        return data

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        result = self._f.seek(offset, whence)
        self._advance()
        return result

    def tell(self) -> int:
        return self._f.tell()

    # requests calcula el Content-Length con fstat y comprueba el modo binario.
    def fileno(self) -> int:
        return self._f.fileno()

    @property
    def mode(self) -> str:
        return self._f.mode


def count_parts(repo, progress: Progress) -> None:
    """Suma a la barra cada parte que MLflow sube directo al bucket.

    MLflow sube los archivos de 500 MB o mas (MLFLOW_MULTIPART_UPLOAD_MINIMUM_FILE_SIZE)
    por partes paralelas con URLs prefirmadas, sin informar del avance: se
    envuelve el metodo que sube cada parte, solo en este repositorio.
    """
    original = getattr(repo, "_upload_part", None)
    if original is None:  # otra version de MLflow: la barra avanza por archivo
        return

    def upload_part(*args, **kwargs):
        part = original(*args, **kwargs)
        local_file, start, size = (kwargs.get(k) for k in ("local_file", "start_byte", "size"))
        if None not in (local_file, start, size):
            progress.add(max(0, min(size, os.path.getsize(local_file) - start)))
        return part

    repo._upload_part = upload_part


def upload_dir(local_dir: Path, artifact_uri: str, tracking_uri: str, progress: Progress) -> int:
    """Sube los archivos de `local_dir` a `artifact_uri`. Devuelve cuantos son."""
    repo = get_artifact_repository(artifact_uri, tracking_uri=tracking_uri)
    count_parts(repo, progress)
    multipart_from = MLFLOW_MULTIPART_UPLOAD_MINIMUM_FILE_SIZE.get()
    files = sorted(p for p in local_dir.rglob("*") if p.is_file())
    for path in files:
        rel = path.relative_to(local_dir).as_posix()
        size = path.stat().st_size
        before = progress.done
        if isinstance(repo, HttpArtifactRepository) and size < multipart_from:
            # Lo que hace HttpArtifactRepository.log_artifact con los archivos
            # chicos (un PUT al servidor), pero contando los bytes que salen.
            with open(path, "rb") as f:
                resp = http_request(
                    get_default_host_creds(repo.artifact_uri),
                    "/" + rel,
                    "PUT",
                    data=ProgressFile(f, progress),
                    extra_headers={"Content-Type": _guess_mime_type(path.name)},
                )
                augmented_raise_for_status(resp)
        else:
            # Los grandes, como siempre: por partes directo al bucket si el
            # servidor lo permite, sin pasar por su memoria.
            repo.log_artifact(str(path), posixpath.dirname(rel) or None)
        progress.add(size - (progress.done - before))  # lo que no se conto por el camino
    return len(files)


class Restorer:
    def __init__(self, client: MlflowClient, backup: Path):
        self.client = client
        self.backup = backup
        self.exp_map: dict[str, str] = {}
        self.run_map: dict[str, str] = {}
        self.model_map: dict[str, str] = {}
        self.counts = {
            "experiments": 0,
            "runs": 0,
            "metric_points": 0,
            "logged_models": 0,
            "registered_models": 0,
            "model_versions": 0,
            "artifact_files": 0,
        }
        self.uploads: list[tuple[Path, str, str]] = []  # carpeta local, URI destino, etiqueta
        self.to_finalize: list[tuple[str, str]] = []  # logged model, estado final

    def upload_all(self) -> None:
        if not self.uploads:
            return
        total = sum(p.stat().st_size for d, _, _ in self.uploads for p in d.rglob("*") if p.is_file())
        with tqdm(total=total, desc="Subiendo", unit="B", unit_scale=True, unit_divisor=1024) as bar:
            progress = Progress(bar)
            for local, uri, label in self.uploads:
                bar.set_postfix_str(label, refresh=False)
                self.counts["artifact_files"] += upload_dir(local, uri, self.client.tracking_uri, progress)

    def experiment(self, exp_dir: Path) -> str:
        exp = load(exp_dir / "experiment.json")
        tags = exp.get("tags") or {}
        if exp["name"] == "Default":
            new_id = self.client.get_experiment_by_name("Default").experiment_id
            for k, v in tags.items():
                self.client.set_experiment_tag(new_id, k, v)
        else:
            new_id = self.client.create_experiment(exp["name"], tags=tags)
        self.exp_map[exp["experiment_id"]] = new_id
        self.counts["experiments"] += 1
        return new_id

    def run(self, run_dir: Path, exp_id: str, data: dict, label: str) -> str:
        info, rdata = data["info"], data["data"]
        tags = dict(rdata.get("tags") or {})
        # MLflow toma el usuario del tag mlflow.user ("unknown" si falta). Si la
        # corrida tenia usuario pero no el tag, se pasa y se quita despues.
        user = info.get("user_id")
        temp_user_tag = bool(user) and user != "unknown" and "mlflow.user" not in tags
        if temp_user_tag:
            tags["mlflow.user"] = user
        run = self.client.create_run(
            exp_id, start_time=info.get("start_time"), tags=tags, run_name=info.get("run_name")
        )
        new_id = run.info.run_id
        self.run_map[info["run_id"]] = new_id
        if temp_user_tag:
            self.client.delete_tag(new_id, "mlflow.user")

        params = [Param(k, str(v)) for k, v in (rdata.get("params") or {}).items()]
        for part in chunks(params, 100):
            self.client.log_batch(new_id, params=part)
        metrics = [
            Metric(key, p["value"], p["timestamp"], p["step"])
            for key, points in (data.get("metric_history") or {}).items()
            for p in points
        ]
        for part in chunks(metrics, 1000):
            self.client.log_batch(new_id, metrics=part)
        self.counts["metric_points"] += len(metrics)

        datasets = []
        for di in (data.get("inputs") or {}).get("dataset_inputs") or []:
            d = di["dataset"]
            datasets.append(
                DatasetInput(
                    Dataset(
                        d["name"],
                        d["digest"],
                        d["source_type"],
                        d["source"],
                        d.get("schema"),
                        d.get("profile"),
                    ),
                    [InputTag(k, v) for k, v in (di.get("tags") or {}).items()],
                )
            )
        if datasets:
            self.client.log_inputs(new_id, datasets=datasets)

        if (run_dir / "artifacts").is_dir():
            self.uploads.append((run_dir / "artifacts", run.info.artifact_uri, label))
        self.counts["runs"] += 1
        return new_id

    def logged_model(self, model_dir: Path, exp_id: str, m: dict, label: str) -> None:
        tags = {k: v for k, v in (m.get("tags") or {}).items() if k not in SKIP_MODEL_TAGS}
        params = {k: str(v) for k, v in (m.get("params") or {}).items()}
        new = self.client.create_logged_model(
            exp_id,
            name=m.get("name"),
            source_run_id=self.run_map.get(m.get("source_run_id") or ""),
            tags=tags or None,
            params=params or None,
            model_type=m.get("model_type") or None,
        )
        self.model_map[m["model_id"]] = new.model_id
        if (model_dir / "artifacts").is_dir():
            self.uploads.append((model_dir / "artifacts", new.artifact_location, label))
        # Se marca como listo cuando ya tenga sus artefactos (despues de subirlos).
        status = m.get("status") if m.get("status") in ("READY", "FAILED") else "READY"
        self.to_finalize.append((new.model_id, status))
        self.counts["logged_models"] += 1

    def finish_run(self, old_id: str, data: dict) -> None:
        """Salidas (logged models), parentRunId y estado final, cuando ya existen todos los IDs."""
        new_id = self.run_map[old_id]
        outputs = [
            LoggedModelOutput(self.model_map[o["model_id"]], o.get("step", 0))
            for o in (data.get("outputs") or {}).get("model_outputs") or []
            if o["model_id"] in self.model_map
        ]
        if outputs:
            self.client.log_outputs(new_id, outputs)
        parent = (data["data"].get("tags") or {}).get("mlflow.parentRunId")
        if parent in self.run_map:
            self.client.set_tag(new_id, "mlflow.parentRunId", self.run_map[parent])
        info = data["info"]
        if info.get("status") in TERMINATED:
            self.client.set_terminated(new_id, status=info["status"], end_time=info.get("end_time"))

    def new_source(self, source: str) -> str:
        """La fuente de una version de modelo con los IDs nuevos."""
        for old, new in {**self.run_map, **self.model_map}.items():
            source = source.replace(old, new)
        match = re.match(r"^mlflow-artifacts:/(\d+)/", source)
        if match and match.group(1) in self.exp_map:
            source = f"mlflow-artifacts:/{self.exp_map[match.group(1)]}/" + source[match.end() :]
        return source

    def registered_model(self, path: Path) -> None:
        rm = load(path)
        name = rm["name"]
        self.client.create_registered_model(
            name, tags=rm.get("tags") or None, description=rm.get("description")
        )
        for v in sorted(rm.get("versions") or [], key=lambda v: int(v["version"])):
            source = self.new_source(v["source"])
            model_id = v.get("model_id")
            if not model_id and source.startswith("models:/m-"):
                model_id = source[len("models:/") :].split("/")[0]
            mv = self.client.create_model_version(
                name,
                source,
                run_id=self.run_map.get(v.get("run_id") or ""),
                tags=v.get("tags") or None,
                description=v.get("description") or None,
                model_id=self.model_map.get(model_id or "", model_id),
            )
            if mv.version != str(v["version"]):
                print(f"AVISO: {name} v{v['version']} quedo como v{mv.version}", file=sys.stderr)
            stage = v.get("current_stage")
            if stage and stage != "None":
                self.client.transition_model_version_stage(name, mv.version, stage)
            self.counts["model_versions"] += 1
        for alias, version in (rm.get("aliases") or {}).items():
            self.client.set_registered_model_alias(name, alias, str(version))
        self.counts["registered_models"] += 1

    def restore(self) -> list[str]:
        exp_dirs = sorted((self.backup / "experiments").glob("*"), key=lambda p: int(p.name))
        total = sum(len(list((d / "runs").glob("*"))) + len(list((d / "models").glob("*"))) for d in exp_dirs)
        pending: list[tuple[str, dict]] = []
        lines = []
        with tqdm(total=total, desc="Metadatos", unit=" elem") as bar:
            for exp_dir in exp_dirs:
                exp_id = self.experiment(exp_dir)
                name = load(exp_dir / "experiment.json")["name"]
                runs = models = 0
                for run_dir in sorted((exp_dir / "runs").glob("*")):
                    data = load(run_dir / "run.json")
                    label = short(f"{name}/{data['info'].get('run_name') or run_dir.name[:8]}")
                    bar.set_postfix_str(label, refresh=False)
                    self.run(run_dir, exp_id, data, label)
                    pending.append((data["info"]["run_id"], data))
                    runs += 1
                    bar.update()
                for model_dir in sorted((exp_dir / "models").glob("*")):
                    m = load(model_dir / "model.json")
                    label = short(f"{name}/{m.get('name') or model_dir.name}")
                    bar.set_postfix_str(label, refresh=False)
                    self.logged_model(model_dir, exp_id, m, label)
                    models += 1
                    bar.update()
                lines.append(f"    {name}: {runs} corridas, {models} logged models")
            bar.set_postfix_str("", refresh=True)
        self.upload_all()
        for model_id, status in self.to_finalize:
            self.client.finalize_logged_model(model_id, status)
        for old_id, data in pending:
            self.finish_run(old_id, data)
        for path in sorted((self.backup / "registered_models").glob("*.json")):
            self.registered_model(path)
        return lines


def main() -> None:
    parser = argparse.ArgumentParser(description="Carga en un MLflow limpio un respaldo de backup_local.py.")
    parser.add_argument("backup", nargs="?", help="carpeta del respaldo (por defecto, el mas reciente)")
    parser.add_argument(
        "--tracking-uri",
        default=os.environ.get("MLFLOW_TRACKING_URI"),
        help="servidor MLflow destino, p. ej. http://IP:8080 (por defecto MLFLOW_TRACKING_URI)",
    )
    parser.add_argument(
        "--dest",
        default=str(Path.home() / "mlflow-backups"),
        help="carpeta donde buscar el respaldo mas reciente (por defecto ~/mlflow-backups)",
    )
    args = parser.parse_args()

    if not args.tracking_uri:
        die("falta el servidor: usa --tracking-uri http://IP:8080 (la IP sale en el resumen del deploy)")
    tracking_uri = args.tracking_uri.rstrip("/")
    if not tracking_uri.startswith(("http://", "https://")):
        die(f"--tracking-uri debe ser una URL http(s)://, no '{tracking_uri}'")

    backup = find_backup(args.backup, Path(args.dest).expanduser().resolve())
    manifest = load(backup / "manifest.json")
    server_version = check_server(tracking_uri)
    if server_version not in ("desconocida", mlflow.__version__):
        print(
            f"AVISO: el servidor es MLflow {server_version} y este cliente {mlflow.__version__}.",
            file=sys.stderr,
        )
    mlflow.set_tracking_uri(tracking_uri)
    # Sin los mensajes INFO de MLflow ("Waiting up to 300 seconds ..."); avisos y errores si.
    logging.getLogger("mlflow").setLevel(logging.WARNING)
    client = MlflowClient(tracking_uri)
    check_empty(client)

    expected = manifest.get("counts", {})
    log(
        f"Cargando {backup.name} (creado {manifest.get('created_at')}) en {tracking_uri} (MLflow {server_version})"
    )
    if not manifest.get("artifacts", True):
        print("AVISO: es un respaldo --no-artifacts: se cargan solo los metadatos.", file=sys.stderr)

    start = time.time()
    restorer = Restorer(client, backup)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
    map_path = backup / f"id-map-{stamp}.json"
    failure = None
    try:
        lines = restorer.restore()
    except BaseException as e:  # tambien Ctrl+C
        failure = "interrumpido" if isinstance(e, KeyboardInterrupt) else str(e)
    map_path.write_text(
        json.dumps(
            {
                "tracking_uri": tracking_uri,
                "experiments": restorer.exp_map,
                "runs": restorer.run_map,
                "logged_models": restorer.model_map,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    if failure is not None:
        abort(
            f"la carga fallo ({failure}). El servidor quedo a medias: vuelve a desplegarlo limpio "
            "(destroy y deploy) antes de reintentar."
        )

    print()
    print("\n".join(lines))
    print(f"Carga terminada en {time.time() - start:.0f} s. Verificacion contra el manifiesto:")
    mismatch = False
    labels = {
        "experiments": "experimentos",
        "runs": "corridas",
        "metric_points": "puntos de metricas",
        "logged_models": "logged models",
        "registered_models": "modelos registrados",
        "model_versions": "versiones",
        "artifact_files": "archivos",
    }
    for key, label in labels.items():
        got, want = restorer.counts[key], expected.get(key)
        if key == "artifact_files" and not manifest.get("artifacts", True):
            want = None
        ok = want is None or got == want
        mismatch |= not ok
        print(f"  {label:<20} {got}" + ("" if want is None else ("  OK" if ok else f"  ESPERADO {want}")))
    print(f"IDs viejos -> nuevos: {map_path}")
    if mismatch:
        die("los conteos no coinciden con el manifiesto")


if __name__ == "__main__":
    main()
