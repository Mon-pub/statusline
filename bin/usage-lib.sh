#!/bin/bash
# usage-lib.sh — per-model weekly quota for the statusline ("Current week (Fable)").
#
# WHY THIS EXISTS: Claude Code's statusline stdin carries only the 5-hour and
# 7-day (all models) windows, plus a gateway-only spend limit. The per-model
# weekly cap that /usage shows as "Current week (Fable)" is NOT on stdin
# (verified on CC 2.1.261: rate_limits is built from five_hour / seven_day /
# spend_limit only). It is available from the same endpoint /usage calls:
#
#   GET https://api.anthropic.com/api/oauth/usage
#   Authorization: Bearer <accessToken from $CLAUDE_CONFIG_DIR/.credentials.json>
#   anthropic-beta: oauth-2025-04-20
#
# whose `limits[]` array holds entries of kind "weekly_scoped" with
# scope.model.display_name ("Fable"), percent, resets_at. Every such entry is
# shown, so a future "Opus"/"Sonnet" bucket appears with no code change.
#
# The same reply carries the 5-hour and 7-day (all models) windows, so they are
# cached too and merged with the stdin figures: stdin only moves when the model
# answers in THIS session, while the poll also sees quota burnt elsewhere (other
# sessions, other machines) and a window that has reset while you were idle.
# Merge rule (see statusline-command.sh): same window → the higher figure wins,
# because usage inside a window only rises; different reset times → the newer
# window wins. That makes a stale poll harmless: it can never lower a number.
#
# HOW IT RUNS: the render never touches the network. It reads a small cache
# ($CACHE_BASE/usage.json, 0600) and, when that is older than USAGE_TTL seconds,
# fires one detached `curl` that rewrites the cache atomically. Failures never
# overwrite good data; they only bump the attempt time so a dead token is retried
# at the TTL, not on every render. Data older than USAGE_STALE seconds is marked
# on the line; older than USAGE_MAX_AGE it is dropped rather than shown as fact.
#
# SECURITY: the token is read in the background process only, sent to exactly
# the endpoint above, and never written to the cache, a log, or the line. The
# cache holds only {times, name, percent, reset}. Names from the server are
# control-stripped and length-capped before display.
#
# OPT-OUT: STATUSLINE_USAGE_API=0 disables the feature entirely (no read of the
# credentials file, no network). Without curl, or without a credentials file
# (macOS keeps the token in Keychain), the feature is silently absent.
#
# TEST HOOK: STATUSLINE_USAGE_URL overrides the endpoint (file:// works).
#
# Functions:
#   usage_rows <cache_base> <claude_dir>
#       Prints one line per window and per model-scoped weekly bucket:
#           W\tfive_hour\tpct\treset_epoch\tage_seconds
#           W\tseven_day\tpct\treset_epoch\tage_seconds
#           S\t<name>\tpct\treset_epoch\tage_seconds
#       (reset_epoch may be empty). Spawns a refresh when the cache is stale.

USAGE_TTL="${STATUSLINE_USAGE_TTL:-300}"      # refresh cadence, seconds
# shellcheck disable=SC2034  # consumed by statusline-command.sh
USAGE_STALE=900                                # older than this → "old Xm" tag
USAGE_MAX_AGE=86400                            # older than this → not shown
_USAGE_URL="${STATUSLINE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"

# jq: ISO-8601 with fraction and numeric offset → unix epoch (null if unparsable)
_USAGE_JQ_ISO='def iso_epoch:
    if type!="string" then null else
    (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))?$") // null) as $c
    | if $c==null then null else
        (($c.d+"Z") | try fromdateiso8601 catch null) as $e
        | if $e==null then null
          elif ($c.z==null or $c.z=="Z") then $e
          else $e - ((if $c.s=="-" then -1 else 1 end) * (($c.h|tonumber)*3600 + ($c.m|tonumber)*60))
          end
      end
    end;'

# _usage_fetch <cache_file> <claude_dir>   (runs detached; writes cache atomically)
_usage_fetch() {
    local cache="$1" claude_dir="$2" creds="$2/.credentials.json"
    local now token expires body tmp
    now=$(date +%s)
    command -v curl >/dev/null 2>&1 || return 0

    token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
    if [ -z "$token" ] && [ -r "$creds" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // "" | if type=="string" then . else "" end' "$creds" 2>/dev/null)
        expires=$(jq -r '.claudeAiOauth.expiresAt | if type=="number" then floor else "" end' "$creds" 2>/dev/null)
        # expiresAt is milliseconds. An expired token is Claude Code's to refresh,
        # not ours (refresh tokens rotate; racing it could log the user out).
        if [[ "$expires" =~ ^[0-9]+$ ]] && [ $(( expires / 1000 )) -le "$now" ]; then token=""; fi
    fi
    [ -n "$token" ] || return 0
    case "$token" in *[!A-Za-z0-9._~+/=-]*) return 0 ;; esac   # never pass junk into a header

    body=$(mktemp) || return 0
    tmp="${cache}.tmp.$$"
    # -f: HTTP >= 400 is a failure (exit 22), body discarded. 8 s cap so a hung
    # network can never pile up fetchers.
    if curl -fsS -m 8 --retry 0 \
            -H "Authorization: Bearer ${token}" \
            -H 'anthropic-beta: oauth-2025-04-20' \
            -H 'Content-Type: application/json' \
            -o "$body" "$_USAGE_URL" 2>/dev/null \
       && jq -e '(.limits|type)=="array"' "$body" >/dev/null 2>&1; then
        # Reduce to what the line needs. Names are control-stripped and capped
        # here so the cache is already safe to print.
        if jq -c --argjson now "$now" "$_USAGE_JQ_ISO"'
            def clean: if type=="string"
                       then (explode | map(select(. > 31 and . != 127 and (. < 128 or . > 159))) | implode | .[0:24])
                       else "" end;
            def win: if type=="object"
                     then { pct: (.utilization | if type=="number" and . >= 0 then . else null end),
                            resets_at: (.resets_at | iso_epoch) }
                     else null end;
            { attempted_at: $now, fetched_at: $now,
              five_hour: (.five_hour | win | select(. != null and .pct != null)),
              seven_day: (.seven_day | win | select(. != null and .pct != null)),
              scoped: [ .limits[] | select(type=="object" and .kind=="weekly_scoped")
                        | select((.scope.model.display_name|type)=="string")
                        | { name: (.scope.model.display_name|clean),
                            pct:  (.percent | if type=="number" and . >= 0 then . else null end),
                            resets_at: (.resets_at | iso_epoch) }
                        | select(.name != "" and .pct != null) ] }' "$body" > "$tmp" 2>/dev/null; then
            chmod 0600 "$tmp" 2>/dev/null; mv -f "$tmp" "$cache" 2>/dev/null
        fi
    else
        # Keep the last good payload; only record the attempt so the TTL throttles retries.
        if [ -f "$cache" ]; then
            jq -c --argjson now "$now" '.attempted_at=$now' "$cache" > "$tmp" 2>/dev/null \
                && chmod 0600 "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null
        else
            printf '{"attempted_at":%s,"fetched_at":0,"scoped":[]}\n' "$now" > "$tmp" 2>/dev/null \
                && chmod 0600 "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null
        fi
    fi
    rm -f "$body" "$tmp" 2>/dev/null
    return 0
}

# usage_rows <cache_base> <claude_dir>
usage_rows() {
    [ "${STATUSLINE_USAGE_API:-1}" = "0" ] && return 0
    local cache_base="$1" claude_dir="$2"
    local cache="$1/usage.json" marker="$1/usage.spawn"
    local now attempted fetched age
    now=$(date +%s)

    attempted=0; fetched=0
    if [ -f "$cache" ]; then
        read -r attempted fetched < <(jq -r '[(.attempted_at // 0), (.fetched_at // 0)] | map(if type=="number" then floor else 0 end) | @tsv' "$cache" 2>/dev/null)
        [[ "$attempted" =~ ^[0-9]+$ ]] || attempted=0
        [[ "$fetched"   =~ ^[0-9]+$ ]] || fetched=0
    fi

    # Refresh when due. The marker stops concurrent renders (several sessions
    # share this account-wide cache) from each launching a fetch.
    if [ $(( now - attempted )) -ge "$USAGE_TTL" ]; then
        local last_spawn=0
        [ -f "$marker" ] && last_spawn=$(cat "$marker" 2>/dev/null)
        [[ "$last_spawn" =~ ^[0-9]+$ ]] || last_spawn=0
        if [ $(( now - last_spawn )) -ge 60 ]; then
            mkdir -p "$cache_base" 2>/dev/null && chmod 0700 "$cache_base" 2>/dev/null
            printf '%s' "$now" > "$marker" 2>/dev/null
            ( _usage_fetch "$cache" "$claude_dir" </dev/null >/dev/null 2>&1 & )
        fi
    fi

    [ "$fetched" -gt 0 ] || return 0
    age=$(( now - fetched ))
    [ "$age" -ge "$USAGE_MAX_AGE" ] && return 0
    # Re-clean on the way out: the cache is ours, but defense in depth is cheap.
    jq -r --argjson age "$age" '
        def clean: if type=="string"
                   then (explode | map(select(. > 31 and . != 127 and (. < 128 or . > 159))) | implode | .[0:24])
                   else "" end;
        def pct:   if type=="number" and . >= 0 then . else empty end;
        def reset: if type=="number" and . > 0 then floor else "" end;
        ( ["five_hour","seven_day"][] as $w | .[$w] | select(type=="object")
          | ["W", $w, (.pct|pct), (.resets_at|reset), $age] ),
        ( (.scoped // [])[] | select(type=="object")
          | ["S", (.name|clean), (.pct|pct), (.resets_at|reset), $age] | select(.[1] != "") )
        | @tsv' "$cache" 2>/dev/null
    return 0
}
