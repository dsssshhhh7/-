[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$sourceManifest = Join-Path $pluginRoot '.codex-plugin\plugin.json'
$source = Get-Content -Raw -LiteralPath $sourceManifest | ConvertFrom-Json

$installBase = [System.IO.Path]::GetFullPath((Join-Path $HOME 'plugins'))
$destination = [System.IO.Path]::GetFullPath((Join-Path $installBase 'team-codex'))
$backup = [System.IO.Path]::GetFullPath((Join-Path $installBase 'team-codex.previous'))
$stage = [System.IO.Path]::GetFullPath((Join-Path $installBase ('team-codex.installing-' + [guid]::NewGuid().ToString('N'))))

function Assert-InstallPath([string]$Path) {
    $prefix = $installBase.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside the Codex plugin install root: $Path"
    }
}

Assert-InstallPath $destination
Assert-InstallPath $backup
Assert-InstallPath $stage

$oldVersion = $null
$installedManifest = Join-Path $destination '.codex-plugin\plugin.json'
if (Test-Path -LiteralPath $installedManifest) {
    try {
        $oldVersion = (Get-Content -Raw -LiteralPath $installedManifest | ConvertFrom-Json).version
    } catch {
        $oldVersion = 'unknown'
    }
}

$marketplacePath = Join-Path $HOME '.agents\plugins\marketplace.json'
$marketplaceDir = Split-Path -Parent $marketplacePath
$marketplaceNeedsWrite = $true
if (Test-Path -LiteralPath $marketplacePath) {
    try {
        $existingMarketplace = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
        $entry = @($existingMarketplace.plugins | Where-Object { $_.name -eq 'team-codex' }) | Select-Object -First 1
        if ($entry -and $entry.policy.installation -eq 'INSTALLED_BY_DEFAULT') {
            $marketplaceNeedsWrite = $false
        }
    } catch {
        $marketplaceNeedsWrite = $true
    }
}

$needsCopy = ($oldVersion -ne $source.version)
if ($needsCopy) {
    New-Item -ItemType Directory -Force -Path $installBase | Out-Null
    Copy-Item -LiteralPath $pluginRoot -Destination $stage -Recurse -Force
    try {
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
        if (Test-Path -LiteralPath $destination) {
            Move-Item -LiteralPath $destination -Destination $backup
        }
        Move-Item -LiteralPath $stage -Destination $destination
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
    } catch {
        if ((-not (Test-Path -LiteralPath $destination)) -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $destination
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
}

if ($marketplaceNeedsWrite) {
    New-Item -ItemType Directory -Force -Path $marketplaceDir | Out-Null
    if (Test-Path -LiteralPath $marketplacePath) {
        $marketplace = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
    } else {
        $marketplace = [pscustomobject]@{
            name = 'personal'
            interface = [pscustomobject]@{ displayName = 'Personal' }
            plugins = @()
        }
    }

    $kept = @($marketplace.plugins | Where-Object { $_.name -ne 'team-codex' })
    $teamEntry = [pscustomobject]@{
        name = 'team-codex'
        source = [pscustomobject]@{ source = 'local'; path = './plugins/team-codex' }
        policy = [pscustomobject]@{ installation = 'INSTALLED_BY_DEFAULT'; authentication = 'ON_INSTALL' }
        category = 'Productivity'
    }
    $marketplace.plugins = @($kept) + @($teamEntry)
    $tmp = "$marketplacePath.tmp-$PID"
    $marketplace | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $marketplacePath -Force
}

function Find-CodexCli {
    $sandboxCli = Join-Path $HOME '.codex\.sandbox-bin\codex.exe'
    if (Test-Path -LiteralPath $sandboxCli) {
        return $sandboxCli
    }

    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw '找不到 Codex CLI，插件文件已复制但无法完成真实安装。'
}

$codexCli = Find-CodexCli
$pluginInstalledBefore = $false
$pluginInstalledVersion = $null
try {
    $stateJson = (& $codexCli plugin list --marketplace personal --available --json 2>$null | Out-String)
    $state = $stateJson | ConvertFrom-Json
    $record = @(@($state.installed) + @($state.available) | Where-Object { $_.pluginId -eq 'team-codex@personal' }) | Select-Object -First 1
    if ($record) {
        $pluginInstalledBefore = [bool]$record.installed
        $pluginInstalledVersion = [string]$record.version
    }
} catch {
    $pluginInstalledBefore = $false
}

$needsPluginAdd = (-not $pluginInstalledBefore) -or ($pluginInstalledVersion -ne [string]$source.version) -or $needsCopy -or $marketplaceNeedsWrite
if ($needsPluginAdd) {
    & $codexCli plugin add team-codex@personal --json 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Codex CLI 安装 team-codex@personal 失败，退出码：$LASTEXITCODE"
    }
}

if ($needsCopy -or $marketplaceNeedsWrite -or $needsPluginAdd) {
    $from = if ($pluginInstalledBefore -and $pluginInstalledVersion) { $pluginInstalledVersion } elseif ($oldVersion -and $pluginInstalledBefore) { [string]$oldVersion } else { '未安装' }
    $message = "🔧 Codex 协作插件已更新：$from → $($source.version)。新建任务后生效。"
    if ($Quiet) {
        [pscustomobject]@{
            systemMessage = $message
            hookSpecificOutput = [pscustomobject]@{
                hookEventName = 'SessionStart'
                additionalContext = "team-codex 已安装为 $($source.version)。当前任务若早于本次更新创建，仍使用旧能力。"
            }
        } | ConvertTo-Json -Depth 5 -Compress
    } else {
        $message
    }
} elseif (-not $Quiet) {
    "team-codex 已是最新版本：$($source.version)"
}
