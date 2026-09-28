#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Reproduit le repo-server d'ArgoCD et rend toutes les sources kustomize.
#
# POURQUOI CE SCRIPT EXISTE
#
# `scripts/render.py` rend avec le kustomize et le helm du poste ou du runner.
# C'est suffisant pour valider des manifests, mais ça ne dit RIEN de ce que le
# cluster saura rendre : le repo-server a ses propres binaires, et une
# incompatibilité entre eux passe entièrement sous le radar.
#
# C'est exactement ce qui est arrivé (cf. docs/adr/0001) : le kustomize livré
# par KSOPS appelait `helm version -c --short`, forme courte supprimée par
# Helm 4, et le générateur `helmCharts:` était inutilisable dans le cluster
# alors que tous les contrôles de la CI étaient verts.
#
# Ce script ne vérifie donc pas le contenu des manifests — les autres tâches
# s'en chargent — mais UNE seule chose : que la chaîne d'outils réellement
# déployée sait rendre ce dépôt.
#
# RIEN N'EST CODÉ EN DUR. Les trois versions et les options de build sont lues
# dans le dépôt, à l'endroit qui fait foi :
#   - image argocd        : rendu du chart argo-cd avec bootstrap/argocd-values.yaml
#   - image ksops         : l'initContainer de bootstrap/argocd-values.yaml
#   - kustomize.buildOptions : la ConfigMap argocd-cm rendue
# Une montée de version par Renovate est donc testée telle qu'elle sera déployée.
#
# LA VRAIE CLÉ AGE N'EST JAMAIS UTILISÉE. Une clé jetable est générée à chaque
# exécution, et des secrets factices sont fabriqués depuis les gabarits
# `*.example.yaml` puis chiffrés pour elle. Le dépôt est public et ce job tourne
# sur les pull requests venant de forks : il ne doit détenir aucun secret.
#
# Usage : bash scripts/render-argocd.sh
# Prérequis : docker, helm, python3 + pyyaml, age, sops.
# ---------------------------------------------------------------------------
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAVAIL="$(mktemp -d)"
VOL_REPO="render-argocd-repo-$$"
VOL_TOOLS="render-argocd-tools-$$"

nettoyer() {
  docker volume rm -f "$VOL_REPO" "$VOL_TOOLS" >/dev/null 2>&1 || true
  rm -rf "$TRAVAIL"
}
trap nettoyer EXIT

echo "── 1. Versions déployées, lues dans le dépôt"

# Le chart argo-cd et sa version, tels que l'Application les déclare.
read -r CHART_REPO CHART_VERSION < <(python3 - "$RACINE" <<'PY'
import pathlib, sys, yaml
racine = pathlib.Path(sys.argv[1])
for d in yaml.safe_load_all((racine / "apps/platform/argocd.yaml").read_text()):
    if not isinstance(d, dict) or d.get("kind") != "Application":
        continue
    spec = d["spec"]
    for s in spec.get("sources") or [spec.get("source", {})]:
        if s.get("chart") == "argo-cd":
            print(s["repoURL"], s["targetRevision"])
            raise SystemExit
raise SystemExit("chart argo-cd introuvable dans apps/platform/argocd.yaml")
PY
)

helm repo add argo-render-argocd "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update argo-render-argocd >/dev/null 2>&1
helm template argocd argo-render-argocd/argo-cd \
  --version "$CHART_VERSION" \
  --namespace argocd \
  --values "$RACINE/bootstrap/argocd-values.yaml" \
  > "$TRAVAIL/argocd-rendu.yaml"

# L'image du repo-server et les options de build, dans le rendu qui fait foi.
read -r IMAGE_ARGOCD < <(python3 - "$TRAVAIL/argocd-rendu.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(d, dict) or d.get("kind") != "Deployment":
        continue
    if "repo-server" not in d["metadata"]["name"]:
        continue
    print(d["spec"]["template"]["spec"]["containers"][0]["image"])
    raise SystemExit
raise SystemExit("Deployment repo-server introuvable dans le rendu")
PY
)

read -r BUILD_OPTIONS < <(python3 - "$TRAVAIL/argocd-rendu.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if isinstance(d, dict) and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "argocd-cm":
        print((d.get("data") or {}).get("kustomize.buildOptions", ""))
        raise SystemExit
raise SystemExit("ConfigMap argocd-cm introuvable dans le rendu")
PY
)

# L'image KSOPS, dans l'initContainer qui l'installe.
IMAGE_KSOPS="$(grep -oE 'viaductoss/ksops:[^"'"'"' ]+' "$RACINE/bootstrap/argocd-values.yaml" | head -1)"
[ -n "$IMAGE_KSOPS" ] || { echo "  image ksops introuvable dans bootstrap/argocd-values.yaml"; exit 1; }

# Le kustomize qui rendra le dépôt est-il celui de l'image, ou celui que KSOPS
# installe et qu'on monte par-dessus ? C'est toute la question de l'ADR 0001, et
# le script doit reproduire ce que disent les values, pas ce qu'on souhaite.
#
# La lecture se fait sur le YAML et non par `grep` : le fichier PARLE de
# `--with-kustomize` dans un commentaire expliquant pourquoi il ne l'utilise
# plus, et un grep y voyait la configuration fautive.
read -r REMPLACE_KUSTOMIZE INSTALLE_KUSTOMIZE < <(python3 - "$RACINE" <<'PY'
import pathlib, sys, yaml
v = yaml.safe_load((pathlib.Path(sys.argv[1]) / "bootstrap/argocd-values.yaml").read_text())
rs = v.get("repoServer") or {}
# Le kustomize effectivement exécuté : celui monté sur /usr/local/bin/kustomize.
monte = any((m.get("mountPath") == "/usr/local/bin/kustomize")
            for m in (rs.get("volumeMounts") or []))
# Et celui que l'initContainer installe dans le volume partagé.
installe = any("--with-kustomize" in (c.get("command") or [])
               for c in (rs.get("initContainers") or []))
print(int(monte), int(installe))
PY
)

if [ "$REMPLACE_KUSTOMIZE" = 1 ] && [ "$INSTALLE_KUSTOMIZE" = 0 ]; then
  echo "  INCOHÉRENCE : /usr/local/bin/kustomize est monté depuis custom-tools,"
  echo "  mais l'initContainer n'installe pas de kustomize (--with-kustomize absent)."
  echo "  Le repo-server démarrerait avec un kustomize manquant."
  exit 1
fi

echo "  image argocd      : $IMAGE_ARGOCD   (chart argo-cd $CHART_VERSION)"
echo "  image ksops       : $IMAGE_KSOPS"
echo "  buildOptions      : $BUILD_OPTIONS"
echo "  kustomize de KSOPS monté par-dessus celui de l'image : $([ "$REMPLACE_KUSTOMIZE" = 1 ] && echo OUI || echo non)"

echo
echo "── 2. Clé age jetable et secrets factices"

# Jamais la vraie clé : elle n'existe ni sur le runner ni dans ce script.
age-keygen -o "$TRAVAIL/keys.txt" 2>/dev/null
DESTINATAIRE="$(age-keygen -y "$TRAVAIL/keys.txt")"
echo "  destinataire jetable : $DESTINATAIRE"

# Copie de travail : la liste des fichiers vient de git — pour ne pas embarquer
# un `charts/` local ni un secret déchiffré qui traînerait — mais le CONTENU
# vient de l'arbre de travail, pour qu'une exécution locale teste ce qu'on
# s'apprête à committer et non le dernier commit.
mkdir -p "$TRAVAIL/repo"
git -C "$RACINE" ls-files -z > "$TRAVAIL/liste"
tar c -C "$RACINE" --null -T "$TRAVAIL/liste" -f - | tar x -C "$TRAVAIL/repo"

# Chaque gabarit devient le .enc.yaml correspondant, placeholders remplacés puis
# chiffré pour la clé jetable. Les vrais .enc.yaml de la copie sont écrasés :
# ils sont chiffrés pour une clé que ce job n'a pas, et n'ont rien à y faire.
NB_SECRETS=0
while IFS= read -r gabarit; do
  cible="${gabarit%.example.yaml}.enc.yaml"
  sed -E 's#REMPLACER[A-Za-z0-9_/.-]*#valeur-factice-de-ci#g' \
    "$TRAVAIL/repo/$gabarit" > "$TRAVAIL/repo/$cible"
  sops encrypt --age "$DESTINATAIRE" \
    --encrypted-regex '^(data|stringData)$' \
    --in-place "$TRAVAIL/repo/$cible"
  echo "  $cible"
  NB_SECRETS=$((NB_SECRETS + 1))
done < <(git -C "$RACINE" ls-files '*.example.yaml')
echo "  $NB_SECRETS secret(s) factice(s) chiffré(s) pour la clé jetable"

echo
echo "── 3. Binaire ksops, extrait comme le fait l'initContainer"

docker volume create "$VOL_TOOLS" >/dev/null
INSTALL_ARGS=(install)
[ "$INSTALLE_KUSTOMIZE" = 1 ] && INSTALL_ARGS=(install --with-kustomize)
docker run --rm --user 0:0 -v "$VOL_TOOLS:/custom-tools" \
  --entrypoint /usr/local/bin/ksops "$IMAGE_KSOPS" \
  "${INSTALL_ARGS[@]}" /custom-tools

echo
echo "── 4. Rendu de chaque source kustomize, dans l'image du repo-server"

docker volume create "$VOL_REPO" >/dev/null
cp "$TRAVAIL/keys.txt" "$TRAVAIL/repo/.ci-age-key"
tar c -C "$TRAVAIL/repo" . | docker run --rm -i -v "$VOL_REPO:/repo" busybox tar x -C /repo

CHEMINS="$(python3 - "$RACINE" <<'PY'
import pathlib, sys, yaml
racine = pathlib.Path(sys.argv[1])
vus = []
for f in sorted((racine / "apps").rglob("*.yaml")):
    for d in yaml.safe_load_all(f.read_text()):
        if not isinstance(d, dict) or d.get("kind") != "Application":
            continue
        spec = d["spec"]
        for s in spec.get("sources") or ([spec["source"]] if "source" in spec else []):
            p = s.get("path")
            if p and p not in vus:
                vus.append(p)
print("\n".join(sorted(vus)))
PY
)"

# HOME=/ et la clé sous /.config/sops/age : c'est le chemin de montage posé par
# bootstrap/argocd-values.yaml. On teste la convention en même temps que le rendu.
#
# Le kustomize monté est celui de KSOPS ou celui de l'image, selon ce que disent
# les values — voir REMPLACE_KUSTOMIZE plus haut.
docker run --rm --user 0:0 \
  -v "$VOL_TOOLS:/custom-tools" \
  -v "$VOL_REPO:/repo" \
  -e "BUILD_OPTIONS=$BUILD_OPTIONS" \
  -e "REMPLACE_KUSTOMIZE=$REMPLACE_KUSTOMIZE" \
  -e "CHEMINS=$CHEMINS" \
  --entrypoint sh "$IMAGE_ARGOCD" -c '
    set -e
    cp /custom-tools/ksops /usr/local/bin/ksops
    if [ "$REMPLACE_KUSTOMIZE" = 1 ]; then
      cp /custom-tools/kustomize /usr/local/bin/kustomize
    fi
    mkdir -p /.config/sops/age && cp /repo/.ci-age-key /.config/sops/age/keys.txt
    export HOME=/
    echo "  kustomize : $(kustomize version)"
    echo "  helm      : $(helm version --short)"
    echo
    echec=0
    for p in $CHEMINS; do
      if kustomize build $BUILD_OPTIONS "/repo/$p" > /tmp/out.yaml 2>/tmp/err.txt; then
        printf "  %-34s OK  (%s documents)\n" "$p" "$(grep -c "^apiVersion:" /tmp/out.yaml || true)"
      else
        printf "  %-34s ÉCHEC\n" "$p"
        sed "s/^/      /" /tmp/err.txt | head -6
        echec=1
      fi
    done
    exit $echec
  ' 2>&1

echo
echo "RÉSULTAT : la chaîne d'outils du repo-server rend toutes les sources."
