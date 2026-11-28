# The feature pack's demo and scenes, dot-sourced by feature-pack.ps1 after the integration helpers.
# A scene is Name (file names), Site (the site/assets base name its WebP takes), Feature and Caption (the manifest),
# Clip (record it), Run (drives the window and calls Save-Shot) and Reset (puts the demo back for the next scene).
# The demo follows the site's staging rules: made-up projects, at most three agent statuses, no badges beside them.

$demoIds = @{}

function Ctl([string[]]$Arguments) {
    $reply = Invoke-Ctl $demo.State $Arguments
    if (-not $reply.ok) { throw "agtermctl $($Arguments -join ' ') replied $($reply.error)" }
    $reply.result
}

# Type-Slowly types `Text` in chunks, so a clip shows it being typed.
function Type-Slowly([string]$Target, [string]$Text, [string]$Pane) {
    $paneArgs = if ($Pane) { @("--pane", $Pane) } else { @() }
    $i = 0
    while ($i -lt $Text.Length) {
        # a chunk never starts with "-", which agtermctl would read as an option
        $end = [Math]::Min($i + 3, $Text.Length)
        while ($end -lt $Text.Length -and $Text[$end] -eq "-") { $end++ }
        Ctl (@("session", "type", "--target", $Target) + $paneArgs + @($Text.Substring($i, $end - $i))) | Out-Null
        $i = $end
        Start-Sleep -Milliseconds 60
    }
    Ctl (@("session", "type", "--target", $Target) + $paneArgs + @("`r")) | Out-Null
}

function New-DemoRepo([string]$Name, [string[]]$Commits) {
    $dir = Join-Path $DemoRoot $Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $ErrorActionPreference = "Continue"
    $env:GIT_AUTHOR_NAME = $env:GIT_COMMITTER_NAME = "agterm demo"
    $env:GIT_AUTHOR_EMAIL = $env:GIT_COMMITTER_EMAIL = "demo@example.com"
    git -C $dir init -q -b main 2>&1 | Out-Null
    $day = 0
    foreach ($message in $Commits) {
        $day++
        $env:GIT_AUTHOR_DATE = $env:GIT_COMMITTER_DATE = "2026-11-$('{0:d2}' -f $day)T10:00:00"
        Add-Content (Join-Path $dir "CHANGES.md") "- $message"
        git -C $dir add -A 2>&1 | Out-Null
        git -C $dir commit -q -m $message 2>&1 | Out-Null
    }
    "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL", "GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE" |
        % { Remove-Item "Env:$_" -ErrorAction SilentlyContinue }
    $dir
}

# Initialize-Demo makes the demo projects and the sessions working in them, and returns nothing.
function Initialize-Demo($Demo) {
    if (Test-Path $DemoRoot) {
        if (-not (Test-Path (Join-Path $DemoRoot ".agterm-feature-pack"))) { throw "$DemoRoot exists and is not a feature-pack demo folder" }
        Remove-Item -Recurse -Force $DemoRoot
    }
    New-Item -ItemType Directory -Force $DemoRoot | Out-Null
    Set-Content (Join-Path $DemoRoot ".agterm-feature-pack") "made by feature-pack.ps1; removed and rebuilt on every run"
    $api = New-DemoRepo "api" @("init service skeleton", "add /health endpoint", "orders: list and create", "orders: pagination",
        "auth: token refresh", "fix: retry on 503 from billing", "metrics: request latency histogram", "orders: idempotency keys")
    $web = New-DemoRepo "web" @("vite app", "orders table", "login form", "dark theme", "orders: infinite scroll")
    $docs = New-DemoRepo "docs" @("outline", "getting started", "orders API reference")
    Set-Content (Join-Path $docs "README.md") -Encoding UTF8 @"
# Orders API

The orders service lists, creates and cancels orders for the storefront.

## Endpoints

| Method | Path | What it does |
|--------|------|--------------|
| GET | ``/orders`` | List orders, newest first, 50 a page |
| POST | ``/orders`` | Create an order; send an ``Idempotency-Key`` |
| DELETE | ``/orders/{id}`` | Cancel an order that has not shipped |

## Running it

``````
make dev        # api on :8080, web on :5173
make test       # unit and contract tests
``````

> Billing answers 503 while it deploys; the client retries three times with backoff.
"@
    $bin = Join-Path $DemoRoot "bin"
    New-Item -ItemType Directory -Force $bin | Out-Null
    # PowerShell 5.1 reads a script without a BOM as ANSI, which would garble the glyphs
    Set-Content (Join-Path $bin "server.ps1") -Encoding UTF8 @'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Write-Host "orders-api " -ForegroundColor Cyan -NoNewline; Write-Host "v2.14.0  listening on :8080"
Write-Host "  db      " -NoNewline; Write-Host "connected" -ForegroundColor Green -NoNewline; Write-Host "  postgres://localhost/orders (pool 20)"
Write-Host "  billing " -NoNewline; Write-Host "ready" -ForegroundColor Green
$paths = "GET  /orders?page=2", "POST /orders", "GET  /orders/8812", "GET  /health", "DELETE /orders/8790", "GET  /orders?status=open"
$deadline = (Get-Date).AddMinutes(45)
for ($i = 0; (Get-Date) -lt $deadline; $i++) {
    $code = if ($i % 11 -eq 7) { 503 } elseif ($i % 5 -eq 1) { 201 } else { 200 }
    $color = if ($code -ge 500) { "Red" } elseif ($code -eq 201) { "Green" } else { "DarkGray" }
    Write-Host ("{0:HH:mm:ss} " -f (Get-Date)) -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-24}" -f $paths[$i % $paths.Count]) -NoNewline
    Write-Host ("{0} " -f $code) -ForegroundColor $color -NoNewline
    Write-Host ("{0,4}ms" -f (7 + ($i * 37) % 90)) -ForegroundColor DarkGray
    Start-Sleep -Milliseconds $(if ($i -lt 12) { 150 } else { 1400 })
}
'@
    Set-Content (Join-Path $bin "tests.ps1") -Encoding UTF8 @'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Write-Host "Running 128 tests in 14 files" -ForegroundColor Cyan
foreach ($suite in "orders.create", "orders.list", "orders.cancel", "auth.refresh", "billing.retry", "metrics.latency") {
    Write-Host ("  {0} " -f [char]0x2713) -ForegroundColor Green -NoNewline; Write-Host $suite -NoNewline
    Write-Host (" ({0} ms)" -f ($suite.Length * 13)) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  128 passed" -ForegroundColor Green -NoNewline; Write-Host "  in 4.21s"
'@
    $shell = "powershell.exe -NoLogo -NoProfile -NoExit"
    $initial = @((Ctl @("tree")).tree.workspaces | % { $_.sessions } | % { $_.id })

    $apiSpace = (Ctl @("workspace", "new", "api")).id
    # plain shells, the demo programs typed into them: a split or scratch pane starts the session's own command
    $demoIds.server = (Ctl @("session", "new", "--workspace", $apiSpace, "--name", "server", "--cwd", $api, "--command", $shell)).id
    $demoIds.tests = (Ctl @("session", "new", "--workspace", $apiSpace, "--name", "tests", "--cwd", $api, "--command", $shell)).id
    $demoIds.logs = (Ctl @("session", "new", "--parent", $demoIds.server, "--name", "logs", "--cwd", $api, "--command", $shell)).id
    $webSpace = (Ctl @("workspace", "new", "web")).id
    $demoIds.dev = (Ctl @("session", "new", "--workspace", $webSpace, "--name", "dev", "--cwd", $web, "--command", $shell)).id
    $demoIds.review = (Ctl @("session", "new", "--workspace", $webSpace, "--name", "review", "--cwd", $web, "--command", $shell)).id
    $docsSpace = (Ctl @("workspace", "new", "docs")).id
    $demoIds.notes = (Ctl @("session", "new", "--workspace", $docsSpace, "--name", "notes", "--cwd", $docs, "--command", $shell)).id
    $demoIds.api = $api; $demoIds.web = $web; $demoIds.docs = $docs
    $demoIds.workspaces = @($apiSpace, $webSpace, $docsSpace)
    foreach ($id in $initial) { Ctl @("session", "close", "--target", $id) | Out-Null }
    foreach ($space in @((Ctl @("tree")).tree.workspaces | ? { $demoIds.workspaces -notcontains $_.id -and -not @($_.sessions).Count })) {
        Invoke-Ctl $Demo.State @("workspace", "delete", "--target", $space.id) | Out-Null
    }

    foreach ($id in "server", "tests", "logs", "dev", "review", "notes") {
        if (-not (Wait-Prompt $Demo.State $demoIds[$id])) { Write-Host "  $id has no prompt yet" }
    }
    Ctl @("session", "type", "--target", $demoIds.server, "..\bin\server.ps1`r") | Out-Null
    Ctl @("session", "type", "--target", $demoIds.tests, "..\bin\tests.ps1`r") | Out-Null
    Ctl @("session", "type", "--target", $demoIds.logs, "git log --oneline --decorate -6`r") | Out-Null
    Ctl @("session", "type", "--target", $demoIds.dev, "git status`r") | Out-Null
    Ctl @("session", "type", "--target", $demoIds.review, "git log --stat -1`r") | Out-Null
    Ctl @("session", "type", "--target", $demoIds.notes, "Get-ChildItem`r") | Out-Null
    Set-DemoStatus
    Ctl @("session", "context", "PR 42: idempotency keys", "--target", $demoIds.server) | Out-Null
    Ctl @("session", "info", "**128** passed in 4.2 s", "--markdown", "--target", $demoIds.tests) | Out-Null
    Ctl @("session", "select", "--target", $demoIds.server) | Out-Null
    Start-Sleep -Seconds 2
}

# the three agent statuses the demo shows; Attention clears them, since a badge never sits beside a status
function Set-DemoStatus {
    Ctl @("session", "status", "active", "--target", $demoIds.dev) | Out-Null
    Ctl @("session", "status", "blocked", "--target", $demoIds.review) | Out-Null
    Ctl @("session", "status", "completed", "--target", $demoIds.tests) | Out-Null
}

# Show-Backdrop covers the screen's corner where banners show with the theme's background: the banner window's
# transparent margin would otherwise show the user's own windows. A banner posted after it opens comes above it.
function Show-Backdrop {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = "None"; $form.ShowInTaskbar = $false; $form.TopMost = $true; $form.StartPosition = "Manual"
    $form.BackColor = [System.Drawing.Color]::FromArgb(0x2e, 0x34, 0x40)
    $form.Bounds = New-Object System.Drawing.Rectangle ($area.Right - 640), ($area.Bottom - 320), 640, 320
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $form
}

function Select-Demo([string]$Name) { Ctl @("session", "select", "--target", $demoIds[$Name]) | Out-Null; Start-Sleep -Milliseconds 500 }

$featureScenes = @(
    @{ Name = "main"; Site = "screenshot-main"; Feature = "Workspaces and sessions"
       Caption = "Projects as workspaces, their shells, servers and agents as sessions, with a companion under the server."
       Run = { Select-Demo "server"; Save-Shot "" } },

    @{ Name = "agent-status"; Site = "docs-status-agents"; Feature = "Agent status"
       Caption = "Agents report active, blocked and completed in the sidebar; the title bar shows what the session is about."
       Run = { Select-Demo "review"; Save-Shot "" } },

    @{ Name = "split"; Site = "screenshot-split"; Feature = "Split panes"; Clip = $true
       Caption = "Split a session and run a second command beside the first."
       Run = {
           Select-Demo "server"
           Ctl @("session", "split", "on", "--target", $demoIds.server) | Out-Null
           Start-Sleep -Seconds 2
           Type-Slowly $demoIds.server "git log --oneline --graph --decorate -10" "right"
           Start-Sleep -Seconds 1
           Save-Shot ""
       }
       Reset = { Invoke-Ctl $demo.State @("session", "split", "close", "--target", $demoIds.server) | Out-Null } },

    @{ Name = "session-palette"; Site = "screenshot-session-palette"; Feature = "Session palette"; Clip = $true
       Caption = "Ctrl+P finds any session by name, workspace or folder."
       Run = {
           $palette = Open-Palette $demo.Window $false
           if (-not $palette) { throw "Ctrl+P opened no palette" }
           Start-Sleep -Milliseconds 600
           foreach ($query in "r", "re", "rev") { [AgtermInput]::SetText($palette.Edit, $query); Start-Sleep -Milliseconds 350 }
           Save-Shot ""
           Send-Key $palette.Edit 0x1B
       } },

    @{ Name = "action-palette"; Site = "screenshot-action-palette"; Feature = "Action palette"; Clip = $true
       Caption = "Ctrl+Shift+P runs any action by name, with its shortcut beside it."
       Run = {
           $palette = Open-Palette $demo.Window $true
           if (-not $palette) { throw "Ctrl+Shift+P opened no palette" }
           Start-Sleep -Milliseconds 600
           foreach ($query in "sp", "spl", "split") { [AgtermInput]::SetText($palette.Edit, $query); Start-Sleep -Milliseconds 350 }
           Save-Shot ""
           Send-Key $palette.Edit 0x1B
       } },

    @{ Name = "dashboard"; Site = "screenshot-dashboard"; Feature = "Dashboard"; Clip = $true
       Caption = "Every recent session live in one grid; a click takes you there."
       Run = { Ctl @("dashboard", "--mru") | Out-Null; Start-Sleep -Seconds 3; Save-Shot "" }
       Reset = { Invoke-Ctl $demo.State @("dashboard", "--close") | Out-Null } },

    @{ Name = "quick-terminal"; Site = "screenshot-quick-terminal"; Feature = "Quick terminal"; Clip = $true
       Caption = "A terminal one shortcut away, over whatever you are doing."
       Run = {
           Ctl @("quick", "show") | Out-Null
           Start-Sleep -Seconds 2
           Ctl @("quick", "type", "Set-Location $($demoIds.api); git log --oneline -5`r") | Out-Null
           Start-Sleep -Seconds 2
           Save-Shot "" -Screen
       }
       Reset = { Invoke-Ctl $demo.State @("quick", "hide") | Out-Null } },

    @{ Name = "floating-overlay"; Site = "screenshot-floating-overlay"; Feature = "Program overlay"; Clip = $true
       Caption = "Run a program in a panel over a session, and come back to the session untouched."
       Run = {
           Select-Demo "server"
           Ctl @("session", "overlay", "open", "git -C $($demoIds.api) log --graph --stat --color=always -4 & pause >nul",
               "--size-percent", "70", "--target", $demoIds.server) | Out-Null
           Start-Sleep -Seconds 3
           Save-Shot ""
       }
       Reset = { Invoke-Ctl $demo.State @("session", "overlay", "close", "--target", $demoIds.server) | Out-Null } },

    @{ Name = "pick"; Site = "docs-pick"; Feature = "Picker"
       Caption = "agtermctl pick opens a fuzzy picker over the window for a script or an agent."
       Run = {
           Select-Demo "dev"
           $pick = Open-Pick $demo.State @("staging", "production", "preview-42", "canary", "local") @("--prompt", "Deploy web to", "--select", "staging")
           # a --no-block reply is the bare id, with no ok/result envelope
           if (-not $pick.id) { throw "pick replied $($pick | ConvertTo-Json -Compress)" }
           $script:openPick = $pick.id
           Start-Sleep -Seconds 1
           Save-Shot ""
       }
       Reset = { if ($script:openPick) { Invoke-Ctl $demo.State @("pick", "cancel", $script:openPick) | Out-Null; $script:openPick = $null } } },

    @{ Name = "ask"; Site = "docs-ask-styles"; Feature = "Question dialog"
       Caption = "agtermctl ask puts a question to the user and waits for the button they press."
       Run = {
           Select-Demo "review"
           $ask = Invoke-Ctl $demo.State @("ask", "Run database migrations on staging?", "--message", "3 pending: orders_idempotency, orders_index, audit_log",
               "--button", "run=Run", "--button", "skip=Skip", "--default", "run", "--style", "gui", "--target", $demoIds.review, "--no-block")
           if (-not $ask.id) { throw "ask replied $($ask | ConvertTo-Json -Compress)" }
           $script:openAsk = $ask.id
           Start-Sleep -Seconds 1
           Save-Shot ""
       }
       Reset = { if ($script:openAsk) { Invoke-Ctl $demo.State @("ask", "cancel", $script:openAsk) | Out-Null; $script:openAsk = $null } } },

    @{ Name = "context-menu"; Site = "screenshot-context-menu"; Feature = "Session menu"
       Caption = "Right-click a session to rename, tint, flag, split or move it."
       Run = {
           Select-Demo "server"
           $script:openMenu = Open-RowMenu $demo $demo.Window 1
           if (-not $script:openMenu) { throw "no context menu" }
           Save-Shot "" -Screen
       }
       Reset = { if ($script:openMenu) { Send-Escape $script:openMenu; $script:openMenu = $null; Start-Sleep -Milliseconds 300 } } },

    @{ Name = "tint"; Site = "docs-tint"; Feature = "Sidebar tint"
       Caption = "Tint a session or a workspace to find it at a glance."
       Run = {
           Ctl @("workspace", "tint", "teal", "--target", $demoIds.workspaces[0]) | Out-Null
           Ctl @("session", "tint", "orange", "--on", "icon,name", "--target", $demoIds.dev) | Out-Null
           Ctl @("session", "tint", "purple", "--target", $demoIds.notes) | Out-Null
           Save-Shot ""
       }
       Reset = {
           Invoke-Ctl $demo.State @("workspace", "tint", "clear", "--target", $demoIds.workspaces[0]) | Out-Null
           foreach ($id in "dev", "notes") { Invoke-Ctl $demo.State @("session", "tint", "clear", "--target", $demoIds[$id]) | Out-Null }
       } },

    @{ Name = "scratch"; Site = "docs-scratch"; Feature = "Scratch terminal"
       Caption = "A scratch terminal slides over a session for a quick command, in the same folder."
       Run = {
           Select-Demo "server"
           Ctl @("session", "scratch", "on", "--target", $demoIds.server) | Out-Null
           Start-Sleep -Seconds 2
           Ctl @("session", "type", "--target", $demoIds.server, "--pane", "scratch", "git status --short --branch`r") | Out-Null
           Start-Sleep -Seconds 1
           Save-Shot ""
       }
       Reset = { Invoke-Ctl $demo.State @("session", "scratch", "off", "--target", $demoIds.server) | Out-Null } },

    @{ Name = "attention"; Site = "screenshot-attention"; Feature = "Notifications"
       Caption = "A notification from a session in the background badges it and shows a Windows banner."
       Run = {
           foreach ($id in "dev", "review", "tests") { Ctl @("session", "status", "idle", "--target", $demoIds[$id]) | Out-Null }
           Select-Demo "server"
           $backdrop = Show-Backdrop
           try {
               Ctl @("notify", "--target", $demoIds.tests, "128 tests passed") | Out-Null
               Start-Sleep -Seconds 2
               Save-Shot ""
               Save-Shot "banner" -Banner
           } finally { $backdrop.Close() }
       }
       Reset = { Invoke-Ctl $demo.State @("session", "seen", "--target", $demoIds.tests) | Out-Null; Set-DemoStatus } },

    @{ Name = "settings"; Site = "docs-settings"; Feature = "Settings"
       Caption = "General, Appearance and Notifications settings."
       Run = {
           foreach ($tab in "general", "appearance", "notifications") {
               $settings = Open-Settings $demo $demo.Window $tab
               if (-not $settings) { throw "Settings did not open on $tab" }
               Start-Sleep -Milliseconds 600
               Save-Shot $tab $settings
               Close-Settings $settings $false | Out-Null
           }
       } }
)
