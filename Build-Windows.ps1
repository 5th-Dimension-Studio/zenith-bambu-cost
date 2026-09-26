param([string]$WorkDirectory = (Join-Path $PSScriptRoot 'work'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Run([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
foreach ($tool in @('git','cmake','perl')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing $tool. Install the prerequisites in README.md first."
    }
}
# Select the real Windows executable, not Strawberry Perl's extensionless script.
# The workflow already installs pkgconfiglite through Chocolatey.
$ChocoRoot = $env:ChocolateyInstall
if ([string]::IsNullOrWhiteSpace($ChocoRoot)) {
    $ChocoRoot = Join-Path $env:ProgramData 'chocolatey'
}
$PkgRoot = Join-Path $ChocoRoot 'lib/pkgconfiglite'
$PkgCandidates = @(Get-ChildItem -LiteralPath $PkgRoot -Filter 'pkg-config.exe' -File -Recurse -ErrorAction SilentlyContinue)
if ($PkgCandidates.Count -eq 0) {
    throw 'pkgconfiglite executable not found. Ensure the workflow installs pkgconfiglite using Chocolatey.'
}
$PkgConfigExe = $null
foreach ($Candidate in $PkgCandidates) {
    try {
        $VersionOutput = & $Candidate.FullName --version
        if ($LASTEXITCODE -eq 0 -and $VersionOutput) {
            $PkgConfigExe = $Candidate.FullName
            Write-Host "Using pkg-config: $PkgConfigExe (version $VersionOutput)"
            break
        }
    } catch {
        Write-Warning "Could not execute $($Candidate.FullName)"
    }
}
if (-not $PkgConfigExe) { throw 'No working pkgconfiglite executable found; stopping before the long build.' }
$env:PKG_CONFIG = $PkgConfigExe
$env:Path = (Split-Path -Parent $PkgConfigExe) + ';' + $env:Path
$PkgConfigArgument = "-DPKG_CONFIG_EXECUTABLE:FILEPATH=$PkgConfigExe"

$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
$Source = Join-Path $WorkDirectory 'BambuStudio'
$Revision = '3f126b717ed1f10fee0f32f05ed9731808d0c8bb'
$Patch = Join-Path $PSScriptRoot 'zenith-cost.patch'
if (-not (Test-Path $Source)) {
    Run 'git' @('clone','--depth','1','--branch','v02.07.01.57','https://github.com/bambulab/BambuStudio.git',$Source)
}
$Head = & git -C $Source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $Head.Trim() -ne $Revision) { throw 'Source revision does not match 2.7.1.57. Use a fresh work directory.' }
# A rerun may reuse the exact patch, but never overwrite unrelated local edits.
# Windows PowerShell 5 may treat a native stderr line as a terminating error.
$ErrorActionPreference = 'Continue'
& git -C $Source apply --reverse --check $Patch 2>$null
$AlreadyApplied = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
if (-not $AlreadyApplied) {
    $Changes = & git -C $Source status --porcelain
    if ($LASTEXITCODE -ne 0 -or $Changes) { throw 'Source has local changes. Use a fresh work directory.' }
    Run 'git' @('-C',$Source,'apply','--check',$Patch)
    Run 'git' @('-C',$Source,'apply',$Patch)
}
$Tests = Join-Path $WorkDirectory 'cost-tests'
Run 'cmake' @('-S',(Join-Path $Source 'zenith/tests'),'-B',$Tests,'-G','Visual Studio 17 2022','-A','x64')
Run 'cmake' @('--build',$Tests,'--config','Release','--parallel','2')
Run 'ctest' @('--test-dir',$Tests,'-C','Release','--output-on-failure')
$DepsBuild = Join-Path $Source 'deps/build'
$DepsDest = Join-Path $DepsBuild 'BambuStudio_dep'
Run 'cmake' @('-S',(Join-Path $Source 'deps'),'-B',$DepsBuild,'-G','Visual Studio 17 2022','-A','x64',"-DDESTDIR=$DepsDest",'-DCMAKE_BUILD_TYPE=Release','-DDEP_DEBUG=OFF',$PkgConfigArgument)
Run 'cmake' @('--build',$DepsBuild,'--config','Release','--parallel','2')
$Build = Join-Path $Source 'build'
$Install = Join-Path $WorkDirectory 'Zenith-BambuStudio-Windows'
Run 'cmake' @('-S',$Source,'-B',$Build,'-G','Visual Studio 17 2022','-A','x64','-DBBL_RELEASE_TO_PUBLIC=1','-DBBL_INTERNAL_TESTING=0',"-DCMAKE_PREFIX_PATH=$DepsDest/usr/local","-DCMAKE_INSTALL_PREFIX=$Install",'-DCMAKE_BUILD_TYPE=Release',$PkgConfigArgument)
Run 'cmake' @('--build',$Build,'--target','install','--config','Release','--parallel','2')
Write-Host "Build completed. Application files: $Install"
Write-Host 'Run the Windows acceptance checklist in README.md before using this custom build.'
