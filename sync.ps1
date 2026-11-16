#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $TargetRepo = '.',
    [switch] $Claude
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$beginMarker = '<!-- agents-baseline:begin -->'
$endMarker = '<!-- agents-baseline:end -->'
$ownerMarker = '.agents-baseline'
$licenseName = 'PSTACK-LICENSE'

function Get-PlainItem([string] $Path) {
    try {
        $item = Get-Item -LiteralPath $Path -Force
    } catch [System.Management.Automation.ItemNotFoundException] {
        return
    }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Symbolic links and junctions are not supported here. Path $Path"
    }
    return $item
}

function Get-BaselineRange([string] $Text, [string] $Path) {
    # Treat a UTF-8 BOM as part of the prefix and accept either line ending.
    $start = [regex]::Matches($Text, "(?m)^(?:\xEF\xBB\xBF)?$([regex]::Escape($beginMarker))(?=\r?$)")
    $end = [regex]::Matches($Text, "(?m)^$([regex]::Escape($endMarker))(?=\r?$)")
    if ($start.Count -ne 1 -or $end.Count -ne 1 -or $start[0].Index -ge $end[0].Index) {
        throw "$Path needs exactly one ordered pair of baseline markers. See README.md for the one-time migration."
    }
    $first = $start[0].Index + $start[0].Length - $beginMarker.Length
    $last = $end[0].Index + $end[0].Length
    return @{ Start = $first; End = $last }
}

function Get-SkillTree([string] $Path) {
    # Check each entry before descending into a directory.
    $tree = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $directories = [Collections.Generic.Stack[string]]::new()
    $directories.Push($Path)
    while ($directories.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath ($directories.Pop()) -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Skill contains a symbolic link or junction. Path $($item.FullName)"
            }
            $relative = [IO.Path]::GetRelativePath($Path, $item.FullName)
            if ($item.PSIsContainer) {
                $tree.Add($relative, 'directory')
                $directories.Push($item.FullName)
            } else {
                $tree.Add($relative, (Get-FileHash -LiteralPath $item.FullName).Hash)
            }
        }
    }
    return ,$tree
}

function Test-SameTree($Source, $Target) {
    if ($Source.Count -ne $Target.Count) { return $false }
    foreach ($path in $Source.Keys) {
        if (!$Target.ContainsKey($path) -or $Source[$path] -cne $Target[$path]) {
            return $false
        }
    }
    return $true
}

$sourceRoot = (Get-Item -LiteralPath $PSScriptRoot).FullName
$targetRoot = git -C $TargetRepo rev-parse --path-format=absolute --show-toplevel
if ($LASTEXITCODE -ne 0) { throw 'Choose a Git working tree.' }
$targetRoot = (Get-Item -LiteralPath $targetRoot).FullName
if ([IO.Path]::GetRelativePath($sourceRoot, $targetRoot) -eq '.') {
    throw 'Choose a project repository other than the baseline source.'
}

$sourceInstructions = Join-Path $sourceRoot 'AGENTS.md'
$targetInstructions = Join-Path $targetRoot 'AGENTS.md'
$skillRoot = Join-Path $sourceRoot 'skills'
$license = Join-Path $skillRoot 'LICENSE'
$locations = @('.agents/skills')
if ($Claude) { $locations += '.claude/skills' }

# Latin-1 gives a one-to-one mapping from bytes to characters. Only the managed block is replaced.
$encoding = [Text.Encoding]::Latin1
$sourceText = $encoding.GetString([IO.File]::ReadAllBytes($sourceInstructions))
$sourceRange = Get-BaselineRange $sourceText $sourceInstructions
$sourceBlock = $sourceText.Substring($sourceRange.Start, $sourceRange.End - $sourceRange.Start)
$licenseText = [IO.File]::ReadAllText($license).Replace("`r`n", "`n")
$skills = @(Get-ChildItem -LiteralPath $skillRoot -Directory | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf
})
if ($skills.Count -eq 0) { throw 'No source skills found.' }
foreach ($skill in $skills) {
    $null = Get-PlainItem $skill.FullName
}

$lockPath = Join-Path $targetRoot '.agents-baseline-sync.lock'
try {
    $null = New-Item -Path $lockPath -ItemType Directory
} catch {
    throw "Cannot acquire sync lock at $lockPath. Check for a running sync or a stale empty lock directory."
}

$stage = $null
$pendingDestination = $null
try {
    $targetItem = Get-PlainItem $targetInstructions
    $newText = $sourceText
    $targetText = $null
    if ($targetItem) {
        if ($targetItem.PSIsContainer) { throw 'AGENTS.md is not a regular file.' }
        $targetText = $encoding.GetString([IO.File]::ReadAllBytes($targetInstructions))
        $targetRange = Get-BaselineRange $targetText $targetInstructions
        $afterBegin = $targetRange.Start + $beginMarker.Length
        $lineEnding = if ($targetText[$afterBegin] -eq "`r") { "`r`n" } else { "`n" }
        $block = $sourceBlock.Replace("`r`n", "`n").Replace("`n", $lineEnding)
        $newText = $targetText.Substring(0, $targetRange.Start) + $block + $targetText.Substring($targetRange.End)
    }

    # Preflight every destination before writing instructions or skills.
    $existingTrees = @{}
    foreach ($location in $locations) {
        $skillTarget = Join-Path $targetRoot $location
        foreach ($path in @((Split-Path -Parent $skillTarget), $skillTarget)) {
            $item = Get-PlainItem $path
            if ($item -and !$item.PSIsContainer) { throw "Expected a directory. Path $path" }
        }
        $notice = Get-PlainItem (Join-Path $skillTarget $licenseName)
        if ($notice -and ($notice.PSIsContainer -or
            [IO.File]::ReadAllText($notice.FullName).Replace("`r`n", "`n") -cne $licenseText)) {
            throw "Existing license differs. Path $($notice.FullName)"
        }

        foreach ($skill in $skills) {
            $destination = Join-Path $skillTarget $skill.Name
            $item = Get-PlainItem $destination
            if (!$item) { continue }
            if (!$item.PSIsContainer) { throw "Expected a skill directory. Path $destination" }
            $owner = Get-PlainItem (Join-Path $destination $ownerMarker)
            if (!$owner -or $owner.PSIsContainer -or
                'agents-baseline' -cnotin [IO.File]::ReadAllLines($owner.FullName)) {
                throw "Existing skill is project-owned. Path $destination"
            }
            $existingTrees[$destination] = Get-SkillTree $destination
        }
    }

    $stage = Join-Path $targetRoot ".agents-baseline-sync.$([guid]::NewGuid())"
    $null = [IO.Directory]::CreateDirectory($stage)
    $stagedInstructions = Join-Path $stage 'AGENTS.md'
    [IO.File]::WriteAllBytes($stagedInstructions, $encoding.GetBytes($newText))

    $stagedTrees = @{}
    foreach ($skill in $skills) {
        $null = Get-SkillTree $skill.FullName
        $stagedSkill = Join-Path $stage $skill.Name
        Copy-Item -LiteralPath $skill.FullName -Destination $stagedSkill -Recurse -Force
        [IO.File]::WriteAllText((Join-Path $stagedSkill $ownerMarker), "agents-baseline`n")
        $stagedTrees[$skill.Name] = Get-SkillTree $stagedSkill
    }

    $next = Join-Path $stage 'next'
    $previous = Join-Path $stage 'previous'
    foreach ($location in $locations) {
        $skillTarget = Join-Path $targetRoot $location
        $null = [IO.Directory]::CreateDirectory($skillTarget)
        $noticePath = Join-Path $skillTarget $licenseName
        if (![IO.File]::Exists($noticePath)) {
            $stagedNotice = Join-Path $stage $licenseName
            [IO.File]::Copy($license, $stagedNotice)
            [IO.File]::Move($stagedNotice, $noticePath)
        }

        foreach ($skill in $skills) {
            $destination = Join-Path $skillTarget $skill.Name
            $existing = $existingTrees.ContainsKey($destination)
            if ($existing -and (Test-SameTree $stagedTrees[$skill.Name] $existingTrees[$destination])) {
                continue
            }
            Copy-Item -LiteralPath (Join-Path $stage $skill.Name) -Destination $next -Recurse -Force
            if ($existing) {
                $pendingDestination = $destination
                [IO.Directory]::Move($destination, $previous)
            }
            [IO.Directory]::Move($next, $destination)
            $pendingDestination = $null
            if ($existing) {
                Remove-Item -LiteralPath $previous -Recurse -Force
                Write-Output "Updated $location/$($skill.Name)"
            } else {
                Write-Output "Installed $location/$($skill.Name)"
            }
        }
    }

    if ($newText -cne $targetText) {
        [IO.File]::Move($stagedInstructions, $targetInstructions, $true)
        Write-Output 'Synced AGENTS.md'
    }
    Write-Output 'Baseline sync complete.'
} finally {
    try {
        if ($pendingDestination -and [IO.Directory]::Exists($previous)) {
            [IO.Directory]::Move($previous, $pendingDestination)
        }
        if ($stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    } finally {
        [IO.Directory]::Delete($lockPath)
    }
}
