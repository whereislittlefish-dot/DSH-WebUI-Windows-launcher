param(
    [string] $OutDir = 'dist'
)

# 从 src/ 编译出单文件 exe 到 dist/
# 用法: .\build.ps1
#
# 注意: param 必须是脚本的第一条语句，注释只能写在它后面。

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw '找不到 csc.exe。需要 .NET Framework 4.x（Windows 10/11 自带）。'
}

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
