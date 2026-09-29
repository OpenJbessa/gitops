#!/usr/bin/env python3
"""Rend localement tout ce qu'ArgoCD rendrait dans le cluster.

Le script ne connaît aucune liste de composants : il découvre les Applications
sous apps/, en extrait charts, versions et fichiers de valeurs, puis reproduit
ce que fait le repo-server. Ajouter une brique au dépôt ne demande donc jamais
de toucher à la CI.

Les répertoires contenant un secret SOPS ne peuvent pas être rendus ici : le
déchiffrement exige la clé age privée, qui n'a rien à faire dans un runner
GitHub, ni sur un poste pour un simple aperçu. Ils sont ignorés en silence.

DEUX MODES, UN SEUL PLAN DE RENDU
---------------------------------
Ce script rend avec le helm et le kustomize de la machine. C'est rapide, et
c'est ce qu'on veut pour itérer — mais ce n'est PAS ce que rend le cluster : le
repo-server d'ArgoCD a ses propres binaires, et une incompatibilité entre eux ne
se voit pas ici (cf. docs/adr/0001).

`--plan` sert exactement à ça : au lieu d'exécuter, le script émet en JSON la
liste des commandes à passer, avec des chemins relatifs à la racine du dépôt.
`scripts/render-argocd.sh` la reprend et l'exécute DANS l'image du repo-server.
La logique de découverte — Applications, sources, fichiers de valeurs, préfixe
$values — n'existe donc qu'ici, en un seul endroit, quel que soit l'exécutant.

Usage :
    scripts/render.py --out /tmp/rendered
    scripts/render.py --plan
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

import yaml

RACINE = pathlib.Path(__file__).resolve().parent.parent
PREFIXE_VALUES = "$values/"


def run(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True)


def applications() -> list[tuple[pathlib.Path, dict]]:
    """Toutes les Applications ArgoCD du dépôt, triées par sync-wave."""
    trouvees = []
    for chemin in sorted((RACINE / "apps").rglob("*.yaml")):
        for doc in yaml.safe_load_all(chemin.read_text()):
            if isinstance(doc, dict) and doc.get("kind") == "Application":
                trouvees.append((chemin, doc))
    trouvees.sort(
        key=lambda t: int(
            (t[1]["metadata"].get("annotations") or {}).get(
                "argocd.argoproj.io/sync-wave", "0"
            )
        )
    )
    return trouvees


def sources(app: dict) -> list[dict]:
    spec = app["spec"]
    return spec.get("sources") or ([spec["source"]] if "source" in spec else [])


def ajouter_depots(apps: list[tuple[pathlib.Path, dict]]) -> dict[str, str]:
    """`helm repo add` pour chaque dépôt de chart rencontré.

    Le nom local est dérivé d'un hash de l'URL : il n'a pas à être lisible, et
    ça évite toute collision avec les dépôts déjà configurés sur la machine.
    """
    urls = {
        s["repoURL"]
        for _, app in apps
        for s in sources(app)
        if "chart" in s
    }
    noms = {}
    for url in sorted(urls):
        nom = "r" + hashlib.sha1(url.encode()).hexdigest()[:10]
        run(["helm", "repo", "add", nom, url])
        noms[url] = nom
    if urls:
        run(["helm", "repo", "update"])
    return noms


def rendre(apps, depots, sortie: pathlib.Path) -> tuple[int, int, list[str]]:
    sortie.mkdir(parents=True, exist_ok=True)
    ok = ignore = 0
    echecs: list[str] = []

    for chemin, app in apps:
        nom = app["metadata"]["name"]
        wave = (app["metadata"].get("annotations") or {}).get(
            "argocd.argoproj.io/sync-wave", "?"
        )
        ns = app["spec"]["destination"]["namespace"]
        srcs = sources(app)

        # Le fichier de valeurs est porté par la source de chart, sous la forme
        # $values/<chemin relatif au dépôt>.
        morceaux: list[str] = []
        souci = None

        for src in srcs:
            if "chart" in src:
                release = (src.get("helm") or {}).get("releaseName", nom)
                cmd = [
                    "helm", "template", release,
                    f"{depots[src['repoURL']]}/{src['chart']}",
                    "--version", src["targetRevision"],
                    "--namespace", ns,
                ]
                for vf in (src.get("helm") or {}).get("valueFiles", []):
                    if not vf.startswith(PREFIXE_VALUES):
                        souci = f"valueFiles sans préfixe {PREFIXE_VALUES} : {vf}"
                        break
                    cmd += ["-f", str(RACINE / vf[len(PREFIXE_VALUES):])]
                if souci:
                    break
                p = run(cmd)
                if p.returncode:
                    souci = p.stderr.strip().splitlines()[0] if p.stderr else "helm template a échoué"
                    break
                morceaux.append(p.stdout)

            elif "path" in src:
                # --enable-helm : `platform/teleport` inflate son chart par le
                # générateur `helmCharts:` plutôt que par une source Helm
                # d'ArgoCD, seule façon de patcher un initContainer codé en dur
                # dans le chart. Le drapeau est posé sur tous les répertoires
                # parce qu'il est sans effet sur ceux qui n'ont pas de
                # `helmCharts:`, et qu'il reproduit `kustomize.buildOptions`
                # du repo-server (cf. bootstrap/argocd-values.yaml).
                p = run(["kubectl", "kustomize", "--enable-helm",
                         str(RACINE / src["path"])])
                if p.returncode:
                    err = (p.stderr or "").lower()
                    if "ksops" in err or "external plugins disabled" in err:
                        # Attendu : la clé age n'est pas disponible en CI.
                        continue
                    souci = p.stderr.strip().splitlines()[0] if p.stderr else "kustomize a échoué"
                    break
                morceaux.append(p.stdout)

        etat = "OK"
        if souci:
            echecs.append(f"{nom} ({chemin.relative_to(RACINE)}) : {souci}")
            etat = "ÉCHEC"
        elif not morceaux:
            ignore += 1
            etat = "ignoré (secret SOPS)"
        else:
            (sortie / f"{nom}.yaml").write_text("\n---\n".join(morceaux))
            ok += 1

        print(f"  wave {wave:>2}  {nom:<22} {etat}")
        if souci:
            print(f"            {souci}")

    return ok, ignore, echecs


def plan(apps) -> list[dict]:
    """Le plan de rendu, en chemins RELATIFS à la racine du dépôt.

    Il décrit quoi rendre, pas comment ni avec quels binaires. C'est ce qui
    permet à render-argocd.sh de l'exécuter dans l'image du repo-server sans
    redéclarer la découverte des Applications.
    """
    entrees = []
    for chemin, app in apps:
        nom = app["metadata"]["name"]
        ns = app["spec"]["destination"]["namespace"]
        etapes: list[dict] = []
        for src in sources(app):
            if "chart" in src:
                helm = src.get("helm") or {}
                valeurs = []
                for vf in helm.get("valueFiles", []):
                    if not vf.startswith(PREFIXE_VALUES):
                        raise SystemExit(
                            f"{nom} : valueFiles sans préfixe {PREFIXE_VALUES} : {vf}"
                        )
                    valeurs.append(vf[len(PREFIXE_VALUES):])
                etapes.append({
                    "type": "helm",
                    "release": helm.get("releaseName", nom),
                    "repo": src["repoURL"],
                    "chart": src["chart"],
                    "version": src["targetRevision"],
                    "namespace": ns,
                    "valeurs": valeurs,
                    "skipTests": bool(helm.get("skipTests")),
                })
            elif "path" in src:
                etapes.append({"type": "kustomize", "chemin": src["path"]})
        if etapes:
            entrees.append({"nom": nom, "etapes": etapes})
    return entrees


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/rendered", type=pathlib.Path)
    ap.add_argument(
        "--plan",
        action="store_true",
        help="Émet le plan de rendu en JSON sur la sortie standard, sans rien "
             "exécuter. Consommé par scripts/render-argocd.sh, qui l'exécute "
             "avec les binaires du repo-server.",
    )
    args = ap.parse_args()

    apps = applications()
    if not apps:
        print("Aucune Application trouvée sous apps/", file=sys.stderr)
        return 1

    if args.plan:
        json.dump(plan(apps), sys.stdout, ensure_ascii=False)
        return 0

    print(f"{len(apps)} Applications découvertes\n")
    depots = ajouter_depots(apps)
    ok, ignore, echecs = rendre(apps, depots, args.out)

    print(f"\n{ok} rendues, {ignore} ignorées (secret SOPS), {len(echecs)} en échec")
    if echecs:
        print("\nÉchecs :")
        for e in echecs:
            print(f"  - {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
