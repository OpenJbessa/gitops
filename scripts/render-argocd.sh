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
# Ce script répond d'abord à UNE question : la chaîne d'outils réellement
# déployée sait-elle rendre ce dépôt. Puis il vérifie les trois choses qu'on ne
# peut constater nulle part ailleurs, chacune sur ce que le repo-server produit
# et non sur ce qu'on croit qu'il produira :
#   - que chaque `subPath` monté depuis le volume d'outils est bien fabriqué par
#     un initContainer (étape 3). Un subPath dont la source manque ne fait pas
#     échouer le montage : le kubelet crée un répertoire à la place, et le
#     conteneur meurt ensuite sur « not a directory » ;
#   - la conformité aux schémas (étape 5) ;
#   - qu'aucun hook PreSync n'attend une ressource que la phase Sync n'a pas
#     encore créée (étape 6). Deux manifests valides peuvent être dans un ordre
#     impossible, et l'ordre ne se lit que sur le rendu complet.
#
# RIEN N'EST CODÉ EN DUR. Versions, options de build et contrat du volume
# d'outils sont lus dans le dépôt, à l'endroit qui fait foi :
#   - image argocd        : rendu du chart argo-cd avec bootstrap/argocd-values.yaml
#   - volume d'outils     : le Deployment repo-server rendu — initContainers,
#                           images, commandes et subPath montés
#   - kustomize.buildOptions : la ConfigMap argocd-cm rendue
# Une montée de version par Renovate est donc testée telle qu'elle sera déployée.
#
# LA VRAIE CLÉ AGE N'EST JAMAIS UTILISÉE. Une clé jetable est générée à chaque
# exécution, et des secrets factices sont fabriqués depuis les gabarits
# `*.example.yaml` puis chiffrés pour elle. Le dépôt est public et ce job tourne
# sur les pull requests venant de forks : il ne doit détenir aucun secret.
#
# CE SCRIPT EST LE RENDU QUI FAIT FOI. Il rend les vingt Applications puis fait
# valider SA sortie par kubeconform. Auparavant deux rendus coexistaient et
# c'est le mauvais qui était validé : celui du runner, avec un helm v3.16 que
# le cluster n'utilise pas. `scripts/render.py` reste l'aperçu rapide sur le
# poste, et lui fournit le plan de rendu par `--plan`.
#
# Usage : bash scripts/render-argocd.sh [répertoire de sortie]
# Prérequis : docker, helm, python3 + pyyaml, age, sops, kubeconform.
# ---------------------------------------------------------------------------
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAVAIL="$(mktemp -d)"
VOL_REPO="render-argocd-repo-$$"
VOL_TOOLS="render-argocd-tools-$$"
VOL_OUT="render-argocd-out-$$"

# Où atterrissent les manifests rendus. La CI passe un chemin qu'elle archive
# ensuite pour la tâche budget ; en local, un répertoire jetable suffit.
SORTIE="${1:-$TRAVAIL/rendu}"

# Version d'API contre laquelle valider. Celle du cluster, lue dans le README
# serait fragile : elle est posée ici et mentionnée dans le message d'aide.
VERSION_K8S="${VERSION_K8S:-1.36.0}"

# ---------------------------------------------------------------------------
# Catalogue de schémas CRD, épinglé à un commit.
#
# Il fournit les schémas que le schéma Kubernetes standard ne connaît pas :
# IngressRoute, Cluster CNPG, ScaledObject, ClusterPolicy, TeleportRoleV7.
#
# POURQUOI UN SHA ET PAS `main`. Un contrôle de conformité qui suit une branche
# n'est pas un contrôle : son verdict change sans qu'aucun commit du dépôt ne
# bouge. Une pull request verte le matin peut être rouge l'après-midi — et le
# plus dangereux des deux est l'inverse, un schéma assoupli en amont qui laisse
# passer ce qu'il refusait la veille. C'est la même règle que pour les charts et
# les images : ce qui décide d'un échec est épinglé.
#
# Renovate fait avancer ce digest comme il fait avancer un chart, par pull
# request relue. La tâche `pinning` refuse tout retour à une branche, et refuse
# aussi ce SHA sans l'annotation ci-dessous — épinglé pour de bon ne vaut pas
# mieux que flottant.
# renovate: datasource=git-refs depName=datreeio/CRDs-catalog packageName=https://github.com/datreeio/CRDs-catalog currentValue=main
CATALOGUE_CRDS_SHA="ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2"
CATALOGUE_CRDS="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CATALOGUE_CRDS_SHA}"

nettoyer() {
  docker volume rm -f "$VOL_REPO" "$VOL_TOOLS" "$VOL_OUT" >/dev/null 2>&1 || true
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

# ---------------------------------------------------------------------------
# Le contrat du volume d'outils, lu dans le POD RENDU et non dans les values.
#
# C'est la leçon d'un CrashLoopBackOff en production : les values disaient une
# chose, le pod en faisait une autre. Ce script lisait `repoServer.volumeMounts`
# avec une règle écrite à la main sur un chemin précis — il ne pouvait voir ni
# un montage venu d'ailleurs dans le chart, ni un chemin qu'on n'avait pas
# prévu. Tout ce qui suit est donc dérivé du Deployment rendu :
#
#   - quels initContainers écrivent dans le volume d'outils, et où ;
#   - quels `subPath` de ce volume le conteneur principal monte, et sur quoi.
#
# Rien n'est codé en dur, pas même le nom du volume : il est déduit du montage
# que les initContainers partagent avec le conteneur principal.
# ---------------------------------------------------------------------------
python3 - "$TRAVAIL/argocd-rendu.yaml" > "$TRAVAIL/outils.json" <<'PY'
import json, sys, yaml

for d in yaml.safe_load_all(open(sys.argv[1])):
    if (isinstance(d, dict) and d.get("kind") == "Deployment"
            and "repo-server" in d["metadata"]["name"]):
        sp = d["spec"]["template"]["spec"]
        break
else:
    raise SystemExit("Deployment repo-server introuvable dans le rendu")

principal = sp["containers"][0]

# Le volume d'outils : celui dont le conteneur principal monte des `subPath` et
# qu'un initContainer monte en entier pour le remplir.
inits = sp.get("initContainers") or []
candidats = {
    m["name"] for m in (principal.get("volumeMounts") or []) if m.get("subPath")
} & {
    m["name"] for c in inits for m in (c.get("volumeMounts") or []) if not m.get("subPath")
}
# Et il doit être un emptyDir : un volume persistant serait déjà peuplé, un
# secret ou une ConfigMap n'aurait pas besoin d'initContainer.
volumes = {v["name"]: v for v in sp.get("volumes") or []}
candidats = {n for n in candidats if "emptyDir" in volumes.get(n, {})}

if len(candidats) != 1:
    raise SystemExit(
        f"Attendu un seul volume d'outils rempli par initContainer, trouvé {sorted(candidats)}"
    )
volume = candidats.pop()

remplisseurs = []
for c in inits:
    for m in c.get("volumeMounts") or []:
        if m["name"] == volume and not m.get("subPath"):
            remplisseurs.append({
                "nom": c["name"],
                "image": c["image"],
                "commande": (c.get("command") or []) + (c.get("args") or []),
                "montage": m["mountPath"],
            })

attendus = [
    {"subPath": m["subPath"], "destination": m["mountPath"]}
    for m in principal.get("volumeMounts") or []
    if m["name"] == volume and m.get("subPath")
]

json.dump({"volume": volume, "remplisseurs": remplisseurs, "attendus": attendus},
          sys.stdout, ensure_ascii=False)
PY

echo "  image argocd      : $IMAGE_ARGOCD   (chart argo-cd $CHART_VERSION)"
echo "  buildOptions      : $BUILD_OPTIONS"
python3 - "$TRAVAIL/outils.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  volume d'outils   : {d['volume']}")
for r in d["remplisseurs"]:
    print(f"    rempli par      : {r['nom']} ({r['image']}) -> {r['montage']}")
for a in d["attendus"]:
    print(f"    monté           : {a['subPath']} -> {a['destination']}")
PY

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
echo "── 3. Outils du repo-server, et cohérence du volume partagé"

# On exécute les initContainers tels que le Deployment les déclare — même image,
# même commande, même point de montage — puis on vérifie que CHAQUE `subPath`
# monté par le conteneur principal existe bel et bien, et comme un FICHIER.
#
# POURQUOI CE CONTRÔLE EXISTE. Un montage `subPath` dont la source est absente
# n'échoue pas au montage : le kubelet crée le chemin manquant, et il le crée
# comme un RÉPERTOIRE. Le conteneur meurt alors au démarrage sur une erreur qui
# ne nomme ni le binaire ni l'initContainer :
#
#   error mounting ... to rootfs at "/usr/local/bin/kustomize": not a directory
#
# C'est ce qui a mis le repo-server en CrashLoopBackOff après que
# `--with-kustomize` a été retiré de l'initContainer : le montage, lui, était
# resté. La version précédente de ce script ne pouvait pas le voir — elle
# copiait les binaires avec `cp`, ce qui échoue bruyamment et autrement, et
# elle décidait quoi copier d'après une règle écrite à la main sur les values
# plutôt que d'après le pod rendu.
docker volume create "$VOL_TOOLS" >/dev/null

python3 - "$TRAVAIL/outils.json" > "$TRAVAIL/remplir.sh" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
for r in d["remplisseurs"]:
    cmd = " ".join(shlex.quote(x) for x in r["commande"])
    print(f'echo "  {r["nom"]} :"')
    print(f'docker run --rm --user 0:0 -v "$VOL_TOOLS:{r["montage"]}" '
          f'--entrypoint {shlex.quote(r["commande"][0])} {shlex.quote(r["image"])} '
          + " ".join(shlex.quote(x) for x in r["commande"][1:]))
PY
. "$TRAVAIL/remplir.sh"

# Le verdict : tout `subPath` monté doit exister comme fichier régulier.
echo
python3 - "$TRAVAIL/outils.json" > "$TRAVAIL/verifier.sh" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
print("manque=0")
for a in d["attendus"]:
    sp = shlex.quote(a["subPath"])
    dst = shlex.quote(a["destination"])
    print(f'''if [ -f /outils/{a["subPath"]} ]; then
  printf "  %-12s -> %-28s OK\\n" {sp} {dst}
else
  printf "  %-12s -> %-28s ABSENT\\n" {sp} {dst}
  manque=1
fi''')
print("exit $manque")
PY
if ! docker run --rm -i -v "$VOL_TOOLS:/outils" busybox sh -s < "$TRAVAIL/verifier.sh"; then
  echo
  echo "  ÉCHEC : un subPath monté par le conteneur principal n'est produit par"
  echo "  aucun initContainer. En cluster, le kubelet créerait ce chemin comme un"
  echo "  RÉPERTOIRE et le repo-server partirait en CrashLoopBackOff sur"
  echo "  « not a directory ». Retirer le montage, ou le faire produire."
  exit 1
fi

echo
echo "── 4. Rendu de TOUTES les Applications, dans l'image du repo-server"

docker volume create "$VOL_REPO" >/dev/null
cp "$TRAVAIL/keys.txt" "$TRAVAIL/repo/.ci-age-key"

# Le plan vient de render.py : Applications, sources, fichiers de valeurs et
# préfixe $values n'ont qu'une seule implémentation, quel que soit l'exécutant.
# Ici on ne fait que le traduire en commandes shell — l'image ArgoCD n'embarque
# ni python ni jq, elle ne pourrait pas lire le JSON elle-même.
python3 "$RACINE/scripts/render.py" --plan > "$TRAVAIL/plan.json"
python3 - "$TRAVAIL/plan.json" > "$TRAVAIL/repo/.ci-render.sh" <<'PY'
import hashlib, json, shlex, sys

plan = json.load(open(sys.argv[1]))
lignes = ["set -u", "mkdir -p /out", "echec=0"]

# Un dépôt Helm par URL, nommé par un hash : illisible, mais sans collision avec
# ce que l'image pourrait déjà connaître.
depots = {}
for app in plan:
    for e in app["etapes"]:
        if e["type"] == "helm" and e["repo"] not in depots:
            depots[e["repo"]] = "r" + hashlib.sha1(e["repo"].encode()).hexdigest()[:10]
for url, nom in sorted(depots.items(), key=lambda kv: kv[1]):
    lignes.append(f"helm repo add {nom} {shlex.quote(url)} >/dev/null")
if depots:
    lignes.append("helm repo update >/dev/null")

for app in plan:
    nom = app["nom"]
    cmds = []
    for e in app["etapes"]:
        if e["type"] == "helm":
            c = ["helm", "template", e["release"],
                 f"{depots[e['repo']]}/{e['chart']}",
                 "--version", e["version"], "--namespace", e["namespace"]]
            if e["skipTests"]:
                c.append("--skip-tests")
            for v in e["valeurs"]:
                c += ["-f", f"/repo/{v}"]
        else:
            c = ["kustomize", "build"] + shlex.split("$BUILD_OPTIONS") + [f"/repo/{e['chemin']}"]
        cmds.append(" ".join(shlex.quote(x) if x != "$BUILD_OPTIONS" else x for x in c))
    corps = " ; echo '---' ; ".join(cmds)
    lignes += [
        f"if {{ {corps} ; }} > /out/{nom}.yaml 2>/tmp/err.txt; then",
        f'  printf "  %-24s OK  (%s documents)\\n" {nom} "$(grep -c \'^apiVersion:\' /out/{nom}.yaml || true)"',
        "else",
        f'  printf "  %-24s ÉCHEC\\n" {nom}',
        '  sed "s/^/      /" /tmp/err.txt | head -6',
        "  echec=1",
        "fi",
    ]
lignes.append("exit $echec")
print("\n".join(lignes))
PY

tar c -C "$TRAVAIL/repo" . | docker run --rm -i -v "$VOL_REPO:/repo" busybox tar x -C /repo

# HOME=/ et la clé sous /.config/sops/age : c'est le chemin de montage posé par
# bootstrap/argocd-values.yaml. On éprouve la convention en même temps que le rendu.
#
# Les outils sont mis en place d'après le pod rendu, et non d'après une règle
# écrite ici : chaque `subPath` du volume d'outils est copié à la destination
# que le Deployment lui donne. La section 3 a déjà garanti qu'ils existent tous.
python3 - "$TRAVAIL/outils.json" > "$TRAVAIL/repo/.ci-outils.sh" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
for a in d["attendus"]:
    print(f'cp {shlex.quote("/custom-tools/" + a["subPath"])} {shlex.quote(a["destination"])}')
PY
tar c -C "$TRAVAIL/repo" .ci-outils.sh | docker run --rm -i -v "$VOL_REPO:/repo" busybox tar x -C /repo

docker volume create "$VOL_OUT" >/dev/null
docker run --rm --user 0:0 \
  -v "$VOL_TOOLS:/custom-tools" \
  -v "$VOL_REPO:/repo" \
  -v "$VOL_OUT:/out" \
  -e "BUILD_OPTIONS=$BUILD_OPTIONS" \
  --entrypoint sh "$IMAGE_ARGOCD" -c '
    set -e
    sh /repo/.ci-outils.sh
    mkdir -p /.config/sops/age && cp /repo/.ci-age-key /.config/sops/age/keys.txt
    export HOME=/
    echo "  kustomize : $(kustomize version)"
    echo "  helm      : $(helm version --short)"
    echo
    sh /repo/.ci-render.sh
  '

# Sortir les manifests du volume /out pour kubeconform ci-dessous et, en CI,
# pour la tâche budget.
mkdir -p "$SORTIE"
docker run --rm -v "$VOL_OUT:/out" busybox tar c -C /out . | tar x -C "$SORTIE"
echo "  manifests écrits dans $SORTIE"

echo
echo "── 5. Validation des schémas, sur CE rendu"

# Le point de tout ceci : kubeconform valide ce que le repo-server produit, avec
# SON helm et SON kustomize, et non ce que produirait la boîte à outils du
# runner. Les deux divergeaient — helm v3.16 côté CI, helm v4 dans l'image — et
# la validation portait donc sur des manifests qui n'étaient déployés nulle part.

# Le catalogue CRDs-catalog décrit `max_session_ttl` d'un TeleportRoleV7 avec
# `format: duration`, c'est-à-dire une durée ISO 8601 — « PT8H ». Teleport
# attend une durée Go : « 8h ». Le schéma est donc faux, pas le manifeste, et y
# obéir casserait le rôle.
#
# Plutôt qu'exclure le kind — ce qui retirerait aussi la validation de tout le
# reste de la ressource — on récupère le schéma amont et on en retire le SEUL
# mot-clé fautif. Il y en a cinq, tous des durées Teleport.
#
# Le schéma corrigé est régénéré à chaque exécution, donc rien n'est vendorisé —
# mais il est dérivé du MÊME commit épinglé que le reste du catalogue, et non de
# la branche. Sans quoi le correctif porterait sur une version du schéma et la
# validation sur une autre.
#
# Le nombre de `format: duration` retirés est vérifié : s'il tombe à zéro, c'est
# que le catalogue a corrigé le champ en amont et que ce contournement n'a plus
# lieu d'être. Mieux vaut l'apprendre par un échec au prochain bump de digest
# que le traîner des années.
SCHEMAS="$TRAVAIL/schemas/resources.teleport.dev"
mkdir -p "$SCHEMAS"
python3 - "$SCHEMAS" "$CATALOGUE_CRDS" <<'PY'
import json, pathlib, sys, urllib.request

URL = f"{sys.argv[2]}/resources.teleport.dev/teleportrolev7_v1.json"
schema = json.loads(urllib.request.urlopen(URL, timeout=30).read())

retires = 0
def nettoyer(o):
    global retires
    if isinstance(o, dict):
        if o.get("format") == "duration":
            del o["format"]
            retires += 1
        for v in o.values():
            nettoyer(v)
    elif isinstance(o, list):
        for v in o:
            nettoyer(v)

nettoyer(schema)
if retires == 0:
    raise SystemExit(
        "  Aucun `format: duration` dans le schéma TeleportRoleV7 du commit "
        "épinglé.\n  Le catalogue l'a probablement corrigé en amont : retirer "
        "ce contournement\n  et le schéma local, puis relancer."
    )
cible = pathlib.Path(sys.argv[1]) / "teleportrolev7_v1.json"
cible.write_text(json.dumps(schema))
print(f"  schéma TeleportRoleV7 corrigé : {retires} `format: duration` retirés")
PY

kubeconform \
  -strict \
  -summary \
  -kubernetes-version "$VERSION_K8S" \
  -schema-location default \
  -schema-location "$TRAVAIL/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -schema-location "$CATALOGUE_CRDS/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -ignore-missing-schemas \
  "$SORTIE"/*.yaml

echo
echo "── 6. Aucun hook PreSync ne dépend de la phase Sync"

# ---------------------------------------------------------------------------
# LA RÈGLE : un hook PreSync ne doit monter aucune ConfigMap ni aucun Secret
# qui ne soit pas lui-même disponible AVANT la phase PreSync.
#
# Pourquoi ce contrôle existe : le Job `api-migrate` était un hook PreSync et
# montait `api-config` et `api-secrets` par envFrom. Ces deux ressources sont
# créées par la phase Sync, qui s'exécute APRÈS la phase PreSync en entier. Le
# premier déploiement réel a donc échoué en CreateContainerConfigError,
# « configmap api-config not found » — et aucune reconstruction depuis zéro
# n'aurait pu aboutir. Détaillé dans docs/adr/0002.
#
# Rien dans les schémas ne pouvait l'attraper : les deux manifests sont
# parfaitement valides. C'est l'ORDRE entre eux qui ne l'est pas, et l'ordre ne
# se lit que sur le rendu complet — celui-ci, celui du repo-server.
#
# CE QUE LE CONTRÔLE ACCEPTE, et qui n'est pas une exception de complaisance :
#   - la ressource est elle-même un hook PreSync, d'une vague antérieure ou
#     égale (les Jobs de validation de Teleport et leurs ConfigMap) ;
#   - elle est produite par une Application d'une wave STRICTEMENT antérieure,
#     la root-app attendant qu'une wave soit saine avant la suivante. À wave
#     égale, deux Applications se synchronisent en parallèle : aucun ordre ;
#   - la référence porte `optional: true`, le kubelet démarrant alors sans elle.
#
# Un Secret de cert-manager n'existe dans aucun manifeste — il est déclaré par
# le `spec.secretName` d'un Certificate. Le contrôle le résout, sans quoi le
# hook de Teleport qui monte `teleport-tls` serait signalé à tort.
#
# Les hooks Helm comptent au même titre : le repo-server lit `helm.sh/hook` dès
# que `argocd.argoproj.io/hook` est absent, et `pre-install` devient PreSync —
# y compris pour un chart inflaté par kustomize, comme Teleport.
# ---------------------------------------------------------------------------
python3 - "$SORTIE" "$RACINE" <<'PY'
import pathlib, sys, yaml

RENDU = pathlib.Path(sys.argv[1])
RACINE = pathlib.Path(sys.argv[2])

HELM_VERS_ARGOCD = {
    "pre-install": "PreSync", "pre-upgrade": "PreSync", "pre-rollback": "PreSync",
    "post-install": "PostSync", "post-upgrade": "PostSync", "post-rollback": "PostSync",
    "post-delete": "PostDelete",
    "test": "Skip", "test-success": "Skip", "test-failure": "Skip",
}


def annotations(doc):
    return (doc.get("metadata") or {}).get("annotations") or {}


def phases(doc):
    """Phases de synchronisation d'une ressource. Ensemble vide = ressource ordinaire."""
    ann = annotations(doc)
    # L'annotation ArgoCD, quand elle existe, masque entièrement les hooks Helm.
    # C'est l'ordre de `util/hook.IsHook` dans le repo-server.
    if "argocd.argoproj.io/hook" in ann:
        return {p.strip() for p in str(ann["argocd.argoproj.io/hook"]).split(",") if p.strip()}
    if "helm.sh/hook" in ann:
        return {HELM_VERS_ARGOCD.get(h.strip(), "")
                for h in str(ann["helm.sh/hook"]).split(",")} - {""}
    return set()


def vague(doc):
    ann = annotations(doc)
    # ArgoCD traduit `helm.sh/hook-weight` en sync-wave pour les hooks Helm.
    for cle in ("argocd.argoproj.io/sync-wave", "helm.sh/hook-weight"):
        if cle in ann:
            try:
                return int(str(ann[cle]).strip())
            except ValueError:
                return 0
    return 0


def pod_spec(doc):
    spec = doc.get("spec") or {}
    if doc.get("kind") == "Pod":
        return spec
    if doc.get("kind") == "CronJob":
        spec = (spec.get("jobTemplate") or {}).get("spec") or {}
    tmpl = (spec.get("template") or {}).get("spec")
    return tmpl if isinstance(tmpl, dict) else None


def references(spec):
    """(kind, nom) de chaque ConfigMap et Secret dont le pod a BESOIN pour démarrer.

    `optional: true` est exclu : le kubelet démarre alors le conteneur sans la
    valeur, ce qui est précisément ce que cette règle laisse faire.
    """
    refs = set()

    def ajouter(kind, source, cle="name"):
        if isinstance(source, dict) and source.get(cle) and not source.get("optional"):
            refs.add((kind, source[cle]))

    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []) \
            + (spec.get("ephemeralContainers") or []):
        for e in c.get("envFrom") or []:
            ajouter("ConfigMap", e.get("configMapRef"))
            ajouter("Secret", e.get("secretRef"))
        for e in c.get("env") or []:
            vf = e.get("valueFrom") or {}
            ajouter("ConfigMap", vf.get("configMapKeyRef"))
            ajouter("Secret", vf.get("secretKeyRef"))

    for v in spec.get("volumes") or []:
        ajouter("ConfigMap", v.get("configMap"))
        ajouter("Secret", v.get("secret"), "secretName")
        for s in ((v.get("projected") or {}).get("sources")) or []:
            ajouter("ConfigMap", s.get("configMap"))
            ajouter("Secret", s.get("secret"))

    for s in spec.get("imagePullSecrets") or []:
        ajouter("Secret", s)

    return sorted(refs)


# Vague de chaque Application, telle que la root-app les ordonne.
vague_app = {}
for f in sorted((RACINE / "apps").rglob("*.yaml")):
    for doc in yaml.safe_load_all(f.read_text()):
        if isinstance(doc, dict) and doc.get("kind") == "Application":
            vague_app[doc["metadata"]["name"]] = vague(doc)

# Ce que produit chaque Application, et les hooks PreSync à examiner. Le nom du
# fichier de rendu EST le nom de l'Application (cf. render.py --plan).
produit, hooks = {}, []
for fichier in sorted(RENDU.glob("*.yaml")):
    app = fichier.stem
    for doc in yaml.safe_load_all(fichier.read_text()):
        if not isinstance(doc, dict) or "kind" not in doc:
            continue
        meta = doc.get("metadata") or {}
        ns, nom = meta.get("namespace") or "", meta.get("name")
        if not nom:
            continue
        produit[(ns, doc["kind"], nom)] = (app, doc)
        if doc["kind"] == "Certificate":
            secret = (doc.get("spec") or {}).get("secretName")
            if secret:
                produit.setdefault((ns, "Secret", secret), (app, None))
        if "PreSync" in phases(doc) and pod_spec(doc) is not None:
            hooks.append((app, ns, doc))

echec = []
for app, ns, doc in hooks:
    nom = doc["metadata"]["name"]
    refs = references(pod_spec(doc))
    print(f"  {app} : hook PreSync {doc['kind']}/{nom} — "
          f"{len(refs)} référence(s) obligatoire(s)")

    for kind, ref in refs:
        # Le namespace peut manquer dans le rendu : il vient alors de la
        # destination de l'Application, que ce rendu ne porte pas.
        app_source, cible = (produit.get((ns, kind, ref))
                             or produit.get(("", kind, ref))
                             or (None, None))

        if app_source is None:
            echec.append(
                f"le hook PreSync {doc['kind']}/{nom} ({app}) monte {kind}/{ref}, que ce "
                f"dépôt ne produit nulle part.\n"
                f"    Rien ne garantit son existence quand la phase PreSync s'exécute : une "
                f"reconstruction\n"
                f"    depuis zéro s'arrêtera en CreateContainerConfigError. Soit {kind}/{ref} "
                f"devient lui aussi\n"
                f"    un hook PreSync, soit la référence passe en `optional: true`."
            )
            continue

        ph = phases(cible) if cible is not None else set()

        if "PreSync" in ph:
            if vague(cible) > vague(doc):
                echec.append(
                    f"le hook PreSync {doc['kind']}/{nom} ({app}, vague {vague(doc)}) monte "
                    f"{kind}/{ref},\n"
                    f"    hook PreSync de vague {vague(cible)} — donc créé APRÈS lui. L'ordre "
                    f"des vagues\n"
                    f"    contredit la dépendance."
                )
            else:
                print(f"      {kind}/{ref} : hook PreSync de vague {vague(cible)} — ok")
            continue

        # Ressource ordinaire, ou hook d'une autre phase : acceptable seulement
        # si une Application d'une wave strictement antérieure la produit.
        if app_source != app and vague_app.get(app_source, 0) < vague_app.get(app, 0):
            origine = "Secret d'un Certificate" if cible is None else "ressource"
            print(f"      {kind}/{ref} : {origine} de l'Application {app_source} "
                  f"(wave {vague_app.get(app_source)} < {vague_app.get(app)}) — ok")
            continue

        quoi = ("une ressource ordinaire, créée par la phase Sync" if not ph
                else f"un hook de phase {', '.join(sorted(ph))}")
        ou = ("la même Application" if app_source == app
              else f"l'Application {app_source}, de wave {vague_app.get(app_source)} — "
                   f"la même que {app} ou une plus tardive")
        echec.append(
            f"le hook PreSync {doc['kind']}/{nom} ({app}) monte {kind}/{ref}, qui est {quoi}\n"
            f"    dans {ou}.\n"
            f"    La phase PreSync s'exécute ENTIÈREMENT avant la phase Sync : le pod du hook "
            f"restera\n"
            f"    en CreateContainerConfigError et aucun premier déploiement ne pourra "
            f"aboutir. Passer\n"
            f"    le hook en phase Sync et ordonner par sync-wave — cf. docs/adr/0002."
        )

if echec:
    print()
    print("\n".join("  ÉCHEC : " + e for e in echec))
    sys.exit(1)
print(f"  {len(hooks)} hooks PreSync examinés, aucun ne dépend de la phase Sync.")
PY

echo
echo "RÉSULTAT : la chaîne d'outils du repo-server rend tout le dépôt, les"
echo "manifests qu'elle produit sont conformes aux schémas, et aucun hook PreSync"
echo "n'attend une ressource que la phase Sync n'a pas encore créée."
