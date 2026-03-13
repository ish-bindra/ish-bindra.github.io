#!/usr/bin/env bash
set -euo pipefail

OBSIDIAN_BLOG_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/icloud vault/Blog"
HUGO_POSTS_DIR="$(git rev-parse --show-toplevel)/content/posts"

if [ ! -d "$OBSIDIAN_BLOG_DIR" ]; then
  echo "Obsidian Blog directory not found, skipping sync"
  exit 0
fi

mkdir -p "$HUGO_POSTS_DIR"

synced=0

for src in "$OBSIDIAN_BLOG_DIR"/*.md; do
  [ -f "$src" ] || continue

  filename="$(basename "$src")"
  # Slugify: lowercase, spaces to hyphens, remove non-alphanumeric (except hyphens/dots)
  slug="$(echo "$filename" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9._-]//g')"
  dest="$HUGO_POSTS_DIR/$slug"

  # Skip if Hugo copy exists and is newer than Obsidian source
  if [ -f "$dest" ] && [ "$dest" -nt "$src" ]; then
    continue
  fi

  # Warn if missing front matter
  if ! head -1 "$src" | grep -q '^---'; then
    echo "WARNING: $filename is missing Hugo front matter, skipping. Use the 'Hugo Blog Post' template in Obsidian."
    continue
  fi

  cp "$src" "$dest"
  synced=$((synced + 1))
done

if [ "$synced" -gt 0 ]; then
  echo "Synced $synced post(s) from Obsidian to Hugo"
  git add "$HUGO_POSTS_DIR"/*.md
fi
