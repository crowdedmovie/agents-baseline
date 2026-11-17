# agents-baseline

Shared development guidelines and skills for AI coding agents on personal software projects. [AGENTS.md](AGENTS.md) defines the common rules. [skills/](skills/) holds workflows to use when the task calls for them.

## Install or update a project

Run the script from a checkout of this repository. Both scripts use Git to locate the target working tree.

On Windows, use PowerShell 7 (`pwsh`) with Git for Windows on PATH.

```powershell
pwsh -NoProfile -File .\sync.ps1 "C:\Projects\my-project"
pwsh -NoProfile -File .\sync.ps1 -Claude "C:\Projects\my-project"
```

If `pwsh` is missing, install PowerShell 7 with `winget install --id Microsoft.PowerShell --exact` and open a new terminal.

In Bash, run:

```sh
./sync.sh /path/to/project
./sync.sh --claude /path/to/project
```

The default skill destination is `.agents/skills/` for Codex and OpenCode. Use `-Claude` in PowerShell or `--claude` in Bash to also write a copy to `.claude/skills/` for Claude Code. For Claude Code sessions that read only `CLAUDE.md`, add an `@AGENTS.md` import to that file to load the shared instructions. For T3 Code, start the thread in the working tree where you ran the sync and select the runtime you want to use. Use the skill selector when available, or ask the agent to follow the installed `SKILL.md` by name and path.

The script creates `AGENTS.md` for a new project. On updates it replaces the block between `<!-- agents-baseline:begin -->` and `<!-- agents-baseline:end -->`. It preserves content outside the block, including the repository-specific section. For an older unmarked file, first mark the shared portion with those exact comments on their own lines. If the old file is entirely project-specific, add an empty marked block above it.

The script installs or refreshes the shared skill folders it owns. Keep project-specific skills in their own folders. An existing folder with the same name and without the ownership marker stops the sync before it writes. Retired skills can be removed by hand after review.

Fetch the latest intended baseline revision before syncing. Review the target's diff, then commit the update there.

## Sync multiple projects on Windows

Run `.\sync-all.ps1 -Help` or `.\sync-all.ps1 -h` for a quick parameter reference.

Pull the baseline revision you want to distribute, then run:

```powershell
pwsh -NoProfile -File .\sync-all.ps1 -Root "$HOME\Code" -Publish -WhatIf
pwsh -NoProfile -File .\sync-all.ps1 -Root "$HOME\Code" -Publish
```

`-Root` accepts a repository or a parent directory. Pass multiple roots as an array from PowerShell. The scan stops at each checkout and skips linked worktrees, submodules, directory links, and the source checkout of `agents-baseline`.

With `-Publish`, the script looks up the default branch on the push destination of `origin` (or `-Remote`). It calls `sync.ps1` in a temporary worktree and commits and pushes the sync when there is a diff. Your active branch, index, and local edits stay in your own checkout. `-WhatIf` shows the proposed targets before fetching or writing. The summary lists the files included in each published commit, along with missing remotes or push failures. If publishing fails after creating a worktree, the warning gives its path for inspection.

Bulk sync updates repositories with a managed `AGENTS.md` by default. Use `-ForceInstall` to include repositories with no `AGENTS.md`. Existing unmarked files are reported as `Needs migration`. Eligibility is checked on the remote branch with `-Publish` and in the local checkout otherwise. Both modes accept `-Claude` to add or refresh the Claude Code copy.

## Workflows

Use `project-setup` when starting a project or revisiting conventions such as the build, release process, feature map, or visual direction. Use `create-verification-skill` and `maintain-verification-skill` for project-local verification procedures based on real runs. Other workflows cover prompt refinement, code walkthroughs, architecture, bug fixes, regression tests, change impact, and recurring mistakes. See [opening a PR](skills/blast-radius/references/opening-a-pr.md) for the review hand-off.

Use [`clean-branches`](skills/clean-branches/SKILL.md) on demand to audit or remove obsolete **local** branches in the current repository. It deletes only branches whose upstream has disappeared and whose commits are already contained in the remote default branch, while preserving branches used by worktrees and ambiguous cases. It never runs automatically or deletes remote branches.

The adapted pstack material comes from Lauren Tan's pstack 0.15.36 and is distributed under the [MIT license](skills/LICENSE).
