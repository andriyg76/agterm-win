# Feature pack: drives a released agterm-win package through its features on the interactive desktop and saves
# screenshots, short clips and a manifest for the site and the docs. Run it by hand in a session you watch; it refuses
# to run under CI. The window runs on its own state directory, so your own agterm-win state is never touched, and only
# the processes this script starts are stopped.
#
#   feature-pack.ps1 -Source agterm-win-0.44.1.11-x64-portable.zip
#   feature-pack.ps1 -Version 0.44.1.11 [-Package setup] [-Scene main,palette*] [-Pause] [-NoVideo]
param(
    # a local -portable.zip, -setup.exe or unpacked app folder
    [string]$Source,
    # a GitHub release to download instead of -Source
    [string]$Version,
    [ValidateSet("portable", "setup")][string]$Package = "portable",
    [ValidateSet("x64", "arm64")][string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }),
    [string]$Output = (Join-Path $env:USERPROFILE "agterm-feature-pack"),
    # wildcard names of the scenes to take, all when omitted
    [string[]]$Scene = @("*"),
    [string]$Theme = "Nord",
    # the window's size in physical pixels, even for H.264; by default the largest at the site hero's 1187:696, up to
    # 2374x1392, that fits the primary screen
    [ValidateRange(0, 3840)][int]$Width = 0,
    [ValidateRange(0, 2160)][int]$Height = 0,
    # where the demo projects the sessions work in are made; short, since the prompt shows it
    [string]$DemoRoot = (Join-Path $env:SystemDrive "agterm-demo"),
    # stop before every shot, to look at the window or tidy it by hand
    [switch]$Pause,
    [switch]$NoVideo,
    [string]$Repo = "andriyg76/agterm-win"
)
$ErrorActionPreference = "Stop"
# -File hands a list over as one comma-separated word
$Scene = @($Scene | % { $_ -split "," } | ? { $_ })

if ($env:CI -or $env:GITHUB_ACTIONS -or $env:TF_BUILD) { throw "feature-pack runs on a desktop you watch, not under CI" }
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0 -or -not [Environment]::UserInteractive) {
    throw "feature-pack needs an interactive desktop: run it in your own session or through a /IT scheduled task"
}
if (-not $Source -and -not $Version) { throw "pass -Source <zip|exe|folder> or -Version <x.y.z.w>" }
if ($Width % 2 -or $Height % 2) { throw "-Width and -Height must be even" }

$ffmpeg = @((Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source,
            (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\ffmpeg.exe")) | ? { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $ffmpeg -and -not $NoVideo) { throw "no ffmpeg: winget install Gyan.FFmpeg, or pass -NoVideo for PNG shots only" }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$work = Join-Path $Output "work-$stamp"
New-Item -ItemType Directory -Force $work | Out-Null

# Get-Package is the package file or folder: the -Source given, or the release asset downloaded into the work folder.
function Get-Package {
    if ($Source) { return (Resolve-Path $Source).Path }
    $suffix = if ($Package -eq "setup") { "setup.exe" } else { "portable.zip" }
    $name = "agterm-win-$Version-$Arch-$suffix"
    $file = Join-Path $work $name
    Write-Host "downloading $name"
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest "https://github.com/$Repo/releases/download/v$Version/$name" -OutFile $file -UseBasicParsing
    $file
}

$appId = "{33086B3F-821D-4FAF-9EC9-F6490E82190B}_is1"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId"
$uninstaller = $null

# Install-App unpacks or installs the package into the work folder and returns the folder with agterm-win.exe.
function Install-App([string]$Path) {
    $app = Join-Path $work "app"
    if (Test-Path $Path -PathType Container) { return $Path }
    if ($Path -like "*.zip") {
        Expand-Archive $Path $app -Force
    } elseif ($Path -like "*.exe") {
        # the installer's AppId is the user's own install: a second copy would take over its uninstall entry and PATH
        if (Test-Path $uninstallKey) { throw "agterm-win is installed for this user; use the portable zip, or uninstall it first" }
        $setup = Start-Process $Path -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/DIR=`"$app`"") -PassThru -Wait
        if ($setup.ExitCode) { throw "setup exited with $($setup.ExitCode)" }
        $script:uninstaller = Join-Path $app "unins000.exe"
    } else { throw "unknown package $Path" }
    $exe = Get-ChildItem $app -Recurse -Filter agterm-win.exe | Select-Object -First 1
    if (-not $exe) { throw "no agterm-win.exe in $Path" }
    $exe.DirectoryName
}

# Keep the display on for the run: a locked or blanked screen captures black.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FeaturePackWin32 {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(int flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string className, string title);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);
    // Bounds is the window as it shows on screen, without the invisible resize border GetWindowRect counts.
    public static Rect Bounds(IntPtr window) {
        Rect rect;
        DwmGetWindowAttribute(window, 9, out rect, Marshal.SizeOf(typeof(Rect)));
        return rect;
    }
}
'@
[FeaturePackWin32]::SetThreadExecutionState(0x80000003) | Out-Null  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED

$appDir = Install-App (Get-Package)
# shell-cases.ps1 and the case files it loads hold the window helpers (launch, agtermctl, palettes, Settings, menus)
$exe = Join-Path $appDir "agterm-win.exe"
$Results = $work
$StepSeconds = 0
. (Join-Path $PSScriptRoot "..\tests\integration\shell-cases.ps1")
. (Join-Path $PSScriptRoot "feature-pack-scenes.ps1")

$build = try { Get-Content (Join-Path $appDir "build-info.json") -Raw | ConvertFrom-Json } catch { $null }
$appVersion = if ($build.version) { $build.version } elseif ($Version) { $Version } else { "unknown" }
$pack = Join-Path $Output "$appVersion-$Arch-$stamp"
$shots = Join-Path $pack "png"
$site = Join-Path $pack "site"
$clips = Join-Path $pack "video"
New-Item -ItemType Directory -Force $shots, $site, $clips | Out-Null

function Invoke-Ffmpeg([string[]]$Arguments) {
    $ErrorActionPreference = "Continue"
    & $ffmpeg -hide_banner -loglevel error -y @Arguments 2>&1 | % { Write-Host "  ffmpeg: $_" }
}

# The pack's current scene: Save-Shot and the clip recorder add their files to it.
$current = $null

# Save-Shot saves the window (`Window`, the main one by default) as PNG, and its WebP twin under the scene's site name.
# `Screen` takes the screen's pixels in the window's bounds instead, for popups that are windows of their own (menus);
# `Banner` takes the screen's pixels in the Windows notification banner's bounds only: never the desktop around it,
# which shows the user's own windows.
function Save-Shot([string]$Label, [IntPtr]$Window = [IntPtr]::Zero, [switch]$Screen, [switch]$Banner) {
    if ($Window -eq [IntPtr]::Zero) { $Window = $demo.Window }
    if ($Pause) {
        Read-Host "  [$($current.Name)] $Label - Enter to take the shot"
        Bring-Front $demo.Window | Out-Null
    }
    Start-Sleep -Milliseconds 400
    $base = "$($current.Name)$(if ($Label) { "-$Label" })"
    $png = Join-Path $shots "$base.png"
    if ($Banner) {
        $toast = Wait-Until { $h = [FeaturePackWin32]::FindWindowW("Windows.UI.Core.CoreWindow", "New notification"); if ($h -ne [IntPtr]::Zero) { $h } } 5
        if (-not $toast) { Write-Host "  no notification banner on screen; $Label skipped"; return }
        $rect = [FeaturePackWin32]::Bounds($toast)
        $bounds = New-Object System.Drawing.Rectangle $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
    } else {
        $rect = [FeaturePackWin32]::Bounds($Window)
        $bounds = New-Object System.Drawing.Rectangle $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
    }
    if ($Screen -or $Banner) {
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        $graphics.Dispose()
        Save-Bitmap $bitmap $png
    } else {
        Save-Snapshot ([pscustomobject]@{ Dir = $shots }) $base $Window
        # PrintWindow draws the outer rect; crop it to what shows on screen
        $outer = New-Object AgtermSnapshot+Rect
        [AgtermSnapshot]::GetWindowRect($Window, [ref]$outer) | Out-Null
        $full = [System.Drawing.Bitmap]::FromFile($png)
        $crop = New-Object System.Drawing.Rectangle ($bounds.Left - $outer.Left), ($bounds.Top - $outer.Top), $bounds.Width, $bounds.Height
        $cut = $full.Clone($crop, $full.PixelFormat)
        $full.Dispose()
        Save-Bitmap $cut $png
    }
    $entry = [ordered]@{ label = $Label; png = "png/$base.png"; width = $bounds.Width; height = $bounds.Height }
    if ($ffmpeg) {
        $siteName = if ($Label -and $current.Site) { "$($current.Site)-$Label" } elseif ($current.Site) { $current.Site } else { $base }
        Invoke-Ffmpeg @("-i", $png, "-c:v", "libwebp", "-quality", "88", "-compression_level", "6", (Join-Path $site "$siteName.webp"))
        $entry.webp = "site/$siteName.webp"
    }
    $current.Shots.Add($entry) | Out-Null
    Write-Host "  shot $base"
}

# Start-Clip records the main window's screen area with Desktop Duplication until Stop-Clip; the mouse is left out.
function Start-Clip {
    if ($NoVideo) { return $null }
    $rect = [FeaturePackWin32]::Bounds($demo.Window)
    $w = ($rect.Right - $rect.Left) -band -2; $h = ($rect.Bottom - $rect.Top) -band -2
    $file = Join-Path $clips "$($current.Name).mp4"
    $grab = "ddagrab=output_idx=0:framerate=30:draw_mouse=0:offset_x=$($rect.Left):offset_y=$($rect.Top):video_size=${w}x${h},hwdownload,format=bgra"
    $info = New-Object System.Diagnostics.ProcessStartInfo $ffmpeg
    $info.Arguments = "-hide_banner -loglevel error -y -f lavfi -i `"$grab`" -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p `"$file`""
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    Start-Sleep -Milliseconds 800
    [pscustomobject]@{ Process = $process; File = $file }
}

function Stop-Clip($Clip) {
    if (-not $Clip) { return }
    Start-Sleep -Milliseconds 800
    $Clip.Process.StandardInput.Write("q")
    $Clip.Process.StandardInput.Close()
    if (-not $Clip.Process.WaitForExit(20000)) { Stop-Process -Id $Clip.Process.Id -Force; Write-Host "  ffmpeg did not stop; clip dropped"; return }
    if (-not (Test-Path $Clip.File)) { Write-Host "  no clip written"; return }
    $name = $current.Name
    Invoke-Ffmpeg @("-i", $Clip.File, "-c:v", "libvpx-vp9", "-crf", "34", "-b:v", "0", "-row-mt", "1", (Join-Path $clips "$name.webm"))
    Invoke-Ffmpeg @("-i", $Clip.File, "-vf", "fps=12,scale=960:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
        (Join-Path $clips "$name.gif"))
    $current.Clip = [ordered]@{ mp4 = "video/$name.mp4"; webm = "video/$name.webm"; gif = "video/$name.gif" }
    Write-Host "  clip $name"
}

# The demo window: launched once on its own state directory, placed and sized on the primary screen, the theme set.
$demo = Start-Shell "demo" $null @{}
$stepShells.Remove($demo.State)   # Invoke-Ctl's per-step test snapshots are not part of the pack
$manifest = [ordered]@{ version = $appVersion; arch = $Arch; package = $(if ($Source) { Split-Path -Leaf $Source } else { "$Version $Package" })
                        build = $build; theme = $Theme; taken = (Get-Date).ToString("o"); scenes = New-Object System.Collections.ArrayList }
try {
    if (-not $demo.Ready) { throw "the window's control socket did not answer" }
    $demo | Add-Member Window (Get-ShellWindow $demo)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if (-not $Width -or -not $Height) {
        $Width = [Math]::Min(2374, [Math]::Min($area.Width - 80, [int](($area.Height - 80) * 1187 / 696))) -band -2
        $Height = [int]($Width * 696 / 1187) -band -2
    }
    Write-Host "window ${Width}x${Height} on a $($area.Width)x$($area.Height) work area"
    [FeaturePackWin32]::SetWindowPos($demo.Window, [IntPtr]::Zero, $area.Left + 40, $area.Top + 40, $Width, $Height, 0x0044) | Out-Null  # SWP_NOZORDER | SWP_SHOWWINDOW
    $bounds = [FeaturePackWin32]::Bounds($demo.Window)
    if ($bounds.Right -gt $area.Right -or $bounds.Bottom -gt $area.Bottom) {
        throw "a ${Width}x${Height} window does not fit the primary screen's work area $area (it shows at $($bounds.Left),$($bounds.Top)-$($bounds.Right),$($bounds.Bottom))"
    }
    # the pointer would show in the shots and hover-highlight rows
    [FeaturePackWin32]::SetCursorPos($area.Right - 1, $area.Bottom - 1) | Out-Null
    Bring-Front $demo.Window | Out-Null
    $themed = Invoke-Ctl $demo.State @("theme", "set", $Theme)
    if (-not $themed.ok) { throw "theme set $Theme replied $($themed.error)" }
    Initialize-Demo $demo

    foreach ($definition in $featureScenes | ? { $name = $_.Name; [bool]($Scene | ? { $name -like $_ }) }) {
        $current = [pscustomobject]@{ Name = $definition.Name; Site = $definition.Site; Shots = New-Object System.Collections.ArrayList; Clip = $null }
        Write-Host "scene $($definition.Name)"
        $clip = if ($definition.Clip) { Start-Clip }
        $failure = $null
        try { & $definition.Run $demo } catch { $failure = "$(Split-Path -Leaf $_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" }
        finally { Stop-Clip $clip }
        if ($definition.Reset) { & $definition.Reset $demo }
        if ($failure) { Write-Host "  FAILED $failure" }
        $manifest.scenes.Add([ordered]@{ name = $definition.Name; feature = $definition.Feature; caption = $definition.Caption
                                        shots = @($current.Shots); clip = $current.Clip; failure = $failure }) | Out-Null
    }
} finally {
    # end the demo's sessions before the window, so no session host outlives the run
    $tree = Invoke-Ctl $demo.State @("tree")
    if ($tree.ok) { foreach ($node in @($tree.result.tree.workspaces | % { $_.sessions })) { Invoke-Ctl $demo.State @("session", "close", "--target", $node.id) | Out-Null } }
    Stop-Shell $demo
    if ($uninstaller -and (Test-Path $uninstaller)) { Start-Process $uninstaller -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -Wait }
    [FeaturePackWin32]::SetThreadExecutionState(0x80000000) | Out-Null
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $pack "manifest.json") -Encoding UTF8

# index.html: every scene with its caption, shots and clip, to review the pack in a browser
$encode = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
$sections = foreach ($s in $manifest.scenes) {
    $media = @($s.shots | % { "<figure><img src=`"$($_.png)`" loading=`"lazy`"><figcaption>$(& $encode $_.label) $(if ($_.webp) { "&middot; $(& $encode $_.webp)" })</figcaption></figure>" })
    if ($s.clip) { $media += "<figure><video src=`"$($s.clip.mp4)`" controls muted loop></video><figcaption>$(& $encode $s.clip.mp4)</figcaption></figure>" }
    $fail = if ($s.failure) { "<p class=`"fail`">$(& $encode $s.failure)</p>" }
    "<section><h2>$(& $encode $s.feature) <small>$(& $encode $s.name)</small></h2><p>$(& $encode $s.caption)</p>$fail$($media -join '')</section>"
}
@"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>agterm-win feature pack</title><style>
body{margin:0;padding:24px 16px;background:#2e3440;color:#eceff4;font:15px/1.5 system-ui,sans-serif}
main{max-width:1200px;margin:auto}h2 small{color:#81a1c1;font-weight:400;font-size:.7em;margin-left:.5em}
img,video{max-width:100%;border-radius:8px;display:block}figure{margin:12px 0}figcaption{color:#a3b1c6;font-size:13px}
.fail{color:#bf616a}section{border-top:1px solid #4c566a;padding-top:8px;margin-top:24px}
</style></head><body><main><h1>agterm-win $(& $encode $appVersion) &middot; $Arch</h1>
<p>$(& $encode $manifest.package) &middot; $(& $encode "$($build.branch) $($build.buildDate)") &middot; theme $(& $encode $Theme) &middot; $(& $encode $manifest.taken)</p>
$($sections -join "`n")
</main></body></html>
"@ | Set-Content (Join-Path $pack "index.html") -Encoding UTF8

$failed = @($manifest.scenes | ? { $_.failure }).Count
# the demo window's log stays for a failed scene
if (-not $failed) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue } else { Write-Host "work folder kept: $work" }
Write-Host "feature pack: $pack ($($manifest.scenes.Count) scenes, $failed failed)"
exit [int]($failed -gt 0)
