#!/bin/bash
# credit-report.sh — one report for your whole Claude Code account: total spend,
# by model, by project, by session — with subagent transcripts counted toward
# the session that spawned them.
#
# Usage:
#   credit-report.sh                       # everything, all time
#   credit-report.sh --since 2026-08-01    # sessions active since a date
#   credit-report.sh --top 10              # up to 10 sessions per project (default 5)
#   credit-report.sh --all                 # every session, no folding
#   credit-report.sh --projects            # projects only, no session rows
#   credit-report.sh --json                # machine-readable JSON instead of text
#   credit-report.sh ~/my-project          # one project (real path or projects/ dir)
#   credit-report.sh --refresh             # ignore the per-session cache
#   credit-report.sh --no-color            # plain text (also: NO_COLOR=1 or a pipe)
#
# Cost is the offline estimate from credit-lib.sh (published per-model rates,
# version- and fast-mode-aware). Claude Code's own per-session figure is only
# available live on the statusline; across an account this estimate is the best
# local source and lands within a few percent of it.
#
# Performance: every session's (main + subagent) transcripts are priced once and
# cached under $XDG_CACHE_HOME/claude-statusline/report/, keyed on mtimes and
# sizes, so re-running the report is instant until a transcript changes.
#
# "Last active" is the newest mtime among a session's files. --since filters on it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credit-lib.sh
source "${SCRIPT_DIR}/credit-lib.sh"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROJECTS_ROOT="${CLAUDE_DIR}/projects"
CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline/report"

since=""; top=5; show_all=0; projects_only=0; as_json=0; refresh=0; color=auto
only_project=""

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --since)     since="${2:-}"; shift ;;
        --since=*)   since="${1#*=}" ;;
        --top)       top="${2:-}"; shift ;;
        --top=*)     top="${1#*=}" ;;
        --all)       show_all=1 ;;
        --projects)  projects_only=1 ;;
        --json)      as_json=1 ;;
        --refresh)   refresh=1 ;;
        --no-color)  color=never ;;
        --color)     color=always ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)           only_project="$1" ;;
    esac
    shift
done

[[ "$top" =~ ^[0-9]+$ ]] || { echo "--top needs a number" >&2; exit 2; }

since_epoch=0
if [ -n "$since" ]; then
    [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "--since needs YYYY-MM-DD" >&2; exit 2; }
    since_epoch=$(date -d "$since" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$since" +%s 2>/dev/null) \
        || { echo "Cannot parse date: $since" >&2; exit 2; }
fi

[ -d "$PROJECTS_ROOT" ] || { echo "No projects dir at $PROJECTS_ROOT" >&2; exit 1; }

# --- colors -----------------------------------------------------------------
if [ "$color" = auto ]; then
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "$as_json" -eq 0 ]; then color=always; else color=never; fi
fi
if [ "$color" = always ]; then
    B=$'\x1b[1m'; D=$'\x1b[2m'; R=$'\x1b[0m'
    C_T=$'\x1b[38;2;46;149;153m'    # teal   — totals / bars
    C_M=$'\x1b[38;2;255;176;85m'    # orange — money
    C_H=$'\x1b[38;2;220;220;220m'   # white  — headings, names
    C_P=$'\x1b[38;2;0;153;255m'     # blue   — project names
    C_G=$'\x1b[38;2;0;160;0m'       # green  — dates
else
    B=""; D=""; R=""; C_T=""; C_M=""; C_H=""; C_P=""; C_G=""
fi

# --- helpers ------------------------------------------------------------------
mtime_of() { stat -c '%Y' -- "$@" 2>/dev/null || stat -f '%m' -- "$@" 2>/dev/null; }
size_of()  { stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null; }
fmt_day()  { date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null; }

# Resolve the optional project argument to a directory under PROJECTS_ROOT.
project_filter=""
if [ -n "$only_project" ]; then
    if [ -d "$only_project" ] && [ "$(cd "$only_project" && pwd)" = "$(cd "$(dirname "$only_project")" 2>/dev/null && pwd)/$(basename "$only_project")" ] \
       && [ "$(cd "$(dirname "$only_project")" && pwd)" = "$PROJECTS_ROOT" ]; then
        project_filter="$(basename "$only_project")"
    else
        abs="$(cd "$only_project" 2>/dev/null && pwd)" || { echo "Not a directory: $only_project" >&2; exit 1; }
        # Claude Code encodes a project path by replacing every non-alphanumeric byte with '-'.
        project_filter="$(printf '%s' "$abs" | sed 's/[^A-Za-z0-9]/-/g')"
        [ -d "$PROJECTS_ROOT/$project_filter" ] || { echo "No transcripts for $abs (looked for $PROJECTS_ROOT/$project_filter)" >&2; exit 1; }
    fi
fi

mkdir -p "$CACHE_DIR" 2>/dev/null && chmod 0700 "$CACHE_DIR" 2>/dev/null

# --- collect ------------------------------------------------------------------
# master TSV, two record kinds:
#   ROW  <proj> <sid> <last_mtime> <nsub> <bucket> <in> <out>
#   META <proj> <sid> <last_mtime> <nsub> <title> <cwd>
master=$(mktemp); trap 'rm -f "$master"' EXIT

sessions=()
for pdir in "$PROJECTS_ROOT"/*/; do
    pdir="${pdir%/}"; pname="$(basename "$pdir")"
    [ -n "$project_filter" ] && [ "$pname" != "$project_filter" ] && continue
    for main in "$pdir"/*.jsonl; do
        [ -f "$main" ] || continue
        sessions+=("$main")
    done
done
total_sessions=${#sessions[@]}
if [ "$total_sessions" -eq 0 ]; then echo "No transcripts found." >&2; exit 1; fi

progress() { [ -t 2 ] && [ "$as_json" -eq 0 ] && printf '\r\033[2K%s' "$1" >&2; }
i=0
for main in "${sessions[@]}"; do
    i=$((i+1))
    pdir="$(dirname "$main")"; pname="$(basename "$pdir")"
    sid="$(basename "$main" .jsonl)"
    subdir="$pdir/$sid/subagents"

    subs=()
    if [ -d "$subdir" ]; then
        while IFS= read -r -d '' f; do subs+=("$f"); done < <(find "$subdir" -maxdepth 1 -name '*.jsonl' -print0 2>/dev/null)
    fi
    nsub=${#subs[@]}

    main_mtime=$(mtime_of "$main"); main_size=$(size_of "$main")
    last=$main_mtime; sub_max=0
    if [ "$nsub" -gt 0 ]; then
        sub_max=$(mtime_of "${subs[@]}" | sort -n | tail -1)
        [ "$sub_max" -gt "$last" ] 2>/dev/null && last=$sub_max
    fi
    [ "$since_epoch" -gt 0 ] && [ "$last" -lt "$since_epoch" ] && continue

    key="${main_mtime}:${main_size}:${nsub}:${sub_max}"
    safe_id=$(printf '%s' "$sid" | tr -c 'a-zA-Z0-9_-' '_')
    cache="$CACHE_DIR/${pname}__${safe_id}.tsv"

    if [ "$refresh" -eq 0 ] && [ -f "$cache" ] && [ "$(head -1 "$cache" 2>/dev/null)" = "# $key" ]; then
        tail -n +2 "$cache" >> "$master"
        continue
    fi

    progress "pricing session ${i}/${total_sessions}  ${sid:0:8}  (${nsub} agents)"

    {
        printf '# %s\n' "$key"
        # Cost rows, aggregated per model bucket over main + subagent files.
        emit_credit_rows_for_jsonl "$main" "${subs[@]}" \
            | awk -F'\t' -v p="$pname" -v s="$sid" -v m="$last" -v n="$nsub" '
                { ci[$1]+=$2; co[$1]+=$3 }
                END { for (b in ci) printf "ROW\t%s\t%s\t%s\t%s\t%s\t%.4f\t%.4f\n", p, s, m, n, b, ci[b], co[b] }'
        # Title: custom title wins over the AI-generated one; newest occurrence.
        title=$( { grep -h -F '"type":"custom-title"' -- "$main" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null; } )
        [ -z "$title" ] && title=$( { grep -h -F '"type":"ai-title"' -- "$main" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null; } )
        cwd=$( { grep -h -m1 -F '"cwd":"' -- "$main" 2>/dev/null | head -1 | jq -r '.cwd // empty' 2>/dev/null; } )
        # Control bytes and tabs are stripped: both fields are printed and TSV-delimited.
        title=$(printf '%s' "$title" | tr -d '\000-\037\177')
        cwd=$(printf '%s' "$cwd" | tr -d '\000-\037\177')
        printf 'META\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pname" "$sid" "$last" "$nsub" "$title" "$cwd"
    } > "$cache.tmp.$$" 2>/dev/null
    mv -f "$cache.tmp.$$" "$cache" 2>/dev/null && chmod 0600 "$cache" 2>/dev/null
    tail -n +2 "$cache" >> "$master"
done
progress ""; [ -t 2 ] && [ "$as_json" -eq 0 ] && printf '\r\033[2K' >&2

if ! grep -q '^ROW' "$master"; then echo "No usage data found." >&2; exit 1; fi

# --- JSON output ---------------------------------------------------------------
if [ "$as_json" -eq 1 ]; then
    jq -Rs --arg since "$since" --arg generated "$(date -Iseconds 2>/dev/null || date)" '
      split("\n") | map(select(length>0) | split("\t")) as $all
      | ($all | map(select(.[0]=="ROW")  | {proj:.[1], sid:.[2], last:(.[3]|tonumber), agents:(.[4]|tonumber), model:.[5], in:(.[6]|tonumber), out:(.[7]|tonumber)})) as $rows
      | ($all | map(select(.[0]=="META") | {proj:.[1], sid:.[2], title:.[5], cwd:.[6]})) as $meta
      | def money: (.*10000|round)/10000;
        def sum_in:  map(.in)  | add // 0;
        def sum_out: map(.out) | add // 0;
        def bymodel: group_by(.model) | map({model:.[0].model, in:(sum_in|money), out:(sum_out|money), cost:((sum_in+sum_out)|money)}) | sort_by(-.cost);
        {
          generated: $generated,
          since: (if $since=="" then null else $since end),
          estimate: true,
          total: { cost: (($rows|sum_in)+($rows|sum_out)|money), in: ($rows|sum_in|money), out: ($rows|sum_out|money) },
          projects_count: ($rows | map(.proj) | unique | length),
          sessions_count: ($rows | map(.sid) | unique | length),
          agents_count:   ($rows | group_by(.sid) | map(.[0].agents) | add // 0),
          by_model: ($rows | bymodel),
          projects: ($rows | group_by(.proj) | map(
              . as $pr | {
                dir: .[0].proj,
                path: ([$meta[] | select(.proj==$pr[0].proj) | .cwd] | map(select(.!="")) | .[0] // null),
                cost: ((sum_in+sum_out)|money), in:(sum_in|money), out:(sum_out|money),
                last_active: (map(.last)|max),
                by_model: bymodel,
                sessions: (group_by(.sid) | map(
                    . as $se | {
                      id: .[0].sid,
                      title: ([$meta[] | select(.sid==$se[0].sid) | .title] | .[0] // ""),
                      cost: ((sum_in+sum_out)|money), in:(sum_in|money), out:(sum_out|money),
                      last_active: .[0].last, agents: .[0].agents,
                      by_model: bymodel
                    }) | sort_by(-.cost))
              }) | sort_by(-.cost))
        }' "$master"
    exit 0
fi

# --- text report ---------------------------------------------------------------
# Aggregate with awk into three sorted tables, then render.
agg=$(mktemp); trap 'rm -f "$master" "$agg"' EXIT
awk -F'\t' '
  $1=="ROW"  { p=$2; s=$3; last[s]=$4; agents[s]=$5; b=$6; ci=$7; co=$8
               proj_of[s]=p
               tin+=ci; tout+=co
               pin[p]+=ci; pout[p]+=co; plast[p]=(plast[p]>$4?plast[p]:$4)
               ses_in[s]+=ci; ses_out[s]+=co
               min[b]+=ci; mout[b]+=co
               sm[s,b]+=ci+co; if (!((s,b) in seen)) { seen[s,b]=1; smodels[s]=smodels[s] SUBSEP b } }
  $1=="META" { title[$3]=$6; if ($7!="" && !($2 in cwd)) cwd[$2]=$7 }
  END {
    printf "TOTAL\t%.4f\t%.4f\n", tin, tout
    for (b in min) printf "MODEL\t%s\t%.4f\t%.4f\n", b, min[b], mout[b]
    for (p in pin) {
      n=0; for (s in proj_of) if (proj_of[s]==p) n++
      printf "PROJ\t%s\t%.4f\t%.4f\t%d\t%d\t%s\n", p, pin[p], pout[p], n, plast[p], cwd[p]
    }
    for (s in ses_in) {
      # dominant model for the session
      best=""; bv=-1; nm=split(substr(smodels[s],2), arr, SUBSEP)
      for (k=1;k<=nm;k++) if (sm[s,arr[k]]>bv) { bv=sm[s,arr[k]]; best=arr[k] }
      printf "SESS\t%s\t%s\t%.4f\t%.4f\t%d\t%d\t%s\t%s\n", proj_of[s], s, ses_in[s], ses_out[s], last[s], agents[s], best, title[s]
    }
  }' "$master" > "$agg"

read -r _ tin tout < <(grep '^TOTAL' "$agg")
total=$(awk -v a="$tin" -v b="$tout" 'BEGIN{printf "%.4f", a+b}')
n_proj=$(grep -c '^PROJ' "$agg"); n_sess=$(grep -c '^SESS' "$agg")
n_agents=$(awk -F'\t' '$1=="SESS"{a+=$7} END{print a+0}' "$agg")

money() { awk -v v="$1" 'BEGIN {
    s = sprintf("%.2f", v); n = index(s, "."); ip = substr(s, 1, n-1); fp = substr(s, n)
    out = ""; while (length(ip) > 3) { out = "," substr(ip, length(ip)-2) out; ip = substr(ip, 1, length(ip)-3) }
    printf "$%s%s", ip out, fp }'; }
pct() { awk -v a="$1" -v t="$2" 'BEGIN { if (t>0) printf "%5.1f%%", a/t*100; else printf "  0.0%%" }'; }
bar() { # <value> <total> <width>
    awk -v a="$1" -v t="$2" -v w="$3" -v f="$C_T" -v d="$D" -v r="$R" 'BEGIN {
        n = (t>0) ? int(a/t*w + 0.5) : 0; if (n>w) n=w
        s = ""; for (i=0;i<n;i++) s = s "█"; e = ""; for (i=n;i<w;i++) e = e "░"
        printf "%s%s%s%s%s", f, s, d, e, r }'; }
trunc() { awk -v s="$1" -v w="$2" 'BEGIN { if (length(s) > w) printf "%s…", substr(s, 1, w-1); else printf "%s", s }'; }
pl() { if [ "$1" -eq 1 ]; then printf '%d %s' "$1" "$2"; else printf '%d %ss' "$1" "$2"; fi; }
short_path() { # ~ for $HOME, then fit
    local p="$1"; [ -n "$p" ] && p="${p/#$HOME/\~}"; printf '%s' "$p"; }

W=100
rule() { printf '%s%s%s\n' "$D" "$(printf '─%.0s' $(seq 1 $W))" "$R"; }

scope="all time"; [ -n "$since" ] && scope="since $since"
[ -n "$project_filter" ] && scope="$scope · $(short_path "$(awk -F'\t' '$1=="PROJ"{print $7; exit}' "$agg")")"

echo
printf ' %s%sClaude Code spend report%s  %s%s · %s · offline estimate%s\n' "$B" "$C_H" "$R" "$D" "$(date +%Y-%m-%d)" "$scope" "$R"
rule
printf ' %sTOTAL%s  %s%s%-14s%s %sin %s · out %s%s   %s%s · %s · %s%s\n' \
    "$B" "$R" "$B" "$C_M" "$(money "$total")" "$R" "$D" "$(money "$tin")" "$(money "$tout")" "$R" \
    "$D" "$(pl "$n_proj" project)" "$(pl "$n_sess" session)" "$(pl "$n_agents" agent)" "$R"
echo

printf ' %s%sBY MODEL%s\n' "$B" "$C_H" "$R"
grep '^MODEL' "$agg" | awk -F'\t' '{printf "%s\t%.4f\t%.4f\t%.4f\n", $2, $3, $4, $3+$4}' | sort -t$'\t' -k4,4gr \
| while IFS=$'\t' read -r b mi mo mt; do
    printf '   %s%-16s%s %s%12s%s  %s %s%s%s  %sin %s · out %s%s\n' "$C_H" "$b" "$R" "$C_M" "$(money "$mt")" "$R" "$(bar "$mt" "$total" 30)" "$D" "$(pct "$mt" "$total")" "$R" "$D" "$(money "$mi")" "$(money "$mo")" "$R"
done
echo

printf ' %s%sBY PROJECT%s %s(sessions folded to top %s by spend; --all shows every one)%s\n' "$B" "$C_H" "$R" "$D" "$top" "$R"
[ "$show_all" -eq 1 ] && top=1000000
grep '^PROJ' "$agg" | awk -F'\t' '{printf "%s\t%.4f\t%.4f\t%.4f\t%d\t%d\t%s\n", $2, $3, $4, $3+$4, $5, $6, $7}' | sort -t$'\t' -k4,4gr \
| while IFS=$'\t' read -r p _ _ pt pn plast pcwd; do
    name=$(short_path "$pcwd"); [ -z "$name" ] && name="$p"
    echo
    printf ' %s%s%-38s%s %s%12s%s  %s %s%s%s  %s%3d sess · %s%s\n' "$B" "$C_P" "$(trunc "$name" 38)" "$R" "$C_M" "$(money "$pt")" "$R" "$(bar "$pt" "$total" 20)" "$D" "$(pct "$pt" "$total")" "$R" "$D" "$pn" "$(fmt_day "$plast")" "$R"
    [ "$projects_only" -eq 1 ] && continue
    grep -F "SESS	$p	" "$agg" | awk -F'\t' '{printf "%s\t%.4f\t%.4f\t%.4f\t%d\t%d\t%s\t%s\n", $3, $4, $5, $4+$5, $6, $7, $8, $9}' | sort -t$'\t' -k4,4gr \
    | awk -F'\t' -v top="$top" -v P="$p" '
        NR<=top { print; next }
        { rest+=$4; nrest++ }
        END { if (nrest>0) printf "MORE\t%d\t%.4f\n", nrest, rest }' \
    | while IFS=$'\t' read -r s1 s2 s3 s4 s5 s6 s7 s8; do
        if [ "$s1" = "MORE" ]; then
            printf '     %s+ %d more session(s) · %s%s\n' "$D" "$s2" "$(money "$s3")" "$R"
            continue
        fi
        t="$s8"; [ -z "$t" ] && t="(untitled)"
        ag=""; [ "$s6" -gt 0 ] 2>/dev/null && ag="$(printf '%2d agents' "$s6")"
        printf '     %s%s%s  %s%-34s%s %s%10s%s  %s%-14s%s %s%s%s %s%s%s\n' \
            "$D" "${s1:0:8}" "$R" "$C_H" "$(trunc "$t" 34)" "$R" "$C_M" "$(money "$s4")" "$R" "$D" "$s7" "$R" "$C_G" "$(fmt_day "$s5")" "$R" "$D" "$ag" "$R"
    done
done
echo
rule
printf ' %sAPI-equivalent pricing (credit-lib.sh, verified 2026-09-05): what this usage costs at published per-token rates.%s\n' "$D" "$R"
printf ' %sOn a Pro/Max subscription you did not pay this directly — it is the value consumed. Subagents bill to their parent session.%s\n' "$D" "$R"
printf ' %sCache: %s (--refresh to rebuild)%s\n\n' "$D" "$CACHE_DIR" "$R"
