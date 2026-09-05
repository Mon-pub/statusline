#!/usr/bin/env bash
# tests/run.sh — self-contained checks for claude-statusline.
#
#   bash tests/run.sh          # run everything
#   bash tests/run.sh -v       # also print each rendered statusline
#
# Covers: shellcheck + node --check (when available), the pricing parser, the
# statusline renderer against fixtures (modern CC, legacy CC, hostile input,
# garbage input), the backup threshold policy, the hook entry point, and the
# streaming context-breakdown parser. No network, no writes outside $TMPDIR.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"; NODE="$ROOT/node"; FX="$ROOT/tests/fixtures"
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
assert_contains() { # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1" "missing: $3"; fi
}
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else fail "$1" "unexpected: $3"; fi
}

# Isolated HOME-ish scratch so the statusline never touches the real caches.
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
export XDG_CACHE_HOME="$SCRATCH/cache"
export CLAUDE_CONFIG_DIR="$SCRATCH/claude"; mkdir -p "$CLAUDE_CONFIG_DIR"
export STATUSLINE_NODE_DIR="$NODE"
export STATUSLINE_LOG_DIR="$SCRATCH/log"
export TZ=UTC

strip() { sed 's/\x1b\[[0-9;]*m//g'; }
render() { bash "$BIN/statusline-command.sh" < "$1" 2>/dev/null | strip; }
now=$(date +%s)

echo "== static checks =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -S warning "$BIN"/*.sh "$ROOT/install.sh" >/dev/null 2>&1; then ok "shellcheck clean (warnings+)"; else fail "shellcheck"; fi
else echo "  skip shellcheck (not installed)"; fi
for f in "$NODE"/*.mjs; do
    if node --check "$f" 2>/dev/null; then ok "node --check $(basename "$f")"; else fail "node --check $(basename "$f")"; fi
done

echo "== pricing =="
# shellcheck source=../bin/credit-lib.sh
source "$BIN/credit-lib.sh"
price() { printf '%s\t%s\n' "$1" "${2:-standard}" | awk -F'\t' "$_AWK_RATE_FN"'{ parse_model($1); set_rates(FAMILY,MAJOR,MINOR,$2); printf "%s %.2f %.3f %.2f %.2f %.2f", bucket_label($2), ri, rr, rc, rc1h, ro }'; }
t=$(price claude-fable-5-1);            assert_contains "fable 5.1 read \$0.25"   "$t" "fable-5.1 10.00 0.250 12.50 20.00 50.00"
t=$(price claude-fable-5);              assert_contains "fable 5 read \$1.00"     "$t" "fable-5.0 10.00 1.000 12.50 20.00 50.00"
t=$(price claude-mythos-5-1);           assert_contains "mythos 5.1 = fable"      "$t" "mythos-5.1 10.00 0.250"
t=$(price claude-opus-5);               assert_contains "opus 5"                  "$t" "opus-5.0 5.00 0.500 6.25 10.00 25.00"
t=$(price claude-opus-4-8 fast);        assert_contains "opus 4.8 fast \$10/\$50" "$t" "opus-4.8+fast 10.00 1.000 12.50 20.00 50.00"
t=$(price claude-opus-4-1-20250805);    assert_contains "opus 4.1 legacy \$15"    "$t" "opus-4.1 15.00 1.500 18.75 30.00 75.00"
t=$(price claude-sonnet-5);             assert_contains "sonnet 5 \$2/\$10"       "$t" "sonnet-5.0 2.00 0.200 2.50 4.00 10.00"
t=$(price claude-sonnet-4-6);           assert_contains "sonnet 4.6 \$3/\$15"     "$t" "sonnet-4.6 3.00 0.300 3.75 6.00 15.00"
t=$(price claude-3-5-sonnet-20241022);  assert_contains "legacy 3-5-sonnet order" "$t" "sonnet-3.5 3.00"
t=$(price claude-haiku-4-5-20251001);   assert_contains "haiku 4.5"               "$t" "haiku-4.5 1.00 0.100 1.25 2.00 5.00"
t=$(price claude-zephyr-6);             assert_contains "unknown family → opus"   "$t" "zephyr-6.0 5.00 0.500"
t=$(price "");                          assert_contains "empty model → unknown"   "$t" "unknown 5.00"

# JSONL estimate: 1 message, fable-5.1, 1h cache split, known arithmetic.
J="$SCRATCH/est.jsonl"
printf '%s\n' '{"type":"assistant","message":{"id":"m1","model":"claude-fable-5-1","usage":{"input_tokens":1000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":20000,"output_tokens":2000,"cache_creation":{"ephemeral_1h_input_tokens":20000,"ephemeral_5m_input_tokens":0}}}}' \
               '{"type":"assistant","message":{"id":"m1","model":"claude-fable-5-1","usage":{"input_tokens":1000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":20000,"output_tokens":2000}}}' > "$J"
# in = 1000*10 + 100000*0.25 + 20000*20 = 10000+25000+400000 = 435000 /1e6 = 0.4350 ; out = 2000*50/1e6 = 0.1000
t=$(compute_credit_for_jsonl "$J"); assert_contains "estimate dedups by message id and prices tiers" "$t" "0.4350	0.1000	0.5350"
t=$(emit_credit_rows_for_jsonl "$J"); assert_contains "per-model row bucket" "$t" "fable-5.1	0.4350	0.1000"

echo "== renderer: modern CC 2.1.261 fixture =="
# project_dir points at a scratch dir that EXISTS: the backup bridge falls back
# to $PWD for a missing one, which would write backups into the repo itself.
RP="$SCRATCH/render-proj"; mkdir -p "$RP"
M="$SCRATCH/modern.json"
jq --argjson n "$now" --arg rp "$RP" '.workspace.project_dir=$rp | .rate_limits.five_hour.resets_at=($n+7230) | .rate_limits.seven_day.resets_at=($n+260000) | .prompt_cache.expires_at=($n+2550)' "$FX/cc-2.1.261-live.json" > "$M"
out=$(render "$M"); [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out"
assert_contains "model + effort badge"        "$out" "Fable 5.1 (high)"
assert_contains "context tokens (input-only)" "$out" "/1m (10% used)"
assert_contains "free until autocompact"      "$out" "% free"
assert_contains "cache share"                 "$out" "cache 9"
assert_contains "prompt-cache TTL countdown"  "$out" "1h warm 42m"
assert_contains "5h bar"                      "$out" "5h: ●●●●●○○○○○ 58%"
assert_contains "7d bar"                      "$out" "7d: ●○○○○○○○○○ 12%"
assert_contains "5h reset countdown"          "$out" "(2h0m)"
assert_contains "7d reset countdown"          "$out" "(3d0h)"
assert_contains "native cost"                 "$out" "\$19.34"
assert_contains "burn rate"                   "$out" "\$7.03/h"
assert_contains "duration"                    "$out" "2h45m"
assert_contains "lines changed"               "$out" "+1739/-223"
assert_not_contains "no git tail for missing dir" "$out" "git:"
assert_not_contains "no fill line without cache"  "$out" "fill:"
line_count=$(printf '%s\n' "$out" | wc -l); [ "$line_count" -eq 3 ] && ok "3 lines (model / ctx / resets)" || fail "line count" "$line_count"

echo "== renderer: burn-rate cap, spend limit, cold cache, badges =="
C="$SCRATCH/cap.json"
jq --argjson n "$now" '.rate_limits.five_hour={used_percentage:90,resets_at:($n+3600)} | .rate_limits.seven_day={used_percentage:20,resets_at:($n+500000)} | .rate_limits.spend_limit={used_percentage:112.4,resets_at:($n+86400*20)} | .prompt_cache.warm=false | .fast_mode=true | .thinking.enabled=false | .agent={name:"reviewer"} | .worktree={name:"feat-x"} | .pr={number:42} | .context_window.current_usage=null' "$M" > "$C"
out=$(render "$C"); [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out"
assert_contains "->cap marker when on pace to hit limit" "$out" "90% ->cap "
assert_contains "cap wall-clock"                       "$out" "m ("
assert_contains "long cap projection uses days"         "$out" "7d: ●●○○○○○○○○ 20% ->cap 4d"
assert_contains "spend bar clamps, number exceeds 100"  "$out" "spend: ●●●●●●●●●● 112%"
assert_contains "spend reset uses calendar date >7d"    "$out" "spend resets "
assert_contains "cold cache (no separator without a share)" "$out" "○ cold |"
assert_not_contains "no cache share after /compact"     "$out" "cache 9"
assert_contains "fast badge"                            "$out" " fast "
assert_contains "no-think badge"                        "$out" "no-think"
assert_contains "agent name prefix"                     "$out" "agent:reviewer"
assert_contains "PR number + worktree"                  "$out" "#42 wt:feat-x"

echo "== renderer: ttl near expiry shows without separator when no share =="
E="$SCRATCH/ttl.json"
jq --argjson n "$now" '.prompt_cache.expires_at=($n+100) | .context_window.current_usage=null' "$M" > "$E"
out=$(render "$E")
assert_contains "warm <2m"                 "$out" "warm 1m"
assert_not_contains "no dangling separator" "$out" "○ · "

echo "== renderer: legacy CC (no cost, no effort key, transcript estimate) =="
L="$SCRATCH/legacy.json"
printf '{"effortLevel":"max"}' > "$CLAUDE_CONFIG_DIR/settings.json"
jq -c --arg t "$J" --arg rp "$RP" '{session_id:"legacy-1",transcript_path:$t,cwd:$rp,model:{id:"claude-fable-5-1",display_name:"Fable"},context_window:{context_window_size:200000,current_usage:{input_tokens:1000,cache_read_input_tokens:100000,cache_creation_input_tokens:20000,output_tokens:2000}}}' -n > "$L"
out=$(render "$L"); [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out"
assert_contains "effort falls back to settings.json on old CC" "$out" "Fable (max)"
assert_contains "manual % used from input tokens"             "$out" "121k/200k (60% used)"
assert_contains "JSONL cost estimate with in/out split"       "$out" "\$0.5350 (in:\$0.4350 out:\$0.1000)"
[ -f "$XDG_CACHE_HOME/claude-statusline/credit-legacy-1.cache" ] && ok "estimate cached on mtime" || fail "estimate cache file"
jq -c '.version="2.1.261"' "$L" > "$L.2"; out=$(render "$L.2")
assert_not_contains "no settings fallback on modern CC without effort key" "$out" "(max)"

echo "== renderer: hostile + garbage input =="
H="$SCRATCH/hostile.json"
jq -c --arg esc "$(printf '\033')" '.model.display_name=("Evil"+$esc+"[2J"+$esc+"]52;c;aGk="+$esc+"\\X") | .effort.level="a[$(id)]" | .context_window.current_usage.input_tokens="a[$(id)]" | .rate_limits.five_hour.used_percentage=250 | .session_id="../../etc/passwd" | .cost.total_duration_ms="x" | .prompt_cache.expires_at="1$(id)" | .pr.number="7;rm" | .transcript_path="/etc/passwd\n/x"' "$M" > "$H"
raw=$(bash "$BIN/statusline-command.sh" < "$H" 2>/dev/null)
esc=$(printf '\033')
if [[ "$raw" == *"${esc}[2J"* || "$raw" == *"${esc}]52"* ]]; then fail "terminal escapes stripped"; else ok "terminal escapes stripped from display_name"; fi
out=$(printf '%s' "$raw" | strip)
assert_contains "string in numeric slot → 0, no eval"  "$out" "Evil[2J]52;c;aGk=\\X (a[\$(id)])"
assert_not_contains "out-of-range 5h pct dropped"       "$out" "5h:"
assert_not_contains "non-numeric pr dropped"            "$out" "#7"
for g in '' 'not json' '{}' '[]' '"str"' '{"context_window":"x","rate_limits":[1],"cost":null}'; do
    out=$(printf '%s' "$g" | bash "$BIN/statusline-command.sh" 2>/dev/null | strip); rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" == *"0/200k (0% used)"* ]]; then ok "garbage input renders defaults: '${g:0:24}'"; else fail "garbage input '${g:0:24}'" "$out"; fi
done

echo "== backup policy (node) =="
P="$SCRATCH/proj"; mkdir -p "$P"
T="$SCRATCH/t.jsonl"
printf '%s\n' '{"type":"user","timestamp":"2026-09-05T00:00:00Z","message":{"role":"user","content":"Please review the whole project carefully"}}' \
               '{"type":"assistant","timestamp":"2026-09-05T00:00:05Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/p/a.sh"}}]}}' \
               '{"type":"user","timestamp":"2026-09-05T00:00:06Z","message":{"role":"user","content":[{"type":"text","text":"Second request as an array block"}]}}' > "$T"
trig() { STATUSLINE_PROJECT_DIR="$P" node "$NODE/trigger-backup.mjs" "sess-1" "tokens_$1" "$2" "$T" "$1" 2>/dev/null; }
r=$(trig 30000 90); [ -z "$r" ] && ok "30k: below first threshold → no backup" || fail "30k" "$r"
r=$(trig 52000 80); [[ "$r" == .claude/backups/1-backup-*.md ]] && ok "52k: first backup created" || fail "52k" "$r"
r=$(trig 58000 78); [ -z "$r" ] && ok "58k: +6k → no update" || fail "58k" "$r"
r=$(trig 63000 76); [ -n "$r" ] && ok "63k: +11k → update" || fail "63k" "$r"
r=$(trig 12000 95); [ -z "$r" ] && ok "12k after compaction → no backup" || fail "12k" "$r"
r=$(trig 61000 25); [ -n "$r" ] && ok "crossed 30% free → backup" || fail "crossed-30" "$r"
st="$P/.claude/backups/.state-sess-1.json"
jq -e '.prevTokens==61000 and .prevFreePct==25 and (.backupPath|test("^\\.claude/backups/1-backup-"))' "$st" >/dev/null && ok "state records baseline" || fail "state" "$(cat "$st")"
grep -q "Second request as an array block" "$P/$(jq -r .backupPath "$st")" && ok "array-content user prompt captured" || fail "array prompt"
grep -q "a.sh" "$P/$(jq -r .backupPath "$st")" && ok "files changed captured" || fail "files changed"
[ "$(stat -c %a "$P/$(jq -r .backupPath "$st")")" = "600" ] && ok "backup file 0600" || fail "backup mode"
[ "$(stat -c %a "$P/.claude/backups")" = "700" ] && ok "backup dir 0700" || fail "backup dir mode"

echo "== hook entry point (node) =="
hook() { printf '%s' "$1" | STATUSLINE_PROJECT_DIR="$P" node "$NODE/conv-backup.mjs" 2>"$SCRATCH/hook.err"; }
o=$(hook "{\"session_id\":\"sess-1\",\"transcript_path\":\"$T\",\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\"}")
[ -z "$o" ] && ok "PreCompact: stdout empty (can never block compaction)" || fail "PreCompact stdout" "$o"
grep -q '^Backup: ' "$SCRATCH/hook.err" && ok "PreCompact: backup reported on stderr" || fail "PreCompact stderr" "$(cat "$SCRATCH/hook.err")"
jq -e '.prevTokens==0 and .prevFreePct==100' "$st" >/dev/null && ok "PreCompact re-arms thresholds" || fail "rearm" "$(cat "$st")"
o=$(hook "{\"session_id\":\"sess-2\",\"transcript_path\":\"$T\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}")
grep -q 'skipped' "$SCRATCH/hook.err" && ok "SessionEnd: no backup for a session that never had one" || fail "SessionEnd new" "$(cat "$SCRATCH/hook.err")"
[ ! -f "$P/.claude/backups/.state-sess-2.json" ] && ok "SessionEnd: no state file created" || fail "SessionEnd state"
o=$(hook "{\"session_id\":\"sess-1\",\"transcript_path\":\"$T\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"prompt_input_exit\"}")
grep -q '^Backup: ' "$SCRATCH/hook.err" && ok "SessionEnd: refreshes an existing backup" || fail "SessionEnd existing"
o=$(hook 'not json'); [ $? -eq 0 ] && ok "hook survives garbage stdin with exit 0" || fail "hook garbage"

echo "== context breakdown (node, streaming) =="
B="$SCRATCH/b.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"content":"old old old old old old old old old old old old old old old old"}}'
  printf '%s\n' '{"type":"system","subtype":"compact_boundary"}'
  printf '%s\n' '{"type":"user","message":{"content":"hello world hello world hello world hello world"}}'   # 48 chars → 12 msgs
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la /tmp/x"}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}'  # 40 → 10 results
  printf '%s\n' '{"type":"attachment","attachment":{"type":"file","content":"bbbbbbbbbbbbbbbbbbbb"}}'
  printf '%s' '{"type":"user","message":{"content":"truncated line without newline'
} > "$B"
node "$NODE/context-breakdown.mjs" "$B" "brk-1" 2>/dev/null
cache="$XDG_CACHE_HOME/claude-statusline/breakdown-brk-1.json"
[ -f "$cache" ] && ok "breakdown cache written" || fail "breakdown cache"
jq -e '.buckets.msgs==12 and .buckets.results==10 and .buckets.tools>0 and .buckets.attach>0 and .total==(.buckets.msgs+.buckets.tools+.buckets.results+.buckets.attach)' "$cache" >/dev/null \
    && ok "only content after the last compact_boundary is counted; truncated tail ignored" || fail "buckets" "$(cat "$cache")"
[ "$(stat -c %a "$cache")" = "600" ] && ok "breakdown cache 0600" || fail "cache mode"
node "$NODE/context-breakdown.mjs" "$B" "../evil" 2>/dev/null; [ ! -e "$XDG_CACHE_HOME/claude-statusline/breakdown-../evil.json" ] && ok "unsafe session id rejected" || fail "unsafe id"
# The bash side renders from that cache
FL="$SCRATCH/fill.json"; jq -c --arg t "$B" '.session_id="brk-1" | .transcript_path=$t' "$M" > "$FL"
out=$(render "$FL"); assert_contains "fill line rendered from cache" "$out" "fill: chat In+Out"

echo "== credit-report (account report) =="
# Synthetic projects root: two projects; the first has a session with a subagent
# transcript and a custom title, the second is older than the --since date.
PR="$CLAUDE_CONFIG_DIR/projects"; mkdir -p "$PR/-tmp-alpha/s-aaaa/subagents" "$PR/-tmp-beta"
mk_asst() { # <file> <msgid> <model> <in> <read> <out> [day]  (day: YYYY-MM-DD, default September)
    local day="${7:-2026-09-03}" ts
    if [ "$day" = "none" ]; then ts=""; else ts=",\"timestamp\":\"${day}T12:00:00.000Z\""; fi
    printf '{"type":"assistant"%s,"message":{"id":"%s","model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":0,"output_tokens":%d}}}\n' \
        "$ts" "$2" "$3" "$4" "$5" "$6" >> "$1"; }
A="$PR/-tmp-alpha/s-aaaa.jsonl"; : > "$A"
printf '{"type":"user","cwd":"/tmp/alpha","message":{"role":"user","content":"hi"}}\n' >> "$A"
printf '{"type":"ai-title","aiTitle":"AI title"}\n{"type":"custom-title","customTitle":"Alpha custom"}\n' >> "$A"
mk_asst "$A" m1 claude-opus-5 1000000 0 100000            # $5 + $2.50 = $7.50
mk_asst "$PR/-tmp-alpha/s-aaaa/subagents/agent-x.jsonl" m2 claude-sonnet-5 1000000 0 0   # $2.00 (subagent)
mk_asst "$PR/-tmp-alpha/s-aaaa/subagents/agent-y.jsonl" m3 claude-sonnet-5 500000 0 0    # $1.00 (subagent)
mkdir -p "$PR/-tmp-alpha/s-aaaa/subagents/workflows/wf_1"
mk_asst "$PR/-tmp-alpha/s-aaaa/subagents/workflows/wf_1/agent-w.jsonl" m6 claude-haiku-4-5 1000000 0 0 2026-08-15  # $1.00, AUGUST
printf '{"type":"workflow-journal","note":"no assistant messages here"}\n' > "$PR/-tmp-alpha/s-aaaa/subagents/workflows/wf_1/journal.jsonl"
mk_asst "$A" msyn "<synthetic>" 1000000 0 1000000          # must be ignored, not priced at Opus rates
Bf="$PR/-tmp-beta/s-bbbb.jsonl"; : > "$Bf"
printf '{"type":"user","cwd":"/tmp/beta","message":{"role":"user","content":"hi"}}\n' >> "$Bf"
mk_asst "$Bf" m4 claude-haiku-4-5 1000000 0 0 2026-01-15   # $1.00, JANUARY — file mtime left at NOW on
                                                          # purpose: a stale-mtime filter would wrongly
                                                          # bill this whole session to today.
rep=$(bash "$BIN/credit-report.sh" --no-color --all 2>/dev/null)
assert_contains "total = main + subagents + workflow agent + other project (synthetic ignored)" "$rep" "TOTAL  \$12.50"
assert_contains "counts: journals are not agents"            "$rep" "2 projects · 2 sessions · 3 agents"
assert_contains "project path from cwd"                     "$rep" "/tmp/alpha"
printf '%s' "$rep" | grep -Eq 's-aaaa +Alpha custom +\$11\.50' && ok "session line: custom title beats AI title" || fail "session title line" "$(printf '%s' "$rep" | grep s-aaaa)"
assert_contains "session cost includes subagents"           "$rep" "\$11.50  opus-5.0"
assert_contains "model mix line for multi-model session"     "$rep" "↳ opus-5.0 \$7.50 (65%) · sonnet-5.0 \$3.00 (26%) · haiku-4.5 \$1.00 (9%)"
assert_contains "agent count shown"                          "$rep" "3 agents"
printf '%s' "$rep" | grep -Eq 'sonnet-5\.0 +\$3\.00 ' && ok "by-model bucket for subagent model" || fail "by-model line" "$(printf '%s' "$rep" | grep sonnet)"
assert_contains "untitled fallback"                          "$rep" "(untitled)"
rep=$(bash "$BIN/credit-report.sh" --no-color --since 2026-06-01 2>/dev/null)
assert_contains "--since drops the old project"             "$rep" "1 project · 1 session"
assert_not_contains "--since: beta gone"                    "$rep" "/tmp/beta"
rep=$(bash "$BIN/credit-report.sh" --no-color --projects 2>/dev/null)
assert_not_contains "--projects hides session rows"         "$rep" "Alpha custom"
rep=$(bash "$BIN/credit-report.sh" --no-color --top 0 2>/dev/null)
assert_contains "--top 0 folds every session"               "$rep" "+ 1 more session · \$11.50"
mkdir -p /tmp/alpha 2>/dev/null
rep=$(bash "$BIN/credit-report.sh" --no-color /tmp/alpha 2>/dev/null)
assert_contains "project filter by real path (encoded)"     "$rep" "1 project · 1 session · 3 agents"
j=$(bash "$BIN/credit-report.sh" --json 2>/dev/null)
jq -e '.total.cost==12.5 and .sessions_count==2 and .agents_count==3 and (.projects[0].sessions[0].by_model|map(.model)|sort)==["haiku-4.5","opus-5.0","sonnet-5.0"] and .projects[0].sessions[0].title=="Alpha custom"' <<< "$j" >/dev/null \
    && ok "--json structure and totals" || fail "--json" "$(printf '%s' "$j" | head -c 400)"
echo "== credit-report: time slicing (regression: mtime is not a date) =="
# alpha: $10.50 on 2026-09-03 + $1.00 (workflow agent) on 2026-08-15
# beta:  $1.00 on 2026-01-15, but its file was written moments ago.
rep=$(bash "$BIN/credit-report.sh" --no-color --all 2>/dev/null)
assert_contains "all-time spans both months"        "$rep" "activity 2026-01-15 → 2026-09-03"
assert_contains "monthly buckets over a long span"  "$rep" "BY MONTH"
printf '%s' "$rep" | grep -Eq '2026-01 +\$1\.00'  && ok "January bucket"  || fail "January bucket"
printf '%s' "$rep" | grep -Eq '2026-08 +\$1\.00'  && ok "August bucket"   || fail "August bucket"
printf '%s' "$rep" | grep -Eq '2026-09 +\$10\.50' && ok "September bucket" || fail "September bucket"
bsum=$(printf '%s' "$rep" | awk '/^   (2026-|undated)/{gsub(/[$,]/,"",$2); t+=$2} END{printf "%.2f", t}')
[ "$bsum" = "12.50" ] && ok "period buckets sum to the total" || fail "bucket sum" "$bsum"

rep=$(bash "$BIN/credit-report.sh" --no-color --all --since 2026-09-01 2>/dev/null)
assert_contains "--since counts only in-window messages, not whole sessions" "$rep" "TOTAL  \$10.50"
assert_contains "--since: fresh-mtime January session excluded"              "$rep" "1 project · 1 session"
assert_contains "narrow window switches to daily buckets"                    "$rep" "BY DAY"
printf '%s' "$rep" | grep -Eq '2026-09-03 +\$10\.50' && ok "daily bucket label" || fail "daily bucket"
assert_contains "session last-active is the last in-window message day"      "$rep" "2026-09-03"
assert_not_contains "--since drops the session's August agent"               "$rep" "haiku-4.5"

rep=$(bash "$BIN/credit-report.sh" --no-color --all --until 2026-08-31 2>/dev/null)
assert_contains "--until keeps only older messages" "$rep" "TOTAL  \$2.00"
assert_contains "--until spans both old months"     "$rep" "2 projects · 2 sessions"

rep=$(bash "$BIN/credit-report.sh" --no-color --since 2026-08-01 --until 2026-08-31 2>/dev/null)
assert_contains "--since + --until isolate one month" "$rep" "TOTAL  \$1.00"
assert_contains "window label"                        "$rep" "2026-08-01 → 2026-08-31"

bash "$BIN/credit-report.sh" --since 2026-09-01 --until 2026-08-01 >/dev/null 2>&1
[ $? -eq 2 ] && ok "inverted window rejected" || fail "inverted window"
bash "$BIN/credit-report.sh" --since 2030-01-01 >/dev/null 2>&1
[ $? -eq 1 ] && ok "empty window reports no usage" || fail "empty window"

j=$(bash "$BIN/credit-report.sh" --json --since 2026-09-01 2>/dev/null)
jq -e '.total.cost==10.5 and .since=="2026-09-01" and .by_period.granularity=="day"
       and (.by_period.buckets|length)==1 and .by_period.buckets[0].period=="2026-09-03"' <<< "$j" >/dev/null \
    && ok "--json carries the window and its buckets" || fail "--json window" "$(printf '%s' "$j" | head -c 300)"

echo "== credit-report: messages with no usable timestamp =="
C2="$SCRATCH/claude2"; mkdir -p "$C2/projects/-tmp-gamma"
G="$C2/projects/-tmp-gamma/s-cccc.jsonl"; : > "$G"
printf '{"type":"user","cwd":"/tmp/gamma","message":{"role":"user","content":"hi"}}\n' >> "$G"
mk_asst "$G" m8 claude-haiku-4-5 1000000 0 0 2026-09-02   # $1.00 dated
mk_asst "$G" m9 claude-haiku-4-5 2000000 0 0 none         # $2.00 undated
rep=$(CLAUDE_CONFIG_DIR="$C2" bash "$BIN/credit-report.sh" --no-color 2>/dev/null)
assert_contains "undated messages still count all-time" "$rep" "TOTAL  \$3.00"
printf '%s' "$rep" | grep -Eq 'undated +\$2\.00' && ok "undated shown as its own bucket" || fail "undated bucket"
rep=$(CLAUDE_CONFIG_DIR="$C2" bash "$BIN/credit-report.sh" --no-color --since 2026-09-01 2>/dev/null)
assert_contains "a window drops what it cannot place" "$rep" "TOTAL  \$1.00"

echo "== credit-report: caching =="
# one file per session priced so far: alpha + beta, plus gamma from the run above
ncache=$(ls "$XDG_CACHE_HOME/claude-statusline/report/" | wc -l)
[ "$ncache" -eq 3 ] && ok "one cache file per session" || fail "cache files" "$ncache"
mk_asst "$PR/-tmp-alpha/s-aaaa/subagents/agent-z.jsonl" m5 claude-sonnet-5 1000000 0 0   # new subagent → cache key changes
rep=$(bash "$BIN/credit-report.sh" --no-color 2>/dev/null)
assert_contains "cache invalidates when a subagent file appears" "$rep" "TOTAL  \$14.50"
mk_asst "$PR/-tmp-alpha/s-aaaa/subagents/agent-z.jsonl" m7 claude-sonnet-5 1000000 0 0   # same file grows, count unchanged
rep=$(bash "$BIN/credit-report.sh" --no-color 2>/dev/null)
assert_contains "cache invalidates when a subagent file grows"   "$rep" "TOTAL  \$16.50"
bash "$BIN/credit-report.sh" --since 2026-13 >/dev/null 2>&1; [ $? -eq 2 ] && ok "bad --since rejected" || fail "bad --since"
bash "$BIN/credit-report.sh" /definitely/not/here >/dev/null 2>&1; [ $? -eq 1 ] && ok "missing project rejected" || fail "missing project"

echo "== isolation =="
# The renderer spawns background backup triggers; give them a moment, then make
# sure nothing landed outside the scratch dir.
sleep 1
stray=$(find "$ROOT/.claude/backups" -newer "$SCRATCH" -type f 2>/dev/null | grep -v -E '/[0-9]+-backup-[0-9-]+\.md$|/\.state-[0-9a-f-]{36}\.json$' || true)
[ -z "$stray" ] && ok "no test artefacts written into the repo" || fail "test wrote into repo" "$stray"
[ -d "$RP/.claude/backups" ] && ok "renderer backups went to the scratch project" || ok "renderer spawned no backup (fine)"

echo
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
