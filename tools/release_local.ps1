<#
.SYNOPSIS
Builds, verifies, and packages a z2000 release locally, as v0.2.0-rc.2 was.

.DESCRIPTION
Runs on Windows with Zig 0.17, Git, and Docker Desktop (whose Linux VM runs
RISC-V binaries through binfmt QEMU), plus the GitHub CLI for -MacosRunId and
-CreateDraft. From a clean, pushed checkout whose VERSION and
docs/releases/<tag>.md match the tag, it:

  1. runs the native Debug and ReleaseFast tests and the Part 1 corpus;
  2. runs the ReleaseFast test suite for x86_64-linux-musl and, under QEMU,
     riscv64-linux-musl in a Linux container;
  3. builds the Windows x86-64, Linux x86-64, and Linux RISC-V 64 release
     binaries with the release workflow's flags and checks that both CLI
     names report the expected version;
  4. converts one fixture on every platform and requires identical output;
  5. takes the macOS arm64 archive from a hosted Release run or a given file
     (it cannot be run here) and checks its binaries, version, and notes;
  6. packages every archive like the Release workflow and writes and checks
     SHA256SUMS.

With -CreateDraft it then tags HEAD, pushes the tag, and creates a draft
GitHub release; publishing the draft is left to a person.

.EXAMPLE
.\tools\release_local.ps1 -Tag v0.2.0-rc.3 -MacosRunId 37301089282

.EXAMPLE
.\tools\release_local.ps1 -Tag v0.2.0-rc.3 -MacosArchive C:\dl\z2000-v0.2.0-rc.3-macos-aarch64.tar.gz -CreateDraft
#>
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$OutDir = "",
    [string]$Zig = "zig",
    [string]$DockerImage = "alpine:3.22",
    [string]$Repo = "bezverec/z2000",
    # The hosted Release workflow run whose release-macos-aarch64 artifact to use.
    [string]$MacosRunId = "",
    # Or a macOS archive already on disk.
    [string]$MacosArchive = "",
    [switch]$SkipMacos,
    [switch]$SkipGates,
    [switch]$SkipRiscvTests,
    [switch]$CreateDraft,
    # For trying the script from a local commit; refused with -CreateDraft.
    [switch]$AllowUnpushed
)

$ErrorActionPreference = "Stop"

function Invoke-NativeChecked([string]$Label, [string]$Exe, [string[]]$ArgList) {
    Write-Host "== $Label =="
    & $Exe @ArgList | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
}

function Get-NativeOutput([string]$Exe, [string[]]$ArgList) {
    $output = (& $Exe @ArgList 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($ArgList -join ' ') failed: $output" }
    return $output
}

function Invoke-Container([string]$Label, [string[]]$Mounts, [string]$Script) {
    $dockerArgs = @("run", "--rm")
    foreach ($mount in $Mounts) { $dockerArgs += @("-v", $mount) }
    $dockerArgs += @($DockerImage, "sh", "-c", $Script)
    Invoke-NativeChecked $Label "docker" $dockerArgs
}

function Get-ContainerOutput([string[]]$Mounts, [string]$Script) {
    $dockerArgs = @("run", "--rm")
    foreach ($mount in $Mounts) { $dockerArgs += @("-v", $mount) }
    $dockerArgs += @($DockerImage, "sh", "-c", $Script)
    return Get-NativeOutput "docker" $dockerArgs
}

function Assert-Equal([string]$Expected, [string]$Actual, [string]$Label) {
    if ($Expected -ne $Actual) { throw "$Label`: expected '$Expected', got '$Actual'" }
    Write-Host "$Label`: $Actual"
}

# --- Preconditions ---------------------------------------------------------

$root = Get-NativeOutput "git" @("rev-parse", "--show-toplevel")
Set-Location -LiteralPath $root

if ($Tag -notmatch '^v(\d+\.\d+\.\d+)(?:-(rc\.[1-9]\d*))?$') {
    throw "tag must look like v0.2.0 or v0.2.0-rc.3, got '$Tag'"
}
$baseVersion = $Matches[1]
$prerelease = $Matches[2]
$version = $Tag.Substring(1)

$versionFile = (Get-Content -LiteralPath (Join-Path $root "VERSION") -Raw).Trim()
if ($versionFile -ne $baseVersion) { throw "VERSION is $versionFile, but $Tag needs $baseVersion" }
$notesPath = Join-Path $root "docs\releases\$Tag.md"
# The archives carry the committed notes, so they must be part of HEAD.
& git cat-file -e "HEAD:docs/releases/$Tag.md" 2>$null
if ($LASTEXITCODE -ne 0) { throw "docs/releases/$Tag.md is not committed in HEAD" }

$macosSources = @($MacosRunId, $MacosArchive) | Where-Object { $_ -ne "" }
if (($macosSources.Count + [int][bool]$SkipMacos) -ne 1) {
    throw "choose exactly one macOS source: -MacosRunId, -MacosArchive, or -SkipMacos"
}

$dirty = Get-NativeOutput "git" @("status", "--porcelain", "--untracked-files=no")
if ($dirty) { throw "tracked files differ from HEAD; commit or stash them first:`n$dirty" }
$head = Get-NativeOutput "git" @("rev-parse", "HEAD")
if ($AllowUnpushed -and $CreateDraft) { throw "-AllowUnpushed is for trial runs and cannot be combined with -CreateDraft" }
if (-not $AllowUnpushed) {
    $upstream = Get-NativeOutput "git" @("rev-parse", "@{u}")
    if ($head -ne $upstream) { throw "HEAD $head is not the pushed upstream $upstream; push first" }
}
$tagCommit = (& git rev-parse -q --verify "refs/tags/$Tag^{commit}" 2>$null | Out-String).Trim()
if ($tagCommit -and $tagCommit -ne $head) { throw "tag $Tag already points to $tagCommit, not HEAD $head" }

$zigVersion = Get-NativeOutput $Zig @("version")
if (-not $zigVersion.StartsWith("0.17.")) { throw "Zig 0.17 is required, found $zigVersion" }
Get-NativeOutput "docker" @("info", "--format", "{{.OSType}}") | Out-Null
if ($MacosRunId -or $CreateDraft) { Get-NativeOutput "gh" @("--version") | Out-Null }

$buildNumber = Get-NativeOutput "git" @("rev-list", "--count", "HEAD")
$gitSha = Get-NativeOutput "git" @("rev-parse", "--short=8", "HEAD")
$expectedVersion = "z2000 $version+build.$buildNumber.g$gitSha"
Write-Host "Release $Tag from $head, expecting '$expectedVersion'"

if (-not $OutDir) { $OutDir = Join-Path $root "zig-out\release\$Tag" }
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force -Confirm:$false }
$work = Join-Path $OutDir "work"
$dist = Join-Path $OutDir "dist"
New-Item -ItemType Directory -Force -Path $work, $dist | Out-Null
$repoMount = "${root}:/w"
$workMount = "${work}:/o"

$releaseFlags = @(
    "-Drelease=true", "-Doptimize=ReleaseFast",
    "-Dbuild-number=$buildNumber", "-Dgit-sha=$gitSha", "-Dgit-dirty=false"
)
if ($prerelease) { $releaseFlags += "-Dprerelease=$prerelease" }

# --- Test gates --------------------------------------------------------------

if (-not $SkipGates) {
    Invoke-NativeChecked "native Debug tests" $Zig @("build", "test", "--summary", "all")
    Invoke-NativeChecked "native ReleaseFast tests" $Zig @("build", "test", "-Doptimize=ReleaseFast", "--summary", "all")
    Invoke-NativeChecked "Part 1 corpus" $Zig @("build", "part1-corpus", "-Doptimize=ReleaseFast")
}

$linuxTargets = @(@{ Target = "x86_64-linux-musl"; Platform = "linux-x86_64" })
if (-not $SkipRiscvTests) { $linuxTargets += @{ Target = "riscv64-linux-musl"; Platform = "linux-riscv64" } }
foreach ($entry in $linuxTargets) {
    $prefix = Join-Path $work "tests-$($entry.Platform)"
    Invoke-NativeChecked "$($entry.Platform) test build" $Zig @(
        "build", "test-bin", "-Dtarget=$($entry.Target)", "-Doptimize=ReleaseFast", "-p", $prefix
    )
    # The suite writes temporary files under .zig-cache relative to the
    # working directory, so it runs inside the checkout.
    Invoke-Container "$($entry.Platform) ReleaseFast tests in $DockerImage" @($repoMount, $workMount) `
        "cd /w && /o/tests-$($entry.Platform)/bin/z2000-tests"
}

# --- Release binaries --------------------------------------------------------

$builds = @(
    @{ Target = "native"; Platform = "windows-x86_64" },
    @{ Target = "x86_64-linux-musl"; Platform = "linux-x86_64" },
    @{ Target = "riscv64-linux-musl"; Platform = "linux-riscv64" }
)
foreach ($build in $builds) {
    $prefix = Join-Path $work "build-$($build.Platform)"
    Invoke-NativeChecked "$($build.Platform) release build" $Zig (@("build") + $releaseFlags + @("-Dtarget=$($build.Target)", "-p", $prefix))
}

$windowsBin = Join-Path $work "build-windows-x86_64\bin"
foreach ($name in @("z2000.exe", "z2k.exe")) {
    Assert-Equal $expectedVersion (Get-NativeOutput (Join-Path $windowsBin $name) @("--version")) "windows-x86_64 $name"
}
foreach ($platform in @("linux-x86_64", "linux-riscv64")) {
    foreach ($name in @("z2000", "z2k")) {
        try {
            $reported = Get-ContainerOutput @($workMount) "/o/build-$platform/bin/$name --version"
        } catch {
            if ($platform -eq "linux-riscv64") {
                throw "the RISC-V binary did not run in $DockerImage; the Docker VM needs a riscv64 binfmt handler (for example 'docker run --privileged --rm tonistiigi/binfmt --install riscv64'): $_"
            }
            throw
        }
        Assert-Equal $expectedVersion $reported "$platform $name"
    }
}

# Every platform must convert the same fixture to the same bytes.
$fixture = "src/testdata/imagemagick-tiff-rgb16-lzw-pred-msb.tif"
$smoke = Join-Path $work "smoke"
New-Item -ItemType Directory -Force -Path $smoke | Out-Null
Invoke-NativeChecked "windows-x86_64 smoke conversion" (Join-Path $windowsBin "z2000.exe") @(
    (Join-Path $root $fixture), (Join-Path $smoke "windows-x86_64.jp2"), "--threads", "1"
)
foreach ($platform in @("linux-x86_64", "linux-riscv64")) {
    Invoke-Container "$platform smoke conversion" @($repoMount, $workMount) `
        "/o/build-$platform/bin/z2000 /w/$fixture /o/smoke/$platform.jp2 --threads 1"
}
$smokeHashes = Get-ChildItem -LiteralPath $smoke -Filter *.jp2 | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
if (@($smokeHashes | Sort-Object -Unique).Count -ne 1) { throw "platforms disagree on the smoke conversion: $($smokeHashes -join ', ')" }
Write-Host "smoke conversion identical on all built platforms: $($smokeHashes[0])"

# --- macOS archive -----------------------------------------------------------

$macosName = "z2000-$Tag-macos-aarch64.tar.gz"
if (-not $SkipMacos) {
    $macosDir = Join-Path $work "macos"
    New-Item -ItemType Directory -Force -Path $macosDir | Out-Null
    if ($MacosRunId) {
        Invoke-NativeChecked "download macOS archive from run $MacosRunId" "gh" @(
            "run", "download", $MacosRunId, "--repo", $Repo, "--name", "release-macos-aarch64", "--dir", $macosDir
        )
        $MacosArchive = Join-Path $macosDir $macosName
    }
    if (-not (Test-Path -LiteralPath $MacosArchive)) { throw "macOS archive not found: $MacosArchive" }
    if ((Split-Path -Leaf $MacosArchive) -ne $macosName) { throw "expected a file named $macosName" }
    $extract = Join-Path $macosDir "extract"
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    Invoke-NativeChecked "unpack macOS archive" "tar" @("-xzf", $MacosArchive, "-C", $extract)
    $macosPackage = Join-Path $extract "z2000-$Tag-macos-aarch64"
    $macosMain = [System.IO.File]::ReadAllBytes((Join-Path $macosPackage "z2000"))
    $macosAlias = [System.IO.File]::ReadAllBytes((Join-Path $macosPackage "z2k"))
    if ([BitConverter]::ToString($macosMain[0..3]) -ne "CF-FA-ED-FE") { throw "macOS z2000 is not a 64-bit Mach-O executable" }
    if (-not [System.Linq.Enumerable]::SequenceEqual($macosMain, $macosAlias)) { throw "macOS z2000 and z2k differ" }
    $versionText = $expectedVersion.Substring("z2000 ".Length)
    if (-not [System.Text.Encoding]::ASCII.GetString($macosMain).Contains($versionText)) {
        throw "macOS binary does not embed $versionText; was it built from $head?"
    }
    $macosNotes = (Get-Content -LiteralPath (Join-Path $macosPackage "RELEASE_NOTES.md") -Raw) -replace "`r`n", "`n"
    $repoNotes = (Get-Content -LiteralPath $notesPath -Raw) -replace "`r`n", "`n"
    if ($macosNotes -ne $repoNotes) { throw "macOS RELEASE_NOTES.md differs from docs\releases\$Tag.md" }
    Copy-Item -LiteralPath $MacosArchive -Destination (Join-Path $dist $macosName)
    Write-Host "macos-aarch64: Mach-O, z2000 == z2k, embeds $versionText, notes match"
}

# --- Packaging -----------------------------------------------------------------

# Unix archives carry the committed (LF) text files and executable modes,
# packed in the container so the modes survive.
$text = Join-Path $work "text"
New-Item -ItemType Directory -Force -Path $text | Out-Null
foreach ($pair in @(@("README.md", "README.md"), @("LICENSE", "LICENSE"), @("VERSION", "VERSION"), @("docs/releases/$Tag.md", "RELEASE_NOTES.md"))) {
    # cmd redirection keeps the blob's bytes; PowerShell would re-encode them.
    $destination = Join-Path $text $pair[1]
    & cmd /c "git cat-file blob HEAD:$($pair[0]) > `"$destination`""
    if ($LASTEXITCODE -ne 0) { throw "git cat-file blob HEAD:$($pair[0]) failed" }
}
$distMount = "${dist}:/d"
foreach ($platform in @("linux-x86_64", "linux-riscv64")) {
    $package = "z2000-$Tag-$platform"
    Invoke-Container "package $platform" @($workMount, $distMount) (
        "set -e; cd /o; rm -rf pkg/$package; mkdir -p pkg/$package; " +
        "install -m 755 build-$platform/bin/z2000 build-$platform/bin/z2k pkg/$package/; " +
        "install -m 644 text/README.md text/LICENSE text/VERSION text/RELEASE_NOTES.md pkg/$package/; " +
        "tar -czf /d/$package.tar.gz --numeric-owner -C pkg $package"
    )
}

$windowsPackage = "z2000-$Tag-windows-x86_64"
$windowsStage = Join-Path $work "pkg\$windowsPackage"
New-Item -ItemType Directory -Force -Path $windowsStage | Out-Null
Copy-Item -LiteralPath (Join-Path $windowsBin "z2000.exe"), (Join-Path $windowsBin "z2k.exe") -Destination $windowsStage
Copy-Item -LiteralPath (Join-Path $root "README.md"), (Join-Path $root "LICENSE"), (Join-Path $root "VERSION") -Destination $windowsStage
Copy-Item -LiteralPath $notesPath -Destination (Join-Path $windowsStage "RELEASE_NOTES.md")
Compress-Archive -Path $windowsStage -DestinationPath (Join-Path $dist "$windowsPackage.zip") -Force

Invoke-Container "SHA256SUMS" @($distMount) "set -e; cd /d; sha256sum z2000-* > SHA256SUMS; sha256sum -c SHA256SUMS"
Get-Content -LiteralPath (Join-Path $dist "SHA256SUMS") | Out-Host

$assets = @(Get-ChildItem -LiteralPath $dist | Sort-Object Name | ForEach-Object { $_.FullName })
Write-Host "Release assets in $dist"

# --- Draft release -------------------------------------------------------------

$titleFlags = @("--title", "z2000 $version", "--notes-file", $notesPath)
$prereleaseFlag = @()
if ($prerelease) { $prereleaseFlag = @("--prerelease") }
if ($CreateDraft) {
    if (-not $tagCommit) {
        Invoke-NativeChecked "create tag $Tag" "git" @("tag", "-a", $Tag, $head, "-m", "z2000 $version")
    }
    Invoke-NativeChecked "push tag $Tag" "git" @("push", "origin", $Tag)
    Invoke-NativeChecked "create draft release" "gh" (@("release", "create", $Tag) + $assets + @(
        "--repo", $Repo, "--verify-tag", "--draft") + $prereleaseFlag + $titleFlags)
    Write-Host "Draft created; review it on https://github.com/$Repo/releases and publish it there."
} else {
    Write-Host "Not tagged or uploaded. To publish, rerun with -CreateDraft, or run:"
    Write-Host "  git tag -a $Tag $head -m `"z2000 $version`"; git push origin $Tag"
    Write-Host "  gh release create $Tag <assets in $dist> --repo $Repo --verify-tag --draft $($prereleaseFlag -join ' ') --title `"z2000 $version`" --notes-file $notesPath"
}
