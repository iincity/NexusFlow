param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$Output = (Join-Path $Root 'release/sbom.cdx.json')
)

$ErrorActionPreference = 'Stop'
$bom = Get-Content -Raw (Join-Path $Root 'release/bom.toml')

function Get-BomCommit([string]$Section) {
    $match = [regex]::Match($bom, '(?ms)^\[' + [regex]::Escape($Section) + '\](.*?)(?=^\[|\z)')
    if (-not $match.Success) { throw "BOM is missing [$Section]" }
    $commit = ([regex]::Match($match.Groups[1].Value, '(?m)^commit\s*=\s*"([0-9a-f]{40})"')).Groups[1].Value
    if (-not $commit) { throw "BOM is missing [$Section].commit" }
    return $commit
}

function Get-BomValue([string]$Section, [string]$Key) {
    $match = [regex]::Match($bom, '(?ms)^\[' + [regex]::Escape($Section) + '\](.*?)(?=^\[|\z)')
    if (-not $match.Success) { throw "BOM is missing [$Section]" }
    $value = ([regex]::Match($match.Groups[1].Value, '(?m)^' + [regex]::Escape($Key) + '\s*=\s*"([^"]+)"')).Groups[1].Value
    if (-not $value) { throw "BOM is missing [$Section].$Key" }
    return $value
}

function Get-CargoPackages([string]$Manifest) {
    $json = cargo metadata --manifest-path $Manifest --locked --format-version 1 | ConvertFrom-Json
    return @($json.packages | ForEach-Object {
        $component = [ordered]@{
            type = 'library'
            name = $_.name
            version = $_.version
            'bom-ref' = "cargo:$($_.name)@$($_.version)"
        }
        if ($_.repository) {
            $component.'externalReferences' = @([ordered]@{ type = 'vcs'; url = $_.repository })
        }
        [pscustomobject]$component
    })
}

$components = @()
$components += Get-CargoPackages (Join-Path $Root 'components/nexus-tunnel/Cargo.toml')
$components += Get-CargoPackages (Join-Path $Root 'components/nexus-platform/control-plane/Cargo.toml')
$components += Get-CargoPackages (Join-Path $Root 'components/nexus-rustdesk/Cargo.toml')
$components += @(
    [pscustomobject]@{ type = 'application'; name = 'nexus-rustdesk'; version = (Get-BomCommit 'rustdesk_client'); 'bom-ref' = 'git:components/nexus-rustdesk' },
    [pscustomobject]@{ type = 'application'; name = 'rustdesk-server'; version = (Get-BomCommit 'rustdesk_server'); 'bom-ref' = 'git:components/rustdesk-server' },
    [pscustomobject]@{ type = 'application'; name = 'rustdesk-server-pro'; version = (Get-BomCommit 'rustdesk_server_pro'); 'bom-ref' = 'git:components/rustdesk-server-pro' },
    [pscustomobject]@{
        type = 'application'; name = 'rustdesk-pro-web-client'; version = (Get-BomValue 'rustdesk_pro_web_client' 'version'); 'bom-ref' = 'artifact:rustdesk-pro-web-client'
        hashes = @([ordered]@{ alg = 'SHA-256'; content = (Get-BomValue 'rustdesk_pro_web_client' 'sha256') })
        externalReferences = @([ordered]@{ type = 'distribution'; url = (Get-BomValue 'rustdesk_pro_web_client' 'archive_url') })
    },
    [pscustomobject]@{ type = 'application'; name = 'nexus-platform'; version = (Get-BomCommit 'nexus_platform'); 'bom-ref' = 'git:components/nexus-platform' },
    [pscustomobject]@{ type = 'application'; name = 'nexus-web-relay'; version = (Get-BomCommit 'nexus_web_relay'); 'bom-ref' = 'artifact:nexus-web-relay' },
    [pscustomobject]@{ type = 'application'; name = 'nexus-tunnel'; version = (Get-BomCommit 'nexus_tunnel'); 'bom-ref' = 'git:components/nexus-tunnel' }
)
$components = @($components | Sort-Object 'bom-ref' -Unique)

$document = [ordered]@{
    bomFormat = 'CycloneDX'
    specVersion = '1.5'
    version = 1
    metadata = [ordered]@{
        tools = @([ordered]@{ vendor = 'NexusFlow'; name = 'generate-sbom.ps1'; version = '1' })
    }
    components = @($components | Sort-Object type, name, version)
}

$parent = Split-Path -Parent $Output
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$json = ($document | ConvertTo-Json -Depth 8) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($Output, "$json`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "SBOM generated: $Output ($($components.Count) components)"
