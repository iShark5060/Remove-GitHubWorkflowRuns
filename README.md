# Remove-GitHubWorkflowRuns

<<<<<<< Updated upstream
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![Cursor](https://img.shields.io/badge/Cursor-IDE-141414?logo=cursor&logoColor=white&style=flat-square)](https://cursor.com)

Deletes old GitHub Actions workflow runs from a repository via the [GitHub CLI](https://cli.github.com/).

Needs PowerShell 7+ (`pwsh`) and an authenticated `gh` (`repo` / Actions write).
=======
Old GitHub Actions runs pile up. This script deletes them through the [GitHub CLI](https://cli.github.com/) so a busy repo does not keep years of green checkmarks around.

Needs PowerShell 7+ (`pwsh`) and `gh` already logged in. The token needs permission to delete Actions workflow runs.
>>>>>>> Stashed changes

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo
```

Defaults to runs older than **7 days**, with a confirmation prompt. `-Days`, `-All`, `-Force`, `-WhatIf`, and `-Parallel` (0 = sequential, 2–10 = concurrent) are the other switches.

## Gotchas

<<<<<<< Updated upstream
- Stops after **10 consecutive failures**, or when a GitHub API rate limit is detected.
- `-Parallel` is faster and more likely to hit secondary rate limits (403/429). Use sequential (`-Parallel 0`) for large org cleanups.
- `-All` ignores `-Days` and deletes every run.
=======
| Parameter   | Required | Default | Description                                             |
| ----------- | -------- | ------- | ------------------------------------------------------- |
| `-Owner`    | Yes      | —       | Repository owner (user or org)                          |
| `-Repo`     | Yes      | —       | Repository name                                         |
| `-Days`     | No       | `7`     | Delete runs older than this many days                   |
| `-All`      | No       | off     | Delete every workflow run (ignores `-Days`)             |
| `-Parallel` | No       | `0`     | Concurrent jobs (`0` = sequential, `2`–`10` = parallel) |
| `-Force`    | No       | off     | Skip the confirmation prompt                            |
| `-WhatIf`   | No       | off     | Show what would be deleted without deleting             |

## Examples

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo -Days 30 -Force
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo -Days 14 -WhatIf
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo -All -Parallel 5 -Force
```

Stops early after **10 consecutive failures**, or when a GitHub API rate limit is detected. Parallel mode is faster but more likely to hit secondary rate limits; use sequential for large cleanups if you see 403/429.
>>>>>>> Stashed changes

## License

MIT. See [LICENSE](LICENSE).
