#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

include_claude=false
if [[ "${1:-}" == "--claude" ]]; then
    include_claude=true
    shift
fi
if [[ "${1:-}" == "--help" ]]; then
    printf 'Usage: %s [--claude] [target-repo]\n' "${0##*/}"
    exit 0
fi
if [[ "$#" -gt 1 || "${1:-}" == -* ]]; then
    fail "Usage: ${0##*/} [--claude] [target-repo]"
fi

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
target_root="$(git -C "${1:-.}" rev-parse --show-toplevel)" || fail "Choose a Git working tree."
target_root="$(cd -- "$target_root" && pwd -P)"
[[ "$source_root" != "$target_root" ]] || fail "Choose a project repository other than the baseline source."

baseline_begin='<!-- agents-baseline:begin -->'
baseline_end='<!-- agents-baseline:end -->'
ownership_file='.agents-baseline'
target_instructions="$target_root/AGENTS.md"
lock_dir="$target_root/.agents-baseline-sync.lock"
skill_targets=("$target_root/.agents/skills")
if "$include_claude"; then
    skill_targets+=("$target_root/.claude/skills")
fi

valid_markers() {
    awk -v begin="$baseline_begin" -v end="$baseline_end" '
        { sub(/\r$/, "") }
        $0 == begin { starts++; first = NR }
        $0 == end { ends++; last = NR }
        END { exit !(starts == 1 && ends == 1 && first < last) }
    ' "$1"
}

valid_markers "$source_root/AGENTS.md" || fail "The baseline source has invalid markers."
mkdir -- "$lock_dir" 2>/dev/null || fail "Cannot acquire sync lock at $lock_dir. If the previous run was killed, check that it has stopped and remove the empty lock directory."
staging=''
pending_destination=''
cleanup() {
    if [[ -n "$pending_destination" && -d "$staging/previous" && ! -e "$pending_destination" ]]; then
        if ! mv -- "$staging/previous" "$pending_destination"; then
            printf 'Previous skill retained at %s\n' "$staging/previous" >&2
            rmdir -- "$lock_dir"
            return 1
        fi
    fi
    if [[ -n "$staging" ]]; then
        rm -rf -- "$staging"
    fi
    rmdir -- "$lock_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ ! -L "$target_instructions" ]] || fail "AGENTS.md is a symlink."
if [[ -e "$target_instructions" ]]; then
    [[ -f "$target_instructions" ]] || fail "AGENTS.md is not a regular file."
    valid_markers "$target_instructions" || fail "AGENTS.md needs exactly one ordered pair of baseline markers. See README.md for the one-time migration."
fi

source_skills=("$source_root"/skills/*/SKILL.md)
[[ -f "${source_skills[0]}" ]] || fail "No source skills found."
notice_names=('BASELINE-LICENSE' 'PSTACK-LICENSE')
notice_sources=("$source_root/LICENSE" "$source_root/skills/LICENSE")
for notice in "${notice_sources[@]}"; do
    [[ -f "$notice" && -r "$notice" ]] || fail "Missing or unreadable license: $notice"
done

# Check ownership and collisions across every requested target before copying.
for skill_target in "${skill_targets[@]}"; do
    for directory in "${skill_target%/*}" "$skill_target"; do
        [[ ! -L "$directory" ]] || fail "Skill directory is a symlink: $directory"
        [[ ! -e "$directory" || -d "$directory" ]] || fail "Expected a directory: $directory"
    done

    for index in "${!notice_names[@]}"; do
        target_notice="$skill_target/${notice_names[$index]}"
        [[ ! -L "$target_notice" ]] || fail "License path is a symlink: $target_notice"
        if [[ -e "$target_notice" ]]; then
            [[ -f "$target_notice" ]] && cmp -s "${notice_sources[$index]}" "$target_notice" ||
                fail "Existing license differs: $target_notice"
        fi
    done

    for skill_file in "${source_skills[@]}"; do
        skill_dir="${skill_file%/SKILL.md}"
        destination="$skill_target/${skill_dir##*/}"
        [[ ! -L "$destination" ]] || fail "Skill path is a symlink: $destination"
        if [[ -e "$destination" ]]; then
            owner="$destination/$ownership_file"
            [[ -d "$destination" && -f "$owner" && ! -L "$owner" ]] &&
                grep -qx 'agents-baseline' "$owner" ||
                fail "Existing skill is project-owned: $destination"
            links="$(find "$destination" -type l -print)"
            [[ -z "$links" ]] || fail "Managed skill contains symlinks: $destination"
        fi
    done
done

staging="$(mktemp -d "$target_root/.agents-baseline-sync.XXXXXX")"

write_instructions() {
    if [[ ! -f "$target_instructions" ]]; then
        cat "$source_root/AGENTS.md"
        return
    fi

    local copy=true line newline
    while true; do
        newline=$'\n'
        if ! IFS= read -r line; then
            [[ -n "$line" ]] || break
            newline=''
        fi
        case "${line%$'\r'}" in
            "$baseline_begin")
                awk -v begin="$baseline_begin" -v end="$baseline_end" '
                    { sub(/\r$/, "") }
                    $0 == begin { copying = 1 }
                    copying { print }
                    $0 == end { exit }
                ' "$source_root/AGENTS.md"
                copy=false
                ;;
            "$baseline_end")
                copy=true
                ;;
            *)
                if "$copy"; then
                    printf '%s%s' "$line" "$newline"
                fi
                ;;
        esac
    done < "$target_instructions"
}

write_instructions > "$staging/AGENTS.md"
for skill_file in "${source_skills[@]}"; do
    skill_dir="${skill_file%/SKILL.md}"
    cp -R -- "$skill_dir" "$staging/"
    printf 'agents-baseline\n' > "$staging/${skill_dir##*/}/$ownership_file"
done

for skill_target in "${skill_targets[@]}"; do
    mkdir -p -- "$skill_target"
    for index in "${!notice_names[@]}"; do
        notice_name="${notice_names[$index]}"
        if [[ ! -f "$skill_target/$notice_name" ]]; then
            cp -- "${notice_sources[$index]}" "$staging/$notice_name"
            mv -- "$staging/$notice_name" "$skill_target/$notice_name"
        fi
    done

    for skill_file in "${source_skills[@]}"; do
        skill_dir="${skill_file%/SKILL.md}"
        skill_name="${skill_dir##*/}"
        destination="$skill_target/$skill_name"
        if [[ -d "$destination" ]] && diff -qr "$staging/$skill_name" "$destination" >/dev/null; then
            continue
        fi

        cp -R -- "$staging/$skill_name" "$staging/next"
        status='Installed'
        if [[ -d "$destination" ]]; then
            pending_destination="$destination"
            mv -- "$destination" "$staging/previous"
            status='Updated'
        fi
        mv -- "$staging/next" "$destination"
        pending_destination=''
        rm -rf -- "$staging/previous"
        printf '%s %s\n' "$status" "${destination#"$target_root"/}"
    done
done

if ! cmp -s "$staging/AGENTS.md" "$target_instructions"; then
    mv -- "$staging/AGENTS.md" "$target_instructions"
    printf 'Synced AGENTS.md\n'
fi
printf 'Baseline sync complete.\n'
