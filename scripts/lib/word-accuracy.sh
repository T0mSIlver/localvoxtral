#!/usr/bin/env bash
# word-accuracy.sh <expected> <actual>  ->  prints 0.000 .. 1.000
#
# The scorer IntegrationTestSupport.wordAccuracy applies to the live STT lanes,
# for the lanes that score in shell: 1 - (word edit distance / the longer word
# count). Dividing by the LONGER side is what makes duplicated insertion lose
# points, which a recall-style score would wave through. A token is a run of
# letters and digits, lowercased; bytes above ASCII count as letters.
#
# Written for the runner's bash 3.2 and the stock macOS awk.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <expected> <actual>" >&2
  exit 2
fi

LC_ALL=C awk -v expected="$1" -v actual="$2" '
function tokens(text, out,    n) {
  text = tolower(text)
  gsub(/[^a-z0-9\200-\377]+/, " ", text)
  sub(/^ +/, "", text)
  sub(/ +$/, "", text)
  if (text == "") return 0
  n = split(text, out, " ")
  return n
}
BEGIN {
  n = tokens(expected, e)
  m = tokens(actual, a)
  if (n == 0) { printf "%.3f\n", (m == 0 ? 1 : 0); exit }
  for (j = 0; j <= m; j++) prev[j] = j
  for (i = 1; i <= n; i++) {
    cur[0] = i
    for (j = 1; j <= m; j++) {
      cost = (e[i] == a[j]) ? 0 : 1
      best = prev[j] + 1
      if (cur[j - 1] + 1 < best) best = cur[j - 1] + 1
      if (prev[j - 1] + cost < best) best = prev[j - 1] + cost
      cur[j] = best
    }
    for (j = 0; j <= m; j++) prev[j] = cur[j]
  }
  longer = (n > m) ? n : m
  score = 1 - prev[m] / longer
  if (score < 0) score = 0
  printf "%.3f\n", score
}'
