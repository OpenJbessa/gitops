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
