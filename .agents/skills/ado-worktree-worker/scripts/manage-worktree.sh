#!/usr/bin/env bash
# Manages isolated Git worktrees for Azure DevOps work items on Linux/macOS (e.g., devs7).
# Usage:
#   ./manage-worktree.sh create <WorkItemId> [Slug] [BaseBranch]
#   ./manage-worktree.sh remove <WorkItemId>
#   ./manage-worktree.sh list
set -euo pipefail

ACTION="${1:?Action required: create | remove | list}"
WORK_ITEM_ID="${2:-}"
SLUG="${3:-task}"
BASE_BRANCH="${4:-main}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
PARENT_DIR="$(dirname "$REPO_ROOT")"

if [ "$ACTION" = "list" ]; then
    git worktree list
    exit 0
fi

if [ -z "$WORK_ITEM_ID" ]; then
    echo "Error: WorkItemId is required for '$ACTION'." >&2
    exit 1
fi

CLEAN_SLUG="$(echo "$SLUG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g')"
BRANCH_NAME="feat/AB-${WORK_ITEM_ID}-${CLEAN_SLUG}"
WORKTREE_PATH="${PARENT_DIR}/${REPO_NAME}-wt-ab-${WORK_ITEM_ID}"

if [ "$ACTION" = "create" ]; then
    git fetch origin "$BASE_BRANCH" 2>/dev/null || true

    if [ -d "$WORKTREE_PATH" ]; then
        echo "Worktree already exists at $WORKTREE_PATH"
    else
        if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
            git worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
        else
            git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "origin/$BASE_BRANCH" 2>/dev/null || \
                git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$BASE_BRANCH"
        fi
    fi

    if [ -f "$WORKTREE_PATH/.env.example" ] && [ ! -f "$WORKTREE_PATH/.env" ]; then
        cp "$WORKTREE_PATH/.env.example" "$WORKTREE_PATH/.env"
        echo "Bootstrapped .env from .env.example"
    fi

    ASSIGNED_PORT=$((4000 + (WORK_ITEM_ID % 1000)))
    echo "READY_WORKTREE_PATH=$WORKTREE_PATH"
    echo "READY_BRANCH=$BRANCH_NAME"
    echo "ASSIGNED_PORT_OFFSET=$ASSIGNED_PORT"
    exit 0
fi

if [ "$ACTION" = "remove" ]; then
    if [ -d "$WORKTREE_PATH" ]; then
        git worktree remove --force "$WORKTREE_PATH"
        echo "Removed worktree at $WORKTREE_PATH"
    fi
    git worktree prune
    exit 0
fi
