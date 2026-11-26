# Zips a staged app folder into a portable package, entries at the zip's root.
#   scripts\portable-zip.ps1 -Stage <folder> -Output <zip>
# Entry names are written with forward slashes: Windows PowerShell's ZipFile.CreateFromDirectory writes backslashes.
param(
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Output
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = (Get-Item $Stage).FullName.TrimEnd('\')
if (Test-Path $Output) { Remove-Item -Force $Output }
$archive = [IO.Compression.ZipFile]::Open($Output, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem $root -Recurse -File) {
        $name = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
}
