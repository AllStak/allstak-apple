#!/bin/sh
# allstak-upload-dsyms.sh — upload Apple dSYM DWARF files to AllStak for
# server-side crash symbolication.
#
# This is BUILD-TIME / CI tooling, not part of the runtime SDK. AllStak symbolicates
# native crashes on the server by matching each crash image's UUID (LC_UUID / debugId)
# to a dSYM you uploaded for that build. This script finds your .dSYM bundles, locates
# the DWARF Mach-O inside each, and POSTs the raw binary to the AllStak dSYM endpoint.
#
# Endpoint (one request per dSYM DWARF binary; a fat/universal dSYM registers one
# slice per arch — the server reads LC_UUID + __TEXT vmaddr from each slice):
#
#   POST {ALLSTAK_API}/api/v1/dsyms/upload?projectId=<UUID>[&name=<binary>]
#   Authorization: Bearer <USER/CI TOKEN with SOURCEMAPS_UPLOAD capability>
#   Content-Type: application/octet-stream
#   Body: raw DWARF Mach-O bytes (--data-binary)   (max 64 MB per file)
#
# IMPORTANT: the bearer token is a USER/CI upload token (SOURCEMAPS_UPLOAD capability),
# NOT the runtime X-AllStak-Key ingest key. Never bake an upload token into the app.
#
# ── Inputs (CLI flags override env) ────────────────────────────────────────────
#   --path <dir|.dSYM>   where to look for dSYMs (repeatable). If omitted, falls back
#                        to Xcode build-phase env (DWARF_DSYM_FOLDER_PATH /
#                        DWARF_DSYM_FILE_NAME), then to ./ as a last resort.
#   --api <url>          AllStak API base       (env ALLSTAK_API)
#   --project-id <uuid>  target project id      (env ALLSTAK_PROJECT_ID)
#   --token <token>      bearer upload token    (env ALLSTAK_AUTH_TOKEN)
#   --dry-run            print what would be uploaded; make no network calls
#   -h | --help          this help
#
# ── Exit codes (CI-friendly) ───────────────────────────────────────────────────
#   0  every located DWARF binary uploaded OK (or --dry-run completed)
#   1  bad usage / missing required input (api, project-id, token)
#   2  one or more uploads failed, or a dSYM exceeded the 64 MB limit
#   3  no dSYM / DWARF binary found to upload
#
# Fail-open note: with no dSYMs found we exit 3 so CI surfaces a misconfigured build,
# but the actual app build is never touched by this script.

set -eu

PROG="allstak-upload-dsyms"
MAX_BYTES=$((64 * 1024 * 1024)) # 64 MB server limit

log()  { printf '[allstak] %s\n' "$*"; }
warn() { printf '[allstak] %s\n' "$*" >&2; }
die()  { printf '[allstak] error: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ── Parse args ─────────────────────────────────────────────────────────────────
API="${ALLSTAK_API:-}"
PROJECT_ID="${ALLSTAK_PROJECT_ID:-}"
TOKEN="${ALLSTAK_AUTH_TOKEN:-}"
DRY_RUN=0
PATHS="" # newline-separated search inputs

while [ $# -gt 0 ]; do
    case "$1" in
        --path)        [ $# -ge 2 ] || die "--path needs a value"; PATHS="$PATHS
$2"; shift 2 ;;
        --path=*)      PATHS="$PATHS
${1#*=}"; shift ;;
        --api)         [ $# -ge 2 ] || die "--api needs a value"; API="$2"; shift 2 ;;
        --api=*)       API="${1#*=}"; shift ;;
        --project-id)  [ $# -ge 2 ] || die "--project-id needs a value"; PROJECT_ID="$2"; shift 2 ;;
        --project-id=*) PROJECT_ID="${1#*=}"; shift ;;
        --token)       [ $# -ge 2 ] || die "--token needs a value"; TOKEN="$2"; shift 2 ;;
        --token=*)     TOKEN="${1#*=}"; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage 0 ;;
        --)            shift; break ;;
        -*)            die "unknown option: $1" ;;
        *)             PATHS="$PATHS
$1"; shift ;; # bare positional = a search path
    esac
done

# ── Resolve search paths ───────────────────────────────────────────────────────
# Priority: explicit --path/positional > Xcode env > current dir.
if [ -z "$(printf '%s' "$PATHS" | tr -d '[:space:]')" ]; then
    if [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
        if [ -n "${DWARF_DSYM_FILE_NAME:-}" ]; then
            PATHS="${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}"
        else
            PATHS="${DWARF_DSYM_FOLDER_PATH}"
        fi
        log "using Xcode dSYM env: $PATHS"
    else
        PATHS="."
        warn "no --path and no Xcode dSYM env; searching current directory"
    fi
fi

# ── Validate required inputs (skip for dry-run so it works offline) ─────────────
if [ "$DRY_RUN" -eq 0 ]; then
    [ -n "$API" ]        || die "missing API base — pass --api or set ALLSTAK_API" 1
    [ -n "$PROJECT_ID" ] || die "missing project id — pass --project-id or set ALLSTAK_PROJECT_ID" 1
    [ -n "$TOKEN" ]      || die "missing token — pass --token or set ALLSTAK_AUTH_TOKEN" 1
    command -v curl >/dev/null 2>&1 || die "curl not found on PATH" 1
fi

# strip a single trailing slash off the API base, if any
API="${API%/}"

# ── Collect .dSYM bundles from the search inputs ───────────────────────────────
# DSYMS accumulates absolute-ish paths to *.dSYM bundles, newline-separated.
DSYMS=""
add_dsym() { DSYMS="$DSYMS
$1"; }

# Iterate the newline-separated PATHS without a subshell so DSYMS persists.
OLDIFS="$IFS"
IFS='
'
for p in $PATHS; do
    [ -n "$p" ] || continue
    if [ ! -e "$p" ]; then
        warn "path does not exist, skipping: $p"
        continue
    fi
    case "$p" in
        *.dSYM)
            add_dsym "$p" ;;
        *)
            if [ -d "$p" ]; then
                # find every .dSYM bundle under this directory
                found=$(find "$p" -type d -name '*.dSYM' 2>/dev/null || true)
                if [ -n "$found" ]; then
                    for d in $found; do add_dsym "$d"; done
                else
                    warn "no .dSYM bundles under: $p"
                fi
            else
                warn "not a directory or .dSYM, skipping: $p"
            fi
            ;;
    esac
done
IFS="$OLDIFS"

# de-dup while preserving order
DSYMS=$(printf '%s\n' "$DSYMS" | awk 'NF && !seen[$0]++')

if [ -z "$DSYMS" ]; then
    die "no .dSYM bundles found in: $(printf '%s' "$PATHS" | tr '\n' ' ')" 3
fi

# ── For each .dSYM, locate the DWARF Mach-O binary(ies) and upload ──────────────
# A dSYM stores its binary at Contents/Resources/DWARF/<binary>. A universal dSYM
# may contain multiple slices in one Mach-O file (the server splits them); there is
# normally exactly one DWARF file per .dSYM, but we upload all we find to be safe.
TOTAL=0
UPLOADED=0
FAILED=0

upload_one() {
    dwarf="$1"
    name=$(basename "$dwarf")
    size=$(wc -c < "$dwarf" 2>/dev/null | tr -d '[:space:]')
    [ -n "$size" ] || size=0
    TOTAL=$((TOTAL + 1))

    if [ "$size" -gt "$MAX_BYTES" ]; then
        warn "SKIP $name: ${size} bytes exceeds 64 MB limit"
        FAILED=$((FAILED + 1))
        return
    fi

    url="$API/api/v1/dsyms/upload?projectId=$PROJECT_ID&name=$name"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN would upload: $name (${size} bytes)"
        log "  -> POST $url"
        UPLOADED=$((UPLOADED + 1))
        return
    fi

    log "uploading $name (${size} bytes) ..."
    # -sS quiet but show errors; -f makes HTTP >=400 a curl failure;
    # capture the HTTP status on its own line for reporting.
    http_status=$(
        curl -sS -o /tmp/${PROG}.$$.body -w '%{http_code}' \
            -X POST \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "@$dwarf" \
            "$url" 2>/tmp/${PROG}.$$.err
    ) || http_status="000"

    body=$(cat "/tmp/${PROG}.$$.body" 2>/dev/null || true)
    rm -f "/tmp/${PROG}.$$.body" "/tmp/${PROG}.$$.err" 2>/dev/null || true

    case "$http_status" in
        2??)
            log "  OK [$http_status] $name"
            # Surface the registered slices when present (best-effort, no jq dep).
            slices=$(printf '%s' "$body" | tr ',' '\n' | grep -i 'debugId' || true)
            [ -n "$slices" ] && printf '%s\n' "$slices" | sed 's/^/[allstak]   slice: /'
            UPLOADED=$((UPLOADED + 1))
            ;;
        *)
            warn "  FAIL [$http_status] $name :: $(printf '%s' "$body" | head -c 300)"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

for dsym in $DSYMS; do
    [ -n "$dsym" ] || continue
    dwarf_dir="$dsym/Contents/Resources/DWARF"
    if [ ! -d "$dwarf_dir" ]; then
        warn "no DWARF dir in $(basename "$dsym") (expected Contents/Resources/DWARF), skipping"
        continue
    fi
    any=0
    for dwarf in "$dwarf_dir"/*; do
        [ -f "$dwarf" ] || continue
        any=1
        upload_one "$dwarf"
    done
    [ "$any" -eq 1 ] || warn "no DWARF binary inside $(basename "$dsym")"
done

# ── Summary + exit ─────────────────────────────────────────────────────────────
if [ "$TOTAL" -eq 0 ]; then
    die "found .dSYM bundles but no DWARF binaries to upload" 3
fi

log "done: $UPLOADED/$TOTAL uploaded, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 2
exit 0
