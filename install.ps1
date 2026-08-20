[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'plugins\team-codex\scripts\install-user.ps1'

if (-not (Test-Path -LiteralPath $installer)) {
    throw "缺少插件安装器：$installer"
}

& $installer -Quiet:$Quiet
if ($LASTEXITCODE -ne 0) {
    throw "team-codex 安装失败，退出码：$LASTEXITCODE"
}

if (-not $Quiet) {
    Write-Output '安装完成。请新建 Codex 任务后使用；旧任务不会热加载新插件。'
}

