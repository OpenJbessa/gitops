#!/usr/bin/env python3
"""Vérifie que la réservation mémoire du cluster tient sous le plafond.

La contrainte structurante du projet est un nœud unique de 8 Go. Ce contrôle
existe parce qu'une clé de valeurs mal placée ne produit AUCUNE erreur Helm :
elle est simplement ignorée, et le pod part sans limite. C'est exactement ce
qui est arrivé au contrôleur ApplicationSet d'ArgoCD.

Le calcul applique la vraie règle Kubernetes :

    réservation du pod = max(somme des conteneurs, max des initContainers)

C'est cette règle qui a révélé que l'initContainer `wait-auth-update` du chart
Teleport, avec ses 256 Mo codés en dur, coûte plus cher que le conteneur
principal.

Le pic tient compte du plafond du ScaledObject KEDA : c'est la seule charge
dont le nombre de réplicas varie.

Usage :
    scripts/check-budget.py --manifests /tmp/rendered
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

import yaml

RACINE = pathlib.Path(__file__).resolve().parent.parent

# Plafond global, en Mio. Le nœud a 8 Go ; le reste va au système, au kubelet,
# à containerd et aux composants K3s (coredns, metrics-server, local-path).
PLAFOND_MIO = 4600

CHARGES = ("Deployment", "StatefulSet", "DaemonSet")


def en_mio(valeur) -> int:
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Mi|Gi|M|G|Ki|K)?", str(valeur or ""))
    if not m:
        return 0
    n, unite = float(m.group(1)), (m.group(2) or "")
    facteur = {"Gi": 1024, "G": 1024, "Ki": 1 / 1024, "K": 1 / 1024}.get(unite, 1)
    return int(n * facteur)


def memoire_pod(spec: dict) -> int:
    conteneurs = sum(
        en_mio((c.get("resources", {}).get("requests") or {}).get("memory"))
        for c in spec.get("containers") or []
    )
    inits = [
        en_mio((c.get("resources", {}).get("requests") or {}).get("memory"))
        for c in spec.get("initContainers") or []
    ]
    return max(conteneurs, max(inits, default=0))


def parcourir(docs):
    """Retourne (lignes, total, pic_supplementaire)."""
    lignes, total, pic = [], 0, 0
    for d in docs:
        if not isinstance(d, dict):
            continue
        kind = d.get("kind")
        nom = (d.get("metadata") or {}).get("name", "?")

        if kind in CHARGES:
            replicas = d["spec"].get("replicas", 1)
            if replicas == 0:
                lignes.append((nom, 0, "0 réplica"))
                continue
            unite = memoire_pod(d["spec"]["template"]["spec"])
            total += unite * replicas
            note = ""
            sp = d["spec"]["template"]["spec"]
            c = sum(en_mio((x.get("resources", {}).get("requests") or {}).get("memory"))
                    for x in sp.get("containers") or [])
            if unite > c:
                note = "imposé par un initContainer"
            lignes.append((nom, unite * replicas, note))

        # Cluster CloudNativePG : les ressources sont portées par la CR, pas
        # par un PodTemplate.
        elif kind == "Cluster" and str(d.get("apiVersion", "")).startswith("postgresql.cnpg.io"):
            r = d["spec"].get("resources", {})
            v = en_mio((r.get("requests") or {}).get("memory")) * d["spec"].get("instances", 1)
            total += v
            lignes.append((nom, v, "cluster postgresql"))

    return lignes, total, pic


def supplement_autoscaling(docs_locaux) -> tuple[int, str]:
    """Mémoire supplémentaire au pic, d'après le ScaledObject KEDA."""
    for d in docs_locaux:
        if isinstance(d, dict) and d.get("kind") == "ScaledObject":
            mini = d["spec"].get("minReplicaCount", 0)
            maxi = d["spec"].get("maxReplicaCount", mini)
            return maxi - mini, d["metadata"]["name"]
    return 0, ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifests", default="/tmp/rendered", type=pathlib.Path)
    args = ap.parse_args()

    docs = []
    fichiers = sorted(args.manifests.glob("*.yaml"))
    for f in fichiers:
        docs += list(yaml.safe_load_all(f.read_text()))

    # Les charges dont le rendu exige un secret SOPS ne sont pas dans la sortie
    # de render.py : on les lit directement depuis leurs manifests.
    directs = [
        RACINE / "data" / "postgres" / "cluster.yaml",
        RACINE / "workloads" / "api" / "deployment.yaml",
    ]
    for f in directs:
        if f.exists():
            docs += list(yaml.safe_load_all(f.read_text()))

    lignes, total, _ = parcourir(docs)

    print(f"{len(fichiers)} fichiers rendus + {len(directs)} manifests directs\n")
    for nom, mio, note in sorted(lignes, key=lambda x: -x[1]):
        suffixe = f"   <- {note}" if note else ""
        print(f"  {mio:>5} Mi   {nom}{suffixe}")

    scaled = list(yaml.safe_load_all(
        (RACINE / "workloads" / "worker" / "scaledobject.yaml").read_text()
    )) if (RACINE / "workloads" / "worker" / "scaledobject.yaml").exists() else []
    replicas_sup, nom_scaled = supplement_autoscaling(scaled)

    # Mémoire d'un réplica de worker, pour chiffrer le pic.
    worker = [d for d in docs
              if isinstance(d, dict) and d.get("kind") == "Deployment"
              and d["metadata"]["name"] == "worker"]
    par_replica = memoire_pod(worker[0]["spec"]["template"]["spec"]) if worker else 0
    supplement = replicas_sup * par_replica
    pic = total + supplement

    print()
    print(f"  Au repos : {total:>5} Mi   / {PLAFOND_MIO} Mi   marge {PLAFOND_MIO - total} Mi")
    if supplement:
        print(f"  Au pic   : {pic:>5} Mi   / {PLAFOND_MIO} Mi   marge {PLAFOND_MIO - pic} Mi"
              f"   (+{replicas_sup} réplicas de {nom_scaled} à {par_replica} Mi)")

    if pic > PLAFOND_MIO:
        print(f"\nÉCHEC : le pic dépasse le plafond de {pic - PLAFOND_MIO} Mi.")
        print("Soit réduire une réservation, soit abaisser maxReplicaCount du ScaledObject.")
        return 1

    print("\nOK : la réservation tient sous le plafond, au repos comme au pic.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
