# Each attempt keeps headers/body private. curl's raw diagnostics may contain credentials.
network_get() {
    local url=$1 output=$2 limit=$3 host=${1#https://} status rc attempt delay retry_after remaining reset
    host=${host%%/*}; host=${host##*@}
    [[ $url == https://* && $host != *:* ]] || fail 5 'Release metadata contains an unsupported download URL.'
    for attempt in 1 2 3; do
        rc=0
        status=$(curl --disable --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time "$limit" --retry 0 \
            --user-agent 'decky-installer' --dump-header "$output.headers" \
            --output "$output.part" --write-out '%{http_code}' "$url" 2>"$output.error") || rc=$?
        if (( rc == 0 )) && [[ $status == 200 ]]; then
            mv -- "$output.part" "$output" || fail 3 'Cannot save downloaded file.'
            rm -f -- "$output.headers" "$output.error"
            return
        fi
        remaining=$(awk 'tolower($1)=="x-ratelimit-remaining:" {gsub("\r", "", $2); v=$2} END {print v}' "$output.headers" 2>/dev/null) || remaining=''
        reset=$(awk 'tolower($1)=="x-ratelimit-reset:" {gsub("\r", "", $2); v=$2} END {print v}' "$output.headers" 2>/dev/null) || reset=''
        if [[ $status == 403 && $remaining == 0 ]]; then
            [[ $reset =~ ^[0-9]+$ ]] || reset=unknown
            fail 4 "GitHub API rate limit exhausted on $host (reset Unix time: $reset). Wait before retrying."
        fi
        delay=$((attempt * 2))
        retry_after=$(awk 'tolower($1)=="retry-after:" {gsub("\r", "", $2); v=$2} END {print v}' "$output.headers" 2>/dev/null) || retry_after=''
        if [[ -n $retry_after ]]; then
            if [[ ! $retry_after =~ ^[0-9]{1,2}$ ]] || (( 10#$retry_after > 30 )); then
                fail 4 "$host requested a delayed retry (HTTP $status). Wait and run the installer again."
            fi
            delay=$((10#$retry_after))
        fi
        if (( attempt < 3 )) && { [[ $rc =~ ^(5|6|7|18|28|52|55|56)$ ]] || { (( rc == 0 )) && [[ $status =~ ^(429|500|502|503|504)$ ]]; }; }; then
            printf '[decky] Network attempt %s failed on %s (curl=%s, HTTP=%s); retrying in %ss.\n' "$attempt" "$host" "$rc" "$status" "$delay" >&2
            sleep "$delay"
            continue
        fi
        case $rc in
            5|6) fail 4 "DNS resolution failed for $host or its proxy. Check DNS and proxy settings." ;;
            7) fail 4 "Cannot connect to $host. Check connectivity, firewall and proxy settings." ;;
            28) fail 4 "Request to $host timed out. Check connectivity and retry." ;;
            35|51|58|60|77|80|82|83|90|91) fail 4 "TLS verification/connection failed for $host. Check the system clock, CA certificates and HTTPS proxy; TLS verification remains enabled." ;;
            23|26) fail 3 'Cannot read/write download files. Check disk space and permissions.' ;;
            0) case $status in
                404) fail 4 "Resource not found on $host (HTTP 404). Retry later or report a missing release asset." ;;
                401|403) fail 4 "Access denied by $host (HTTP $status). Check GitHub access restrictions or rate limits." ;;
                429) fail 4 "$host is rate limiting requests (HTTP 429). Wait before retrying." ;;
                *) fail 4 "Download from $host failed (HTTP $status). Check service availability and retry." ;;
                esac ;;
            *) fail 4 "Transfer from $host failed (curl exit $rc). Check the network/proxy and retry." ;;
        esac
    done
}

find_release() {
    local channel=$1 dir=$2 page=1 release count prerelease=false
    [[ $channel == prerelease ]] && prerelease=true
    while :; do
        network_get "https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases?per_page=100&page=$page" "$dir/releases.json" 60
        jq -e 'type == "array" and all(.[]; type == "object" and (.prerelease | type == "boolean") and (.draft | type == "boolean"))' "$dir/releases.json" >/dev/null 2>&1 ||
            fail 5 'GitHub returned invalid release metadata (expected a release array).'
        release=$(jq -c --argjson pre "$prerelease" 'first(.[] | select(.draft == false and .prerelease == $pre)) // empty' "$dir/releases.json")
        if [[ -n $release ]]; then
            printf '%s\n' "$release" > "$dir/release.json"
            break
        fi
        count=$(jq length "$dir/releases.json")
        (( count == 100 && page < 100 )) || fail 5 "No $channel release was found on GitHub."
        page=$((page + 1))
    done
    jq -e --arg asset "$ASSET" '
        (.tag_name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")) and
        (.assets | type == "array") and
        ([.assets[] | select(.name == $asset)] | length == 1) and
        ([.assets[] | select(.name == $asset)][0] |
            (.size | type == "number" and . > 0 and . == floor) and
            (.browser_download_url | type == "string" and startswith("https://github.com/SteamDeckHomebrew/decky-loader/releases/download/")) and
            (.digest == null or (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))))
        ' "$dir/release.json" >/dev/null 2>&1 || fail 5 "Release has missing, ambiguous or invalid metadata for $ASSET."
    VERSION=$(jq -r .tag_name "$dir/release.json")
    DOWNLOAD_URL=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .browser_download_url' "$dir/release.json")
    SIZE=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .size' "$dir/release.json")
    DIGEST=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .digest // "none"' "$dir/release.json")
}
