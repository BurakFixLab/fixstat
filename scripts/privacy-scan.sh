#!/bin/bash
# Scans for personal data (serial numbers, UUIDs, user home paths) before it
# can reach the repository.
#
# Usage:
#   scripts/privacy-scan.sh --staged        # added lines in the git index (pre-commit)
#   scripts/privacy-scan.sh --history       # every line ever added in any commit
#   scripts/privacy-scan.sh FILE...         # arbitrary files
#
# A line can be exempted by putting the marker "privacy:allow" on it. Use this
# sparingly and only for values that are provably not personal data.
#
# Exit status: 0 = clean, 1 = findings, 2 = usage error.

set -u

mode="${1:-}"
if [ -z "$mode" ]; then
    echo "usage: $0 --staged | --history | FILE..." >&2
    exit 2
fi

# --- Identifiers of the machine running the scan --------------------------
# Read at runtime so the literal values never need to be stored in the repo.
literals=()
add_literal() {
    local v="$1"
    # Ignore empty / trivially short values to avoid false positives.
    if [ "${#v}" -ge 6 ]; then literals+=("$v"); fi
}
if command -v ioreg >/dev/null 2>&1; then
    platform=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null)
    add_literal "$(printf '%s' "$platform" | sed -n 's/.*"IOPlatformSerialNumber" = "\([^"]*\)".*/\1/p' | head -1)"
    add_literal "$(printf '%s' "$platform" | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p' | head -1)"
    battery=$(ioreg -rn AppleSmartBattery -d1 2>/dev/null)
    add_literal "$(printf '%s' "$battery" | sed -n 's/.*"Serial"="\([^"]*\)".*/\1/p' | head -1)"
    add_literal "$(printf '%s' "$battery" | sed -n 's/.*"BatterySerialNumber" = "\([^"]*\)".*/\1/p' | head -1)"
    add_literal "$(printf '%s' "$battery" | sed -n 's/.*"SerialNumber" = "\([^"]*\)".*/\1/p' | head -1)"
    # Internal SSD serial (lower-case hex, not caught by the generic patterns).
    while IFS= read -r ssd; do add_literal "$ssd"; done < <(
        ioreg -rc IONVMeBlockStorageDevice -d1 2>/dev/null | grep -o '"Serial Number"="[^"]*"' | sed 's/.*="\(.*\)"/\1/'
        ioreg -rc IOEmbeddedNVMeBlockDevice -d1 2>/dev/null | grep -o '"Serial Number"="[^"]*"' | sed 's/.*="\(.*\)"/\1/'
        ioreg -rc IONVMeController -d1 2>/dev/null | sed -n 's/.*"Serial Number" = "\([^"]*\)".*/\1/p'
        ioreg -rc IONVMeController -d1 2>/dev/null | grep -o '"controller-unique-id"="[^"]*"' | sed 's/.*="\([^" ]*\).*/\1/'
    )
fi
# The local account name is only flagged as part of a home path; a bare short
# user name would match ordinary words.
home_user="$(id -un 2>/dev/null || true)"

# --- Generic patterns (extended regex, case-sensitive) --------------------
# UUID / GUID.
re_uuid='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
# Serial-number keys followed by a value that is not visibly masked.
re_serial_key='"?(IOPlatformSerialNumber|IOPlatformUUID|BatterySerialNumber|SerialNumber|Serial|serial|serialNumber|kUSBSerialNumberString|USB Serial Number|Serial Number|UUID|uuid)"?[[:space:]]*[=:][[:space:]]*"[^"*<]{6,}"'
# Apple-style serials: 10-12 chars (device) or 17-18 chars (battery pack),
# upper-case alphanumeric, mixing letters and digits.
re_apple_serial='(^|[^A-Za-z0-9_])[A-Z0-9]{10,12}([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])[A-Z0-9]{17,18}([^A-Za-z0-9_]|$)'
# Absolute home directory paths with a concrete user name.
re_home='/Users/[A-Za-z0-9._-]+/'
# Placeholders that are allowed in home paths.
re_home_ok='/Users/(<[^>]*>|\$USER|\$\{USER\}|USER|username|you|Shared|example)/'

findings=0
report() {
    # $1 = location, $2 = reason, $3 = line
    local line="$3"
    [ "${#line}" -gt 160 ] && line="${line:0:160}..."
    printf '  %s: %s\n      %s\n' "$1" "$2" "$line" >&2
    findings=$((findings + 1))
}

# Returns 0 if a token looks like a real serial (mixes letters and digits and
# is not a pure hex string, which would more likely be a hash or constant).
looks_like_serial() {
    local t="$1"
    [[ "$t" =~ [A-Z] ]] || return 1
    [[ "$t" =~ [0-9] ]] || return 1
    local digits="${t//[^0-9]/}"
    local letters="${t//[^A-Z]/}"
    [ "${#digits}" -ge 2 ] && [ "${#letters}" -ge 2 ] || return 1
    [[ "$t" =~ ^[0-9A-F]+$ ]] && return 1
    return 0
}

check_line() {
    # $1 = location, $2 = line
    local loc="$1" line="$2"
    [[ "$line" == *"privacy:allow"* ]] && return

    local lit
    for lit in "${literals[@]+"${literals[@]}"}"; do
        if [[ "$line" == *"$lit"* ]]; then
            report "$loc" "contains an identifier of THIS Mac (serial/UUID)" "${line//$lit/<redacted>}"
            return
        fi
    done
    if [ -n "$home_user" ] && [[ "$line" == *"/Users/$home_user/"* || "$line" == *"/Users/$home_user" ]]; then
        report "$loc" "contains the local home directory path" "${line//$home_user/<user>}"
        return
    fi
    if [[ "$line" =~ $re_uuid ]]; then
        report "$loc" "UUID" "$line"; return
    fi
    if [[ "$line" =~ $re_serial_key ]]; then
        report "$loc" "serial/UUID key with unmasked value" "$line"; return
    fi
    if [[ "$line" =~ $re_home ]] && ! [[ "$line" =~ $re_home_ok ]]; then
        report "$loc" "absolute home directory path" "$line"; return
    fi
    local rest="$line" tok
    while [[ "$rest" =~ $re_apple_serial ]]; do
        tok="${BASH_REMATCH[0]}"
        rest="${rest#*"$tok"}"
        tok="${tok//[^A-Z0-9]/}"
        if looks_like_serial "$tok"; then
            report "$loc" "looks like an Apple serial number ($tok)" "$line"
            return
        fi
    done
}

# Reads unified diff text on stdin and checks every added line.
scan_diff() {
    local label="$1" file="" line
    while IFS= read -r line; do
        case "$line" in
            "+++ b/"*) file="${line#+++ b/}" ;;
            "+++ "*)   file="" ;;
            "+"*)      [ -n "$file" ] && check_line "$label$file" "${line#+}" ;;
        esac
    done
}

case "$mode" in
    --staged)
        # Binary files are not diffed as text; screenshots must be reviewed by hand.
        # Process substitution (not a pipe) so that scan_diff runs in this shell
        # and its findings count survives.
        scan_diff "" < <(git diff --cached --no-color -U0 --diff-filter=ACMR)
        # File names themselves.
        while IFS= read -r name; do
            check_line "(file name)" "$name"
        done < <(git diff --cached --name-only --diff-filter=ACMR)
        ;;
    --history)
        while IFS= read -r commit; do
            scan_diff "${commit:0:8}:" < <(git show --no-color -U0 --format= "$commit")
        done < <(git rev-list --all)
        # Commit metadata (messages, author e-mails).
        while IFS= read -r line; do
            check_line "(commit metadata)" "$line"
        done < <(git log --all --format='%H %an <%ae> %cn <%ce>%n%B' | grep -v '^[0-9a-f]\{40\} ' || true)
        ;;
    -*)
        echo "unknown option: $mode" >&2; exit 2 ;;
    *)
        for f in "$@"; do
            n=0
            while IFS= read -r line || [ -n "$line" ]; do
                n=$((n + 1))
                check_line "$f:$n" "$line"
            done < "$f"
        done
        ;;
esac

if [ "$findings" -gt 0 ]; then
    echo "privacy-scan: $findings finding(s). Mask the values or add 'privacy:allow' to a line that is provably safe." >&2
    exit 1
fi
exit 0
