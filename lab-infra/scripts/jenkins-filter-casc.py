#!/usr/bin/env python3

import argparse
from pathlib import Path

import yaml


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--jenkins-url", required=True)
    args = parser.parse_args()

    with args.source.open(encoding="utf-8") as stream:
        exported = yaml.safe_load(stream)

    result = {}

    # Kubernetes clouds
    clouds = exported.get("jenkins", {}).get("clouds", [])

    if clouds:
        result["jenkins"] = {"clouds": clouds}

        for cloud in result["jenkins"]["clouds"]:
            if "kubernetes" in cloud:
                cloud["kubernetes"]["jenkinsUrl"] = args.jenkins_url

    # Global Shared Libraries
    libraries = exported.get("unclassified", {}).get("globalLibraries")

    if libraries:
        result.setdefault("unclassified", {})[
            "globalLibraries"
        ] = libraries

    # Global tools (optional)
    tools = exported.get("tool")

    if tools:
        result["tool"] = tools

    args.destination.parent.mkdir(parents=True, exist_ok=True)

    with args.destination.open("w", encoding="utf-8") as stream:
        yaml.safe_dump(result, stream, sort_keys=False)

    print(f"Generated {args.destination}")


if __name__ == "__main__":
    main()
