#!/usr/bin/env python3
"""Rend localement tout ce qu'ArgoCD rendrait dans le cluster.

Le script ne connaît aucune liste de composants : il découvre les Applications
sous apps/, en extrait charts, versions et fichiers de valeurs, puis reproduit
ce que fait le repo-server. Ajouter une brique au dépôt ne demande donc jamais
de toucher à la CI.

Les répertoires contenant un secret SOPS ne peuvent pas être rendus ici : le
déchiffrement exige la clé age privée, qui n'a rien à faire dans un runner
GitHub. Ils sont comptés à part et vérifiés autrement (scripts/check-secrets.sh).

Usage :
    scripts/render.py --out /tmp/rendered
"""

from __future__ import annotations

import argparse
import hashlib
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
                p = run(["kubectl", "kustomize", str(RACINE / src["path"])])
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/rendered", type=pathlib.Path)
    args = ap.parse_args()

    apps = applications()
    if not apps:
        print("Aucune Application trouvée sous apps/", file=sys.stderr)
        return 1

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
