# Remove-GitHubWorkflowRuns

PowerShell script that deletes old (or all) GitHub Actions workflow runs from a repository using the [GitHub CLI](https://cli.github.com/).

## Requirements

- **PowerShell 7+** (`pwsh`)
- **GitHub CLI** (`gh`) installed and authenticated (`gh auth login`)
- A token with permission to delete Actions workflow runs (typically `repo` / Actions write access)

## Quick start

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo
```

By default this deletes runs older than **7 days**, after an interactive confirmation.

## Parameters

| Parameter   | Required | Default | Description |
|-------------|----------|---------|-------------|
| `-Owner`    | Yes      | —       | Repository owner (user or org) |
| `-Repo`     | Yes      | —       | Repository name |
| `-Days`     | No       | `7`     | Delete runs older than this many days |
| `-All`      | No       | off     | Delete every workflow run (ignores `-Days`) |
| `-Parallel` | No       | `0`     | Concurrent jobs (`0` = sequential, `2`–`10` = parallel) |
| `-Force`    | No       | off     | Skip the confirmation prompt |
| `-WhatIf`   | No       | off     | Show what would be deleted without deleting |

## Examples

### Delete runs older than 7 days (default)

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo
```

### Delete runs older than 30 days, no prompt

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo -Days 30 -Force
```

### Preview deletion without making changes

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo -Days 14 -WhatIf
```

### Delete all workflow runs with parallel jobs

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo -All -Parallel 5 -Force
```

### Organization cleanup (sequential, safer for rate limits)

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo busy-ci-repo -Days 90
```

## Behavior notes

- Progress is shown via `Write-Progress` while deletions run.
- Stops early after **10 consecutive failures**, or when a **GitHub API rate limit** is detected (and reports when to retry).
- Parallel mode (`-Parallel 2`–`10`) is faster but more likely to hit secondary rate limits; use sequential (`-Parallel 0`) for large cleanups if you see 403/429 responses.

## License

See [LICENSE](LICENSE).
