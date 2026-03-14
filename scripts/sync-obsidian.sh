#!/usr/bin/env bash
set -euo pipefail

OBSIDIAN_BLOG_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/icloud vault/Blog"
HUGO_POSTS_DIR="$(git rev-parse --show-toplevel)/content/posts"
HUGO_DRAFTS_DIR="$(git rev-parse --show-toplevel)/content/drafts"

if [ ! -d "$OBSIDIAN_BLOG_DIR" ]; then
  echo "Obsidian Blog directory not found"
  exit 1
fi

mkdir -p "$HUGO_POSTS_DIR" "$HUGO_DRAFTS_DIR"

synced=0

for src in "$OBSIDIAN_BLOG_DIR"/*.md; do
  [ -f "$src" ] || continue

  filename="$(basename "$src")"
  # Slugify: lowercase, spaces to hyphens, remove non-alphanumeric (except hyphens/dots)
  slug="$(echo "$filename" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9._-]//g')"

  # Warn if missing front matter
  if ! head -1 "$src" | grep -q '^---'; then
    echo "WARNING: $filename is missing Hugo front matter, skipping. Use the 'Hugo Blog Post' template in Obsidian."
    continue
  fi

  # Check if draft: true in front matter
  is_draft=false
  if sed -n '/^---$/,/^---$/p' "$src" | grep -q '^draft: true'; then
    is_draft=true
  fi

  if [ "$is_draft" = true ]; then
    dest="$HUGO_DRAFTS_DIR/$slug"
    # Remove from posts if it was previously published
    rm -f "$HUGO_POSTS_DIR/$slug"
  else
    dest="$HUGO_POSTS_DIR/$slug"
    # Remove from drafts if it was previously a draft
    rm -f "$HUGO_DRAFTS_DIR/$slug"
  fi

  # Skip if Hugo copy exists and is newer than Obsidian source
  if [ -f "$dest" ] && [ "$dest" -nt "$src" ]; then
    continue
  fi

  cp "$src" "$dest"
  synced=$((synced + 1))
done

if [ "$synced" -gt 0 ]; then
  echo "Synced $synced post(s) from Obsidian to Hugo"
else
  echo "All posts up to date"
fi
