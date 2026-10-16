#!/usr/bin/env python3
"""Chạy Flyway qua docker compose. Chạy SAU dbsetup.py, TRƯỚC pytest."""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_COMPOSE = HERE / "docker-compose.yml"  # chỉnh theo layout


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--compose-file", type=Path, default=Path(os.environ.get("COMPOSE_FILE", DEFAULT_COMPOSE)))
    p.add_argument("--command", default="migrate", choices=["migrate", "validate", "info"])
    args = p.parse_args(argv)

    if not os.environ.get("MIG_PASSWORD"):
        sys.exit("thiếu MIG_PASSWORD")

    for schema in ("contract", "service"):
        cmd = ["docker", "compose", "-f", str(args.compose_file), "run", "--rm",
               "-e", f"FLYWAY_LOCATIONS=filesystem:/flyway/sql/{schema}",
               "-e", f"FLYWAY_DEFAULT_SCHEMA={schema}",
               "-e", f"FLYWAY_SCHEMAS={schema}",
               "flyway", args.command]
        rc = subprocess.run(cmd, check=False).returncode
        if rc:
            return rc

    return 0


if __name__ == "__main__":
    sys.exit(main())