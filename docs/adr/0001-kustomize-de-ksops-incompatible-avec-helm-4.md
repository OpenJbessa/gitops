# ADR 0001 — Le kustomize de KSOPS est incompatible avec Helm 4

- Statut : accepté
- Date : 2026-09-28

## Contexte

Le proxy Teleport immobilisait 156 Mo inutiles. Le chart `teleport-cluster`
insère un initContainer `wait-auth-update` dont la requête mémoire est codée en
dur à 256 Mo, alors qu'il ne fait qu'attendre une résolution DNS. Comme
Kubernetes réserve `max(initContainers, somme des conteneurs)` pour toute la vie
du pod, ces 256 Mo étaient bloqués en permanence pour un conteneur principal qui
en demande 100.

Aucune valeur du chart ne l'expose : `initContainers` ne fait qu'**ajouter** des
conteneurs. Et une source Helm d'une Application ArgoCD ne peut pas être patchée
par une source kustomize de la même Application — les deux sont rendues
indépendamment, puis concaténées.

La seule sortie était d'inflater le chart depuis kustomize, par le générateur
`helmCharts:`, et de poser un patch JSON sur cet initContainer. Ce qui demande
`--enable-helm` dans `kustomize.buildOptions` du repo-server.

## Symptôme

Le réglage a été posé, et vérifié dans la ConfigMap `argocd-cm` rendue :

```
kustomize.buildOptions: --enable-alpha-plugins --enable-exec --enable-helm
```

Les six tâches de la CI étaient vertes. `scripts/render.py`, qui reproduit le
repo-server, rendait les vingt Applications sans une erreur.

Et pourtant, en reproduisant le repo-server avec **ses propres binaires** —
image `quay.io/argoproj/argocd:v3.5.3`, binaire ksops de
`viaductoss/ksops:v4.5.1` — le rendu de `platform/teleport` échouait :

```
Error: Error: unknown shorthand flag: 'c' in -c
: unable to run: 'helm version -c --short' with env=[...] (is 'helm' installed?)
```

Fusionner aurait laissé l'Application `teleport` en `Unknown`, sur une erreur de
rendu sans rapport visible avec le changement — un patch de ressources mémoire.

## Cause

Trois éléments, chacun correct isolément.

1. `ksops install --with-kustomize` installe, en plus de ksops, **le kustomize
   que KSOPS embarque** : v5.3.0 pour KSOPS v4.5.1.
2. `bootstrap/argocd-values.yaml` montait ce kustomize **par-dessus celui de
   l'image ArgoCD** (v5.8.1), au motif que les deux devaient partager la même
   version d'API de plugin exec.
3. kustomize v5.3.0 détecte Helm en appelant `helm version -c --short`. La forme
   courte `-c` est un héritage de Helm 2 (`--client`), dépréciée en Helm 3 et
   **supprimée en Helm 4**. L'image `argocd:v3.5.3` embarque `helm v4.2.1`.

Le générateur `helmCharts:` était donc inutilisable dans le cluster, quelle que
soit la valeur de `kustomize.buildOptions`.

Ce qu'aucun contrôle ne voyait : la CI et le poste rendent avec **leur** kustomize
et **leur** helm, pas avec ceux du repo-server. Le dépôt peut être entièrement
valide et rester irrendable par le cluster. C'est un angle mort de principe, pas
un oubli ponctuel — et il concerne toute montée de version d'ArgoCD, de KSOPS ou
de Helm, aucune ne touchant le moindre manifeste.

## Décision

**Ne plus remplacer le kustomize de l'image ArgoCD.** `ksops install` est appelé
sans `--with-kustomize`, et seul le binaire `ksops` est monté dans le
repo-server.

Vérifié dans l'image, avec le binaire ksops et la clé age :

- `observability/victoriametrics` rend, **les deux secrets sont déchiffrés** :
  le kustomize v5.8.1 d'ArgoCD exécute le plugin exec de KSOPS sans difficulté.
  La prémisse du montage — une API de plugin qui devrait correspondre — ne tient
  plus pour ces versions.
- `platform/teleport` rend, avec la requête de l'initContainer à 100 Mi.

La dépendance s'inverse : la compatibilité du plugin repose désormais sur le
kustomize d'ArgoCD et non sur celui de KSOPS. C'est écrit dans les values et
dans le README comme point à revérifier.

## Contrôle ajouté

Une tâche de CI, `render-argocd`, adossée à `scripts/render-argocd.sh` pour
rester rejouable sur le poste.

Elle reproduit le repo-server au lieu de l'approximer :

- **rien n'est codé en dur.** L'image ArgoCD est extraite du rendu du chart
  `argo-cd` avec `bootstrap/argocd-values.yaml`, l'image KSOPS de l'initContainer
  de ce même fichier, et `kustomize.buildOptions` de la ConfigMap `argocd-cm`
  rendue. Une montée de version par Renovate est donc testée telle qu'elle sera
  déployée ;
- le binaire ksops est extrait de son image comme le fait l'initContainer, et le
  kustomize de KSOPS n'est monté que si les values le demandent — le YAML est
  lu, pas grepé, parce que le fichier *parle* de `--with-kustomize` dans le
  commentaire qui explique pourquoi il ne l'utilise plus ;
- `kustomize build` tourne sur **chaque source kustomize** déclarée par une
  Application, dans l'image, avec les buildOptions lues ;
- la clé age est **jetable, générée à chaque exécution**. Les secrets sont
  fabriqués depuis les gabarits `*.example.yaml` et chiffrés pour elle. La vraie
  clé n'a rien à faire dans une CI sans identifiant, sur un dépôt public dont les
  pull requests peuvent venir d'un fork.

La tâche a été éprouvée dans les deux sens sur une branche jetable. Avec
l'ancienne configuration réintroduite :

```
  kustomize : v5.3.0+ksops.v4.5.1
  helm      : v4.2.1+gd591a19

  platform/teleport                  ÉCHEC
      Error: Error: unknown shorthand flag: 'c' in -c
```

code de sortie 1. Avec le correctif, `kustomize : v5.8.1` et les quatorze
sources rendues.

`renovate.json` groupe ArgoCD, KSOPS, sops et l'image ArgoCD sous une règle qui
interdit la fusion automatique et pose le label `render-argocd-requis`.

### Un seul rendu, celui qui fait foi

La première version de ce contrôle s'ajoutait à la tâche `render`, qui rendait
avec le helm du runner (v3.16) et faisait valider *sa* sortie par `kubeconform`.
Deux rendus coexistaient donc, et c'est le mauvais qui était validé : les
schémas étaient vérifiés sur des manifests produits par un helm qui n'est
déployé nulle part, pendant que le cluster utilisait helm v4.2.

C'est la même erreur que celle de cet incident, un cran plus loin : valider
autre chose que ce qui tourne. Les deux tâches ont été fusionnées sur
`render-argocd`, qui rend les vingt Applications avec la chaîne du repo-server
puis lance `kubeconform` sur cette sortie — laquelle alimente ensuite la tâche
`budget`.

`scripts/render.py` reste, comme chemin rapide sur le poste, et garde la
découverte des Applications : son option `--plan` la livre en JSON à
`render-argocd.sh`, qui l'exécute dans l'image. La logique n'est écrite qu'une
fois, quel que soit l'exécutant.

Deux angles morts disparaissent au passage :

- **les trois Applications à secret SOPS** (`cert-manager-issuers`, `postgres`,
  `api`) n'étaient rendues ni validées nulle part. Avec les secrets factices,
  elles le sont ;
- **le schéma de `TeleportRoleV7`**. Le catalogue CRDs-catalog décrit
  `max_session_ttl` avec `format: duration`, soit une durée ISO 8601 (`PT8H`),
  alors que Teleport attend une durée Go (`8h`). Le schéma est faux, pas le
  manifeste, et lui obéir casserait le rôle. Plutôt qu'exclure le kind — ce qui
  retirerait la validation de tout le reste de la ressource — le script récupère
  le schéma amont et en retire les cinq `format: duration`, tous des durées
  Teleport. Rien n'est vendorisé : le schéma corrigé est régénéré à chaque
  exécution.

### Le catalogue de schémas est épinglé, lui aussi

Une dernière référence flottait : `kubeconform` tirait les schémas de CRD depuis
la branche `main` de CRDs-catalog, et le correctif du schéma Teleport aussi.
C'est la même faute que celles ci-dessus, dans une autre matière — ce qui décide
d'un échec de la CI doit être épinglé, sinon le verdict change sans qu'aucun
commit du dépôt ne bouge.

Le cas gênant n'est pas qu'une pull request devienne rouge du jour au lendemain.
C'est l'inverse : un schéma assoupli en amont laisse passer ce qu'il refusait la
veille, sans que personne ne l'apprenne. Un contrôle qui se relâche tout seul est
pire qu'un contrôle absent, parce qu'on continue de compter dessus.

Le SHA est déclaré une fois dans `scripts/render-argocd.sh`, sous une annotation
`# renovate: datasource=git-refs`, et sert aux deux usages — sans quoi le
correctif porterait sur une version du schéma et la validation sur une autre.
Un gestionnaire regex de `renovate.json` fait avancer le digest.

`pinning` refuse quatre choses désormais : une référence de schéma sur une
branche, une variable de référence qui ne vaut pas un SHA, un SHA sans
annotation Renovate — épinglé pour de bon ne vaut pas mieux que flottant — et
une clé dupliquée dans le workflow, que `yaml.safe_load` avalait en silence.
Les quatre ont été éprouvées par régression volontaire avant d'être retenues.

## Suite : le correctif a mis le repo-server en CrashLoopBackOff

Après fusion, le nouveau pod repo-server n'a jamais démarré :

```
error mounting ".../volume-subpaths/custom-tools/repo-server/0" to rootfs
at "/usr/local/bin/kustomize": ... not a directory
```

Le pod portait la NOUVELLE commande d'initContainer — `ksops install
/custom-tools`, sans `--with-kustomize` — et l'ANCIEN montage
`/usr/local/bin/kustomize` avec `subPath: kustomize`. Le binaire n'était donc
plus produit, mais le montage le réclamait toujours.

Ce qui rend la panne illisible est le comportement du kubelet : un `subPath`
dont la source est absente n'échoue pas au montage. Le kubelet **crée le chemin
manquant, et il le crée comme un répertoire**. Le conteneur meurt ensuite sur
un bind-mount de répertoire vers un fichier, avec un message qui ne nomme ni le
binaire absent ni l'initContainer qui aurait dû le produire.

`bootstrap/argocd-values.yaml` était pourtant correct, sur la branche comme sur
`main` : le rendu du chart ne produit que le montage `ksops`. L'écart était
dans l'objet vivant, pas dans le manifeste — signature d'un champ co-détenu par
un autre gestionnaire d'application côté serveur. ArgoCD applique en
`ServerSideApply=true` ; retirer une entrée de sa configuration ne la supprime
que s'il en est le seul propriétaire. L'installation d'amorçage par
`helm install` est le co-propriétaire le plus probable — supprimer le secret de
release Helm (étape 7 de l'amorçage) ne retire pas la propriété des champs.

### Remédiation, sans toucher au pod qui sert

Le Deployment a un réplica et aucune `strategy` explicite : RollingUpdate par
défaut, `maxUnavailable` 25 % arrondi à **0** et `maxSurge` à 1. L'ancien pod
reste donc Available tant que le nouveau n'est pas Ready — c'est ce qui a
permis au cluster de continuer à se synchroniser pendant la panne, et c'est ce
qui rend la correction sûre.

```bash
# 1. Constater qui détient les champs (lecture seule)
kubectl -n argocd get deploy argocd-repo-server \
  -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\n"}{end}'

# 2. Retirer l'entrée résiduelle, par sa clé de fusion et non par son index
kubectl -n argocd patch deployment argocd-repo-server --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"repo-server",
    "volumeMounts":[{"mountPath":"/usr/local/bin/kustomize","$patch":"delete"}]}]}}}}'

# 3. Attendre — cette commande ne supprime rien, elle observe
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=180s

# 4. Vérifier que le montage a disparu
kubectl -n argocd get deploy argocd-repo-server \
  -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].mountPath}'
```

Le patch crée un nouveau ReplicaSet. Le pod en échec occupe le créneau de surge
et sera retiré pour le libérer ; **l'ancien pod, lui, n'est remplacé qu'une fois
le nouveau Ready**. Aucune étape ne le supprime.

`Replace=true` ou `Force=true` dans les `syncOptions` auraient réglé le cas
d'autorité, et c'est précisément ce qu'il ne faut pas faire ici : ils
remplacent l'objet entier, donc recréent le repo-server — en supprimant le pod
qui sert les rendus, au moment exact où l'on en dépend.

### Ce que la CI ne voyait pas, et ce qu'elle voit maintenant

`render-argocd.sh` reproduisait le repo-server sur deux points faux :

1. **il copiait les binaires (`cp`) là où le pod les monte en `subPath`.** Une
   source absente fait échouer `cp` bruyamment ; elle fait créer un répertoire
   au kubelet, puis mourir le conteneur. Deux mécanismes, deux pannes, et c'est
   la seconde qui compte ;
2. **il décidait quoi copier d'après une règle écrite à la main sur les
   values** — « `/usr/local/bin/kustomize` est-il monté ? » — et non d'après le
   pod rendu. Il ne pouvait voir ni un montage venu d'ailleurs dans le chart, ni
   un chemin qu'on n'avait pas prévu.

La section 3 du script dérive désormais tout du Deployment rendu : quel volume
d'outils est rempli par initContainer, par quelles images et commandes, et
quels `subPath` le conteneur principal monte. Elle exécute les initContainers
tels que déclarés, puis vérifie que **chaque `subPath` monté existe comme
fichier régulier**. Un montage sans producteur fait échouer la tâche, avec le
message qui nomme la cause.

Cette vérification ferme le trou au niveau du manifeste — celui qui aurait
laissé partir un demi-changement, et le cas s'est présenté deux fois pendant
l'écriture de ce lot. Elle ne voit pas la dérive de l'objet vivant : aucune
tâche de CI ne parle au cluster, et ce dépôt ne détient aucun identifiant. Ce
trou-là est fermé par la remédiation ci-dessus et par le fait que le manifeste
est, lui, correct.

## Conséquences

- Une classe entière de régressions devient visible : celles où la chaîne
  d'outils du repo-server cesse d'être cohérente sans qu'aucun manifeste change.
- La CI gagne une tâche qui tire deux images Docker. C'est la plus lente du
  pipeline, et elle ne remplace pas `render` — l'une valide les manifests, l'autre
  la capacité du cluster à les produire.
- **Une action hors dépôt reste nécessaire** : déclarer `render-argocd` comme
  contrôle requis dans la protection de branche de `main`. Renovate peut refuser
  d'automerger, il ne peut pas empêcher une fusion manuelle. Tant que ce réglage
  n'est pas posé, la garantie repose sur la relecture.
- Teleport reste la seule Application à source unique du dépôt, et la seule à
  inflater son chart par kustomize. `charts/` est ignoré par git : le générateur
  fait un `helm pull` sur place, et le committer vendoriserait le chart.
