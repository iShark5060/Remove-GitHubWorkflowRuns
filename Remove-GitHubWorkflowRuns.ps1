#Requires -Version 7.0

<#
.SYNOPSIS
    Deletes old GitHub Actions workflow runs from a repository.

.DESCRIPTION
    Fetches workflow runs via the GitHub CLI (`gh`) and deletes those older
    than a given number of days (or all runs). Supports sequential or
    parallel deletion, WhatIf, and rate-limit detection.

.PARAMETER Owner
    GitHub repository owner (user or organization).

.PARAMETER Repo
    GitHub repository name.

.PARAMETER Days
    Delete runs older than this many days. Ignored when -All is specified.
    Default: 7.

.PARAMETER All
    Delete every workflow run in the repository, regardless of age.

.PARAMETER Parallel
    Number of concurrent deletion jobs (2–10). Omit or use 0 for sequential.

.PARAMETER Force
    Skip the interactive confirmation prompt.

.EXAMPLE
    .\Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo

    Deletes workflow runs older than 7 days (default), with confirmation.

.EXAMPLE
    .\Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo -Days 30 -Force

    Deletes runs older than 30 days without prompting.

.EXAMPLE
    .\Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo -All -Parallel 5 -WhatIf

    Shows how many runs would be deleted (all of them), using 5 parallel jobs.

.NOTES
    Requires GitHub CLI (https://cli.github.com/) authenticated with a token
    that has permission to delete Actions workflow runs.
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Owner,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Repo,

    [ValidateRange(1, 36500)]
    [int] $Days = 7,

    [switch] $All,

    [ValidateRange(0, 10)]
    [int] $Parallel = 0,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

#region Helpers

function Test-GitHubCli {
    if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) {
        throw @'
GitHub CLI (gh) is not installed.
Install it from https://cli.github.com/
'@
    }

    & gh auth status 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'GitHub CLI is not authenticated. Run: gh auth login'
    }
}

function ConvertFrom-DeleteResponse {
    <#
    .SYNOPSIS
        Parses `gh api --method DELETE --include` output into a result object.
    #>
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Output,

        [Parameter(Mandatory)]
        [int] $ExitCode,

        [long] $RunId = 0
    )

    $text = $Output -join [Environment]::NewLine
    $statusCode = 0
    $remaining = $null
    $resetEpoch = $null
    $retryAfter = $null

    if ($text -match '(?im)^HTTP/\S+\s+(\d{3})') {
        $statusCode = [int] $Matches[1]
    }
    if ($text -match '(?im)^x-ratelimit-remaining:\s*(\d+)') {
        $remaining = [int] $Matches[1]
    }
    if ($text -match '(?im)^x-ratelimit-reset:\s*(\d+)') {
        $resetEpoch = [long] $Matches[1]
    }
    if ($text -match '(?im)^retry-after:\s*(\d+)') {
        $retryAfter = [int] $Matches[1]
    }

    $rateLimited = (
        $statusCode -in @(403, 429) -and
        (
            $remaining -eq 0 -or
            $null -ne $retryAfter -or
            $text -match '(?i)rate.?limit|secondary rate'
        )
    )

    $retryAt = $null
    if ($rateLimited) {
        if ($null -ne $retryAfter) {
            $retryAt = [DateTimeOffset]::Now.AddSeconds($retryAfter)
        }
        elseif ($null -ne $resetEpoch) {
            $retryAt = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).ToLocalTime()
        }
        else {
            $retryAt = [DateTimeOffset]::Now.AddMinutes(1)
        }
    }

    [pscustomobject]@{
        Id          = $RunId
        Success     = ($ExitCode -eq 0 -and $statusCode -eq 204)
        RateLimited = $rateLimited
        StatusCode  = $statusCode
        RetryAt     = $retryAt
        Output      = $text
    }
}

function Invoke-WorkflowRunDelete {
    param (
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [long] $RunId
    )

    $target = "repos/$Repository/actions/runs/$RunId"

    try {
        $output = @(
            & gh api $target --method DELETE --include 2>&1
        )
        ConvertFrom-DeleteResponse -Output $output -ExitCode $LASTEXITCODE -RunId $RunId
    }
    catch {
        [pscustomobject]@{
            Id          = $RunId
            Success     = $false
            RateLimited = $false
            StatusCode  = 0
            RetryAt     = $null
            Output      = $_.Exception.Message
        }
    }
}

function Get-WorkflowRunsToDelete {
    param (
        [Parameter(Mandatory)]
        [string] $Repository,

        [switch] $All,

        [DateTimeOffset] $CutoffUtc
    )

    $rawRuns = & gh api `
        "repos/$Repository/actions/runs" `
        --paginate `
        --jq '.workflow_runs[] | [.id, .created_at] | @tsv'

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to retrieve workflow runs for $Repository."
    }

    @(
        $rawRuns |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object {
                $parts = $_ -split "`t", 2
                [pscustomobject]@{
                    Id        = [long] $parts[0]
                    CreatedAt = [DateTimeOffset]::Parse($parts[1])
                }
            } |
            Where-Object { $All -or $_.CreatedAt -lt $CutoffUtc }
    )
}

function Update-DeletionProgress {
    param (
        [Parameter(Mandatory)]
        [int] $Completed,

        [Parameter(Mandatory)]
        [int] $Total,

        [Parameter(Mandatory)]
        [int] $Deleted,

        [Parameter(Mandatory)]
        [int] $Failed
    )

    $percent = if ($Total -gt 0) {
        [math]::Min(100, [int](($Completed / $Total) * 100))
    }
    else {
        0
    }

    Write-Progress `
        -Activity 'Deleting workflow runs' `
        -Status ('{0}/{1} completed · {2} deleted · {3} failed' -f $Completed, $Total, $Deleted, $Failed) `
        -PercentComplete $percent
}

#endregion Helpers

#region Validation

if ($Parallel -eq 1) {
    throw [System.ArgumentOutOfRangeException]::new(
        'Parallel',
        $Parallel,
        'Use 0 for sequential deletion, or 2–10 for parallel jobs.'
    )
}

Test-GitHubCli

#endregion Validation

#region Fetch

$repository = "$Owner/$Repo"
$cutoffUtc = $null

if ($All) {
    Write-Host "Fetching all workflow runs from $repository..."
}
else {
    $cutoffUtc = [DateTimeOffset]::UtcNow.AddDays(-$Days)
    Write-Host (
        "Fetching workflow runs older than {0} day(s) (before {1})..." -f
        $Days,
        $cutoffUtc.ToString('u')
    )
}

$getRunsParams = @{
    Repository = $repository
    All        = $All
}
if (-not $All) {
    $getRunsParams.CutoffUtc = $cutoffUtc
}

$runs = Get-WorkflowRunsToDelete @getRunsParams

if ($runs.Count -eq 0) {
    Write-Host 'No workflow runs found to delete.'
    exit 0
}

$total = $runs.Count
$selectionDescription = if ($All) {
    'all workflow runs'
}
else {
    "workflow runs older than $Days day(s)"
}

Write-Host "Found $total run(s): $selectionDescription."
Write-Host $(
    if ($Parallel -gt 0) {
        "Parallel deletion enabled ($Parallel jobs)."
    }
    else {
        'Deleting sequentially.'
    }
)

#endregion Fetch

#region Confirm

if (-not $Force) {
    $confirmation = Read-Host "Delete all $total selected run(s)? Type 'y' to confirm"
    if ($confirmation -notin @('y', 'Y')) {
        Write-Host 'Operation cancelled.'
        exit 0
    }
}

if ($WhatIfPreference) {
    Write-Host "WhatIf: $total workflow run(s) would be deleted."
    exit 0
}

#endregion Confirm

#region Delete

$failed = [System.Collections.Generic.List[object]]::new()
$deleted = 0
$completed = 0
$consecutiveFailures = 0
$rateLimitHit = $false
$rateLimitRetryAt = $null
$stopRequested = $false

if ($Parallel -eq 0) {
    foreach ($run in $runs) {
        $result = Invoke-WorkflowRunDelete -Repository $repository -RunId $run.Id
        $completed++

        if ($result.Success) {
            $deleted++
            $consecutiveFailures = 0
        }
        elseif ($result.RateLimited) {
            $rateLimitHit = $true
            $rateLimitRetryAt = $result.RetryAt
            $stopRequested = $true
            break
        }
        else {
            $failed.Add([pscustomobject]@{
                    Id     = $run.Id
                    Status = $result.StatusCode
                    Error  = $result.Output
                })
            $consecutiveFailures++

            if ($consecutiveFailures -ge 10) {
                Write-Warning 'Stopping after 10 consecutive deletion failures.'
                $stopRequested = $true
                break
            }
        }

        Update-DeletionProgress `
            -Completed $completed `
            -Total $total `
            -Deleted $deleted `
            -Failed $failed.Count
    }
}
else {
    # ForEach-Object -Parallel cannot call local functions; inline a compact
    # delete that mirrors ConvertFrom-DeleteResponse / Invoke-WorkflowRunDelete.
    # In-flight parallel jobs cannot be cancelled; stopRequested only skips
    # further result bookkeeping once a hard failure mode is detected.
    $runs | ForEach-Object -Parallel {
        $run = $_
        $target = "repos/$using:repository/actions/runs/$($run.Id)"

        try {
            $output = @(& gh api $target --method DELETE --include 2>&1)
            $exitCode = $LASTEXITCODE
            $text = $output -join [Environment]::NewLine
            $statusCode = 0
            $remaining = $null
            $resetEpoch = $null
            $retryAfter = $null

            if ($text -match '(?im)^HTTP/\S+\s+(\d{3})') { $statusCode = [int] $Matches[1] }
            if ($text -match '(?im)^x-ratelimit-remaining:\s*(\d+)') { $remaining = [int] $Matches[1] }
            if ($text -match '(?im)^x-ratelimit-reset:\s*(\d+)') { $resetEpoch = [long] $Matches[1] }
            if ($text -match '(?im)^retry-after:\s*(\d+)') { $retryAfter = [int] $Matches[1] }

            $rateLimited = (
                $statusCode -in @(403, 429) -and
                (
                    $remaining -eq 0 -or
                    $null -ne $retryAfter -or
                    $text -match '(?i)rate.?limit|secondary rate'
                )
            )

            $retryAt = $null
            if ($rateLimited) {
                if ($null -ne $retryAfter) {
                    $retryAt = [DateTimeOffset]::Now.AddSeconds($retryAfter)
                }
                elseif ($null -ne $resetEpoch) {
                    $retryAt = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).ToLocalTime()
                }
                else {
                    $retryAt = [DateTimeOffset]::Now.AddMinutes(1)
                }
            }

            [pscustomobject]@{
                Id          = $run.Id
                Success     = ($exitCode -eq 0 -and $statusCode -eq 204)
                RateLimited = $rateLimited
                StatusCode  = $statusCode
                RetryAt     = $retryAt
                Output      = $text
            }
        }
        catch {
            [pscustomobject]@{
                Id          = $run.Id
                Success     = $false
                RateLimited = $false
                StatusCode  = 0
                RetryAt     = $null
                Output      = $_.Exception.Message
            }
        }
    } -ThrottleLimit $Parallel | ForEach-Object {
        $result = $_

        if ($stopRequested) {
            return
        }

        $script:completed++

        if ($result.Success) {
            $script:deleted++
            $script:consecutiveFailures = 0
        }
        elseif ($result.RateLimited) {
            $script:rateLimitHit = $true
            $script:rateLimitRetryAt = $result.RetryAt
            $script:stopRequested = $true
            Write-Warning 'Rate limit detected. Stopping further processing.'
        }
        else {
            $failed.Add([pscustomobject]@{
                    Id     = $result.Id
                    Status = $result.StatusCode
                    Error  = $result.Output
                })
            $script:consecutiveFailures++

            if ($script:consecutiveFailures -ge 10) {
                Write-Warning 'Detected 10 consecutive failures. Stopping further processing.'
                $script:stopRequested = $true
            }
        }

        Update-DeletionProgress `
            -Completed $script:completed `
            -Total $total `
            -Deleted $script:deleted `
            -Failed $failed.Count
    }
}

Write-Progress -Activity 'Deleting workflow runs' -Completed

#endregion Delete

#region Summary

if ($rateLimitHit) {
    $localRetryTime = if ($null -ne $rateLimitRetryAt) {
        $rateLimitRetryAt.ToString('yyyy-MM-dd HH:mm:ss zzz')
    }
    else {
        'unknown'
    }
    Write-Warning "GitHub API rate limit hit. Retry after: $localRetryTime"
}

if ($consecutiveFailures -ge 10) {
    Write-Warning 'The script stopped because the last 10 processed runs failed.'
}

if ($failed.Count -gt 0) {
    Write-Warning "Deleted $deleted of $total selected run(s)."
    Write-Warning "Failed $($failed.Count) run(s)."
    Write-Warning "Failed run IDs: $($failed.Id -join ', ')"
}
else {
    Write-Host "Successfully deleted $deleted of $total selected run(s)."
}

#endregion Summary
