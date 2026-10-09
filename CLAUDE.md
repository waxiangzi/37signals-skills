# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository packages 37signals' Rails patterns in two forms:

- `skills/` - Installable agent skills (one folder per skill, each containing a `SKILL.md` with YAML frontmatter). These are the primary deliverable.
- `guide/` - Long-form markdown reference extracted from analyzing 37signals' Fizzy and Campfire codebases and their pull requests.

This fork also carries skills that are not 37signals material (see the "Added in this fork" table in `README.md`): `rails-conventions` (original), and `ruby` plus six `hwc-*` skills vendored from superpowers-ruby. Their licenses live in `THIRD_PARTY_NOTICES.md`.

There is no application code, build system, or tests.

## Structure

- `README.md` - Main entry point: skill catalog, installation instructions, guide table of contents
- `skills/<name>/SKILL.md` - Agent skills; frontmatter has `name`, `description`, and optionally `disable-model-invocation`. Some skills also carry sibling files (`references/`, `BACKEND-SKILLS.md`, a template); `SKILL.md` points to them.
- `guide/*.md` - Topic reference files (e.g. `guide/controllers.md`, `guide/models.md`)
- `THIRD_PARTY_NOTICES.md` - Upstream license texts for vendored skills

## Vendored skills

Do not hand-edit `ruby` or `hwc-*`: they are copies. To change one, change it upstream or note the divergence here.

Divergences from upstream (re-apply after re-syncing):

- Each `hwc-*` `description` ends before the sentence "Use hwc-X for ..., hwc-Y for ...". That sentence listed the five sibling skills, and the same list is already in each body under `## Escalate to Neighbor Skills`. A description is loaded into every conversation while the body loads only on use, so the copy in the description cost about 535 tokens per turn across the six skills for no extra routing. Bodies are untouched. Skills that reference each other do so by sibling path (`../<name>/SKILL.md`), so keep skill folders flat under `skills/`.

## Content Guidelines

When editing or adding content:
- Focus on transferable patterns, not Fizzy-specific business logic
- Keep skills terse and rule-based; they are loaded into agent context, so every line must earn its place
- When a pattern is added to a skill, check whether the corresponding `guide/` topic file needs it too (and vice versa)
- Include code examples licensed under the O'Saasy License
- Link PR references to actual GitHub PRs when available
- Maintain the existing markdown structure and style
