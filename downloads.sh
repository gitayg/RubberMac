#!/bin/bash
# How often RubberMAC has been downloaded, from GitHub's own count for each release file.
#   ./downloads.sh               every release's downloads: the .dmg (people downloading RubberMAC) and the .zip
#                                (mostly RubberMAC updating itself, which fetches the .zip)
#   ./downloads.sh --record DIR  adds today's counts to DIR/downloads.csv (a rerun the same day replaces them) and
#                                rewrites DIR/README.md; the Download Counts workflow runs it daily on the stats branch
# GitHub keeps only each file's running total, so the history (and the downloads per day) exists only from these records.
set -euo pipefail
REPO=${REPO:-gitayg/RubberMac}

# shellcheck disable=SC2016  # $t is a jq variable
counts() {   # release <tab> file <tab> downloads, newest release first
    gh api "repos/$REPO/releases" --paginate --jq '.[] | .tag_name as $t | .assets[] | [$t, .name, .download_count] | @tsv'
}

# One line per release: dmg, zip, and the totals.
table() {
    awk -F'\t' '
        { tag = $1; if (!(tag in seen)) { seen[tag] = 1; order[++n] = tag } }
        $2 ~ /\.dmg$/ { dmg[tag] += $3; tdmg += $3 }
        $2 ~ /\.zip$/ { zip[tag] += $3; tzip += $3 }
        END {
            printf "| Release | .dmg | .zip |\n|---|---:|---:|\n"
            for (i = 1; i <= n; i++) printf "| %s | %d | %d |\n", order[i], dmg[order[i]], zip[order[i]]
            printf "| **All** | **%d** | **%d** |\n", tdmg, tzip
        }'
}

if [ "${1:-}" != "--record" ]; then
    counts | table
    exit 0
fi

DIR=${2:?usage: ./downloads.sh --record DIR}
CSV="$DIR/downloads.csv"
today=$(date -u +%F)
rows=$(counts)
[ -n "$rows" ] || { echo "GitHub listed no release files for $REPO" >&2; exit 1; }
{
    echo "date,release,file,downloads"
    [ -f "$CSV" ] && awk -F, -v d="$today" 'NR > 1 && $1 != d' "$CSV"
    printf '%s\n' "$rows" | awk -F'\t' -v d="$today" '{ printf "%s,%s,%s,%d\n", d, $1, $2, $3 }'
} > "$CSV.new"
mv "$CSV.new" "$CSV"

# Totals per recorded day, and how many were added since the day recorded before it.
{
    echo "# RubberMAC download counts"
    echo
    echo "Recorded daily from GitHub's download count for each release file by \`.github/workflows/downloads.yml\` on \`main\`; every day's counts are in [downloads.csv](downloads.csv). The .dmg is what people download from the releases page. The .zip is mostly RubberMAC updating itself."
    echo
    echo "## By day (UTC), last 30 records"
    echo
    awk -F, '
        NR > 1 { if (!($1 in seen)) { seen[$1] = 1; day[++n] = $1 } }
        NR > 1 && $3 ~ /\.dmg$/ { dmg[$1] += $4 }
        NR > 1 && $3 ~ /\.zip$/ { zip[$1] += $4 }
        END {
            printf "| Day | .dmg in all | .zip in all | new .dmg | new .zip |\n|---|---:|---:|---:|---:|\n"
            for (i = n; i >= 1 && i > n - 30; i--) {
                d = day[i]
                if (i > 1) printf "| %s | %d | %d | %+d | %+d |\n", d, dmg[d], zip[d], dmg[d] - dmg[day[i-1]], zip[d] - zip[day[i-1]]
                else printf "| %s | %d | %d | – | – |\n", d, dmg[d], zip[d]
            }
        }' "$CSV"
    echo
    echo "## By release, $today"
    echo
    printf '%s\n' "$rows" | table
} > "$DIR/README.md"
echo "recorded $(printf '%s\n' "$rows" | wc -l | tr -d ' ') release files for $today in $CSV"
