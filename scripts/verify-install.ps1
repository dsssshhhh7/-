[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Find-CodexCli {
    $bundledCli = Join-Path $HOME '.codex\.sandbox-bin\codex.exe'
    if (Test-Path -LiteralPath $bundledCli) {
        return $bundledCli
    }

    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw '找不到 Codex CLI。请先安装并启动 Codex Desktop。'
}

$codexCli = Find-CodexCli
$pluginPath = Join-Path $HOME 'plugins\team-codex'
$manifestPath = Join-Path $pluginPath '.codex-plugin\plugin.json'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "找不到已安装插件 manifest：$manifestPath"
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$stateJson = (& $codexCli plugin list --marketplace personal --available --json 2>$null | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "读取 Codex 插件状态失败，退出码：$LASTEXITCODE"
}

$state = $stateJson | ConvertFrom-Json
$record = @(@($state.installed) + @($state.available) | Where-Object { $_.pluginId -eq 'team-codex@personal' }) | Select-Object -First 1

if (-not $record) {
    throw 'Personal marketplace 中没有 team-codex@personal。'
}
if (-not $record.installed) {
    throw 'team-codex 已出现在 marketplace，但尚未真实安装。请重新运行 install.ps1。'
}
if (-not $record.enabled) {
    throw 'team-codex 已安装但未启用。'
}
if ([string]$record.version -ne [string]$manifest.version) {
    throw "安装状态版本 $($record.version) 与源码版本 $($manifest.version) 不一致。"
}

$gitBash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $gitBash)) {
    throw "找不到 Git Bash：$gitBash"
}

[pscustomobject]@{
    pluginId = $record.pluginId
    installed = [bool]$record.installed
    enabled = [bool]$record.enabled
    version = [string]$record.version
    path = [string]$record.source.path
    gitBash = $gitBash
    dataRoot = (Join-Path $HOME 'codex-team')
    nextStep = '新建 Codex 任务，然后说：代号叫 测试端'
} | Format-List

