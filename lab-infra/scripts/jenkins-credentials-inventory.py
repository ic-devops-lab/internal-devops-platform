#!/usr/bin/env python3

import argparse
import csv
import sys
from pathlib import Path

import yaml


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("export", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    with args.export.open(encoding="utf-8") as stream:
        config = yaml.safe_load(stream)

    credentials = (
        config.get("credentials", {})
        .get("system", {})
        .get("domainCredentials", [])
    )

    rows = []

    for domain in credentials:
        for credential in domain.get("credentials", []):
            for kind, values in credential.items():
                rows.append(
                    {
                        "id": values.get("id", ""),
                        "kind": kind,
                        "description": values.get("description", ""),
                        "scope": values.get("scope", ""),
                    }
                )

    args.output.parent.mkdir(parents=True, exist_ok=True)

    with args.output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=["id", "kind", "description", "scope"],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"Found {len(rows)} credentials")
    print(f"Inventory saved to {args.output}")


if __name__ == "__main__":
    main()
