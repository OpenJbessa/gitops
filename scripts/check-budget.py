#!/usr/bin/env python3
"""Vérifie que les réservations mémoire ET CPU du cluster tiennent sous leurs plafonds.

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

# Plafond mémoire, en Mio. Le nœud a 8 Go ; le reste va au système, au kubelet,
# à containerd et aux composants K3s (coredns, metrics-server, local-path).
PLAFOND_MIO = 4600

# Plafond CPU, en millicores. Le nœud a 2 vCPU ; le kubelet en réserve 300m
# (system-reserved + kube-reserved), l'allocatable est donc de 1700m, dont
# environ 200m sont pris par coredns, metrics-server et local-path-provisioner.
#
# Ce contrôle a été ajouté APRÈS le premier amorçage : le budget initial ne
# portait que sur la mémoire, et le cluster s'est retrouvé à 1730m demandés pour
# 1700m disponibles. Teleport ne pouvait plus être ordonnancé — « Insufficient
# cpu » — alors qu'il restait 2,4 Go de mémoire libre. Un budget qui ne surveille
# qu'une ressource ne surveille rien.
PLAFOND_CPU_M = 1500

CHARGES = ("Deployment", "StatefulSet", "DaemonSet")


def en_milli(valeur) -> int:
    """Millicores depuis une quantité Kubernetes ('100m', '0.5', '2')."""
    v = str(valeur or "")
    if not v:
        return 0
    if v.endswith("m"):
        return int(v[:-1])
    try:
        return int(float(v) * 1000)
    except ValueError:
        return 0


def en_mio(valeur) -> int:
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Mi|Gi|M|G|Ki|K)?", str(valeur or ""))
    if not m:
        return 0
    n, unite = float(m.group(1)), (m.group(2) or "")
    facteur = {"Gi": 1024, "G": 1024, "Ki": 1 / 1024, "K": 1 / 1024}.get(unite, 1)
    return int(n * facteur)


def _ressource_pod(spec: dict, cle: str, conv) -> int:
    conteneurs = sum(
        conv((c.get("resources", {}).get("requests") or {}).get(cle))
        for c in spec.get("containers") or []
    )
    inits = [
        conv((c.get("resources", {}).get("requests") or {}).get(cle))
        for c in spec.get("initContainers") or []
    ]
    return max(conteneurs, max(inits, default=0))


def memoire_pod(spec: dict) -> int:
    return _ressource_pod(spec, "memory", en_mio)


def cpu_pod(spec: dict) -> int:
    return _ressource_pod(spec, "cpu", en_milli)


def parcourir(docs):
    """Retourne (lignes, total_mio, total_cpu_m)."""
    lignes, total, total_cpu = [], 0, 0
    for d in docs:
        if not isinstance(d, dict):
            continue
        kind = d.get("kind")
        nom = (d.get("metadata") or {}).get("name", "?")

        if kind in CHARGES:
            replicas = d["spec"].get("replicas", 1)
            if replicas == 0:
                lignes.append((nom, 0, 0, "0 réplica"))
                continue
            sp = d["spec"]["template"]["spec"]
            unite = memoire_pod(sp)
            cpu = cpu_pod(sp)
            total += unite * replicas
            total_cpu += cpu * replicas

            somme_conteneurs = sum(
                en_mio((x.get("resources", {}).get("requests") or {}).get("memory"))
                for x in sp.get("containers") or []
            )
            note = "imposé par un initContainer" if unite > somme_conteneurs else ""
            lignes.append((nom, unite * replicas, cpu * replicas, note))

        # Cluster CloudNativePG : les ressources sont portées par la CR, pas
        # par un PodTemplate.
        elif kind == "Cluster" and str(d.get("apiVersion", "")).startswith("postgresql.cnpg.io"):
            r = (d["spec"].get("resources", {}).get("requests") or {})
            n = d["spec"].get("instances", 1)
            v, c = en_mio(r.get("memory")) * n, en_milli(r.get("cpu")) * n
            total += v
            total_cpu += c
            lignes.append((nom, v, c, "cluster postgresql"))

    return lignes, total, total_cpu


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

    lignes, total, total_cpu = parcourir(docs)

    print(f"{len(fichiers)} fichiers rendus + {len(directs)} manifests directs\n")
    for nom, mio, cpu, note in sorted(lignes, key=lambda x: -x[1]):
        suffixe = f"   <- {note}" if note else ""
        print(f"  {mio:>5} Mi   {cpu:>4}m   {nom}{suffixe}")

    scaled = list(yaml.safe_load_all(
        (RACINE / "workloads" / "worker" / "scaledobject.yaml").read_text()
    )) if (RACINE / "workloads" / "worker" / "scaledobject.yaml").exists() else []
    replicas_sup, nom_scaled = supplement_autoscaling(scaled)

    # Mémoire d'un réplica de worker, pour chiffrer le pic.
    worker = [d for d in docs
              if isinstance(d, dict) and d.get("kind") == "Deployment"
              and d["metadata"]["name"] == "worker"]
    sp_worker = worker[0]["spec"]["template"]["spec"] if worker else None
    par_replica = memoire_pod(sp_worker) if sp_worker else 0
    cpu_replica = cpu_pod(sp_worker) if sp_worker else 0
    supplement = replicas_sup * par_replica
    pic = total + supplement
    pic_cpu = total_cpu + replicas_sup * cpu_replica

    print()
    print(f"  Au repos : {total:>5} Mi   / {PLAFOND_MIO} Mi   marge {PLAFOND_MIO - total} Mi")
    if supplement:
        print(f"  Au pic   : {pic:>5} Mi   / {PLAFOND_MIO} Mi   marge {PLAFOND_MIO - pic} Mi"
              f"   (+{replicas_sup} réplicas de {nom_scaled} à {par_replica} Mi)")

    print()
    print(f"  CPU au repos : {total_cpu:>5}m / {PLAFOND_CPU_M}m   marge {PLAFOND_CPU_M - total_cpu}m")
    if replicas_sup:
        print(f"  CPU au pic   : {pic_cpu:>5}m / {PLAFOND_CPU_M}m   marge {PLAFOND_CPU_M - pic_cpu}m")

    echec = False
    if pic > PLAFOND_MIO:
        print(f"\nÉCHEC : le pic mémoire dépasse le plafond de {pic - PLAFOND_MIO} Mi.")
        print("Soit réduire une réservation, soit abaisser maxReplicaCount du ScaledObject.")
        echec = True
    if pic_cpu > PLAFOND_CPU_M:
        print(f"\nÉCHEC : le pic CPU dépasse le plafond de {pic_cpu - PLAFOND_CPU_M}m.")
        print("Un pod non ordonnançable pour cause de CPU affiche « Insufficient cpu »,")
        print("alors même qu'il reste de la mémoire libre.")
        echec = True
    if echec:
        return 1

    print("\nOK : mémoire et CPU tiennent sous leurs plafonds, au repos comme au pic.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
