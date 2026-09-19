#!/usr/bin/env bash
# Garde-fou sur les secrets. Le dépôt est PUBLIC : une seule valeur en clair
# poussée ici est compromise définitivement, y compris après un force-push,
# parce que GitHub conserve les objets orphelins et que les forks les gardent.
#
# Ce script ne vérifie pas que les secrets sont bons — il vérifie qu'ils ne
# sont pas lisibles.
#
# Chaque contrôle rapporte son propre résultat, indépendamment des précédents :
# un premier échec ne doit pas masquer l'état des suivants.

set -uo pipefail
cd "$(dirname "$0")/.."

echec=0
ko() { echo "  ÉCHEC : $*"; echec=1; }
ok() { echo "  ok : $*"; }

echo "── 1. Clés privées committées"
# Le motif est assemblé à l'exécution pour que la chaîne littérale n'apparaisse
# jamais dans ce fichier. Sans cette précaution, le script se détecte lui-même
# et signale une fuite inexistante — un faux positif qui apprend à ignorer
# l'alarme, ce qui est pire que pas d'alarme du tout.
motif="AGE-SECRET-""KEY-1|BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE ""KEY"
if trouve=$(git ls-files -z | xargs -0 grep -lE "$motif" 2>/dev/null); then
  ko "clé privée détectée dans : $trouve"
else
  ok "aucune clé privée"
fi

echo "── 2. Tout fichier .enc.yaml est réellement chiffré"
mapfile -t chiffres < <(git ls-files '*.enc.yaml')
if [ ${#chiffres[@]} -eq 0 ]; then
  ko "aucun fichier .enc.yaml versionné — les waves 2, 5 et 7 échoueront"
else
  for f in "${chiffres[@]}"; do
    if ! grep -q 'ENC\[AES256_GCM' "$f"; then
      ko "$f n'est pas chiffré"
    elif grep -qE 'REMPLACER|REPLACE_ME|changeme' "$f"; then
      ko "$f contient encore un placeholder"
    else
      ok "$f ($(grep -c 'ENC\[AES256_GCM' "$f") valeur(s) chiffrée(s))"
    fi
  done
fi

echo "── 3. Aucun Secret Kubernetes en clair hors gabarit"
souci3=0
while IFS= read -r f; do
  case "$f" in *.example.yaml|*.enc.yaml) continue;; esac
  if grep -qE '^kind:[[:space:]]*Secret' "$f" 2>/dev/null; then
    ko "$f déclare un Secret sans être chiffré ni marqué .example.yaml"
    souci3=1
  fi
done < <(git ls-files '*.yaml')
[ $souci3 -eq 0 ] && ok "aucun Secret en clair"

echo "── 4. Les gabarits ne contiennent que des placeholders"
souci4=0
for f in $(git ls-files '*.example.yaml'); do
  if ! grep -qE 'REMPLACER' "$f"; then
    ko "$f devrait ne contenir que des placeholders"
    souci4=1
  fi
done
[ $souci4 -eq 0 ] && ok "gabarits sains"

echo "── 5. Fichiers en clair qui auraient dû être ignorés"
souci5=0
for motif_fichier in cloudflare-token.yaml credentials.yaml secrets.yaml ntfy.yaml keys.txt '*.agekey'; do
  if trouve=$(git ls-files "$motif_fichier"); then
    [ -n "$trouve" ] && { ko "$trouve est versionné"; souci5=1; }
  fi
done
[ $souci5 -eq 0 ] && ok "aucun résidu en clair"

echo
if [ $echec -eq 0 ]; then
  echo "RÉSULTAT : aucun secret exposé."
else
  echo "RÉSULTAT : au moins un secret est exposé. NE PAS POUSSER."
fi
exit $echec
