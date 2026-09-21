param(
    [string] $OutDir = 'dist'
)

# 从 src/ 编译出单文件 exe 到 dist/
# 用法: .\build.ps1
#
# 注意: param 必须是脚本的第一条语句，注释只能写在它后面。

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# 查找 C# 编译器。
# 不同机器上 csc.exe 的位置不一样：
#   - 普通 Windows 10/11：System32 下的 .NET Framework 目录
#   - GitHub Actions runner：只有 Visual Studio 里的 Roslyn 版本
#     (C:\Program Files\Microsoft Visual Studio\2022\...\MSBuild\Current\Bin\Roslyn\csc.exe)
# 所以这里逐个探测常见位置，而不是写死一条路径。
$cscCandidates = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere) {
    $vsRoot = & $vswhere -latest -products * -property installationPath 2>$null
    if ($vsRoot) {
        $cscCandidates += (Join-Path $vsRoot.Trim() 'MSBuild\Current\Bin\Roslyn\csc.exe')
    }
}

foreach ($base in @("$env:ProgramFiles\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio")) {
    if (Test-Path -LiteralPath $base) {
        $found = Get-ChildItem -LiteralPath $base -Recurse -Filter 'csc.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { $cscCandidates += $found.FullName }
    }
}

$csc = $cscCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

if (-not $csc) {
    Write-Host '已探测的位置:'
    $cscCandidates | ForEach-Object { Write-Host "  - $_" }
    throw '找不到 csc.exe (C# 编译器)。'
}

Write-Host "编译器: $csc"

$srcDir = Join-Path $root 'src'
$outDirFull = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $outDirFull | Out-Null

$exe = Join-Path $outDirFull 'DSH WebUI.exe'
$ps1 = Join-Path $srcDir 'DSH-WebUI-WPF.ps1'
$ico = Join-Path $srcDir 'app.ico'
$cs  = Join-Path $srcDir 'Launcher.cs'

foreach ($f in @($ps1, $ico, $cs)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "缺少源文件: $f" }
}

Write-Host '编译中...'

& $csc /nologo /target:winexe `
    /win32icon:"$ico" `
    /out:"$exe" `
    /resource:"$ps1",DswWebUi.ui.ps1 `
    /resource:"$ico",DswWebUi.app.ico `
    "$cs"

if ($LASTEXITCODE -ne 0) { throw "编译失败（csc 退出码 $LASTEXITCODE）" }
if (-not (Test-Path -LiteralPath $exe)) { throw '编译完成但没有产出 exe' }

$size = [math]::Round((Get-Item -LiteralPath $exe).Length / 1KB, 1)
Write-Host "完成: $exe ($size KB)"
