#!/usr/bin/env bash
# Run from a disposable server session selected in the Windows client.
set -euo pipefail

session=${AGTERM_SESSION_ID:?Run inside an agterm-server session}
case_name=${1:-html}
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d)
page_id=

session_state() {
    agtermctl tree --json | jq -ce --arg id "$session" \
        '.result.tree | recurse(.workspaces[]?, .sessions[]?, .children[]?, .companions[]?) | select(.id == $id)'
}

page_state() {
    session_state | jq -c --arg page "$page_id" '.htmlOverlays[]? | select(.id == $page)'
}

cleanup() {
    if [[ -n $page_id && -n $(page_state 2>/dev/null) ]]; then
        agtermctl session overlay close --target "$session" >/dev/null 2>&1 || true
    fi
    rm -f "$work_dir/page.html" "$work_dir/page.md"
    rmdir "$work_dir"
}
trap cleanup EXIT

if ! session_state | jq -e '.presenters.presenter == true and (.overlay != true) and ([.remoteOverlays[]?, .htmlOverlays[]?] | length == 0)' >/dev/null; then
    printf 'The test session needs a connected presenter and a free overlay slot.\n' >&2
    exit 1
fi

case "$case_name" in
    html)
        title="agterm remote HTML ${work_dir##*.}"
        printf '<!doctype html><meta charset="utf-8"><title>%s</title><p>Remote overlay content</p>\n' "$title" > "$work_dir/page.html"
        source_type=--html
        source_file="$work_dir/page.html"
        ;;
    markdown)
        printf '# Remote Markdown overlay\n' > "$work_dir/page.md"
        source_type=--markdown
        source_file="$work_dir/page.md"
        ;;
    image)
        source_type=--image
        source_file="$test_dir/../../../site/assets/favicon-180.png"
        ;;
    *)
        printf 'Usage: bash %s [html|markdown|image]\n' "$0" >&2
        exit 2
        ;;
esac

if reply=$(agtermctl session overlay open "$source_type" "$source_file" --target "$session" --json); then
    page_id=$(jq -er '.result.pageID' <<< "$reply")
elif [[ $case_name == markdown ]] && jq -e '.error | strings | test("unsupported|not supported|not implemented|unavailable"; "i")' <<< "$reply" >/dev/null; then
    printf 'PASS Markdown was refused with an explanation.\n'
    exit 0
else
    printf 'Overlay open failed: %s\n' "$reply" >&2
    exit 1
fi

for ((attempt = 0; attempt < 30; attempt++)); do
    page=$(page_state)
    if [[ -z $page ]]; then
        outcome=$(agtermctl session overlay result --page "$page_id" --target "$session" --json || true)
        printf 'FAIL %s disappeared before sending the expected state: %s\n' "$case_name" "$outcome" >&2
        exit 1
    fi
    if [[ $case_name == html ]] && jq -e --arg title "$title" '.state == "loaded" and .title == $title' <<< "$page" >/dev/null; then
        printf 'PASS HTML loaded the supplied document title.\n'
        exit 0
    fi
    if [[ $case_name == image ]] && jq -e '.state == "loaded" and .image != null' <<< "$page" >/dev/null; then
        printf 'PASS The Windows client reported the PNG loaded.\n'
        exit 0
    fi
    if [[ $case_name == markdown ]] && jq -e '.error | strings | test("unsupported|not supported|not implemented|unavailable"; "i")' <<< "$page" >/dev/null; then
        printf 'PASS Markdown reported why the Windows client could not display it.\n'
        exit 0
    fi
    sleep 0.5
done

printf 'FAIL %s did not reach the expected state: %s\n' "$case_name" "$page" >&2
exit 1
