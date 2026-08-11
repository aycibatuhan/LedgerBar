#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/PUBLIC_FILES.txt"
TEMP_LIST="$(mktemp "${TMPDIR:-/tmp}/ledgerbar-public-files.XXXXXX")"
ACTUAL_LIST="$(mktemp "${TMPDIR:-/tmp}/ledgerbar-public-actual.XXXXXX")"
HISTORY_RAW="$(mktemp "${TMPDIR:-/tmp}/ledgerbar-public-history-raw.XXXXXX")"
HISTORY_LIST="$(mktemp "${TMPDIR:-/tmp}/ledgerbar-public-history.XXXXXX")"
WORKTREE_PORCELAIN="$(mktemp "${TMPDIR:-/tmp}/ledgerbar-public-worktrees.XXXXXX")"
WORKTREE_PATHS="$(mktemp "${TMPDIR:-/tmp}/ledgerbar-public-worktree-paths.XXXXXX")"
WORKTREE_FILES="$(mktemp "${TMPDIR:-/tmp}/ledgerbar-public-worktree-files.XXXXXX")"
trap 'rm -f "$TEMP_LIST" "$ACTUAL_LIST" "$HISTORY_RAW" "$HISTORY_LIST" "$WORKTREE_PORCELAIN" "$WORKTREE_PATHS" "$WORKTREE_FILES"' EXIT

fail() {
    printf 'public-files: FAIL: %s\n' "$1" >&2
    exit 1
}

# Every git invocation must succeed for this checker to mean anything. A git
# failure (broken worktree pointer, moved main repository, missing binary)
# must surface as FAIL, never degrade into a vacuous PASS.
run_git_to() {
    # $1 = output file; remaining arguments are passed to `git -C "$ROOT_DIR"`.
    local out="$1"
    shift
    if ! git -C "$ROOT_DIR" "$@" > "$out"; then
        fail "git $* failed; cannot verify the publication state"
    fi
}

is_forbidden_assistant_path() {
    case "$1" in
        CLAUDE.md|*/CLAUDE.md|CLAUDE.local.md|*/CLAUDE.local.md|\
        AGENTS.md|*/AGENTS.md|GEMINI.md|*/GEMINI.md|CODEX.md|*/CODEX.md|\
        OPENCODE.md|*/OPENCODE.md|CURSOR.md|*/CURSOR.md)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_forbidden_artifact_path() {
    case "$1" in
        .build/*|DerivedData/*|.swiftpm/*|LedgerBar.xcodeproj/*|.private/*|Secrets/*|\
        *.sqlite|*.sqlite-*|*.db|*.db-*|*.p12|*.pem|*.key|.env|.env.*|\
        *.xcuserstate|simplefin-shape-fixture.json|.simplefin-capture-raw-*.json)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

[[ -f "$MANIFEST" ]] || fail "missing allowlist: $MANIFEST"

# Fail closed before any per-file logic if the repository context is unusable.
repo_context="$(git -C "$ROOT_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)"
[[ "$repo_context" == "true" ]] || \
    fail "$ROOT_DIR is not a usable Git work tree (broken or moved repository); refusing to certify"

while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -z "$path" ]] && continue
    [[ "$path" == \#* ]] && continue
    [[ "$path" != /* ]] || fail "absolute path is not allowed: $path"
    [[ "$path" != *$'\t'* ]] || fail "tab in path is not allowed: $path"
    [[ "$path" != *$'\n'* ]] || fail "newline in path is not allowed"
    case "$path" in
        ..|../*|*/../*|*/..)
            fail "path traversal is not allowed in the allowlist: $path"
            ;;
    esac
    if grep -Fqx -- "$path" "$TEMP_LIST"; then
        fail "duplicate allowlist entry: $path"
    fi
    if is_forbidden_assistant_path "$path"; then
        fail "generated, private, credential, or internal assistant path is forbidden: $path"
    fi
    if is_forbidden_artifact_path "$path"; then
        fail "generated, private, or credential path is forbidden: $path"
    fi
    [[ -f "$ROOT_DIR/$path" ]] || fail "allowlisted file is missing: $path"
    # check-ignore is tri-state: 0 = ignored, 1 = not ignored, >1 = git error.
    # Only exit 1 may continue; an error must not pass as "not ignored".
    ignore_status=0
    git -C "$ROOT_DIR" check-ignore --no-index -q -- "$path" || ignore_status=$?
    case "$ignore_status" in
        0) fail "allowlisted file is ignored by .gitignore: $path" ;;
        1) ;;
        *) fail "git check-ignore failed (exit $ignore_status) for: $path" ;;
    esac
    printf '%s\n' "$path" >> "$TEMP_LIST"
done < "$MANIFEST"

run_git_to "$ACTUAL_LIST" ls-files -co --exclude-standard
while IFS= read -r actual || [[ -n "$actual" ]]; do
    [[ -z "$actual" ]] && continue
    if is_forbidden_assistant_path "$actual"; then
        fail "internal assistant file is not publishable: $actual"
    fi
    grep -Fqx -- "$actual" "$TEMP_LIST" || fail "repository file is not allowlisted: $actual"
done < "$ACTUAL_LIST"

# History audit limitation: this inspects the FILENAMES reachable from any
# ref only — it never scans blob content, so a secret pasted into an
# innocuously named file in an old commit is invisible here. Content-level
# review of history is a separate, manual pre-publication gate. Note also
# that `git log --name-only` omits merge-commit diffs; that is acceptable
# while the history is linear — revisit with --diff-merges if merges appear.
run_git_to "$HISTORY_RAW" log --all --format= --name-only -- .
LC_ALL=C sort -u "$HISTORY_RAW" > "$HISTORY_LIST"
while IFS= read -r history_path || [[ -n "$history_path" ]]; do
    [[ -z "$history_path" ]] && continue
    if is_forbidden_assistant_path "$history_path"; then
        fail "internal assistant file is present in reachable history: $history_path"
    fi
    if is_forbidden_artifact_path "$history_path"; then
        fail "generated, private, or credential path is present in reachable history: $history_path"
    fi
done < "$HISTORY_LIST"

run_git_to "$WORKTREE_PORCELAIN" worktree list --porcelain
sed -n 's/^worktree //p' "$WORKTREE_PORCELAIN" > "$WORKTREE_PATHS"
[[ -s "$WORKTREE_PATHS" ]] || fail "git worktree list reported no worktrees; repository context is broken"
while IFS= read -r worktree_path || [[ -n "$worktree_path" ]]; do
    [[ -z "$worktree_path" ]] && continue
    # A listed worktree that cannot be inspected is unverified coverage, not a
    # skippable entry. Repair or `git worktree prune` before publishing.
    [[ -d "$worktree_path" ]] || \
        fail "linked worktree path is missing and cannot be checked: $worktree_path"
    if ! git -C "$worktree_path" ls-files -co --exclude-standard > "$WORKTREE_FILES"; then
        fail "git ls-files failed in linked worktree: $worktree_path"
    fi
    while IFS= read -r worktree_file || [[ -n "$worktree_file" ]]; do
        [[ -z "$worktree_file" ]] && continue
        if is_forbidden_assistant_path "$worktree_file"; then
            fail "internal assistant file is present in linked worktree index: $worktree_file"
        fi
    done < "$WORKTREE_FILES"
done < "$WORKTREE_PATHS"

count="$(wc -l < "$TEMP_LIST" | tr -d ' ')"
printf 'public-files: PASS (%s allowlisted files)\n' "$count"
