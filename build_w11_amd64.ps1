#requires -Version 7
# Full Windows 11 amd64 build: static, dependency-free mdbtools command-line tools.
# Usage: .\build_w11_amd64.ps1      -> dist\w11\amd64\   (see README-BUILD.txt)
# Exit codes: 0 ok, 1 build/test failure, 2 wrong machine or dirty tree, 3 tool download failure.
# No autotools: the few values ./configure would compute are fixed below for the mingw-w64 UCRT target.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = $PSScriptRoot
$ZigVersion = '0.17.1'
$ZigName = "zig-x86_64-windows-$ZigVersion"
$ZigUrl = "https://ziglang.org/download/$ZigVersion/$ZigName.zip"
$ZigSha256 = 'b03f477a1943673e02aca0f570e8030dffd536ce1f45cbc4d3326ec31159562e'
$Tools = 'mdb-tables', 'mdb-schema', 'mdb-export', 'mdb-count', 'mdb-ver', 'mdb-json'
# Only DLLs that are part of Windows 10/11 may be imported (UCRT api sets + kernel32/ntdll).
$AllowedDll = '^(kernel32|ntdll|ucrtbase|api-ms-win-crt-[a-z]+-l1-1-0)\.dll$'

function Fail([int]$Code, [string]$Message) { Write-Host "ERROR: $Message" -ForegroundColor Red; exit $Code }
function Run([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { Fail 1 "$(Split-Path $Exe -Leaf) $($Arguments[0..2] -join ' ') ... exited with $LASTEXITCODE" }
}

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Fail 2 "this command builds on Windows amd64 only (host: $env:PROCESSOR_ARCHITECTURE)" }
$dirty = git -C $Root status --porcelain
if ($dirty) { $dirty | Write-Host; Fail 2 'uncommitted changes; commit first (the package must match a commit)' }
$Source = git -C $Root describe --tags --always --long
if ($LASTEXITCODE -ne 0) { Fail 2 'git describe failed' }
Write-Host "Source: $Source"

if ((Get-Content "$Root\configure.ac" -Raw) -notmatch 'AC_INIT\(\[mdbtools\],\[([0-9.]+)\]') { Fail 1 'version not found in configure.ac' }
$Version = $Matches[1]
$Product = "mdbtools-$Version-w11-amd64"

# --- pinned compiler: Zig (clang + mingw-w64 UCRT headers/libs in one archive) ---
$Zig = "$Root\.tools\$ZigName\zig.exe"
if (-not (Test-Path $Zig)) {
    New-Item -ItemType Directory -Force "$Root\.tools" | Out-Null
    $zip = "$Root\.tools\$ZigName.zip"
    if (-not (Test-Path $zip)) { Write-Host "Downloading $ZigUrl" }
    try { if (-not (Test-Path $zip)) { Invoke-WebRequest $ZigUrl -OutFile $zip } } catch { Fail 3 "download failed: $_" }
    $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $ZigSha256) { Remove-Item $zip; Fail 3 "sha256 mismatch for $ZigName.zip: $got" }
    # Windows' own bsdtar reads zip and is much faster than Expand-Archive (a GNU tar earlier in PATH would not).
    & "$env:SystemRoot\System32\tar.exe" -xf $zip -C "$Root\.tools"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Zig)) { Fail 3 "could not extract $zip" }
    Remove-Item $zip
}
if ((& $Zig version) -ne $ZigVersion) { Fail 3 "$Zig is not version $ZigVersion" }

$Build = "$Root\build.stage.$PID"
$Stage = "$Root\dist\.stage"
foreach ($dir in $Build, $Stage) { if (Test-Path $dir) { Remove-Item -Recurse -Force $dir } }
New-Item -ItemType Directory -Force "$Build\include", "$Build\obj", "$Stage\$Product" | Out-Null
$env:ZIG_LOCAL_CACHE_DIR = "$Build\zig-cache"

try {
    # --- headers that ./configure would generate (no iconv, no GLib: the bundled fake glib is used) ---
    (Get-Content "$Root\include\mdbtools.h.in" -Raw).
        Replace('@HAVE_ICONV_H@', '0').Replace('@HAVE_XLOCALE_H@', '0').
        Replace('@GLIB_INCLUDE_HEADER@', 'mdbfakeglib.h').Replace('@LOCALE_T@', 'locale_t') |
        Set-Content "$Build\include\mdbtools.h" -NoNewline
    (Get-Content "$Root\include\mdbver.h.in" -Raw).Replace('@PACKAGE@', 'mdbtools').Replace('@VERSION@', $Version) |
        Set-Content "$Build\include\mdbver.h" -NoNewline

    # -s: no debug info (and no build paths) in the executables. TLS/HAVE_VASPRINTF: what configure detects on mingw-w64.
    $cflags = '-target', 'x86_64-windows-gnu', '-O2', '-s', '-w', '-D_GNU_SOURCE', '-DHAVE_VASPRINTF=1', '-DTLS=__thread',
        "-I$Build\include", "-I$Root\include"
    $libSources = (Get-ChildItem "$Root\src\libmdb\*.c").FullName + "$Root\scripts\win\binmode.c"
    $objects = foreach ($source in $libSources) {
        $object = "$Build\obj\$([IO.Path]::GetFileNameWithoutExtension($source)).o"
        Run $Zig (@('cc', '-c') + $cflags + @('-o', $object, $source))
        $object
    }

    foreach ($tool in $Tools) {
        $exe = "$Stage\$Product\$tool.exe"
        Run $Zig (@('cc') + $cflags + @('-o', $exe, "$Root\src\util\$tool.c", "$Root\scripts\win\utf8.manifest") + $objects)

        # --- checks on the finished executable ---
        $out = & $exe --version
        if ($LASTEXITCODE -ne 0 -or "$out" -notmatch [regex]::Escape($Version)) { Fail 1 "$tool.exe --version failed: $out" }
        $text = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($exe))
        # Every ".dll" string in the image (a superset of the import table) must be a Windows system DLL.
        $dlls = [regex]::Matches($text, '[A-Za-z0-9_.-]+\.dll') | ForEach-Object Value | Sort-Object -Unique
        $foreign = @($dlls | Where-Object { $_ -notmatch $AllowedDll })
        if (-not $dlls -or $foreign) { Fail 1 "$tool.exe depends on non-system DLLs: $($foreign -join ', ')" }
        foreach ($secret in $env:USERNAME, $env:COMPUTERNAME) {
            foreach ($needle in $secret, ($secret.ToCharArray() -join "`0")) {
                if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail 1 "$tool.exe contains the user or machine name" }
            }
        }
        Write-Host ("  {0,-15} {1,8} bytes  imports: {2}" -f "$tool.exe", (Get-Item $exe).Length, ($dlls -join ' '))
    }

    Copy-Item "$Root\COPYING", "$Root\COPYING.LIB" "$Stage\$Product"
    "mdbtools $Version ($Source) - Windows amd64, static, no iconv/GLib. Source and build: README-BUILD.txt in the repository." |
        Set-Content "$Stage\$Product\VERSION.txt"
    Compress-Archive -Path "$Stage\$Product" -DestinationPath "$Stage\$Product.zip"
    Copy-Item "$Stage\$Product\*.exe" $Stage
    Remove-Item -Recurse -Force "$Stage\$Product"
    Get-ChildItem $Stage -File | Sort-Object Name | ForEach-Object {
        "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    } | Set-Content "$Stage\SHA256SUMS.txt"

    # Only now replace the previous products.
    $Dist = "$Root\dist\w11\amd64"
    if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
    New-Item -ItemType Directory -Force (Split-Path $Dist) | Out-Null
    Move-Item $Stage $Dist
    Write-Host "OK: $Dist"
    Get-ChildItem $Dist | ForEach-Object { Write-Host ("  {0,10}  {1}" -f $_.Length, $_.Name) }
}
finally {
    $env:ZIG_LOCAL_CACHE_DIR = $null
    if (Test-Path $Build) { Remove-Item -Recurse -Force $Build }
}
