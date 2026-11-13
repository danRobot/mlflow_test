#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "google-auth-oauthlib==1.5.0",
# ]
# ///
"""Genera el secret GDRIVE_CREDENTIALS con tu cuenta de Google.

Los workflows backup y restore lo usan para guardar los respaldos en tu
Google Drive personal. Una service account no puede: Google no le da espacio
propio y solo sube archivos a unidades compartidas (Google Workspace).

Se hace una vez, en tu computador (abre el navegador):

  uv run scripts/gdrive_token.py client_secret.json

  o, sin uv:
  pip install google-auth-oauthlib==1.5.0
  python scripts/gdrive_token.py client_secret.json

client_secret.json es el ID de cliente de OAuth, tipo "App de escritorio",
del proyecto de Google Cloud con la API de Drive habilitada (pasos en el
README). Entra con la cuenta duena de la carpeta de respaldos y acepta el
permiso de Google Drive. Imprime una sola linea de JSON: copiala completa al
secret GDRIVE_CREDENTIALS. Con la CLI de GitHub puedes guardarla directo:

  uv run scripts/gdrive_token.py client_secret.json | gh secret set GDRIVE_CREDENTIALS

La linea da acceso a tu Drive: no la guardes en el repo. Para revocarla:
https://myaccount.google.com/permissions
"""

from __future__ import annotations

import argparse
import contextlib
import json
import sys

from google_auth_oauthlib.flow import InstalledAppFlow

SCOPES = ["https://www.googleapis.com/auth/drive"]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Genera GDRIVE_CREDENTIALS (OAuth de tu usuario de Google) para los respaldos en Drive."
    )
    parser.add_argument("client_secret", help="JSON del ID de cliente de OAuth (App de escritorio)")
    parser.add_argument(
        "--no-browser", action="store_true", help="no abrir el navegador: solo imprime el enlace"
    )
    args = parser.parse_args()

    try:
        flow = InstalledAppFlow.from_client_secrets_file(args.client_secret, scopes=SCOPES)
    except (OSError, ValueError) as e:
        sys.exit(
            f"No se pudo leer {args.client_secret} ({e}). Tiene que ser el JSON que descargas al crear "
            "un ID de cliente de OAuth de tipo 'App de escritorio'."
        )

    # Todo lo que imprime el flujo va a stderr: stdout queda solo para el JSON.
    with contextlib.redirect_stdout(sys.stderr):
        try:
            creds = flow.run_local_server(
                port=0,
                open_browser=not args.no_browser,
                authorization_prompt_message="Si el navegador no se abre solo, entra a este enlace:\n{url}\n",
                success_message="Listo: cierra esta pestana y vuelve a la terminal.",
                prompt="consent",  # para que Google entregue siempre el refresh token
            )
        except Warning as e:  # oauthlib: el permiso concedido no es el pedido
            sys.exit(
                f"Google no concedio el permiso de Drive ({e}). Vuelve a ejecutar y marca la casilla "
                "de Google Drive en la pantalla de permisos."
            )
    if not creds.refresh_token:
        sys.exit("Google no entrego un refresh token: vuelve a ejecutar el script.")

    info = json.loads(creds.to_json(strip=["token", "expiry"]))
    info["type"] = "authorized_user"
    print(json.dumps(info, separators=(",", ":")))
    if sys.stdout.isatty():
        print(
            "\nLa linea de arriba es el secret GDRIVE_CREDENTIALS (copiala completa). No la guardes en el repo.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
