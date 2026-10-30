# Shared Agent Instructions

This `AGENTS.md` provides common development guidelines for AI coding agents across repositories. Follow the current repository's specific instructions and the user's explicit requests when they refine or override this baseline.

## 1. Working Principles

- Prefer simple, maintainable, reliable solutions over unnecessary complexity.
- Respect the existing architecture, technology stack, conventions, and intended platforms.
- Keep changes focused; avoid unrelated refactoring, premature abstractions, and needless dependencies.
- Make routine implementation decisions autonomously. Consult the user for material changes to requirements, architecture, behavior, or deployment.
- Do not impose a framework, Docker, or a packaging/deployment model unless the repository calls for it.

## 2. Code Quality and Security

- Write clear, consistent code with meaningful names and focused functions.
- Keep business logic separate from presentation code when useful, without forcing extra layers.
- Follow existing formatting, typing, and linting conventions where applicable.
- Comment non-obvious decisions or logic, rather than narrating obvious code.
- Handle relevant errors and edge cases; preserve compatibility with supported environments.
- Prefer existing dependencies and built-in functionality when practical; update dependency declarations when needed.
- Never hardcode, commit, disclose, or transfer passwords, tokens, credentials, or private signing keys.

## 3. Proportionate Validation

- Validate changes according to their scope, dependencies, and risk.
- For UI-only changes, prioritize relevant interactions and visual rendering when tools permit.
- For backend changes, prioritize the modified logic and directly affected integrations.
- Add or update automated tests when they materially help verify behavior; do not require unit tests for every feature.
- Do not run a full application-wide test suite for every small edit unless the change, project rules, or risk warrants it.
- Before a release or distributable build, follow any project-specific build, packaging, and validation requirements.
- Never report a test, build, or visual check as successful unless it was actually performed. Explain relevant limits.

## 4. Branches and Pull/Merge Requests

- Never make development commits directly on the repository's default branch (`main`, `master`, or equivalent).
- Work on dedicated branches organized by coherent workstreams, not by individual prompts or minor changes.
- Continue on the current branch for related features, refinements, and fixes, even across multiple sessions.
- Do not automatically create a branch or PR/MR at the end of every task.
- When a request introduces a substantially different workstream, propose separating it into a new branch before starting unrelated changes.
- If the current workstream is ready for integration, prepare a PR/MR for the user's review as part of that transition. If it is not ready, discuss how to proceed instead of opening a premature PR/MR.
- Prefer starting the next workstream from the updated default branch once the previous PR/MR has been merged, unless the user wants parallel development.
- Never merge a PR/MR or enable auto-merge without explicit user authorization.
- Never force-push, rewrite shared history, or discard unrelated changes without authorization.
- Respect existing branch protection and repository rules.

## 5. Commits and Attribution

- Commit at meaningful development milestones, grouping logically related changes together.
- Do not make a commit per file, per trivial adjustment, or automatically after every agent response.
- Avoid both excessive micro-commits and large commits that mix unrelated changes.
- Use clear, concise commit messages; prefer Conventional Commit prefixes where useful (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Preserve the Git author and committer identity configured in the environment; do not impersonate the repository owner.
- For commits genuinely assisted by Codex, include this trailer **once**, separated from the message body by a blank line:

  `Co-authored-by: Codex <noreply@openai.com>`

- Preserve other legitimate co-author attributions and avoid duplicate trailers.
- Use the environment's existing Git commit-signing configuration when available. Do not disable it merely to work around a signing error.
- Never export or upload private signing keys to a cloud environment. When signing is unavailable, clearly report that commits are unsigned; do not claim `Verified` status.

## 6. Versioning and Releases

- Use Semantic Versioning (SemVer) for project releases, with Git tags named `vMAJOR.MINOR.PATCH`.
- Development does not need a release from the start. Prefer `v0.1.0` for the first usable version that meaningfully fulfills the project's initial purpose.
- Continue normal development through as many commits, tasks, and PRs/MRs as appropriate between releases.
- Do not create a version bump, tag, or release just because a task or PR/MR was completed.
- After `v1.0.0`, use PATCH for compatible fixes, MINOR for compatible new functionality, and MAJOR for breaking changes to the project's supported public behavior or interfaces. In `0.x`, treat versions as pre-stable and adjust increments to the project's maturity and impact.
- Either the user or the agent may initiate a release discussion. Periodically consider whether the changes since the latest release justify a new publication, especially at significant milestones.
- When proposing a release, inspect the changes since the latest release tag and explain the suggested version number, meaningful features/fixes, readiness, validation needs, and any required artifacts. It is also acceptable to recommend waiting.
- Always obtain explicit user approval before creating release tags, publishing releases, building or distributing release artifacts, or changing a published version.
- Once approved, follow repository-specific release checks and procedures. Keep published version tags stable and traceable to the released commit.
- Publish concise release notes with each release on the hosting platform (GitHub/GitLab). Do not require a separate `CHANGELOG.md` unless the repository specifically benefits from one.

## 7. Documentation

- Keep documentation short, accurate, and useful.
- Update the README and related instructions when changes affect users, installation, configuration, or operation.
- Record important assumptions, non-obvious behavior, and known limitations.
- Do not create unnecessary documentation files.

## 8. Reporting and Hand-off

- Briefly summarize changes made, relevant validations actually performed, and any known issues or unfinished work.
- State the current working branch and PR/MR status when relevant.
- Point out meaningful next decisions, including a potential release when warranted, without turning every task completion into a PR/MR or release request.

## 9. Repository-Specific Extension

This baseline is intentionally technology-agnostic. Add project-specific instructions for architecture, supported platforms, commands, tests, build and deployment processes, and any exceptions or additional constraints. Preserve the common principles where possible without copying irrelevant rules into a project.
