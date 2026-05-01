#!/usr/bin/env python3
"""Cross-reference checks for demo Kubernetes manifests (no cluster required)."""

from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "PyYAML is required. Install with: pip install pyyaml",
        file=sys.stderr,
    )
    sys.exit(1)

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_DIRS = [
    ROOT / "demo-1-cpu-hpa" / "k8s",
    ROOT / "demo-2-redpanda-keda" / "k8s",
]

REQUIRED = {
    "demo-1": {
        "Deployment": {"demo-1-cpu-hpa"},
        "Service": {"demo-1-cpu-hpa"},
        "HorizontalPodAutoscaler": {"demo-1-cpu-hpa"},
    },
    "demo-2": {
        "Namespace": {"demo-2-redpanda-keda"},
        "Deployment": {"consumer", "producer", "redpanda"},
        "Service": {"producer", "redpanda"},
        "ScaledObject": {"consumer-kafka-lag"},
    },
}


def ns(meta: dict) -> str:
    return (meta.get("namespace") or "").strip() or "default"


def load_object(path: Path) -> dict | None:
    text = path.read_text(encoding="utf-8")
    doc = yaml.safe_load(text)
    if doc is None:
        return None
    if not isinstance(doc, dict):
        print(f"{path}: expected a mapping document", file=sys.stderr)
        sys.exit(1)
    return doc


def main() -> None:
    deployments: dict[tuple[str, str], dict] = {}
    services: list[tuple[str, str, dict]] = []
    hpas: list[tuple[str, str, dict]] = []
    scaled_objects: list[tuple[str, str, dict]] = []
    kinds_by_demo: dict[str, dict[str, set[str]]] = defaultdict(
        lambda: defaultdict(set)
    )

    yaml_files = sorted(
        p for d in MANIFEST_DIRS for p in d.glob("*.yaml") if p.is_file()
    )
    if not yaml_files:
        print("No Kubernetes manifest YAML files found.", file=sys.stderr)
        sys.exit(1)

    for path in yaml_files:
        rel = path.relative_to(ROOT)
        obj = load_object(path)
        if obj is None:
            print(f"{rel}: empty document", file=sys.stderr)
            sys.exit(1)

        kind = obj.get("kind")
        if not kind:
            print(f"{rel}: missing kind", file=sys.stderr)
            sys.exit(1)

        demo = "demo-2" if "demo-2-redpanda-keda" in str(rel) else "demo-1"
        meta = obj.get("metadata") or {}
        name = meta.get("name")
        if not name:
            print(f"{rel}: missing metadata.name", file=sys.stderr)
            sys.exit(1)
        kinds_by_demo[demo][kind].add(name)

        if kind == "Deployment":
            spec = obj.get("spec") or {}
            template = spec.get("template") or {}
            tpl_meta = template.get("metadata") or {}
            pod_labels = tpl_meta.get("labels") or {}
            dep_key = (ns(meta), name)
            deployments[dep_key] = {
                "pod_labels": pod_labels,
                "selector": (spec.get("selector") or {}).get("matchLabels") or {},
            }
        elif kind == "Service":
            services.append((ns(meta), name, obj))
        elif kind == "HorizontalPodAutoscaler":
            hpas.append((ns(meta), name, obj))
        elif kind == "ScaledObject":
            scaled_objects.append((ns(meta), name, obj))

    # Required objects per demo
    for demo, want in REQUIRED.items():
        for kind, names in want.items():
            have = kinds_by_demo[demo].get(kind, set())
            missing = names - have
            if missing:
                print(
                    f"Missing required {kind}(s) in {demo}: "
                    f"{', '.join(sorted(missing))}",
                    file=sys.stderr,
                )
                sys.exit(1)

    def deployment_names_in_namespace(namespace: str) -> set[str]:
        return {n for (ns_, n) in deployments if ns_ == namespace}

    # Service selectors must match some Deployment's pod labels in the same namespace
    for namespace, svc_name, svc in services:
        spec = svc.get("spec") or {}
        selector = spec.get("selector") or {}
        if not selector:
            print(
                f"Service {namespace}/{svc_name} has empty spec.selector",
                file=sys.stderr,
            )
            sys.exit(1)
        matched = False
        for (dns, dname), dep in deployments.items():
            if dns != namespace:
                continue
            labels = dep["pod_labels"]
            if all(labels.get(k) == v for k, v in selector.items()):
                matched = True
                break
        if not matched:
            print(
                f"Service {namespace}/{svc_name}: selector {selector!r} matches no "
                f"Deployment pod template labels in that namespace",
                file=sys.stderr,
            )
            sys.exit(1)

    # HPA -> Deployment
    for namespace, hpa_name, hpa in hpas:
        spec = hpa.get("spec") or {}
        ref = spec.get("scaleTargetRef") or {}
        if ref.get("kind") != "Deployment":
            print(
                f"HPA {namespace}/{hpa_name}: expected scaleTargetRef.kind Deployment",
                file=sys.stderr,
            )
            sys.exit(1)
        target = ref.get("name")
        if not target:
            print(
                f"HPA {namespace}/{hpa_name}: missing scaleTargetRef.name",
                file=sys.stderr,
            )
            sys.exit(1)
        if target not in deployment_names_in_namespace(namespace):
            print(
                f"HPA {namespace}/{hpa_name}: scaleTargetRef.name {target!r} "
                f"is not an existing Deployment in namespace {namespace!r}",
                file=sys.stderr,
            )
            sys.exit(1)

    # ScaledObject -> Deployment (KEDA CRD; not validated by kubeconform without CRD schemas)
    for namespace, so_name, so in scaled_objects:
        spec = so.get("spec") or {}
        ref = spec.get("scaleTargetRef") or {}
        target = ref.get("name")
        if not target:
            print(
                f"ScaledObject {namespace}/{so_name}: missing scaleTargetRef.name",
                file=sys.stderr,
            )
            sys.exit(1)
        if target not in deployment_names_in_namespace(namespace):
            print(
                f"ScaledObject {namespace}/{so_name}: scaleTargetRef.name {target!r} "
                f"is not an existing Deployment in namespace {namespace!r}",
                file=sys.stderr,
            )
            sys.exit(1)

    print("Manifest consistency checks passed.")


if __name__ == "__main__":
    main()
