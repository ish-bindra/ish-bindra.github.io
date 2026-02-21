# ish-bindra.github.io

Personal blog built with [Hugo](https://gohugo.io/) and the [PaperModX](https://github.com/reorx/hugo-PaperModX) theme, hosted on GitHub Pages.

## Setup Instructions

### 1. Clone the repository
```bash
git clone --recurse-submodules https://github.com/ish-bindra/ish-bindra.github.io.git
cd ish-bindra.github.io
```

If you already cloned without submodules:
```bash
git submodule update --init --recursive
```

### 2. Install Hugo
**macOS:**
```bash
brew install hugo
```

**Linux:**
```bash
wget https://github.com/gohugoio/hugo/releases/download/v0.139.3/hugo_extended_0.139.3_linux-amd64.deb
sudo dpkg -i hugo_extended_0.139.3_linux-amd64.deb
```

### 3. Run locally
```bash
hugo server -D
```

Visit `http://localhost:1313` to see your blog.

## Writing a New Post

Create a new post:
```bash
hugo new content/posts/my-new-post.md
```

Or manually create a file in `content/posts/` with this format:

```markdown
---
title: "My Post Title"
date: 2026-02-17
draft: false
tags: [tag1, tag2]
categories: [category1]
---

Your content here...
```

## Publishing

Just commit and push to `main`:
```bash
git add .
git commit -m "Add new post"
git push origin main
```

GitHub Actions will automatically build and deploy your site using Hugo.

## Structure

```
.
├── .github/
│   └── workflows/
│       └── hugo.yml         # GitHub Actions workflow
├── content/
│   ├── posts/               # Blog posts go here
│   └── page/                # Static pages (about, etc.)
├── themes/
│   └── PaperModX/           # Theme (git submodule)
├── hugo.yaml                # Site configuration
└── README.md
```

## Theme Configuration

The PaperModX theme is added as a git submodule. To update it:
```bash
git submodule update --remote themes/PaperModX
```

## Customization

Edit `hugo.yaml` to customize:
- Site title and description
- Social links
- Menu items
- Theme settings

See [PaperModX documentation](https://github.com/reorx/hugo-PaperModX) for more theme options.
