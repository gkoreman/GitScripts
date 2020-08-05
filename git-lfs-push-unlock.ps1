[CmdletBinding()] # Fail on unknown args
param (
    [switch]$dryrun = $false,
    [switch]$help = $false,
    [Parameter(Position=0)]
    $remote,
    [Parameter(ValueFromRemainingArguments)]
    $refs
)

function Print-Usage {
    Write-Output "Git LFS push-unlock"
    Write-Output "   Push a branch to a remote, and unlock any files which you pushed (that aren't modified)"
    Write-Output "Usage:"
    Write-Output "  git-lfs-push-and-unlock.ps1 [options] <remote> [<ref>...]"
    Write-Output " "
    Write-Output "Options:"
    Write-Output " "
    Write-Output "  -dryrun      : Don't perform actions, just report what would happen"
    Write-Output "  -verbose     : Print more"
    Write-Output "  -help        : Print this help"

}

$ErrorActionPreference = "Stop"

if ($help) {
    Print-Usage
    Exit 0
}

if (-not $remote) {
    Write-Output " "
    Write-Output "  ERROR: Missing parameter: remote"
    Write-Output " "
    Print-Usage
    Exit 3
}

if (-not $refs) {
    # git lfs needs at least one ref, get current branch
    $refs = git branch --show-current
}


Write-Output "Checking for what we'd push..."

$gitallopt = ""
if ($all) {
    $gitallopt = "--all"
}

# git lfs push in dry run mode will tell us the list of objects
#$lfsPushOutput = git lfs push $gitallopt --dry-run origin master
$lfspushargs = "lfs", "push", $gitallopt, "--dry-run", $remote, $refs
$lfsPushOutput = Invoke-Expression "git $lfspushargs"

# Result format is of the form
# push f4ee401c063058a78842bb3ed98088e983c32aa447f346db54fa76f844a7e85e => Path/To/File
# With some potential informationals we can ignore

$filesbeingpushed = [System.Collections.ArrayList]@()
foreach ($line in $lfsPushOutput) {
    if ($line -match "^push ([a-f0-9]+)\s+=>\s+(.+)$") {
        $oid = $matches[1]
        $filename = $matches[2]
        $filesbeingpushed.Add($filename) > $null
    }
}

# Wrap in @() to avoid collapsing to a single string when only 1 file
$filesbeingpushed = @($filesbeingpushed | Select-Object -Unique)
if ($verbose -or $dryrun) {
    Write-Output ("Files being pushed: `n    " + ($filesbeingpushed -join "`n    "))
}

# Get the list of locked files so we don't try to unlock things we don't own
# That's an error for git-lfs
# Would be nice to use --local for speed, but this actually shows any files which
# are read/write and lockable. It doesn't mean they're actually locked, and
# getting it wrong makes the command fail. So we have to call the server
# This will also report locks from other users, so we want the intersection
# server should complain if we try to unlock someone else's lock
$lfsLocksOutput = git lfs locks
$lockedfiles = [System.Collections.ArrayList]@()
# Output is of the form
# Path/To/File\tsteve\tID:268
foreach ($line in $lfsLocksOutput) {
    # Need to use explicit tab to ensure support for whitespace in filenames
    if ($line -match "^(.*)\t(.*)\s+ID:(\d+)$") {
        $filename = $matches[1]
        $name = $matches[2]
        $id = $matches[3]
        $lockedfiles.Add($filename) > $null
    }
}
if ($verbose -or $dryrun) {
    Write-Output ("Files currently locked: `n    " + ($lockedfiles -join "`n    "))
}

# Take the intersection of locked and pushed, that's unlock baby
# Wrap in @() to avoid collapsing to a single string when only 1 file
$filesToUnlock = @($lockedfiles | Where-Object {$filesbeingpushed -contains $_})
if ($verbose -or $dryrun) {
    Write-Output ("Files to unlock: `n    " + ($filesToUnlock -join "`n    "))
}

# Push first
$gitpushargs = "push", $gitallopt, $remote, $refs
if ($verbose -or $dryrun) {
    Write-Output ("Run 'git $gitpushargs'")
}
if (-not $dryrun) {
    $ErrorActionPreference = "Continue"
    $pushOutput = Invoke-Expression "git $gitpushargs"

    if (!$?) {        
        Write-Output "ERROR: Push failed"

        if (($pushOutput -contains "[rejected]") -and ($pushOutput -contains "[rejected]")) {
            Write-Output "   You need to pull changes from remote branch first."
        }
        Exit 5
    }

    $ErrorActionPreference = "Stop"
}

# Unlock these files
$startFileIdx = 0
$fileCount = $filesToUnlock.Count
while ($fileCount -gt 0) {
    $batchCount = $fileCount
    $fileargs = ($filesToUnlock[$startFileIdx..($startFileIdx + $batchCount - 1)] -join " ")
    
    # Careful about command line length getting too long
    while ($fileargs.Length -gt 2000) {
        # Split args
        $batchCount = $batchCount / 2
        $fileargs = ($filesToUnlock[$startFileIdx..($startFileIdx + $batchCount - 1)] -join " ")
    }

    if ($verbose -or $dryrun) {
        Write-Output ("Run 'git lfs unlock $fileargs")
    }
    if (-not $dryrun) {
        Invoke-Expression "git lfs unlock $fileargs"
    }

    $startFileIdx += $batchCount
    $fileCount -= $batchCount

}

Write-Output "DONE: Push and unlock completed successfully"