#!/bin/bash
# credit-report.sh — one report for your whole Claude Code account: total spend,
# over time, by model, by project, by session — with every subagent and
# workflow-agent transcript billed to the session that spawned it.
#
# Usage:
#   credit-report.sh                              # everything, all time
#   credit-report.sh --since 2026-08-01           # spend from that day onward
#   credit-report.sh --since 2026-08-01 --until 2026-08-31   # just August
#   credit-report.sh --top 10                     # up to 10 sessions per project (default 5)
#   credit-report.sh --all                        # every session, no folding
#   credit-report.sh --projects                   # projects only, no session rows
#   credit-report.sh --json                       # machine-readable JSON instead of text
#   credit-report.sh ~/my-project                 # one project (real path or projects/ dir)
#   credit-report.sh --refresh                    # ignore the per-session cache
#   credit-report.sh --no-color                   # plain text (also: NO_COLOR=1 or a pipe)
#
# --since/--until are inclusive local calendar dates.
#
# TIME SLICING: every assistant message is attributed to the day it was actually
# produced (its own timestamp), NOT to the transcript's modification time. This
# matters: a session can run for months and Claude Code touches its file whenever
# you resume it, so "sessions whose file changed since X" is not the same set as
# "money spent since X" — filtering on mtime bills a whole session's lifetime to
# whatever day you last opened it.
#
# Cost is the offline estimate from credit-lib.sh (published per-model rates,
# version- and fast-mode-aware) — API-equivalent value, not a subscription bill.
#
# Performance: each session's transcripts are priced once into a small per-day,
# per-model cache under $XDG_CACHE_HOME/claude-statusline/report/, keyed on file
# sizes and mtimes, so re-runs are instant until a transcript changes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credit-lib.sh
source "${SCRIPT_DIR}/credit-lib.sh"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROJECTS_ROOT="${CLAUDE_DIR}/projects"
CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline/report"
CACHE_FORMAT=v2   # bump when the cached row shape changes
# Cached rows hold dollars, so they must also go stale when a PRICE changes.
# Fingerprint the pricing code itself: editing any rate in credit-lib.sh
# re-prices every session on the next run, with nothing to remember to bump.
PRICING_SIG=$(printf '%s' "$_AWK_RATE_FN" | cksum | cut -d' ' -f1)

since=""; until_=""; top=5; show_all=0; projects_only=0; as_json=0; refresh=0; color=auto
only_project=""

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "$1" >&2; exit "${2:-2}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --since)     since="${2:-}"; shift ;;
        --since=*)   since="${1#*=}" ;;
        --until)     until_="${2:-}"; shift ;;
        --until=*)   until_="${1#*=}" ;;
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

[[ "$top" =~ ^[0-9]+$ ]] || die "--top needs a number"
for _d in "$since" "$until_"; do
    [ -z "$_d" ] && continue
    [[ "$_d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "dates must be YYYY-MM-DD (got '$_d')"
done
if [ -n "$since" ] && [ -n "$until_" ] && [[ "$since" > "$until_" ]]; then
    die "--since ($since) is after --until ($until_)"
fi

# Only --since gets a cheap file-level fast path, and only because a file's mtime
# is always >= the timestamp of the last message inside it: a transcript
# untouched since before the window cannot contain in-window messages. There is
# no equivalent shortcut for --until (a file touched today may hold old work).
since_epoch=0
if [ -n "$since" ]; then
    since_epoch=$(date -d "$since" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$since" +%s 2>/dev/null) \
        || die "cannot parse date: $since"
fi

[ -d "$PROJECTS_ROOT" ] || die "No projects dir at $PROJECTS_ROOT" 1

# --- colors -----------------------------------------------------------------
if [ "$color" = auto ]; then
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "$as_json" -eq 0 ]; then color=always; else color=never; fi
fi
if [ "$color" = always ]; then
    B=$'\x1b[1m'; D=$'\x1b[2m'; R=$'\x1b[0m'
    C_T=$'\x1b[38;2;46;149;153m'    # teal   — bars
    C_M=$'\x1b[38;2;255;176;85m'    # orange — money
    C_H=$'\x1b[38;2;220;220;220m'   # white  — headings, names
    C_P=$'\x1b[38;2;0;153;255m'     # blue   — project names
    C_G=$'\x1b[38;2;0;160;0m'       # green  — dates
else
    B=""; D=""; R=""; C_T=""; C_M=""; C_H=""; C_P=""; C_G=""
fi

# --- resolve the optional project argument to a directory under PROJECTS_ROOT --
project_filter=""
if [ -n "$only_project" ]; then
    if [ -d "$only_project" ] && [ "$(cd "$(dirname "$only_project")" 2>/dev/null && pwd)" = "$PROJECTS_ROOT" ]; then
        project_filter="$(basename "$only_project")"
    else
        abs="$(cd "$only_project" 2>/dev/null && pwd)" || die "Not a directory: $only_project" 1
        # Claude Code encodes a project path by replacing every non-alphanumeric byte with '-'.
        project_filter="$(printf '%s' "$abs" | sed 's/[^A-Za-z0-9]/-/g')"
        [ -d "$PROJECTS_ROOT/$project_filter" ] \
            || die "No transcripts for $abs (looked for $PROJECTS_ROOT/$project_filter)" 1
    fi
fi

mkdir -p "$CACHE_DIR" 2>/dev/null && chmod 0700 "$CACHE_DIR" 2>/dev/null

# --- collect ------------------------------------------------------------------
# master TSV, two record kinds:
#   ROW   <proj> <sid> <day> <bucket> <in> <out>
#   META  <proj> <sid> <last_mtime> <nagents> <title> <cwd>
master=$(mktemp); agg=$(mktemp); trap 'rm -f "$master" "$agg"' EXIT

sessions=()
for pdir in "$PROJECTS_ROOT"/*/; do
    pdir="${pdir%/}"; pname="$(basename "$pdir")"
    [ -n "$project_filter" ] && [ "$pname" != "$project_filter" ] && continue
    for main in "$pdir"/*.jsonl; do
        [ -f "$main" ] || continue
        sessions+=("$main")
    done
done
[ "${#sessions[@]}" -gt 0 ] || die "No transcripts found." 1

progress() { [ -t 2 ] && [ "$as_json" -eq 0 ] && printf '\r\033[2K%s' "$1" >&2; }
i=0
for main in "${sessions[@]}"; do
    i=$((i+1))
    pdir="$(dirname "$main")"; pname="$(basename "$pdir")"
    sid="$(basename "$main" .jsonl)"
    sessdir="$pdir/$sid"

    # Every transcript under the session dir belongs to this session: direct
    # subagents (subagents/agent-*.jsonl), workflow agents
    # (subagents/workflows/wf_*/agent-*.jsonl) and workflow journals. Journals
    # carry no assistant messages so they price to zero; only agent-*.jsonl files
    # count as "agents".
    subs=(); nsub=0
    if [ -d "$sessdir" ]; then
        while IFS= read -r -d '' f; do
            subs+=("$f")
            case "$(basename "$f")" in agent-*.jsonl) nsub=$((nsub+1)) ;; esac
        done < <(find "$sessdir" -name '*.jsonl' -print0 2>/dev/null)
    fi

    # Cache key: main mtime+size, plus file count, summed size and newest mtime
    # over the subagent set (an agent file can grow without the count changing).
    read -r main_mtime main_size < <(stat -c '%Y %s' -- "$main" 2>/dev/null || stat -f '%m %z' -- "$main" 2>/dev/null)
    last_mtime=$main_mtime; sub_sig="0:0:0"
    if [ "${#subs[@]}" -gt 0 ]; then
        sub_sig=$( { stat -c '%Y %s' -- "${subs[@]}" 2>/dev/null || stat -f '%m %z' -- "${subs[@]}" 2>/dev/null; } \
                   | awk '{ if ($1>mx) mx=$1; sz+=$2; n++ } END { printf "%d:%d:%d", n, sz, mx }')
        sub_max="${sub_sig##*:}"
        [ "$sub_max" -gt "$last_mtime" ] 2>/dev/null && last_mtime=$sub_max
    fi
    [ "$since_epoch" -gt 0 ] && [ "$last_mtime" -lt "$since_epoch" ] && continue

    key="${CACHE_FORMAT}:${PRICING_SIG} ${main_mtime}:${main_size}:${nsub}:${sub_sig}"
    safe_id=$(printf '%s' "$sid" | tr -c 'a-zA-Z0-9_-' '_')
    cache="$CACHE_DIR/${pname}__${safe_id}.tsv"

    if [ "$refresh" -eq 0 ] && [ -f "$cache" ] && [ "$(head -1 "$cache" 2>/dev/null)" = "# $key" ]; then
        tail -n +2 "$cache" >> "$master"
        continue
    fi

    progress "pricing session ${i}/${#sessions[@]}  ${sid:0:8}  (${nsub} agents)"

    {
        printf '# %s\n' "$key"
        # One row per (day, model) over the main transcript and every agent file.
        emit_credit_rows_dated_for_jsonl "$main" "${subs[@]}" \
            | awk -F'\t' -v p="$pname" -v s="$sid" '
                { ci[$1 "\t" $2]+=$3; co[$1 "\t" $2]+=$4 }
                END { for (k in ci) printf "ROW\t%s\t%s\t%s\t%.4f\t%.4f\n", p, s, k, ci[k], co[k] }'
        # Title: a custom title wins over the AI-generated one; newest occurrence.
        title=$( { grep -h -F '"type":"custom-title"' -- "$main" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null; } )
        [ -z "$title" ] && title=$( { grep -h -F '"type":"ai-title"' -- "$main" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null; } )
        cwd=$( { grep -h -m1 -F '"cwd":"' -- "$main" 2>/dev/null | head -1 | jq -r '.cwd // empty' 2>/dev/null; } )
        # Control bytes are stripped: both fields are printed and TSV-delimited.
        title=$(printf '%s' "$title" | tr -d '\000-\037\177')
        cwd=$(printf '%s' "$cwd" | tr -d '\000-\037\177')
        printf 'META\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pname" "$sid" "$last_mtime" "$nsub" "$title" "$cwd"
    } > "$cache.tmp.$$" 2>/dev/null
    mv -f "$cache.tmp.$$" "$cache" 2>/dev/null && chmod 0600 "$cache" 2>/dev/null
    tail -n +2 "$cache" >> "$master"
done
progress ""; [ -t 2 ] && [ "$as_json" -eq 0 ] && printf '\r\033[2K' >&2

# Window filter on the message day (never on a file mtime — see the header note).
# Rows whose record carried no usable timestamp land in "unknown"; they are kept
# for an all-time report and dropped whenever a window is requested, because
# there is no honest way to place them inside it.
if [ -n "$since" ] || [ -n "$until_" ]; then
    filtered=$(mktemp)
    awk -F'\t' -v s="$since" -v u="$until_" '
        $1=="META" { print; next }
        $1=="ROW"  { d=$4
                     if (d=="unknown") next
                     if (s!="" && d < s) next
                     if (u!="" && d > u) next
                     print }' "$master" > "$filtered"
    mv -f "$filtered" "$master"
fi

grep -q '^ROW' "$master" || {
    if [ -n "$since" ] || [ -n "$until_" ]; then die "No usage in that window." 1; fi
    die "No usage data found." 1
}

# --- aggregate ----------------------------------------------------------------
# Emits TOTAL / GRAN / PERIOD / MODEL / PROJ / SESS / SMOD records, consumed by
# the text renderer below and by the --json builder.
awk -F'\t' '
  # Julian day number from YYYY-MM-DD, so a calendar span needs no date(1).
  function daynum(d,   y,m,dd,a,yy,mm) {
    y=substr(d,1,4)+0; m=substr(d,6,2)+0; dd=substr(d,9,2)+0
    a=int((14-m)/12); yy=y+4800-a; mm=m+12*a-3
    return dd + int((153*mm+2)/5) + 365*yy + int(yy/4) - int(yy/100) + int(yy/400) - 32045
  }
  $1=="ROW" {
    p=$2; s=$3; d=$4; b=$5; ci=$6+0; co=$7+0; c=ci+co
    proj_of[s]=p
    tin+=ci; tout+=co
    pin[p]+=ci; pout[p]+=co
    ses_in[s]+=ci; ses_out[s]+=co
    min_[b]+=ci; mout[b]+=co
    sm[s,b]+=c; if (!((s SUBSEP b) in seen)) { seen[s SUBSEP b]=1; smodels[s]=smodels[s] SUBSEP b }
    if (!(s in sess_seen)) { sess_seen[s]=1; pn[p]++ }
    if (d != "unknown") {
      daycost[d]+=c
      if (d > slast[s]) slast[s]=d
      if (d > plast[p]) plast[p]=d
      if (minday=="" || d < minday) minday=d
      if (maxday=="" || d > maxday) maxday=d
    } else undated+=c
  }
  $1=="META" { title[$3]=$6; agents[$3]=$5+0; if ($7!="" && !($2 in cwd)) cwd[$2]=$7 }
  END {
    printf "TOTAL\t%.4f\t%.4f\n", tin, tout
    for (b in min_) printf "MODEL\t%s\t%.4f\t%.4f\n", b, min_[b], mout[b]

    # Time buckets: months once the span passes a month, else single days.
    span = (minday != "" ? daynum(maxday) - daynum(minday) : 0)
    gran = (span > 31 ? "month" : "day")
    printf "GRAN\t%s\t%s\t%s\n", gran, minday, maxday
    for (d in daycost) {
      k = (gran == "month" ? substr(d,1,7) : d)
      pcost[k] += daycost[d]; pdays[k]++
    }
    for (k in pcost) printf "PERIOD\t%s\t%.4f\t%d\n", k, pcost[k], pdays[k]
    if (undated > 0) printf "PERIOD\tundated\t%.4f\t0\n", undated

    for (p in pin)
      printf "PROJ\t%s\t%.4f\t%.4f\t%d\t%s\t%s\n", p, pin[p], pout[p], pn[p], plast[p], cwd[p]

    for (s in ses_in) {
      best=""; bv=-1; nm=split(substr(smodels[s],2), arr, SUBSEP)
      for (k=1; k<=nm; k++) {
        if (sm[s,arr[k]] > bv) { bv=sm[s,arr[k]]; best=arr[k] }
        printf "SMOD\t%s\t%s\t%.4f\n", s, arr[k], sm[s,arr[k]]
      }
      printf "SESS\t%s\t%s\t%.4f\t%.4f\t%s\t%d\t%s\t%d\t%s\n", \
        proj_of[s], s, ses_in[s], ses_out[s], slast[s], agents[s], best, nm, title[s]
    }
  }' "$master" > "$agg"

# --- JSON output ---------------------------------------------------------------
if [ "$as_json" -eq 1 ]; then
    jq -Rs --arg since "$since" --arg until "$until_" --arg generated "$(date -Iseconds 2>/dev/null || date)" '
      def money: (.*10000|round)/10000;
      def sum_in:  map(.in)  | add // 0;
      def sum_out: map(.out) | add // 0;
      split("\n") | map(select(length>0) | split("\t")) as $a
      | ($a | map(select(.[0]=="SESS") | {proj:.[1], sid:.[2], in:(.[3]|tonumber), out:(.[4]|tonumber),
                                          last:.[5], agents:(.[6]|tonumber), title:.[9]}))          as $sess
      | ($a | map(select(.[0]=="SMOD") | {sid:.[1], model:.[2], cost:(.[3]|tonumber)}))             as $smod
      | ($a | map(select(.[0]=="PROJ") | {dir:.[1], in:(.[2]|tonumber), out:(.[3]|tonumber),
                                          sessions:(.[4]|tonumber), last:.[5], path:(.[6] // "")})) as $proj
      | ($a | map(select(.[0]=="MODEL")| {model:.[1], in:(.[2]|tonumber), out:(.[3]|tonumber)}))    as $models
      | ($a | map(select(.[0]=="PERIOD")|{period:.[1], cost:(.[2]|tonumber), active_days:(.[3]|tonumber)})
             | sort_by(.period))                                                                    as $periods
      | ($a | map(select(.[0]=="GRAN")) | .[0])                                                     as $gran
      | {
          generated: $generated,
          since: (if $since=="" then null else $since end),
          until: (if $until=="" then null else $until end),
          estimate: true,
          note: "API-equivalent cost; each message counted on the day it was produced",
          total: { cost: (($sess|sum_in)+($sess|sum_out)|money), in: ($sess|sum_in|money), out: ($sess|sum_out|money) },
          first_day: ($gran[2] // null),
          last_day:  ($gran[3] // null),
          projects_count: ($proj|length),
          sessions_count: ($sess|length),
          agents_count:   ($sess | map(.agents) | add // 0),
          by_period: { granularity: ($gran[1] // "day"), buckets: $periods },
          by_model: ($models | map({model, in:(.in|money), out:(.out|money), cost:((.in+.out)|money)}) | sort_by(-.cost)),
          projects: ($proj | sort_by(-(.in + .out)) | map(. as $p | {
              dir: .dir, path: (if .path=="" then null else .path end),
              cost: ((.in + .out)|money), in: (.in|money), out: (.out|money),
              last_active: .last, sessions_count: .sessions,
              sessions: ($sess | map(select(.proj==$p.dir)) | sort_by(-(.in + .out)) | map(. as $s | {
                  id: .sid, title: .title,
                  cost: ((.in + .out)|money), in: (.in|money), out: (.out|money),
                  last_active: .last, agents: .agents,
                  by_model: ($smod | map(select(.sid==$s.sid) | {model, cost:(.cost|money)}) | sort_by(-.cost))
                }))
            }))
        }' "$agg"
    exit 0
fi

# --- text report ---------------------------------------------------------------
read -r _ tin tout < <(grep '^TOTAL' "$agg")
total=$(awk -v a="$tin" -v b="$tout" 'BEGIN{printf "%.4f", a+b}')
n_proj=$(grep -c '^PROJ' "$agg"); n_sess=$(grep -c '^SESS' "$agg")
n_agents=$(awk -F'\t' '$1=="SESS"{a+=$7} END{print a+0}' "$agg")
read -r _ gran first_day last_day < <(grep '^GRAN' "$agg")

money() { awk -v v="$1" 'BEGIN {
    s = sprintf("%.2f", v); n = index(s, "."); ip = substr(s, 1, n-1); fp = substr(s, n)
    out = ""; while (length(ip) > 3) { out = "," substr(ip, length(ip)-2) out; ip = substr(ip, 1, length(ip)-3) }
    printf "$%s%s", ip out, fp }'; }
pct() { awk -v a="$1" -v t="$2" 'BEGIN { if (t>0) printf "%5.1f%%", a/t*100; else printf "  0.0%%" }'; }
bar() { awk -v a="$1" -v t="$2" -v w="$3" -v f="$C_T" -v d="$D" -v r="$R" 'BEGIN {
        n = (t>0) ? int(a/t*w + 0.5) : 0; if (n>w) n=w
        s = ""; for (i=0;i<n;i++) s = s "█"; e = ""; for (i=n;i<w;i++) e = e "░"
        printf "%s%s%s%s%s", f, s, d, e, r }'; }
trunc() { awk -v s="$1" -v w="$2" 'BEGIN { if (length(s) > w) printf "%s…", substr(s, 1, w-1); else printf "%s", s }'; }
pl() { if [ "$1" -eq 1 ]; then printf '%d %s' "$1" "$2"; else printf '%d %ss' "$1" "$2"; fi; }
short_path() { local p="$1"; [ -n "$p" ] && p="${p/#$HOME/\~}"; printf '%s' "$p"; }

W=100
rule() { printf '%s%s%s\n' "$D" "$(printf '─%.0s' $(seq 1 $W))" "$R"; }

if   [ -n "$since" ] && [ -n "$until_" ]; then scope="$since → $until_"
elif [ -n "$since" ];  then scope="since $since"
elif [ -n "$until_" ]; then scope="until $until_"
else scope="all time"; fi
[ -n "$project_filter" ] && scope="$scope · $(short_path "$(awk -F'\t' '$1=="PROJ"{print $7; exit}' "$agg")")"

echo
printf ' %s%sClaude Code spend report%s  %s%s · %s · offline estimate%s\n' \
    "$B" "$C_H" "$R" "$D" "$(date +%Y-%m-%d)" "$scope" "$R"
rule
printf ' %sTOTAL%s  %s%s%-14s%s %sin %s · out %s%s   %s%s · %s · %s%s\n' \
    "$B" "$R" "$B" "$C_M" "$(money "$total")" "$R" "$D" "$(money "$tin")" "$(money "$tout")" "$R" \
    "$D" "$(pl "$n_proj" project)" "$(pl "$n_sess" session)" "$(pl "$n_agents" agent)" "$R"
[ -n "$first_day" ] && printf ' %sactivity %s → %s%s\n' "$D" "$first_day" "$last_day" "$R"
echo

if [ "$gran" = month ]; then head_label="BY MONTH"; else head_label="BY DAY"; fi
printf ' %s%s%s\n' "$B$C_H" "$head_label" "$R"
grep '^PERIOD' "$agg" | sort -t$'\t' -k2,2 \
| while IFS=$'\t' read -r _ label cost days; do
    extra=""; [ "$days" -gt 0 ] 2>/dev/null && extra="$(pl "$days" "active day")"
    printf '   %s%-16s%s %s%12s%s  %s %s%s%s  %s%s%s\n' \
        "$C_H" "$label" "$R" "$C_M" "$(money "$cost")" "$R" \
        "$(bar "$cost" "$total" 30)" "$D" "$(pct "$cost" "$total")" "$R" "$D" "$extra" "$R"
done
echo

printf ' %s%sBY MODEL%s\n' "$B" "$C_H" "$R"
grep '^MODEL' "$agg" | awk -F'\t' '{printf "%s\t%.4f\t%.4f\t%.4f\n", $2, $3, $4, $3+$4}' | sort -t$'\t' -k4,4gr \
| while IFS=$'\t' read -r b mi mo mt; do
    printf '   %s%-16s%s %s%12s%s  %s %s%s%s  %sin %s · out %s%s\n' \
        "$C_H" "$b" "$R" "$C_M" "$(money "$mt")" "$R" "$(bar "$mt" "$total" 30)" \
        "$D" "$(pct "$mt" "$total")" "$R" "$D" "$(money "$mi")" "$(money "$mo")" "$R"
done
echo

printf ' %s%sBY PROJECT%s %s(sessions folded to top %s by spend; --all shows every one)%s\n' \
    "$B" "$C_H" "$R" "$D" "$top" "$R"
[ "$show_all" -eq 1 ] && top=1000000
grep '^PROJ' "$agg" | awk -F'\t' '{printf "%s\t%.4f\t%d\t%s\t%s\n", $2, $3+$4, $5, $6, $7}' | sort -t$'\t' -k2,2gr \
| while IFS=$'\t' read -r p pt pn plast pcwd; do
    name=$(short_path "$pcwd"); [ -z "$name" ] && name="$p"
    echo
    printf ' %s%s%-38s%s %s%12s%s  %s %s%s%s  %s%3d sess · %s%s\n' \
        "$B" "$C_P" "$(trunc "$name" 38)" "$R" "$C_M" "$(money "$pt")" "$R" \
        "$(bar "$pt" "$total" 20)" "$D" "$(pct "$pt" "$total")" "$R" "$D" "$pn" "$plast" "$R"
    [ "$projects_only" -eq 1 ] && continue
    grep -F "SESS	$p	" "$agg" \
    | awk -F'\t' '{printf "%s\t%.4f\t%s\t%d\t%s\t%d\t%s\n", $3, $4+$5, $6, $7, $8, $9, $10}' | sort -t$'\t' -k2,2gr \
    | awk -F'\t' -v top="$top" '
        NR<=top { print; next }
        { rest+=$2; nrest++ }
        END { if (nrest>0) printf "MORE\t%.4f\t%d\n", rest, nrest }' \
    | while IFS=$'\t' read -r sid cost slast nag best nmod title; do
        if [ "$sid" = "MORE" ]; then
            printf '     %s+ %s · %s%s\n' "$D" "$(pl "$slast" "more session")" "$(money "$cost")" "$R"
            continue
        fi
        [ -z "$title" ] && title="(untitled)"
        ag=""; [ "$nag" -gt 0 ] 2>/dev/null && ag="$(printf '%3d agents' "$nag")"
        printf '     %s%s%s  %s%-34s%s %s%10s%s  %s%-14s%s %s%s%s %s%s%s\n' \
            "$D" "${sid:0:8}" "$R" "$C_H" "$(trunc "$title" 34)" "$R" "$C_M" "$(money "$cost")" "$R" \
            "$D" "$best" "$R" "$C_G" "$slast" "$R" "$D" "$ag" "$R"
        # Model mix: one dim continuation line when more than one model worked in
        # the session (main conversation plus all of its agents), ordered by spend.
        if [ "$nmod" -gt 1 ] 2>/dev/null; then
            mix=$(grep -F "SMOD	$sid	" "$agg" | sort -t$'\t' -k4,4gr | awk -F'\t' -v tot="$cost" '
                { pc = (tot>0) ? $4/tot*100 : 0
                  c = sprintf("%.2f", $4); n = index(c, "."); ip = substr(c, 1, n-1); fp = substr(c, n); o = ""
                  while (length(ip) > 3) { o = "," substr(ip, length(ip)-2) o; ip = substr(ip, 1, length(ip)-3) }
                  printf "%s%s $%s%s (%.0f%%)", (NR>1 ? " · " : ""), $3, ip o, fp, pc }')
            printf '               %s↳ %s%s\n' "$D" "$mix" "$R"
        fi
    done
done
echo
rule
printf ' %sEach message counts on the day it was produced, so a window shows money spent in it, not whole sessions touched.%s\n' "$D" "$R"
printf ' %sAgent counts are per session (not windowed). Subagent and workflow-agent transcripts bill to their parent session.%s\n' "$D" "$R"
printf ' %sAPI-equivalent pricing (credit-lib.sh, verified 2026-09-05): the value consumed, not a subscription bill.%s\n' "$D" "$R"
printf ' %sCache: %s (--refresh to rebuild)%s\n\n' "$D" "$CACHE_DIR" "$R"
