# Run the log_viz Sinatra app from anywhere in the repo.
#
# Usage: .\bin\logviz.ps1

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$logVizDir = Join-Path $repoRoot "week1_baseline\log_viz"

Push-Location $logVizDir
try {
    bundle exec ruby bin/log_viz @args
} finally {
    Pop-Location
}
