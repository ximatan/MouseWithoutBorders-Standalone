[CmdletBinding()]
param(
    [string]$Repo = "C:\Users\nike2\source\repos\ximatan\MouseWithoutBorders-Standalone",
    [string]$SourceTag = "v0.102.3001",
    [string]$PowerToysVersion = "0.102.3001.0",
    [string]$ReleaseLabel = "v0.102.3001",
    [switch]$SkipService,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# Intentionally do not enable StrictMode globally. The upstream build-common.ps1
# accesses .Count on Get-ChildItem results and expects Windows PowerShell's
# default scalar/array behavior for one-project directories.

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host "`n========== $Title ==========" -ForegroundColor Cyan
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-NoProcessesInReleaseDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (!(Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }

    $prefix = [IO.Path]::GetFullPath($Directory).TrimEnd('\') + '\'
    try {
        $processes = @(
            Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
                Where-Object {
                    $_.ExecutablePath -and
                    $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
                }
        )
    }
    catch {
        throw "无法检查发布目录中的运行进程。为避免覆盖正在使用的程序，发布已中止。原始错误：$($_.Exception.Message)"
    }

    if ($processes.Count -gt 0) {
        $details = $processes |
            Select-Object Name, ProcessId, ExecutablePath |
            Format-Table -AutoSize |
            Out-String

        throw @"
检测到旧发布目录中仍有程序正在运行，不能安全替换：
$Directory

运行中的进程：
$details

请从系统托盘正常退出该目录中的 Mouse Without Borders 主程序和 Helper，
重新运行本脚本。脚本不会自动结束进程。
"@
    }
}

function Invoke-MwbPublish {
    param(
        [Parameter(Mandatory = $true)][string]$BuildScript,
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [Parameter(Mandatory = $true)][string]$PublishDirectory,
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [Parameter(Mandatory = $true)][string]$ExpectedExe
    )

    if (!(Test-Path -LiteralPath $ProjectDirectory -PathType Container)) {
        throw "$ComponentName 项目目录不存在：$ProjectDirectory"
    }

    New-Item -ItemType Directory -Path $PublishDirectory -Force | Out-Null
    $publishPath = [IO.Path]::GetFullPath($PublishDirectory).TrimEnd('\') + '\'

    Write-Host "发布 $ComponentName ..." -ForegroundColor Yellow
    Write-Host "项目：$ProjectDirectory"
    Write-Host "输出：$publishPath"

    # Keep these as explicit named parameters. MSBuild options after -Path are
    # positional extras consumed by build.ps1's ValueFromRemainingArguments.
    Set-StrictMode -Off
    $global:LASTEXITCODE = 0
    & $BuildScript `
        -Platform 'x64' `
        -Configuration 'Release' `
        -Path $ProjectDirectory `
        '/restore' `
        '/t:Publish' `
        '/p:RuntimeIdentifier=win-x64' `
        '/p:SelfContained=true' `
        '/p:RestorePackagesConfig=true' `
        "/p:PublishDir=$publishPath"

    $buildExitCode = $global:LASTEXITCODE
    if ($buildExitCode -ne 0) {
        throw "$ComponentName 发布失败，退出代码：$buildExitCode"
    }

    $expectedPath = Join-Path $PublishDirectory $ExpectedExe
    if (!(Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
        throw "$ComponentName 发布未生成预期程序：$expectedPath"
    }
}

function Copy-PublishTree {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $sourceRoot = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    $conflicts = New-Object 'System.Collections.Generic.List[string]'

    Get-ChildItem -LiteralPath $sourceRoot -File -Recurse |
        Where-Object { $_.Extension -ne '.pdb' } |
        ForEach-Object {
            $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
            $destination = Join-Path $DestinationDirectory $relative
            $destinationParent = Split-Path -Parent $destination
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null

            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $sourceHash = Get-Sha256 -Path $_.FullName
                $targetHash = Get-Sha256 -Path $destination
                if ($sourceHash -ne $targetHash) {
                    $conflicts.Add($relative)
                }
            }
            else {
                Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
            }
        }

    if ($conflicts.Count -gt 0) {
        $message = "检测到不同项目发布文件发生同名冲突：`n - " + ($conflicts -join "`n - ")
        throw "$message`n为避免覆盖不同版本的依赖，脚本已停止。请提供冲突清单。"
    }
}

function Assert-RequiredFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Files,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $missing = @()
    foreach ($file in $Files) {
        if (!(Test-Path -LiteralPath (Join-Path $Directory $file) -PathType Leaf)) {
            $missing += $file
        }
    }

    if ($missing.Count -gt 0) {
        throw "$Context 缺少必要文件：`n - $($missing -join "`n - ")"
    }
}

function Move-ExistingOutputsToBackup {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$BackupDirectory
    )

    $existing = @($Paths | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -eq 0) {
        return $null
    }

    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    $movedOriginals = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($path in $existing) {
            $leaf = Split-Path -Leaf $path
            $backupPath = Join-Path $BackupDirectory $leaf
            Move-Item -LiteralPath $path -Destination $backupPath -ErrorAction Stop
            $movedOriginals.Add($path)
            Write-Host "旧发布产物已备份：$backupPath" -ForegroundColor DarkYellow
        }
    }
    catch {
        $backupError = $_.Exception.Message
        foreach ($originalPath in $movedOriginals) {
            $savedPath = Join-Path $BackupDirectory (Split-Path -Leaf $originalPath)
            if (Test-Path -LiteralPath $savedPath) {
                Move-Item -LiteralPath $savedPath -Destination $originalPath -ErrorAction SilentlyContinue
            }
        }
        throw "备份旧发布产物时失败：$backupError。脚本已尝试恢复已移动的旧文件。请检查：$BackupDirectory"
    }

    return $BackupDirectory
}

# ---------- Validate inputs and repository layout ----------
$Repo = [IO.Path]::GetFullPath($Repo)
$ReleaseLabel = $ReleaseLabel.Trim()
if ([string]::IsNullOrWhiteSpace($ReleaseLabel) -or $ReleaseLabel -match '[\\/:*?"<>|]') {
    throw "ReleaseLabel 不能为空，也不能包含 Windows 文件名非法字符。"
}

if (!(Test-Path -LiteralPath $Repo -PathType Container)) {
    throw "仓库目录不存在：$Repo"
}

$buildScript = Join-Path $Repo 'tools\build\build.ps1'
$appProject = Join-Path $Repo 'src\modules\MouseWithoutBorders\App'
$helperProject = Join-Path $Repo 'src\modules\MouseWithoutBorders\App\Helper'
$serviceProject = Join-Path $Repo 'src\modules\MouseWithoutBorders\App\Service'

foreach ($requiredPath in @($buildScript, $appProject, $helperProject)) {
    if (!(Test-Path -LiteralPath $requiredPath)) {
        throw "缺少构建所需路径：$requiredPath"
    }
}
if (!$SkipService -and !(Test-Path -LiteralPath $serviceProject)) {
    throw "Service 项目目录不存在：$serviceProject。若本次不打包 Service，请添加 -SkipService。"
}

$outRoot = Join-Path $Repo 'out'
$releaseRoot = Join-Path $outRoot 'Release'
$releaseName = "MWB-Portable-$ReleaseLabel"
$releaseDirectory = Join-Path $releaseRoot $releaseName
$zipPath = Join-Path $outRoot "$releaseName.zip"
$shaPath = "$zipPath.sha256"
$workRoot = Join-Path $outRoot ("_MWB-ReleaseWork-" + [guid]::NewGuid().ToString('N'))

New-Item -ItemType Directory -Path $outRoot -Force | Out-Null
New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

$existingOutputs = @(
    @($releaseDirectory, $zipPath, $shaPath) |
        Where-Object { Test-Path -LiteralPath $_ }
)
if ($existingOutputs.Count -gt 0 -and !$Force) {
    throw "发布输出已存在。新版脚本会在 -Force 时自动备份旧产物；如确认要替换，请添加 -Force：`n$($existingOutputs -join "`n")"
}

# Fail early if the exact release folder is still running. Check again just
# before promotion to cover the case where the user launches it during build.
if (Test-Path -LiteralPath $releaseDirectory -PathType Container) {
    Assert-NoProcessesInReleaseDirectory -Directory $releaseDirectory
}

# Git metadata is recorded for traceability. Dirty worktrees are allowed.
$gitCommit = 'unknown'
$gitBranch = 'unknown'
$gitStatus = 'Git metadata unavailable'
try {
    $gitCommitResult = & git -C $Repo rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitCommitResult) {
        $gitCommit = ($gitCommitResult | Out-String).Trim()
    }
    $gitBranchResult = & git -C $Repo branch --show-current 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitBranchResult) {
        $gitBranch = ($gitBranchResult | Out-String).Trim()
    }
    $gitStatusResult = & git -C $Repo status --short 2>$null
    if ($LASTEXITCODE -eq 0) {
        $gitStatus = ($gitStatusResult | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($gitStatus)) { $gitStatus = 'Clean' }
    }
}
catch {
    Write-Warning "无法读取 Git 元数据：$($_.Exception.Message)"
}

$backupDirectory = $null
$promotedPaths = New-Object 'System.Collections.Generic.List[string]'

try {
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $appStage = Join-Path $workRoot 'App'
    $helperStage = Join-Path $workRoot 'Helper'
    $serviceStage = Join-Path $workRoot 'Service'
    $packageStage = Join-Path $workRoot 'Package'
    $stagedReleaseDirectory = Join-Path $workRoot $releaseName
    $stagedZipPath = Join-Path $workRoot "$releaseName.zip"
    $stagedShaPath = "$stagedZipPath.sha256"

    Write-Section '1/7 编译发布 App'
    Invoke-MwbPublish -BuildScript $buildScript -ProjectDirectory $appProject `
        -PublishDirectory $appStage -ComponentName 'App' `
        -ExpectedExe 'PowerToys.MouseWithoutBorders.exe'

    Write-Section '2/7 编译发布 Helper'
    Invoke-MwbPublish -BuildScript $buildScript -ProjectDirectory $helperProject `
        -PublishDirectory $helperStage -ComponentName 'Helper' `
        -ExpectedExe 'PowerToys.MouseWithoutBordersHelper.exe'

    if (!$SkipService) {
        Write-Section '3/7 编译发布 Service'
        Invoke-MwbPublish -BuildScript $buildScript -ProjectDirectory $serviceProject `
            -PublishDirectory $serviceStage -ComponentName 'Service' `
            -ExpectedExe 'PowerToys.MouseWithoutBordersService.exe'
    }
    else {
        Write-Section '3/7 跳过 Service'
    }

    Write-Section '4/7 组装并检查便携目录'
    New-Item -ItemType Directory -Path $packageStage -Force | Out-Null

    # App and Helper must remain beside each other. Service is also kept beside
    # App because Worker.cs locates the main application relative to Service.
    Copy-PublishTree -SourceDirectory $appStage -DestinationDirectory $packageStage
    Copy-PublishTree -SourceDirectory $helperStage -DestinationDirectory $packageStage
    if (!$SkipService) {
        Copy-PublishTree -SourceDirectory $serviceStage -DestinationDirectory $packageStage
    }

    $requiredMainFiles = @(
        'PowerToys.MouseWithoutBorders.exe',
        'PowerToys.MouseWithoutBorders.dll',
        'PowerToys.MouseWithoutBorders.deps.json',
        'PowerToys.MouseWithoutBorders.runtimeconfig.json',
        'PowerToys.MouseWithoutBordersHelper.exe',
        'PowerToys.MouseWithoutBordersHelper.dll',
        'PowerToys.MouseWithoutBordersHelper.deps.json',
        'PowerToys.MouseWithoutBordersHelper.runtimeconfig.json'
    )
    Assert-RequiredFiles -Directory $packageStage -Files $requiredMainFiles -Context '便携目录'

    $requiredServiceFiles = @(
        'PowerToys.MouseWithoutBordersService.exe',
        'PowerToys.MouseWithoutBordersService.dll',
        'PowerToys.MouseWithoutBordersService.deps.json',
        'PowerToys.MouseWithoutBordersService.runtimeconfig.json'
    )
    if (!$SkipService) {
        Assert-RequiredFiles -Directory $packageStage -Files $requiredServiceFiles -Context 'Service 发布目录'
    }

    foreach ($licenseName in @('LICENSE', 'LICENSE.txt', 'NOTICE', 'NOTICE.txt', 'ThirdPartyNotices.txt')) {
        $licenseSource = Join-Path $Repo $licenseName
        if (Test-Path -LiteralPath $licenseSource -PathType Leaf) {
            Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $packageStage $licenseName) -Force
        }
    }

    $appExe = Join-Path $packageStage 'PowerToys.MouseWithoutBorders.exe'
    $appVersionInfo = (Get-Item -LiteralPath $appExe).VersionInfo
    $actualFileVersion = $appVersionInfo.FileVersion
    $actualProductVersion = $appVersionInfo.ProductVersion

    @"
Microsoft PowerToys - Mouse Without Borders
Standalone Portable Release

PowerToys source tag: $SourceTag
PowerToys product version: $PowerToysVersion
Mouse Without Borders FileVersion: $actualFileVersion
Mouse Without Borders ProductVersion: $actualProductVersion
Architecture: x64
Runtime: .NET self-contained (win-x64)
Build configuration: Release
Build date (local): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Git branch: $gitBranch
Git commit: $gitCommit
Git working tree: $gitStatus

Main application and Helper are placed together in this directory.
Run PowerToys.MouseWithoutBorders.exe to start the application.
Helper is launched by the application and supports clipboard/file-transfer features.

$(if ($SkipService) { 'Optional Service component: NOT INCLUDED.' } else { 'Optional Service component: included beside the main application. Special desktop/service installation is not validated by this release script.' })

This package does not include the complete PowerToys application.
"@ | Set-Content -LiteralPath (Join-Path $packageStage 'VERSION.txt') -Encoding UTF8

    @"
Mouse Without Borders Standalone Portable

普通桌面使用：
1. 将整个 MWB-Portable 文件夹解压到任意目录。
2. 不要移动主程序目录中的 DLL、deps.json、runtimeconfig.json 等依赖文件。
3. 在每台电脑上运行 PowerToys.MouseWithoutBorders.exe。
4. 在两台电脑上配置相同的安全密钥。
5. 设置与实际摆放位置一致的电脑布局，并启用 Easy Mouse。
6. 测试鼠标、键盘、文本/图片剪贴板及文件传输。

主程序和 Helper 必须位于同一目录。Helper 由主程序自动启动。

$(if ($SkipService) { '本包未包含 Service。' } else { '可选 Service 文件与主程序放在同一目录，因为 Service 会从自身目录定位主程序。该组件的特殊桌面功能、服务注册及卸载尚未由本脚本验收；普通桌面共享不需要安装它。不要双击运行 Service EXE。' })

FILES.sha256 包含包内其他文件的 SHA256 清单，不包含其自身。
本包不包含完整 PowerToys 套件。建议在未安装完整 PowerToys 的 Windows 电脑上进行独立运行验收。
"@ | Set-Content -LiteralPath (Join-Path $packageStage 'README.txt') -Encoding UTF8

    # Create an internal per-file hash manifest (self-reference intentionally excluded).
    $manifestLines = New-Object 'System.Collections.Generic.List[string]'
    $packageFiles = @(Get-ChildItem -LiteralPath $packageStage -File -Recurse | Sort-Object FullName)
    foreach ($file in $packageFiles) {
        $relative = $file.FullName.Substring($packageStage.Length).TrimStart('\') -replace '\\', '/'
        $hash = Get-Sha256 -Path $file.FullName
        $manifestLines.Add("$hash  $relative")
    }
    $manifestPath = Join-Path $packageStage 'FILES.sha256'
    $manifestLines.ToArray() | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    # Freeze the complete package directory in the work area. The current live
    # release is not touched until ZIP extraction and hash checks all pass.
    New-Item -ItemType Directory -Path $stagedReleaseDirectory -Force | Out-Null
    Copy-PublishTree -SourceDirectory $packageStage -DestinationDirectory $stagedReleaseDirectory

    Write-Section '5/7 创建临时发布目录'
    Assert-RequiredFiles -Directory $stagedReleaseDirectory -Files $requiredMainFiles -Context '临时发布目录'
    if (!$SkipService) {
        Assert-RequiredFiles -Directory $stagedReleaseDirectory -Files $requiredServiceFiles -Context '临时发布目录 Service'
    }

    Write-Section '6/7 生成临时 ZIP 和 SHA256'
    Compress-Archive -Path $stagedReleaseDirectory -DestinationPath $stagedZipPath -CompressionLevel Optimal
    $stagedZipHash = Get-Sha256 -Path $stagedZipPath
    "$stagedZipHash  $([IO.Path]::GetFileName($zipPath))" |
        Set-Content -LiteralPath $stagedShaPath -Encoding ASCII

    Write-Section '7/7 解压、文件清单和 SHA256 验证'
    $verifyDirectory = Join-Path $workRoot 'Verify'
    Expand-Archive -LiteralPath $stagedZipPath -DestinationPath $verifyDirectory -Force
    $verifiedReleaseDirectory = Join-Path $verifyDirectory $releaseName
    if (!(Test-Path -LiteralPath $verifiedReleaseDirectory -PathType Container)) {
        throw 'ZIP 解压后未找到预期顶层目录。'
    }

    Assert-RequiredFiles -Directory $verifiedReleaseDirectory -Files $requiredMainFiles -Context 'ZIP 解压验证'
    if (!$SkipService) {
        Assert-RequiredFiles -Directory $verifiedReleaseDirectory -Files $requiredServiceFiles -Context 'ZIP 解压验证 Service'
    }
    Assert-RequiredFiles -Directory $verifiedReleaseDirectory -Files @('README.txt', 'VERSION.txt', 'FILES.sha256') -Context 'ZIP 文档验证'

    # Verify every file that was included in FILES.sha256.
    $manifestRead = Get-Content -LiteralPath (Join-Path $verifiedReleaseDirectory 'FILES.sha256')
    foreach ($line in $manifestRead) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([A-Fa-f0-9]{64})  (.+)$') {
            throw "FILES.sha256 格式无效：$line"
        }
        $expectedFileHash = $matches[1].ToUpperInvariant()
        $relativeFile = $matches[2] -replace '/', '\'
        $verifiedFile = Join-Path $verifiedReleaseDirectory $relativeFile
        if (!(Test-Path -LiteralPath $verifiedFile -PathType Leaf)) {
            throw "ZIP 解压后缺少清单文件：$relativeFile"
        }
        $actualFileHash = Get-Sha256 -Path $verifiedFile
        if ($actualFileHash -ne $expectedFileHash) {
            throw "ZIP 解压文件哈希不匹配：$relativeFile"
        }
    }

    $expectedZipHash = (Get-Content -LiteralPath $stagedShaPath -Raw).Trim().Split()[0].ToUpperInvariant()
    $actualZipHash = Get-Sha256 -Path $stagedZipPath
    if ($expectedZipHash -ne $actualZipHash) {
        throw '临时 ZIP 的 SHA256 校验失败。'
    }

    # Re-check immediately before promotion: the app may have been launched while
    # the build was running. Do not terminate it automatically.
    if (Test-Path -LiteralPath $releaseDirectory -PathType Container) {
        Assert-NoProcessesInReleaseDirectory -Directory $releaseDirectory
    }

    $pathsToPromote = @($releaseDirectory, $zipPath, $shaPath)
    $currentExisting = @($pathsToPromote | Where-Object { Test-Path -LiteralPath $_ })
    if ($currentExisting.Count -gt 0 -and !$Force) {
        throw "发布期间发现目标文件已出现，且未指定 -Force：`n$($currentExisting -join "`n")"
    }

    # Keep old artifacts as a rollback set. Only move them after the new build,
    # ZIP extraction, internal file hashes and ZIP SHA256 have all passed.
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupDirectoryCandidate = Join-Path $outRoot ("ReleaseBackups\$releaseName-$timestamp")
    if ($currentExisting.Count -gt 0) {
        $backupDirectory = Move-ExistingOutputsToBackup -Paths $pathsToPromote -BackupDirectory $backupDirectoryCandidate
    }

    try {
        New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null
        Move-Item -LiteralPath $stagedReleaseDirectory -Destination $releaseDirectory -ErrorAction Stop
        $promotedPaths.Add($releaseDirectory)
        Move-Item -LiteralPath $stagedZipPath -Destination $zipPath -ErrorAction Stop
        $promotedPaths.Add($zipPath)
        Move-Item -LiteralPath $stagedShaPath -Destination $shaPath -ErrorAction Stop
        $promotedPaths.Add($shaPath)
    }
    catch {
        $promotionError = $_.Exception.Message
        foreach ($path in $promotedPaths) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        if ($backupDirectory -and (Test-Path -LiteralPath $backupDirectory)) {
            foreach ($originalPath in $pathsToPromote) {
                $savedPath = Join-Path $backupDirectory (Split-Path -Leaf $originalPath)
                if (Test-Path -LiteralPath $savedPath) {
                    Move-Item -LiteralPath $savedPath -Destination $originalPath -ErrorAction SilentlyContinue
                }
            }
        }

        throw "发布文件替换失败：$promotionError。脚本已尝试回滚旧版文件；请检查 ReleaseBackups 目录。"
    }

    # Final post-promotion checks.
    Assert-RequiredFiles -Directory $releaseDirectory -Files $requiredMainFiles -Context '最终发布目录'
    $finalHash = Get-Sha256 -Path $zipPath
    $finalExpectedHash = (Get-Content -LiteralPath $shaPath -Raw).Trim().Split()[0].ToUpperInvariant()
    if ($finalHash -ne $finalExpectedHash) {
        throw '最终发布目录已更新，但 ZIP 与 SHA256 文件不匹配，请检查输出。'
    }

    Write-Host "`n发布成功！" -ForegroundColor Green
    [PSCustomObject]@{
        ReleaseDirectory  = $releaseDirectory
        Zip               = $zipPath
        Sha256File        = $shaPath
        BackupDirectory   = $backupDirectory
        ZipSizeMB         = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
        SHA256            = $finalHash
        AppFileVersion    = $actualFileVersion
        AppProductVersion = $actualProductVersion
        ServiceIncluded   = (!$SkipService)
        Verification      = 'Passed (extract + internal file hashes + ZIP SHA256)'
    } | Format-List
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
