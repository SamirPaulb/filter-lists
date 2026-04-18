#!/bin/bash
# merge.sh — Downloads all filter lists, resolves !#include directives,
# deduplicates, and merges into a single file.
# Includes safety validation to reject corrupted or non-filter-list downloads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SOURCES="$REPO_DIR/sources.txt"
CUSTOM="$REPO_DIR/custom-rules.txt"
OUTPUT="$REPO_DIR/filters.txt"
TEMP_DIR=$(mktemp -d)
INCLUDE_DIR="$TEMP_DIR/includes"
mkdir -p "$INCLUDE_DIR"

trap 'rm -rf "$TEMP_DIR"' EXIT

# Counter file for unique filenames (works across subshells)
echo "0" > "$TEMP_DIR/.counter"

# ──────────────────────────────────────────────
# Safety validation for downloaded filter lists
# ──────────────────────────────────────────────
validate_filter_list() {
    local file="$1"
    local url="$2"
    local lines
    lines=$(wc -l < "$file" | tr -d ' ')

    # 1. Reject empty files (download failed silently)
    if [ "$lines" -lt 2 ]; then
        echo "   [SKIP] Empty file — $url"
        return 1
    fi

    # 2. Reject HTML error pages (proxy blocks, 404s, captchas, rate limits)
    if head -10 "$file" | grep -qi '<!doctype\|<html'; then
        echo "   [SKIP] HTML page (not a filter list) — $url"
        return 1
    fi

    # 3. Reject binary/executable files
    if file -b --mime "$file" 2>/dev/null | grep -q 'binary\|octet-stream\|executable'; then
        echo "   [SKIP] Binary content — $url"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────
# Resolve !#include directives recursively
# Downloads included files relative to the parent URL
# ──────────────────────────────────────────────
resolve_includes() {
    local file="$1"
    local base_url="$2"
    local depth="$3"
    local inc_list="$TEMP_DIR/.inc_paths_${depth}.txt"

    # Safety: max recursion depth of 3 to prevent infinite loops
    if [ "$depth" -gt 3 ]; then
        return
    fi

    # Get the directory part of the URL (strip filename)
    local dir_url
    dir_url=$(echo "$base_url" | sed 's|/[^/]*$|/|')

    # Extract all !#include paths to a temp file (avoids subshell issues)
    grep '^!#include ' "$file" 2>/dev/null | sed 's/^!#include //' | tr -d '\r' > "$inc_list" || true

    # Process each include path
    while IFS= read -r include_path; do
        # Skip empty paths
        [ -z "$include_path" ] && continue

        # Build full URL
        local include_url
        if echo "$include_path" | grep -q '^https\?://'; then
            include_url="$include_path"
        else
            include_url="${dir_url}${include_path}"
        fi

        # Unique filename via counter file
        local fc
        fc=$(cat "$TEMP_DIR/.counter")
        fc=$((fc + 1))
        echo "$fc" > "$TEMP_DIR/.counter"
        local include_file="$INCLUDE_DIR/inc_${fc}.txt"

        # Download
        if curl -s -L --max-time 60 --retry 1 -o "$include_file" "$include_url" 2>/dev/null; then
            local inc_lines
            inc_lines=$(wc -l < "$include_file" | tr -d ' ')
            if [ "$inc_lines" -gt 1 ]; then
                if ! head -5 "$include_file" | grep -qi '<!doctype\|<html'; then
                    echo "      [+] $inc_lines lines — ${include_path:0:60}"
                    # Recursively resolve includes in this file too
                    resolve_includes "$include_file" "$include_url" $((depth + 1))
                else
                    rm -f "$include_file"
                fi
            else
                rm -f "$include_file"
            fi
        else
            echo "      [-] Failed — ${include_path:0:60}"
        fi
    done < "$inc_list"
}

echo ">> Downloading filter lists..."
echo ""

total=0
success=0
failed=0
skipped=0
includes_found=0

while IFS= read -r url; do
    # Skip comments and blank lines
    [[ -z "$url" || "$url" =~ ^# ]] && continue

    total=$((total + 1))
    filename="$TEMP_DIR/list_${total}.txt"

    if curl -s -L --max-time 120 --retry 2 --retry-delay 5 -o "$filename" "$url" 2>/dev/null; then
        if validate_filter_list "$filename" "$url"; then
            lines=$(wc -l < "$filename" | tr -d ' ')
            echo "   [OK] $lines lines — ${url:0:80}"
            success=$((success + 1))

            # Check for !#include directives and resolve them
            inc_count=$(grep -c '^!#include ' "$filename" 2>/dev/null || true)
            inc_count=${inc_count:-0}
            if [ "$inc_count" -gt 0 ]; then
                echo "      Resolving $inc_count includes..."
                resolve_includes "$filename" "$url" 0
                includes_found=$((includes_found + inc_count))
            fi
        else
            rm -f "$filename"
            skipped=$((skipped + 1))
        fi
    else
        echo "   [FAIL] $url"
        rm -f "$filename"
        failed=$((failed + 1))
    fi
done < "$SOURCES"

# Count how many include files were downloaded
inc_downloaded=$(find "$INCLUDE_DIR" -name 'inc_*.txt' 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo ">> Downloaded $success/$total lists ($failed failed, $skipped skipped)"
echo ">> Resolved $inc_downloaded included sub-files"
echo ">> Processing rules..."

# Combine all downloaded lists + resolved includes
cat "$TEMP_DIR"/list_*.txt "$INCLUDE_DIR"/inc_*.txt 2>/dev/null \
    | grep -v '^\s*$' \
    | grep -v '^!' \
    | grep -v '^\[Adblock' \
    | grep -v '^# ' \
    | grep -v '^#$' \
    > "$TEMP_DIR/all_rules_raw.txt"

echo "   Raw rules: $(wc -l < "$TEMP_DIR/all_rules_raw.txt" | tr -d ' ')"

# Deduplicate (sort -u)
sort -u "$TEMP_DIR/all_rules_raw.txt" > "$TEMP_DIR/all_rules_dedup.txt"
echo "   After dedup: $(wc -l < "$TEMP_DIR/all_rules_dedup.txt" | tr -d ' ')"

# Extract custom rules (keep comments for section readability)
grep -v '^\s*$' "$CUSTOM" > "$TEMP_DIR/custom_rules.txt" 2>/dev/null || true

# Count totals
subscription_count=$(wc -l < "$TEMP_DIR/all_rules_dedup.txt" | tr -d ' ')
custom_count=$(grep -cv '^!' "$TEMP_DIR/custom_rules.txt" 2>/dev/null | tr -d ' ' || echo "0")
total_rules=$((subscription_count + custom_count))

# Generate timestamp
timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# Build the final file
cat > "$OUTPUT" << HEADER
! Title: Samir's Ultimate Filter List
! Description: Comprehensive ad, tracker, malware, phishing & annoyance protection
! Last updated: ${timestamp}
! Expires: 1 day
! Homepage: https://github.com/SamirPaulb/filter-lists
! License: https://github.com/SamirPaulb/filter-lists/blob/main/LICENSE
! Total rules: ${total_rules} (${subscription_count} from ${success} sources + ${custom_count} custom)
!
! Auto-generated by GitHub Actions. Do not edit directly.
! To modify: edit sources.txt or custom-rules.txt and push.
!
! SETUP: Subscribe to this single URL in your browser:
!   https://raw.githubusercontent.com/SamirPaulb/filter-lists/main/filters.txt
!
! ==============================
! SUBSCRIPTION RULES (merged from ${success} sources)
! ==============================
HEADER

cat "$TEMP_DIR/all_rules_dedup.txt" >> "$OUTPUT"

cat >> "$OUTPUT" << SEPARATOR

! ==============================
! CUSTOM RULES
! ==============================
SEPARATOR

cat "$TEMP_DIR/custom_rules.txt" >> "$OUTPUT"

echo ""
echo ">> Output: $OUTPUT"
echo ">> Total rules: $total_rules ($subscription_count subscription + $custom_count custom)"
echo ">> Done!"
