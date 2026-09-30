# ADR 0002 — Les migrations passent en hook Sync, ordonnées par sync waves

- Statut : accepté
- Date : 2026-09-30

## Contexte

Le cahier prévoyait, pour les migrations de base de l'API, **un hook PreSync**.
L'intention derrière ce choix est parfaitement fondée, et elle ne change pas
avec cette décision :

- la migration tourne **une fois** par synchronisation, et non à chaque
  démarrage de conteneur — un `artisan migrate` dans l'entrypoint rejouerait la
  vérification à chaque redémarrage, et une migration cassée boucle alors en
  CrashLoopBackOff ;
- elle tourne **avant que le nouveau code soit déployé**. Si elle échoue, la
  synchronisation s'arrête et l'ancienne version de l'API continue de servir sur
  l'ancien schéma.

PreSync a été retenu comme « la phase qui vient avant ». C'est là qu'est
l'erreur, et elle n'apparaît qu'au premier déploiement réel.

## Symptôme

Premier déploiement réel de l'Application `api`. Le Job `api-migrate` ne démarre
pas :

```
Pod api-migrate-xxxxx   CreateContainerConfigError
  Error: configmap "api-config" not found
```

La synchronisation reste bloquée en phase PreSync. Aucune ressource de
l'Application n'est appliquée — ni le ConfigMap, ni le Secret, ni le Deployment.
L'Application ne sort jamais de `Progressing`.

## Cause

`PreSync` ne signifie pas « avant le Deployment ». Il signifie **avant la phase
Sync tout entière**, et la phase Sync est celle qui applique les ressources
ordinaires de l'Application — dont `api-config` et `api-secrets`, que le Job
monte par `envFrom`.

Le Job attendait donc deux ressources que sa propre phase interdisait d'avoir
déjà créées. Ce n'est pas un incident de circonstance : c'est **un ordre
impossible**. Le premier déploiement ne pouvait pas aboutir, et aucune
reconstruction depuis zéro ne le pourrait — seul un cluster où les deux
ressources existent déjà d'une vie antérieure masque le problème, ce qui en fait
exactement le genre de panne qui n'arrive qu'en reprise après sinistre.

Ce qu'aucun contrôle ne voyait, et c'est la parenté avec l'ADR 0001 : les deux
manifests sont **individuellement valides**. `kubeconform` les accepte, la
chaîne d'outils du repo-server les rend sans broncher. C'est la *relation* entre
eux qui est fausse, et une relation ne se lit que sur le rendu complet.

## L'écart avec le cahier

Le cahier demandait un hook PreSync ; ce dépôt déploie un hook Sync. L'écart
porte sur le mécanisme, pas sur la garantie.

Ce que PreSync apporte réellement, et que rien d'autre n'apporte : s'exécuter
avant que **quoi que ce soit** de l'Application soit appliqué. C'est le bon
outil pour un hook qui ne dépend de rien — les deux Jobs `teleport-*-test` du
chart Teleport valident un fichier de configuration qui est lui-même un hook, ils
sont à leur place en PreSync.

Ce n'était pas le besoin ici. Le besoin était « avant le Deployment », pas
« avant tout ». La phase Sync sait exprimer cela, et les sync waves y ordonnent
les hooks comme les ressources ordinaires, dans une seule et même phase :

| Vague | Ressources | Ce que la vague garantit à la suivante |
|---|---|---|
| **-1** | `api-config`, `api-secrets`, NetworkPolicy `api` | La configuration de la migration existe, et sa sortie vers PostgreSQL est ouverte. |
| **0** | Job `api-migrate` (hook Sync) | Le schéma est à jour. ArgoCD attend la fin du Job : un hook n'est sain qu'une fois terminé avec succès. |
| **1** | Deployment `api` | — |

La garantie du cahier est intacte : la migration tourne avant le nouveau code,
et son échec laisse l'ancienne version en place puisque la vague 1 n'est jamais
appliquée. Ce qui disparaît est la condition préalable impossible.

`Service` et `IngressRoute` restent en vague 0, sans annotation : ils ne
dépendent de rien et rien ne dépend d'eux.

## Décision

Le Job porte désormais :

```yaml
argocd.argoproj.io/hook: Sync
argocd.argoproj.io/sync-wave: "0"
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

La vague 0 est écrite explicitement bien qu'elle soit la valeur par défaut :
c'est le pivot du plan, pas un reste.

`hook-delete-policy` perd `HookSucceeded`. Le Job **survit** désormais à son
succès comme à son échec : ses journaux sont la seule trace de la dernière
migration, et `HookSucceeded` les effaçait précisément dans le cas nominal —
celui qu'on veut pouvoir relire pour savoir ce qui a été appliqué et quand.
`BeforeHookCreation` reste indispensable : c'est la synchronisation suivante qui
supprime le Job, juste avant de recréer le sien. Sans elle, le Job précédent
garderait son nom et la synchronisation échouerait sur un conflit de nom plutôt
que sur la migration.

### L'annotation du Secret est posée par kustomize

`api-secrets` est généré par KSOPS depuis `secrets.enc.yaml`. Son annotation de
vague est posée par un patch de `workloads/api/kustomization.yaml`, et non dans
le fichier chiffré : **SOPS calcule son MAC sur tout le document**, y compris les
champs laissés en clair par `encrypted_regex` — les métadonnées en font partie.
Deux lignes ajoutées à la main invalideraient le MAC, et ksops refuserait de
déchiffrer dans le repo-server. L'Application entière passerait en `Unknown`,
sur une erreur qui ne parlerait pas de sync waves.

### La NetworkPolicy aussi est en vague -1

Elle sélectionne `app.kubernetes.io/name: api`, label que le Job de migration
reprend : c'est elle qui autorise la migration à joindre PostgreSQL. ArgoCD
applique déjà les NetworkPolicy avant les Job à l'intérieur d'une même vague,
mais cet ordre est une convention interne d'ArgoCD, pas un ordre demandé par ce
dépôt. Une dépendance réseau ne se confie pas à un tri implicite : sans cette
règle, la migration n'échouerait pas franchement, elle **expirerait** — et
l'`activeDeadlineSeconds` de dix minutes du Job ferait échouer la
synchronisation bien après qu'on ait cherché ailleurs.

### Ce qui change réellement de comportement

Trois différences, aucune n'étant un effet de bord anodin :

1. **La migration voit la nouvelle configuration.** En PreSync, elle tournait
   avec le `api-config` et le `api-secrets` de la version *précédente*, non
   encore mis à jour. En vague 0, la vague -1 est déjà passée. C'est le
   comportement souhaitable — la migration lit la configuration de la version
   pour laquelle elle migre — mais c'est un changement.
2. **Une migration en échec laisse la vague -1 appliquée.** Le nouveau
   `api-config` est dans le cluster pendant que les anciens pods tournent
   encore. Ils ne le relisent pas : `envFrom` est résolu à la création du pod.
   Mais un pod redémarré pour une autre raison — éviction, OOMKill — pendant que
   la synchronisation est bloquée repartirait avec la nouvelle configuration et
   l'ancienne image. La fenêtre est étroite ; elle étend au ConfigMap la règle
   de compatibilité déjà posée pour les migrations : **on ajoute d'abord, on
   retire dans une version ultérieure.**
3. **Un objet Job terminé reste en permanence dans le namespace.** C'est le prix
   des journaux de la dernière migration, et il est payé sciemment.

### Alternatives écartées

- **Faire de `api-config` et `api-secrets` des hooks PreSync eux aussi.** Elles
  quitteraient la phase Sync : plus comparées à l'état désiré, candidates à
  l'élagage, et le Deployment dépendrait de ressources qui n'existent que si la
  phase de hook s'est déroulée. On transformerait deux ressources ordinaires en
  hooks pour servir un hook.
- **`optional: true` sur les `envFrom` du Job.** Le pod démarrerait, et la
  migration échouerait en tentant de joindre une base dont elle n'a ni l'adresse
  ni les identifiants — un défaut d'ordonnancement déguisé en panne de base de
  données. C'est aussi ce qui désarmerait le contrôle ci-dessous.
- **Migrer depuis un initContainer du Deployment.** L'échec surviendrait *après*
  que le Deployment est appliqué. Avec `strategy: Recreate`, l'ancien pod est
  déjà supprimé : on perdrait exactement la garantie qu'on cherche à tenir.

## Contrôle ajouté

Une étape 6 dans `scripts/render-argocd.sh`, donc dans la tâche de CI
`render-argocd`, et rejouable sur le poste comme le reste du script.

**La règle : un hook PreSync ne doit monter aucune ConfigMap ni aucun Secret qui
ne soit pas disponible avant la phase PreSync.** Elle s'applique aux `envFrom`,
aux `env.valueFrom`, aux volumes — y compris projetés — et aux
`imagePullSecrets`, sur les conteneurs comme sur les initContainers.

Trois situations sont acceptées, et aucune n'est une exception de complaisance :

- la ressource est elle-même un **hook PreSync**, d'une vague antérieure ou
  égale. C'est le cas des ConfigMap `teleport-auth-test` et
  `teleport-proxy-test` ;
- elle est produite par une **Application d'une wave strictement antérieure** :
  la root-app attend qu'une wave soit saine avant d'entamer la suivante. À wave
  égale, deux Applications se synchronisent en parallèle et aucun ordre n'est
  garanti ;
- la référence porte **`optional: true`**, le kubelet démarrant alors le
  conteneur sans elle.

Deux résolutions sont nécessaires pour que le verdict soit juste :

- **les hooks Helm comptent.** Le repo-server lit `helm.sh/hook` dès que
  `argocd.argoproj.io/hook` est absent, et `pre-install` devient PreSync — y
  compris pour un chart inflaté par kustomize. Sans cela les deux Jobs de
  Teleport seraient invisibles au contrôle ;
- **un Secret de cert-manager n'existe dans aucun manifeste.** Il est déclaré par
  le `spec.secretName` d'un Certificate. Le contrôle le résout, sans quoi le hook
  `teleport-proxy-test`, qui monte `teleport-tls`, serait signalé à tort. Un
  contrôle qui crie sur une configuration correcte apprend à ignorer l'alarme.

Éprouvé dans les deux sens. Sur l'arbre d'avant le correctif :

```
  ÉCHEC : le hook PreSync Job/api-migrate (api) monte ConfigMap/api-config,
    qui est une ressource ordinaire, créée par la phase Sync dans la même Application.
```

code de sortie 1, et les quatre hooks PreSync du dépôt tous examinés. Après le
correctif, `api-migrate` n'est plus un hook PreSync et sort du périmètre ; les
trois autres passent, `teleport-tls` et les deux ConfigMap de Teleport résolus.

Le contrôle garde donc sa valeur pour l'avenir : c'est un retour de `api-migrate`
en PreSync — ou un nouveau hook construit sur le même malentendu — qu'il refuse.

## worker et emitter : pas d'ordonnancement, une convergence

**Les sync waves ne traversent pas les Applications.** `worker` et `emitter`
vivent dans `workloads/worker`, une Application distincte, et montent le même
`api-config` et le même `api-secrets` par `envFrom`. Rien ne les ordonne après la
migration : les deux Applications portent la wave 7 de la root-app et se
synchronisent en parallèle.

**Décision : on ne les ordonne pas.** Porter `worker` en wave 8 ferait attendre
la santé de l'API à chaque synchronisation du worker, y compris quand seule son
image change. Le gain ne concerne que la reconstruction depuis zéro, et elle
converge seule — voici comment.

1. **`worker` et `emitter` partent en `CreateContainerConfigError`** tant que la
   vague -1 de `api` n'a pas créé `api-config` et `api-secrets`. Ce n'est pas un
   échec terminal : le pod reste planifié, et le kubelet retente la création du
   conteneur à chaque resynchronisation du pod. Dès que les deux ressources
   existent, les conteneurs démarrent, sans intervention ni redémarrage du pod.
2. **`worker` tourne alors normalement.** Il ne touche plus la base — le port
   5432 lui est fermé par NetworkPolicy — et consomme un stream vide.
3. **`emitter` démarre avant la fin de la migration** (vague 0), et sa purge de
   démarrage tombe sur un schéma absent : il sort en erreur et passe en
   CrashLoopBackOff. Le kubelet le relance avec un délai qui double à chaque
   échec, **plafonné à cinq minutes**. Il repart donc au plus tard cinq minutes
   après la fin de la migration, et se stabilise.

Rien dans cette séquence n'exige d'action. Elle a un coût d'affichage : pendant
la fenêtre, l'Application `worker` apparaît `Progressing`, puis `Degraded` si
`emitter` n'est pas disponible dans le `progressDeadlineSeconds` de dix minutes
de son Deployment — ce qui arrive si la migration elle-même approche de son
`activeDeadlineSeconds`. Elle redevient `Healthy` d'elle-même.

**Point à observer pendant RECON-01.** La convergence est déduite du
comportement du kubelet et d'ArgoCD, pas encore constatée sur une reconstruction
réelle. Pendant l'exercice, relever :

- l'heure à laquelle `api-config` apparaît, et celle à laquelle `worker` et
  `emitter` quittent `CreateContainerConfigError` ;
- le nombre de redémarrages d'`emitter`
  (`kube_pod_container_status_restarts_total`) et l'heure de fin du Job
  `api-migrate` ;
- le délai entre la fin du Job et la disponibilité d'`emitter`. **Au-delà de cinq
  minutes, ce n'est plus l'ordonnancement** : c'est un vrai défaut, à traiter
  comme tel ;
- si `worker` passe par `Degraded`, et combien de temps.

Si l'exercice montre une fenêtre inacceptable, le remède reste d'une ligne —
`worker` en wave 8 — et cet ADR sera amendé avec les mesures.

## Conséquences

- Le premier déploiement, et toute reconstruction depuis zéro, deviennent
  possibles. C'est la seule raison de cette décision.
- Une classe de défauts devient visible en CI : celle où deux manifests valides
  sont dans un ordre impossible. `kubeconform` ne pouvait pas la voir, aucun
  schéma ne décrivant une relation entre deux ressources.
- L'ordre interne de l'Application `api` est désormais écrit dans les manifests
  plutôt que déduit d'une phase. Il est lisible à la relecture, au prix de
  quatre annotations à maintenir cohérentes.
- `api-secrets` est la première ressource générée du dépôt à recevoir une
  annotation par patch. Le motif est réutilisable pour les autres secrets KSOPS,
  et la raison — le MAC de SOPS — mérite d'être connue avant d'éditer un
  `.enc.yaml` à la main pour n'importe quel autre motif.
