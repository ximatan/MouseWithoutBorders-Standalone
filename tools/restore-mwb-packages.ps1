$ErrorActionPreference = "Stop"

# 仓库根目录
$repo = Split-Path $PSScriptRoot -Parent

# NuGet.exe
$nuget = Join-Path $PSScriptRoot "NuGet\nuget.exe"

# NuGet 配置
$configFile = Join-Path $repo "nuget.config"

# 包存放目录
$packageDir = Join-Path $repo "packages"

if (!(Test-Path $nuget)) {
    throw "找不到 NuGet.exe：$nuget"
}

if (!(Test-Path $configFile)) {
    throw "找不到 nuget.config：$configFile"
}

New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

Write-Host "NuGet.exe: $nuget" -ForegroundColor Cyan
Write-Host "Packages:  $packageDir" -ForegroundColor Cyan

# MWB 构建依赖的原生 NuGet 包配置
$projects = @(
    "src\common\logger\packages.config",
    "src\common\GPOWrapper\packages.config",
    "src\common\interop\packages.config",
    "src\common\SettingsAPI\packages.config"
)

foreach ($relativePath in $projects) {

    $configPath = Join-Path $repo $relativePath

    if (!(Test-Path $configPath)) {
        throw "缺少依赖配置文件：$configPath"
    }

    Write-Host "`n正在恢复：$relativePath" -ForegroundColor Yellow

    & $nuget restore $configPath `
        -PackagesDirectory $packageDir `
        -ConfigFile $configFile `
        -NonInteractive `
        -Verbosity normal

    $restoreExitCode = $LASTEXITCODE

    if ($restoreExitCode -ne 0) {
        throw "NuGet 恢复失败：$relativePath，退出代码：$restoreExitCode"
    }
}

# 检查必须存在的原生构建文件
$requiredFiles = @(
    "Microsoft.Windows.CppWinRT.2.0.250303.1\build\native\Microsoft.Windows.CppWinRT.props",
    "Microsoft.Windows.CppWinRT.2.0.250303.1\build\native\Microsoft.Windows.CppWinRT.targets",
    "Microsoft.Windows.ImplementationLibrary.1.0.260126.7\build\native\Microsoft.Windows.ImplementationLibrary.targets"
)

foreach ($relativeFile in $requiredFiles) {

    $fullPath = Join-Path $packageDir $relativeFile

    if (!(Test-Path $fullPath)) {
        throw "依赖文件仍然缺失：$fullPath"
    }

    Write-Host "[OK] $relativeFile" -ForegroundColor Green
}

Write-Host "`nMWB NuGet 依赖恢复成功！" -ForegroundColor Green