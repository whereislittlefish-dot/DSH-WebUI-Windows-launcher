param(
    [string] $OutDir = 'dist'
)

# 从 src/ 编译出单文件 exe 到 dist/
# 用法: .\build.ps1
#
# 注意: param 必须是脚本的第一条语句，注释只能写在它后面。

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Write-Host '== build =='
Write-Host "PowerShell : $($PSVersionTable.PSVersion)"
Write-Host "OS         : $([System.Environment]::OSVersion.VersionString)"
Write-Host "Root       : $root"

# 查找 C# 编译器。
# 不同机器上 csc.exe 的位置不一样:
#   - 普通 Windows 10/11: System32 下的 .NET Framework 目录
#   - GitHub Actions runner: Visual Studio 里的 Roslyn 版本
# 不要用 -Recurse 扫 Visual Studio 目录: 那里有成千上万个文件, 会把构建拖到超时。
$cscCandidates = New-Object System.Collections.Generic.List[string]
$cscCandidates.Add((Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'))
$cscCandidates.Add((Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere) {
    try {
        $vsRoot = & $vswhere -latest -products * -property installationPath 2>$null
        if ($vsRoot) {
            $cscCandidates.Add((Join-Path $vsRoot.Trim() 'MSBuild\Current\Bin\Roslyn\csc.exe'))
        }
    } catch {
        Write-Host "vswhere failed: $($_.Exception.Message)"
    }
}

foreach ($base in @("$env:ProgramFiles\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio")) {
    if (Test-Path -LiteralPath $base) {
        foreach ($year in @('2022', '2019', '2017')) {
            foreach ($edition in @('Enterprise', 'Professional', 'Community', 'BuildTools', 'Preview')) {
                $cscCandidates.Add((Join-Path $base "$year\$edition\MSBuild\Current\Bin\Roslyn\csc.exe"))
            }
        }
    }
}

Write-Host '== csc.exe candidates =='
$found = @()
foreach ($c in ($cscCandidates | Select-Object -Unique)) {
    $ok = Test-Path -LiteralPath $c
    Write-Host "  [$(if ($ok) { 'FOUND' } else { 'missing' })] $c"
    if ($ok) { $found += $c }
}

if ($found.Count -eq 0) {
    throw 'No csc.exe found. Cannot compile.'
}
$csc = $found[0]
Write-Host "Using compiler: $csc"

$srcDir = Join-Path $root 'src'
$outDirFull = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $outDirFull | Out-Null

$exe = Join-Path $outDirFull 'dsh-webui.exe'
$ps1 = Join-Path $srcDir 'DSH-WebUI-WPF.ps1'
$ico = Join-Path $srcDir 'app.ico'
$cs  = Join-Path $srcDir 'Launcher.cs'

Write-Host '== inputs =='
foreach ($f in @($ps1, $ico, $cs)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing source file: $f" }
    Write-Host ("  {0,8} bytes  {1}" -f (Get-Item -LiteralPath $f).Length, $f)
}

if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue }

Write-Host '== compiling =='
# 显式捕获 csc 的输出与退出码: 失败时必须能在这里看到真实原因,
# 否则 CI 上只能看到"步骤失败"而无法定位。
$output = & $csc /nologo /target:winexe `
    /win32icon:"$ico" `
    /out:"$exe" `
    /resource:"$ps1",DswWebUi.ui.ps1 `
    /resource:"$ico",DswWebUi.app.ico `
    "$cs" 2>&1
$code = $LASTEXITCODE

if ($output) {
    Write-Host '== compiler output =='
    $output | ForEach-Object { Write-Host "  $_" }
}

Write-Host "== csc exit code: $code =="

if ($code -ne 0) { throw "Compile failed with exit code $code" }
if (-not (Test-Path -LiteralPath $exe)) { throw 'csc reported success but produced no exe' }

$size = [math]::Round((Get-Item -LiteralPath $exe).Length / 1KB, 1)
Write-Host "== done: $exe ($size KB) =="
