#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Sync')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Sync')]
    [string[]] $Root,
    [Parameter(ParameterSetName = 'Sync')]
    [switch] $Publish,
    [Parameter(ParameterSetName = 'Sync')]
    [switch] $ForceInstall,
    [Parameter(ParameterSetName = 'Sync')]
    [switch] $Claude,
    [Parameter(ParameterSetName = 'Sync')]
    [ValidateNotNullOrEmpty()]
    [string] $Remote = 'origin',
    [Parameter(Mandatory, ParameterSetName = 'Help')]
    [Alias('h')]
    [switch] $Help
)

if ($PSCmdlet.ParameterSetName -eq 'Help') {
    Write-Output @'
Sync the shared agent baseline across Git repositories.

Usage
  .\sync-all.ps1 -Root <path[]> [-Publish] [-ForceInstall] [-Remote <name>] [-Claude] [-WhatIf]
  .\sync-all.ps1 -Help

  -Root          One or more repository or parent paths. Parent paths are scanned recursively.
  -Publish       Commit and push changes to the remote default branch, then pull into an
                 eligible local checkout. Omit for a local sync.
  -ForceInstall  Also install the baseline in repositories with no AGENTS.md.
                 Existing unmarked files still require migration.
  -Remote        Remote to use with -Publish. Defaults to origin.
  -Claude        Also install or update the Claude Code copy of the shared skills.
  -WhatIf        Preview the targets. With -Publish, query the remote without fetching or writing.
  -Help, -h      Show this overview.

Examples
  .\sync-all.ps1 -Root '..\save-web-int' -Publish -WhatIf
  .\sync-all.ps1 -Root "$HOME\Code" -Publish
  .\sync-all.ps1 -Root "$HOME\Code\GitHub" -ForceInstall -Publish
  .\sync-all.ps1 -Root @('C:\Code\GitHub', 'C:\Code\GitLab') -Claude
'@
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$sourceRepo = (Get-Item -LiteralPath $PSScriptRoot).FullName
$syncScript = Join-Path $sourceRepo 'sync.ps1'
$git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$comparison = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$eligibleStatuses = @('Managed')
if ($ForceInstall) { $eligibleStatuses += 'Not installed' }
$syncAction = if ($ForceInstall) { 'Install or sync guidelines' } else { 'Sync managed guidelines' }

function Invoke-RepoGit([string] $Repo, [string[]] $Arguments) {
    $output = & $git -C $Repo @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments[0]) failed (exit $LASTEXITCODE). $($output -join ' ')"
    }
    $output | Where-Object { $_ -is [string] }
}

function Find-Repositories([string[]] $Roots) {
    $directories = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $visited = [Collections.Generic.HashSet[string]]::new($comparison)
    foreach ($path in $Roots) {
        $item = Get-Item -LiteralPath $path
        if (!$item.PSIsContainer) { throw "Expected a directory. Path $path" }
        $directories.Push($item)
    }

    while ($directories.Count -gt 0) {
        $directory = $directories.Pop()
        if (!$visited.Add($directory.FullName) -or
            ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $comparison.Equals($directory.FullName, $sourceRepo)) {
            continue
        }

        $gitPath = Join-Path $directory.FullName '.git'
        if (Test-Path -LiteralPath $gitPath -PathType Container) {
            $directory.FullName
        } elseif (!(Test-Path -LiteralPath $gitPath)) {
            # Linked worktrees and submodules have a .git file.
            foreach ($child in Get-ChildItem -LiteralPath $directory.FullName -Directory -Force) {
                $directories.Push($child)
            }
        }
    }
}

function Get-InstallStatus([string] $Repo) {
    $instructions = Join-Path $Repo 'AGENTS.md'
    if (!(Test-Path -LiteralPath $instructions -PathType Leaf)) {
        return 'Not installed'
    }

    $text = [IO.File]::ReadAllText($instructions)
    if ($text -cnotmatch '(?m)^<!-- agents-baseline:begin -->\r?$' -or
        $text -cnotmatch '(?m)^<!-- agents-baseline:end -->\r?$') {
        return 'Needs migration'
    }

    return 'Managed'
}

function Get-PublishTarget([string] $Repo) {
    $names = @(Invoke-RepoGit $Repo @('remote'))
    if ($Remote -cnotin $names) { return }
    $urls = @(Invoke-RepoGit $Repo @('remote', 'get-url', '--push', '--all', '--', $Remote))
    if ($urls.Count -ne 1) { throw "Remote $Remote must have one push destination." }

    # Resolve HEAD on the actual push destination, including when pushurl is set.
    $head = @(Invoke-RepoGit $Repo @('ls-remote', '--symref', '--', $urls[0], 'HEAD')) -join "`n"
    $ref = [regex]::Match($head, '(?m)^ref: (refs/heads/[^\r\n\t]+)\tHEAD$')
    $tip = [regex]::Match($head, '(?m)^([0-9a-f]{40}|[0-9a-f]{64})\tHEAD$')
    if (!$ref.Success -or !$tip.Success) {
        throw "Could not resolve the default branch on remote $Remote."
    }

    return @{ Ref = $ref.Groups[1].Value; Tip = $tip.Groups[1].Value; Url = $urls[0] }
}

function Publish-Repository([string] $Repo, [hashtable] $Target) {
    # A detached worktree isolates the sync from the user's branch and index.
    $worktree = Join-Path ([IO.Path]::GetTempPath()) "agents-baseline-$([guid]::NewGuid())"
    $null = Invoke-RepoGit $Repo @('fetch', '--no-tags', '--no-write-fetch-head', '--', $Target.Url, $Target.Tip)
    $null = Invoke-RepoGit $Repo @('worktree', 'add', '--detach', '--', $worktree, $Target.Tip)

    $changes = @()
    try {
        $status = Get-InstallStatus $worktree
        $canPull = $status -in $eligibleStatuses
        if ($canPull) {
            $null = & $syncScript -TargetRepo $worktree -Claude:$Claude
            $paths = @('AGENTS.md', '.agents/skills')
            if ($Claude) { $paths += '.claude/skills' }
            $null = Invoke-RepoGit $worktree (@('add', '-A', '--') + $paths)

            $changes = @(Invoke-RepoGit $worktree @('diff', '--cached', '--name-status'))
            if ($changes.Count -eq 0) {
                $status = 'Already up to date'
            } else {
                $tree = Invoke-RepoGit $worktree @('write-tree')
                $null = Invoke-RepoGit $worktree @('commit', '-m', 'chore: sync agent baseline')
                $commit = Invoke-RepoGit $worktree @('rev-parse', 'HEAD')
                $parent = Invoke-RepoGit $worktree @('rev-parse', 'HEAD^')
                $committedTree = Invoke-RepoGit $worktree @('rev-parse', 'HEAD^{tree}')
                if ($parent -cne $Target.Tip -or $committedTree -cne $tree) {
                    throw 'The resulting commit differs from the staged sync.'
                }

                $null = Invoke-RepoGit $Repo @(
                    '-c', 'push.followTags=false', '-c', "remote.$Remote.mirror=false",
                    'push', '--porcelain', '--recurse-submodules=no', '--',
                    $Remote, "${commit}:$($Target.Ref)"
                )
                $status = "Published $commit"
            }
        }
    } catch {
        throw "$($_.Exception.Message) Worktree retained at $worktree."
    }

    $null = Invoke-RepoGit $Repo @('worktree', 'remove', '--', $worktree)
    return [pscustomobject]@{ Status = $status; Changes = $changes; CanPull = $canPull }
}

function Update-LocalCheckout([string] $Repo, [string] $Branch, [hashtable] $Target) {
    $currentBranch = Invoke-RepoGit $Repo @('branch', '--show-current')
    if ($currentBranch -cne $Branch) {
        return "Pull skipped (local checkout is not on $Branch)"
    }

    $upstream = Invoke-RepoGit $Repo @(
        'for-each-ref', '--format=%(upstream:remotename)%09%(upstream:remoteref)%09%(upstream)', $Target.Ref
    )
    $upstreamRemote, $upstreamBranch, $trackingRef = $upstream -csplit "`t"
    $fetchUrl = Invoke-RepoGit $Repo @('remote', 'get-url', '--', $Remote)
    if ($upstreamRemote -cne $Remote -or $upstreamBranch -cne $Target.Ref -or
        $trackingRef -cnotlike 'refs/remotes/*' -or $fetchUrl -cne $Target.Url) {
        return "Pull skipped (upstream does not match the push destination)"
    }

    $operationPaths = Invoke-RepoGit $Repo @(
        'rev-parse', '--path-format=absolute', '--git-path', 'MERGE_HEAD', '--git-path', 'CHERRY_PICK_HEAD',
        '--git-path', 'REVERT_HEAD', '--git-path', 'sequencer', '--git-path', 'rebase-merge',
        '--git-path', 'rebase-apply', '--git-path', 'BISECT_START'
    )
    foreach ($path in $operationPaths) {
        if (Test-Path -LiteralPath $path) {
            return 'Pull skipped (a Git operation is in progress)'
        }
    }

    $dirty = @(Invoke-RepoGit $Repo @('status', '--porcelain', '--untracked-files=normal', '--ignore-submodules=none'))
    if ($dirty.Count) { return 'Pull skipped (local checkout has changes)' }

    # Use the two steps of a pull so Git can refuse to overwrite ignored files.
    $null = Invoke-RepoGit $Repo @(
        'fetch', '--no-tags', '--no-recurse-submodules', '--no-write-fetch-head', '--refmap=',
        '--', $Remote, "+$($Target.Ref):$trackingRef"
    )
    if ((Invoke-RepoGit $Repo @('branch', '--show-current')) -cne $Branch) {
        return "Pull skipped (local checkout switched away from $Branch)"
    }

    $before = Invoke-RepoGit $Repo @('rev-parse', 'HEAD')
    $null = Invoke-RepoGit $Repo @('merge', '--ff-only', '--no-autostash', '--no-squash', '--no-overwrite-ignore', '--', $trackingRef)
    $after = Invoke-RepoGit $Repo @('rev-parse', 'HEAD')
    if ($before -ceq $after) { return 'Local checkout already up to date' }
    return "Pulled $Branch to $after"
}

$repositories = @(Find-Repositories $Root | Sort-Object)
if (!$repositories.Count) {
    Write-Output 'No project repositories found.'
    return
}

$results = foreach ($repo in $repositories) {
    $branch = ''
    $changes = @()
    $pull = ''
    $pullFailed = $false
    try {
        if ($Publish) {
            $target = Get-PublishTarget $repo
            if (!$target) {
                $status = "Skipped (no $Remote remote)"
            } else {
                $branch = $target.Ref.Substring('refs/heads/'.Length)
                if ($PSCmdlet.ShouldProcess("$repo -> $Remote/$branch", "$syncAction, then commit and push, then pull if eligible")) {
                    $publication = Publish-Repository $repo $target
                    $status = $publication.Status
                    $changes = $publication.Changes
                    if ($publication.CanPull) {
                        try {
                            $pull = Update-LocalCheckout $repo $branch $target
                        } catch {
                            $pullFailed = $true
                            $pull = 'Pull failed'
                            Write-Warning "$repo - Local pull failed. $($_.Exception.Message)"
                        }
                    }
                } else {
                    $status = 'Preview'
                }
            }
        } else {
            $status = Get-InstallStatus $repo
            if ($status -in $eligibleStatuses) {
                if ($PSCmdlet.ShouldProcess($repo, "$syncAction in the local checkout")) {
                    & $syncScript -TargetRepo $repo -Claude:$Claude | Out-Host
                    $status = 'Synced locally'
                } else {
                    $status = 'Preview'
                }
            }
        }
    } catch {
        $status = 'Failed'
        Write-Warning "$repo - $($_.Exception.Message)"
    }
    [pscustomobject]@{
        Repository = $repo
        Branch = $branch
        Status = $status
        Changes = $changes
        Pull = $pull
        PullFailed = $pullFailed
    }
}

foreach ($result in $results) {
    $label = $result.Repository
    if ($result.Branch) { $label += " -> $Remote/$($result.Branch)" }
    Write-Output "$($result.Status) | $label"
    foreach ($change in $result.Changes) { Write-Output "  $change" }
    if ($result.Pull) { Write-Output "  $($result.Pull)" }
}
if ($results.Status -contains 'Failed' -or $results.PullFailed -contains $true) { exit 1 }
