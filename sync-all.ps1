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
  -Publish       Commit and push changes to the remote default branch. Omit for a local sync.
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
        if ($status -in $eligibleStatuses) {
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
    return [pscustomobject]@{ Status = $status; Changes = $changes }
}

$repositories = @(Find-Repositories $Root | Sort-Object)
if (!$repositories.Count) {
    Write-Output 'No project repositories found.'
    return
}

$results = foreach ($repo in $repositories) {
    $branch = ''
    $changes = @()
    try {
        if ($Publish) {
            $target = Get-PublishTarget $repo
            if (!$target) {
                $status = "Skipped (no $Remote remote)"
            } else {
                $branch = $target.Ref.Substring('refs/heads/'.Length)
                if ($PSCmdlet.ShouldProcess("$repo -> $Remote/$branch", "$syncAction, then commit and push")) {
                    $publication = Publish-Repository $repo $target
                    $status = $publication.Status
                    $changes = $publication.Changes
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
    [pscustomobject]@{ Repository = $repo; Branch = $branch; Status = $status; Changes = $changes }
}

foreach ($result in $results) {
    $label = $result.Repository
    if ($result.Branch) { $label += " -> $Remote/$($result.Branch)" }
    Write-Output "$($result.Status) | $label"
    foreach ($change in $result.Changes) { Write-Output "  $change" }
}
if ($results.Status -contains 'Failed') { exit 1 }
