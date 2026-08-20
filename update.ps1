[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

git -C $PSScriptRoot pull --ff-only
if ($LASTEXITCODE -ne 0) {
    throw "git pull --ff-only 失败，退出码：$LASTEXITCODE"
}

& (Join-Path $PSScriptRoot 'install.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "插件更新失败，退出码：$LASTEXITCODE"
}

