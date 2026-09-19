# gitops

État désiré du cluster K3s de `jbessa.tech`. Ce dépôt est le seul que lit
ArgoCD, et la seule source de vérité du cluster.

L'infrastructure sous-jacente — VPS Hostinger, durcissement Debian, K3s — est
décrite dans le dépôt OpenTofu. Elle s'arrête au cluster nu, Traefik désactivé.
Ce dépôt reprend à partir de là.

---

## Sommaire

1. [Principes](#principes)
2. [Intégration continue](#intégration-continue)
3. [Amorçage](#amorçage)
4. [Carte des sync waves](#carte-des-sync-waves)
5. [Budget mémoire](#budget-mémoire)
6. [Secrets](#secrets)
7. [Étapes manuelles résiduelles](#étapes-manuelles-résiduelles)
8. [Valeurs à renseigner](#valeurs-à-renseigner)
9. [Restauration après perte d'ArgoCD](#restauration-après-perte-dargocd)
10. [Risques ouverts](#risques-ouverts)

---

## Principes

**Un seul nœud, 8 Go.** La mémoire est la ressource structurante. Chaque charge
porte des `requests` et `limits` explicites, et la plupart des décisions de ce
dépôt — nombre de réplicas, stratégie de déploiement, choix d'un composant
plutôt qu'un autre — en découlent directement. Les commentaires des fichiers le
disent à chaque fois.

**Aucune haute disponibilité revendiquée.** Un réplica pour l'API et le front,
une instance PostgreSQL, un Redis. Les déploiements utilisent `strategy:
Recreate` et provoquent une courte interruption : faire cohabiter deux pods
pendant une bascule doublerait la réservation mémoire au pire moment.

**Aucun chart vendorisé.** Les charts restent dans leurs dépôts amont. Ce dépôt
ne contient que des fichiers de valeurs et des manifests bruts.

**Aucun identifiant de cluster hors d'ici.** Aucune CI ne parle au cluster, pas
même celle de ce dépôt. Les dépôts applicatifs construisent, signent et poussent
leur image, puis ouvrent une pull request ici pour faire avancer un tag. Le
modèle reste strictement *pull* : ArgoCD va chercher son état, personne ne le
lui pousse. Le pipeline de `.github/workflows/validate.yml` ne détient donc
aucun secret et refuse simplement ce qui ne tient pas debout.

**Dépôt public.** ArgoCD le clone en anonyme, ce qui supprime le dernier
identifiant qu'il aurait fallu fournir à l'amorçage. En contrepartie, les
fichiers `.enc.yaml` sont lisibles par tous : la confidentialité repose
entièrement sur la clé privée age, jamais sur la discrétion du dépôt.

**Aucun secret en clair.** Tout secret est chiffré avec SOPS et age, et
déchiffré dans le repo-server d'ArgoCD par KSOPS.

---

## Intégration continue

`.github/workflows/validate.yml` s'exécute sur chaque pull request, sans aucun
secret et avec `permissions: contents: read` — une pull request venant d'un fork
ne peut donc rien exfiltrer, ce qui compte sur un dépôt public.

| Tâche | Ce qu'elle attrape |
|---|---|
| `secrets` | Clé privée committée, `.enc.yaml` non chiffré, `Secret` en clair, placeholder oublié. Tourne en premier : sur un dépôt public, une valeur poussée est compromise définitivement. |
| `render` | Reproduit le repo-server ArgoCD : `helm template` de chaque chart avec ses valeurs, `kustomize build` de chaque répertoire, puis validation `kubeconform` contre les schémas de l'API et des CRD. |
| `budget` | Calcule la réservation mémoire réelle, `max(conteneurs, initContainers) × réplicas`, et échoue au-dessus de 4 600 Mio — pic d'autoscaling inclus. |
| `pinning` | Version de chart flottante, image sans tag ou en `latest`. |
| `policies` | `kyverno validate` sur les ClusterPolicy. |
| `renovate` | `renovate-config-validator --strict`. |

La tâche `budget` mérite une explication : **une clé de valeurs Helm mal placée
ne produit aucune erreur**. Elle est ignorée en silence, et le pod part sans
limite mémoire. C'est exactement ce qui est arrivé au contrôleur ApplicationSet
d'ArgoCD et au contexte de sécurité de Kyverno pendant la construction de ce
dépôt. Le seul contrôle fiable est de mesurer le rendu.

Les trois Applications dont le rendu exige un secret SOPS (`cert-manager-issuers`,
`postgres`, `api`) ne sont pas rendues en CI : le déchiffrement demande la clé
age privée, qui n'a rien à faire dans un runner. Elles sont comptées à part et
couvertes par la tâche `secrets`.

Pour rejouer la validation localement avant de pousser :

```bash
bash scripts/check-secrets.sh
python3 scripts/render.py --out /tmp/rendered
python3 scripts/check-budget.py --manifests /tmp/rendered
```

---

## Amorçage

Sept commandes, dont **un seul `kubectl apply`**. Tout le reste du cluster
découle de celui-là.

Ce `kubectl apply` ne peut pas venir d'un workflow GitHub : il faudrait déposer
un kubeconfig dans les secrets du dépôt, ce qui contredirait le principe « aucun
identifiant de cluster hors d'ici » et exposerait le cluster à quiconque peut
déclencher un workflow. Un cluster où ArgoCD ne gère encore rien n'a de toute
façon personne pour le déclencher : l'amorçage est manuel par nature.

### Prérequis sur le poste

```bash
sudo apt install -y age
curl -fsSLO https://github.com/getsops/sops/releases/download/v3.9.4/sops_3.9.4_amd64.deb
sudo dpkg -i sops_3.9.4_amd64.deb && rm sops_3.9.4_amd64.deb
# helm : dépôt officiel baltocdn
# kubectl : ALIGNER LA MINEURE SUR CELLE DU SERVEUR (k3s --version sur le VPS).
#   Le client tolère un écart d'une mineure ; au-delà, certains verbes échouent
#   de façon peu explicite. Le cluster tourne actuellement en v1.36.
```

### Accès au cluster

Le port 6443 du VPS n'est pas ouvert sur Internet, et il n'a pas à l'être. On
passe par un tunnel SSH, ce qui permet aussi de garder la clé age sur le poste :

```bash
# terminal 1 — laisser ouvert pendant tout l'amorçage
ssh -N -L 6443:127.0.0.1:6443 <utilisateur>@<ip-vps>

# terminal 2
mkdir -p ~/.kube
# `sudo cat` et non `scp` : la configuration K3s pose write-kubeconfig-mode 0600,
# donc le fichier n'est lisible que par root et scp échoue sur un « Permission denied ».
ssh <utilisateur>@<ip-vps> "sudo cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/config-jbessa
chmod 600 ~/.kube/config-jbessa
export KUBECONFIG=~/.kube/config-jbessa

# Vérifier AVANT de poursuivre : sans kubeconfig valide, kubectl retombe
# silencieusement sur http://localhost:8080 et toutes les commandes suivantes
# échouent en cascade.
kubectl get nodes
```

Aucune modification du fichier n'est nécessaire : K3s y inscrit déjà
`https://127.0.0.1:6443`, et le certificat du kube-apiserver porte `127.0.0.1`
dans ses noms alternatifs. Le tunnel suffit.

### 1. Clé age

À générer **sur le poste, jamais sur le serveur** : c'est la racine de confiance
de tous les secrets du dépôt, et le VPS est précisément ce qu'elle protège.

```bash
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # -> à coller dans .sops.yaml
```

Sauvegarder la clé privée hors ligne (gestionnaire de mots de passe) **avant**
de continuer. Sans elle, aucun `.enc.yaml` n'est récupérable, ni par vous ni par
ArgoCD.

### 2. Namespace et clé privée dans le cluster

```bash
kubectl create namespace argocd
kubectl create secret generic sops-age -n argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
```

Ce secret ne peut pas être chiffré par SOPS : il *est* la clé de déchiffrement.
C'est la seule exception du dépôt.

### 3. Chiffrer les secrets

Trois fichiers, décrits dans [Secrets](#secrets). À faire maintenant : sans eux,
les waves 2, 5 et 7 resteront en échec.

### 4. Installer ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 10.9.1 \
  --values bootstrap/argocd-values.yaml \
  --wait --timeout 10m
```

La version doit être **exactement** celle de `apps/platform/argocd.yaml`. Si les
deux divergent, ArgoCD redéploiera ArgoCD au milieu de la synchronisation
initiale.

### 5. Le seul apply manuel

```bash
kubectl apply -f bootstrap/root-app.yaml
```

Idempotent : le réappliquer après modification du fichier est la procédure
normale de mise à jour de la root-app.

### 6. Suivre le déroulement

```bash
watch -n5 'kubectl get applications -n argocd \
  -o custom-columns=NOM:.metadata.name,WAVE:".metadata.annotations.argocd\.argoproj\.io/sync-wave",SYNC:.status.sync.status,SANTE:.status.health.status'
```

Compter vingt à trente minutes : la wave 2 attend la propagation DNS chez
Cloudflare, la wave 5 l'initialisation de PostgreSQL.

### 7. Nettoyer la release Helm orpheline

Une fois l'Application `argocd` en `Synced/Healthy`, ArgoCD gère ses propres
ressources et le secret de release Helm ne sert plus qu'à semer la confusion :

```bash
kubectl get application argocd -n argocd   # vérifier Synced + Healthy
kubectl delete secret -n argocd -l owner=helm,name=argocd
```

Les ressources restent en place : seul l'enregistrement de release disparaît.

### Mot de passe ArgoCD

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## Carte des sync waves

La root-app matérialise les Applications de `apps/`, chacune portant une
annotation `argocd.argoproj.io/sync-wave`. ArgoCD attend qu'une wave soit
*Healthy* avant d'entamer la suivante — c'est ce qui ordonne tout le cluster à
partir d'un seul apply.

| Wave | Composants | Ce que la wave garantit à la suivante |
|---|---|---|
| **0** | `namespaces`, `argocd` | Namespaces avec labels PSA et NetworkPolicies de refus par défaut. PSA est évalué à l'admission : sans ces labels, les pods suivants entreraient sans contrôle. |
| **1** | `cert-manager`, `traefik` | CRD `Certificate` et webhook opérationnels ; entrée HTTP du cluster en place. |
| **2** | `cert-manager-issuers` | `ClusterIssuer` Let's Encrypt et certificats émis. Le secret `teleport-tls` existe. |
| **3** | `kyverno` (+ policies), `keda`, `teleport` | Contrôle d'admission actif. **À partir d'ici, tout pod doit satisfaire les policies** : les waves 4 à 7 sont les premières réellement contrôlées. |
| **4** | `cnpg-operator`, `redis` | CRD `Cluster` et webhook CloudNativePG ; Redis prêt à accepter cache, sessions et file de jobs. |
| **5** | `postgres` | Base initialisée, rôle `app` créé, service `postgres-rw` résolvable. |
| **6** | `victoriametrics`, `vmagent`, `vmalert`, `kube-state-metrics`, `grafana`, `gatus` | Collecte et alertes en place **avant** les charges applicatives : le premier démarrage de l'API est donc observé. |
| **7** | `api`, `web`, `worker` | — |

Deux ordonnancements internes, invisibles dans cette table :

- Les **ClusterPolicy Kyverno** portent une sync-wave `1` *à l'intérieur* de
  l'Application `kyverno`. Kyverno valide ses propres policies par un webhook en
  `failurePolicy: Fail` : les soumettre depuis une Application séparée de la même
  wave échouerait selon l'ordre d'arrivée.
- Le **TLSStore** de Traefik et l'**IngressRouteTCP** de Teleport suivent la même
  logique, pour laisser les CRD de leur chart s'installer d'abord.

---

## Budget mémoire

Valeurs **mesurées** sur les manifests réellement rendus, pas déclarées. La
réservation d'un pod est `max(initContainers, somme des conteneurs) × réplicas`,
règle qui réserve quelques surprises (voir Teleport).

| Composant | Réservé | Budget cible | |
|---|---:|---:|---|
| ArgoCD (controller, repo-server, server, redis) | **704 Mo** | 450 | **+254** |
| Traefik | 80 Mo | 80 | |
| cert-manager (controller, webhook, cainjector) | 120 Mo | 120 | |
| Teleport (auth + proxy) | **356 Mo** | 200 | **+156** |
| Kyverno (admission seul) | 176 Mo | 200 | |
| KEDA (operator, metrics, webhooks) | 120 Mo | 120 | |
| CloudNativePG (opérateur) | 100 Mo | 100 | |
| PostgreSQL | 768 Mo | 768 | |
| Redis | 256 Mo | 256 | |
| VictoriaMetrics | 256 Mo | — | |
| vmagent | 128 Mo | — | |
| vmalert | 64 Mo | — | |
| *(sous-total VM + vmagent + vmalert)* | *448 Mo* | *450* | |
| Alertmanager | 80 Mo | 80 | |
| kube-state-metrics | **48 Mo** | — | **ajouté** |
| Grafana | 180 Mo | 180 | |
| Gatus | 32 Mo | 32 | |
| API Laravel | 320 Mo | 320 | |
| Front Nuxt | 256 Mo | 256 | |
| Worker (1 réplica) | 128 Mo | 128 | |
| **Total au repos** | **4 172 Mo** | **4 600** | marge 428 |
| **Total au pic** (worker à 4) | **4 556 Mo** | **4 600** | marge 44 |

### Rapporté à l'allocatable réel

Le plafond de 4 600 Mio est un garde-fou que la CI fait respecter. La vraie
contrainte est l'allocatable calculé par le kubelet à partir des réservations
posées dans `/etc/rancher/k3s/config.yaml` :

```
capacité du nœud        7 939 Mi
− system-reserved          600 Mi
− kube-reserved            300 Mi
− seuil d'éviction         250 Mi   (eviction-hard: memory.available<250Mi)
= allocatable            6 789 Mi
```

| | Mio | Part de l'allocatable |
|---|---:|---:|
| Requests au repos | 3 916 | 57 % |
| Requests au pic worker | 4 300 | 63 % |
| **Limites cumulées au pic** | **6 500** | **95 %** |

Les 63 % de requests sont confortables : l'ordonnanceur garde 2 489 Mio de
marge, de quoi absorber un pod de debug ou un Job de migration sans rien
déloger.

Les 95 % de limites, en revanche, disent le surengagement : **si toutes les
charges atteignaient leur plafond en même temps, le nœud serait à la limite de
l'éviction.** C'est le fonctionnement normal d'un nœud unique — on parie que les
pics ne coïncident pas — mais ça a deux conséquences pratiques :

- l'alerte `NoeudMemoireSaturee` (7 Go) est le signal qui précède l'éviction, pas
  une courtoisie ;
- tous les pods sont en QoS *Burstable*, donc l'éviction frappe d'abord celui
  qui dépasse le plus sa request. Si PostgreSQL devait être protégé
  explicitement, le levier serait une `priorityClassName` dédiée — non posée
  aujourd'hui, à envisager si des évictions surviennent.

Le levier de correction est alors les **limites**, pas les requests : baisser une
request libère de l'ordonnancement, baisser une limite réduit le surengagement.

### Les trois écarts, et pourquoi

**ArgoCD, +62 Mo.** L'application-controller a été tué par l'OOM killer neuf
secondes après son démarrage lors du premier amorçage, avec une limite à
256 Mo. La cause n'est pas sa consommation de régime — mesurée bien plus bas —
mais la synchronisation initiale de son cache : il liste d'un coup toutes les
ressources du cluster, CRD comprises. Le correctif ouvre surtout la **limite**
(512 Mo) plutôt que la request (256 Mo) : l'ordonnanceur réserve le régime
permanent, la limite absorbe le pic de démarrage.

**Teleport, +156 Mo.** Le chart `teleport-cluster` insère dans le pod proxy un
initContainer `wait-auth-update` dont les ressources sont codées en dur à
256 Mo / 512 Mo, avec ce commentaire des auteurs :

> propagating through the limits from the main resources section would double
> the requested amounts and may prevent scheduling on the cluster. as such, we
> hardcode small limits for this tiny container.

Comme Kubernetes réserve `max(init, conteneurs)` pour toute la durée de vie du
pod, le proxy immobilise 256 Mo alors qu'il en consomme une centaine. Ce n'est
pas réglable par les valeurs.

Deux sorties possibles si les 156 Mo deviennent gênants :
- passer l'Application Teleport en inflation Helm par kustomize (`helmCharts:`)
  et appliquer un patch JSON sur les ressources de cet initContainer — le chart
  reste amont, rien n'est vendorisé, mais Teleport sort du motif multi-source
  uniforme et il faut ajouter `--enable-helm` à `kustomize.buildOptions` ;
- accepter, ce qui est le choix actuel.

Un piège voisin a été corrigé : dès qu'on fournit un certificat par
`tls.existingSecretName`, le chart passe le proxy à **2 réplicas** même avec
`highAvailability.replicaCount: 1`. Il faut le forcer sous
`proxy.highAvailability.replicaCount`. Sans ça, Teleport coûtait 612 Mo.

**kube-state-metrics, +48 Mo.** Composant absent de la table initiale, ajouté
parce que deux livrables demandés en dépendent et ne sont pas réalisables
autrement : l'alerte `PodEnCrashLoop`
(`kube_pod_container_status_waiting_reason`, publié par rien d'autre) et le
panneau « réplicas worker » (`kube_deployment_status_replicas`). Ce n'est ni
kube-prometheus-stack ni l'opérateur Prometheus : un exportateur unique, sans
CRD ni webhook, restreint à quatre collecteurs.

### Ce qui a été évité

- **node-exporter** : le kubelet expose déjà `node_memory_working_set_bytes` et
  `node_cpu_usage_seconds_total` sur `/metrics/resource`.
- **redis_exporter** : le retard du consumer group est publié par KEDA lui-même
  (`keda_scaler_metrics_value`), qui le lit déjà pour décider de monter en charge.
- **sidecar de dashboards Grafana** : la ConfigMap est construite par kustomize
  et montée directement, son nom étant connu à l'avance.
- **opérateur VictoriaMetrics** : trois charts simples plutôt que
  `victoria-metrics-k8s-stack`.
- **opérateur Teleport** : les rôles sont appliqués par `tctl` (voir plus bas).

---

## Secrets

### Fonctionnement

`.sops.yaml` chiffre pour une seule clé age. `encrypted_regex: ^(data|stringData)$`
laisse `apiVersion`, `kind` et `metadata` en clair, sans quoi ni kustomize ni
KSOPS ne pourraient identifier la ressource avant déchiffrement.

Côté cluster, le repo-server d'ArgoCD monte la clé privée depuis le secret
`sops-age` et exécute KSOPS comme plugin exec de kustomize — un initContainer
qui copie les binaires, plutôt qu'un sidecar qui réserverait de la mémoire en
permanence.

Tout fichier chiffré est suffixé `.enc.yaml`. Les variantes en clair sont
bloquées par `.gitignore`.

### Prérequis : un éditeur

`sops edit` ouvre `$EDITOR`. Sans cette variable, la commande échoue de façon
peu explicite.

```bash
export EDITOR=nano                 # ou vim
export EDITOR="code --wait"        # VS Code : --wait est indispensable
```

### Créer un secret

Le travail se fait **en place, sur le fichier `.enc.yaml` lui-même**. Aucune
copie en clair n'existe jamais sur le disque, et il n'y a donc rien à effacer
ensuite.

```bash
cd <répertoire du secret>
cp <nom>.example.yaml <nom>.enc.yaml
sops encrypt --in-place <nom>.enc.yaml   # chiffre le gabarit, placeholders compris
sops edit <nom>.enc.yaml                 # remplace les valeurs, rechiffre à la sauvegarde
```

**Pourquoi pas `sops --encrypt fichier.yaml > fichier.enc.yaml`** : SOPS
applique ses `creation_rules` au chemin du fichier qu'on lui passe, et le
`path_regex` de `.sops.yaml` ne reconnaît que `*.enc.yaml`. Chiffrer un fichier
nommé autrement échoue sur `no matching creation rules found`.

### Relire ou modifier

```bash
sops edit <nom>.enc.yaml       # édition en place, rechiffrement à la sauvegarde
sops decrypt <nom>.enc.yaml    # lecture seule vers la sortie standard
```

### Vérifier qu'un fichier est bien chiffré

```bash
grep -c 'ENC\[AES256_GCM' <nom>.enc.yaml   # doit être > 0
grep -E '^(apiVersion|kind|type):' <nom>.enc.yaml   # doit rester lisible
```

Les deux à la fois : des valeurs chiffrées, et des métadonnées en clair pour que
kustomize et KSOPS sachent de quelle ressource il s'agit avant déchiffrement.

### Les trois secrets du dépôt

| Fichier à produire | Contenu | Wave bloquée sans lui |
|---|---|---|
| `platform/cert-manager/issuers/cloudflare-token.enc.yaml` | Jeton API Cloudflare | 2 — aucun certificat |
| `data/postgres/credentials.enc.yaml` | Mots de passe `app` et `postgres` | 5 — base non initialisée |
| `workloads/api/secrets.enc.yaml` | `APP_KEY`, identifiants base | 7 — API et worker |

**Duplication à surveiller** : `DB_PASSWORD` dans `workloads/api/secrets.enc.yaml`
doit être identique au mot de passe du rôle `app` dans
`data/postgres/credentials.enc.yaml`. Les secrets Kubernetes ne traversent pas
les namespaces, donc la même valeur est chiffrée deux fois. Les faire diverger
casse l'accès à la base sans message clair : l'API répond simplement 500.

### Rotation du mot de passe PostgreSQL

Les mots de passe de `credentials.enc.yaml` ne sont lus qu'à l'initialisation du
cluster. Les changer ensuite ne modifie pas le rôle dans PostgreSQL :

```bash
# 1. changer la valeur dans les DEUX fichiers chiffrés, merger
# 2. appliquer le changement dans PostgreSQL
kubectl exec -n data postgres-1 -c postgres -- \
  psql -c "ALTER ROLE app WITH PASSWORD '<nouveau>'"
# 3. redémarrer l'API et le worker pour qu'ils relisent le secret
kubectl rollout restart -n apps deployment/api deployment/worker
```

### Jeton Cloudflare

Permissions strictement nécessaires, sur la seule zone `jbessa.tech` :

```
Zone → DNS  → Edit
Zone → Zone → Read
```

Surtout pas la Global API Key, qui donne accès à l'intégralité du compte.

---

## Étapes manuelles résiduelles

Cinq, et chacune a une raison de ne pas être automatisée.

### 1. `kubectl apply -f bootstrap/root-app.yaml`

Le point de départ. Rien ne peut le déclencher depuis l'intérieur d'un cluster
où ArgoCD ne gère encore rien.

### 2. Le secret `sops-age`

Il contient la clé qui déchiffre tous les autres secrets. Le chiffrer avec SOPS
serait circulaire.

### 3. Les rôles Teleport

`platform/teleport/roles.yaml` est une ressource **Teleport**, pas un manifeste
Kubernetes. Il est volontairement absent de `kustomization.yaml` : ArgoCD ne
sait pas l'appliquer.

Les matérialiser en CRD imposerait l'opérateur Teleport, soit environ 64 Mo de
plus — un tiers au-dessus de l'enveloppe allouée à Teleport, déjà dépassée. Le
fichier reste donc la source de vérité versionnée, appliquée à la main :

```bash
kubectl exec -i -n teleport deploy/teleport-auth -- \
  tctl create -f < platform/teleport/roles.yaml
```

Toute modification passe par une pull request, puis par cette commande.

### 4. L'agent Teleport de l'hôte

Le nœud lui-même doit être enrôlé dans Teleport pour que l'accès SSH passe par
lui. L'agent tourne **sur l'hôte**, hors Kubernetes : un agent conteneurisé ne
donnerait pas accès au système du nœud, ce qui est précisément le besoin.

À faire pendant **la dernière session SSH avant fermeture du port 22** :

```bash
# depuis le poste, tunnel ouvert
kubectl exec -n teleport deploy/teleport-auth -- \
  tctl tokens add --type=node --ttl=1h

# sur le VPS, en SSH
curl https://cdn.teleport.dev/install.sh | sudo bash -s 18.10.0
sudo teleport node configure \
  --output=file:///etc/teleport.yaml \
  --token=<jeton> \
  --proxy=teleport.jbessa.tech:443 \
  --labels=role=node
sudo systemctl enable --now teleport
```

Vérifier que le nœud apparaît **avant** de fermer le port 22 :

```bash
tsh login --proxy=teleport.jbessa.tech:443
tsh ls          # le nœud doit être listé
tsh ssh ops@<nœud>      # et la connexion doit aboutir
```

La fermeture du port 22 elle-même se fait dans le dépôt OpenTofu.

### 5. Le premier tag d'image

`workloads/*/kustomization.yaml` porte `newTag: sha-REMPLACER_PAR_LE_PREMIER_DEPLOIEMENT`.
Aucune image n'existe encore. Après le premier build signé, la CI applicative
prend le relais :

```bash
cd workloads/api
kustomize edit set image ghcr.io/openjbessa/api=ghcr.io/openjbessa/api:sha-$GITHUB_SHA
```

et ouvre une pull request. Le dépôt applicatif ne reçoit jamais de kubeconfig.

---

## Valeurs à renseigner

### Bloquantes avant l'amorçage

| Valeur | Emplacement | Origine |
|---|---|---|
| Clé publique age | `.sops.yaml` | `age-keygen -y ~/.config/sops/age/keys.txt` |
| Adresse Let's Encrypt | `platform/cert-manager/issuers/clusterissuer.yaml` — **2 occurrences** | La vôtre ; sert aux avis d'expiration |
| Jeton API Cloudflare | `cloudflare-token.enc.yaml` | Cloudflare → My Profile → API Tokens |
| Mots de passe PostgreSQL | `data/postgres/credentials.enc.yaml` | `openssl rand -base64 32` |
| `APP_KEY` Laravel | `workloads/api/secrets.enc.yaml` | `php artisan key:generate --show` |
| `DB_PASSWORD` | `workloads/api/secrets.enc.yaml` | Identique au rôle `app` ci-dessus |

Déjà renseignés : domaine `jbessa.tech`, organisation `OpenJbessa`, registre
`ghcr.io/openjbessa`.

### Confirmé à la mise en service

Le PVC de Teleport s'appelle bien `teleport` : la valeur posée dans
`platform/teleport/recordings-gc.yaml` est correcte, la purge des
enregistrements trouvera son volume.

### Après le premier déploiement

| Valeur | Emplacement | Comment l'obtenir |
|---|---|---|
| Tags d'images | `workloads/*/kustomization.yaml` | Premier build de la CI |
| Destination Alertmanager | `observability/victoriametrics/alert-values.yaml` | Webhook Discord/Slack ou SMTP |
| ~~Stream et consumer group~~ | — | **tranché** : file sur listes Laravel, `listName: queues:default` |

### Enregistrements DNS

Déjà en place chez Cloudflare :

```
A  @  <ip-vps>  DNS only
A  *  <ip-vps>  DNS only
```

`teleport.jbessa.tech` **doit** rester en DNS only : Teleport fait du routage
ALPN et termine son propre TLS, que le proxy Cloudflare casserait.

---

## Restauration après perte d'ArgoCD

ArgoCD ne détient aucun état propre : tout vient de ce dépôt, sauf trois choses
qui vivent sur des volumes. C'est ce qui rend la restauration courte.

### Cas 1 — ArgoCD est cassé, le cluster tourne

Les charges continuent de fonctionner : ArgoCD n'est pas sur le chemin du
trafic. Reprendre l'amorçage à l'étape 4 :

```bash
helm uninstall argocd -n argocd    # laisse les CRD, keep: true
helm install argocd argo/argo-cd -n argocd --version 10.9.1 \
  --values bootstrap/argocd-values.yaml --wait
kubectl apply -f bootstrap/root-app.yaml
```

Les Applications sont recréées et **adoptent** les ressources existantes au lieu
de les recréer : le suivi se fait par annotation
(`application.resourceTrackingMethod: annotation`), qui survit à la disparition
d'ArgoCD. Aucune interruption des charges.

Le secret `sops-age` doit exister — s'il a disparu, le recréer avant (étape 2).

### Cas 2 — namespace `argocd` entièrement perdu

```bash
kubectl create namespace argocd
kubectl create secret generic sops-age -n argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
# puis étapes 4 et 5 de l'amorçage
```

Le mot de passe admin est régénéré ; les Applications sont reconstruites depuis
`apps/`.

### Cas 3 — cluster entièrement perdu

Reprendre l'amorçage du début sur un K3s nu. Ce qui **ne revient pas** avec le
dépôt :

| Donnée | Où elle vit | Conséquence |
|---|---|---|
| Données PostgreSQL | PVC local-path | **Perdues.** Les sauvegardes ne sont pas activées, voir Risques ouverts. |
| File de jobs et cache Redis | PVC local-path | Jobs en file perdus ; le cache se reconstruit seul. |
| État Teleport (utilisateurs, certificats d'hôte) | PVC local-path, SQLite | Recréer les utilisateurs, réenrôler l'agent de l'hôte. |
| Métriques | PVC VictoriaMetrics | 15 jours d'historique perdus. |

Sauvegarder au minimum, à intervalle régulier :

```bash
# sur le VPS
sudo tar czf /tmp/pvc-$(date +%F).tgz /var/lib/rancher/k3s/storage/
```

et rapatrier l'archive hors du VPS.

### Vérifier qu'ArgoCD peut déchiffrer

Après toute restauration :

```bash
kubectl exec -n argocd deploy/argocd-repo-server -- ls -l /.config/sops/age/keys.txt
kubectl get application cert-manager-issuers -n argocd \
  -o jsonpath='{.status.sync.status}{"\n"}'
```

Une Application avec un secret SOPS restée `Unknown` ou en erreur signale
presque toujours un problème de clé age.

---

## Risques ouverts

**Sauvegardes PostgreSQL désactivées.** La structure est prête dans
`data/postgres/cluster.yaml`, commentée : la destination de stockage n'est pas
arbitrée. En l'état, la seule protection est la copie du volume local-path, qui
partage le disque du nœud — donc aucune protection contre la perte du VPS.
C'est le risque le plus important du dépôt.

**Redis sans authentification.** Le contrôle d'accès repose entièrement sur la
NetworkPolicy. Si le contrôleur de NetworkPolicy de K3s est désactivé
(`--disable-network-policy`), Redis devient joignable par tout le cluster. À
vérifier sur le VPS :

```bash
sudo grep -E 'disable-network-policy' /etc/systemd/system/k3s.service
```

**Clé age dans etcd.** Le secret `sops-age` est stocké dans le datastore SQLite
de K3s. Si le chiffrement des secrets au repos n'est pas actif, il y est en
base64 :

```bash
sudo k3s secrets-encrypt status
```

Cela se corrige dans le dépôt OpenTofu (`--secrets-encryption`), de préférence
**avant** l'amorçage : l'activer après coup impose une rotation des secrets déjà
écrits.

**Chart Grafana déprécié en amont.** `grafana/grafana` porte `deprecated: true`
tout en continuant de publier la dernière version de Grafana (12.3.1). Aucun
remplaçant standalone n'existe : l'alternative est l'opérateur Grafana, qui
ajoute des CRD et un pod hors budget. Renovate étiquette ces mises à jour
`chart-deprecie` pour que l'arrêt des publications se remarque.

**Gatus surveille le nœud qui l'héberge.** Il ne dira rien le jour où le VPS
tombe. Une sonde externe est le complément naturel, hors périmètre de ce dépôt.

**Le namespace `traefik` est en PSA `privileged`.** Seule exception du cluster,
imposée par le ServiceLB de K3s : les pods `svclb-*` utilisent des `hostPort` et
la capability `NET_ADMIN`, refusées par `restricted` comme par `baseline`. Les
labels `audit` et `warn` restent sur `restricted` pour conserver le signal, et
le webhook Kyverno exclut ce namespace pour la même raison. Détaillé dans
`platform/namespaces/namespaces.yaml`.

**Le schéma de valeurs Traefik est lié à la majeure du chart.** La v41 valide
contre un schéma JSON strict — ce qui est une bonne nouvelle : une clé déplacée
fait échouer le rendu au lieu de dériver en silence. Mais une montée de majeure
proposée par Renovate ne se merge pas sans relire le fichier de valeurs. Le
`packageRules` correspondant impose l'étiquette `relecture-schema-requise`.
