# Remove-GitHubWorkflowRuns

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![Cursor](https://img.shields.io/badge/Cursor-IDE-141414?logo=cursor&logoColor=white&style=flat-square)](https://cursor.com)

Deletes old GitHub Actions workflow runs from a repository via the [GitHub CLI](https://cli.github.com/).

Needs PowerShell 7+ (`pwsh`) and an authenticated `gh` (`repo` / Actions write).

```powershell
pwsh ./Remove-GitHubWorkflowRuns.ps1 -Owner myorg -Repo myrepo
```

Defaults to runs older than **7 days**, with a confirmation prompt. `-Days`, `-All`, `-Force`, `-WhatIf`, and `-Parallel` (0 = sequential, 2–10 = concurrent) are the other switches.

## Gotchas

- Stops after **10 consecutive failures**, or when a GitHub API rate limit is detected.
- `-Parallel` is faster and more likely to hit secondary rate limits (403/429). Use sequential (`-Parallel 0`) for large org cleanups.
- `-All` ignores `-Days` and deletes every run.

## License

MIT. See [LICENSE](LICENSE).
