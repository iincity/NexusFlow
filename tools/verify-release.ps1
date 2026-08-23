param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$bom = Get-Content -Raw (Join-Path $Root 'release/bom.toml')
function Get-BomCommit([string]$section) {
    $body = ([regex]::Match($bom, '(?ms)^\[' + [regex]::Escape($section) + '\](.*?)(?=^\[|\z)')).Groups[1].Value
    return ([regex]::Match($body, '(?m)^commit\s*=\s*"([0-9a-f]{40})"')).Groups[1].Value
}
$required = @(
    @{ Path = 'components/nexus-rustdesk'; Bom = 'rustdesk_client'; Module = 'nexus-rustdesk' },
    @{ Path = 'components/rustdesk-server'; Bom = 'rustdesk_server'; Module = 'rustdesk-server' },
    @{ Path = 'components/rustdesk-server-pro'; Bom = 'rustdesk_server_pro'; Module = 'rustdesk-server-pro' },
    @{ Path = 'components/nexus-platform'; Bom = 'nexus_platform'; Module = 'nexus-platform' },
    @{ Path = 'components/nexus-tunnel'; Bom = 'nexus_tunnel'; Module = 'nexus-tunnel' }
)
$gitmodules = Get-Content -Raw (Join-Path $Root '.gitmodules')

foreach ($component in $required) {
    $bomSection = ([regex]::Match($bom, '(?ms)^\[' + $component.Bom + '\](.*?)(?=^\[|\z)')).Groups[1].Value
    $commit = Get-BomCommit $component.Bom
    if (-not $commit) { throw "BOM is missing $($component.Bom).commit" }
    $repository = ([regex]::Match($bomSection, '(?m)^repository = "([^"]+)"')).Groups[1].Value
    if (-not $repository) { throw "BOM is missing $($component.Bom).repository" }
    $moduleSection = ([regex]::Match($gitmodules, '(?ms)^\[submodule "' + $component.Module + '"\](.*?)(?=^\[|\z)')).Groups[1].Value
    $moduleUrl = ([regex]::Match($moduleSection, '(?m)^\s*url\s*=\s*(\S+)')).Groups[1].Value
    if ($repository -ne $moduleUrl) { throw "Source mismatch for $($component.Path): BOM $repository, submodule $moduleUrl" }
    $dirty = (@(git -C (Join-Path $Root $component.Path) status --porcelain) -join "`n").Trim()
    if ($dirty) { throw "Dirty worktree for $($component.Path); create the additive shared commit before release verification." }
    $actual = (git -C $Root submodule status -- $component.Path).Trim().TrimStart('-+ ' ).Split(' ')[0]
    if ($actual -ne $commit) { throw "BOM mismatch for $($component.Path): expected $commit, got $actual" }
}

@('components/nexus-rustdesk/LICENCE', 'components/rustdesk-server/LICENSE', 'components/rustdesk-server-pro/terms') |
    ForEach-Object { if (-not (Test-Path (Join-Path $Root $_))) { throw "Required upstream licensing input is missing: $_" } }

@('components/nexus-tunnel/Cargo.toml', 'components/nexus-platform/control-plane/Cargo.toml') |
    ForEach-Object {
        $manifest = Get-Content -Raw (Join-Path $Root $_)
        if ($manifest -notmatch '(?m)^license\s*=\s*"Proprietary"\s*$' -or $manifest -notmatch '(?m)^publish\s*=\s*false\s*$') {
            throw "First-party component must declare a non-publishable proprietary license: $_"
        }
    }

@(
    'components/nexus-platform/control-plane/Cargo.lock',
    'components/nexus-tunnel/Cargo.lock',
    'components/nexus-platform/migrations/20260811_nexus_devices.sql',
    'components/nexus-platform/admin-web/index.html',
    'components/nexus-platform/admin-web/app.js',
    'components/nexus-platform/admin-web/styles.css'
) |
    ForEach-Object { if (-not (Test-Path (Join-Path $Root $_))) { throw "Required release input is missing: $_" } }

$sbomPath = Join-Path $Root 'release/sbom.cdx.json'
if (-not (Test-Path $sbomPath)) { throw 'Required release artifact is missing: release/sbom.cdx.json' }
try { $sbom = Get-Content -Raw $sbomPath | ConvertFrom-Json } catch { throw 'SBOM is not valid JSON' }
if ($sbom.bomFormat -ne 'CycloneDX' -or $sbom.specVersion -ne '1.5') { throw 'SBOM must be CycloneDX 1.5' }
if (-not $sbom.components -or $sbom.components.Count -eq 0) { throw 'SBOM must contain components' }
$sbomRefs = @($sbom.components | ForEach-Object { $_.'bom-ref' })
if ($sbomRefs.Count -ne @($sbomRefs | Sort-Object -Unique).Count) { throw 'SBOM contains duplicate bom-ref values' }
foreach ($component in $required) {
    if ($sbomRefs -notcontains "git:$($component.Path)") { throw "SBOM is missing fixed component $($component.Path)" }
    $sbomComponent = @($sbom.components | Where-Object { $_.'bom-ref' -eq "git:$($component.Path)" })[0]
    if ($sbomComponent.version -ne (Get-BomCommit $component.Bom)) {
        throw "SBOM version mismatch for $($component.Path): BOM and SBOM commits differ"
    }
}
if ($sbomRefs -notcontains 'artifact:nexus-web-relay') {
    throw 'SBOM is missing nexus-web-relay artifact provenance'
}
$relaySbom = @($sbom.components | Where-Object { $_.'bom-ref' -eq 'artifact:nexus-web-relay' })[0]
$relayCommit = Get-BomCommit 'nexus_web_relay'
if ($relaySbom.version -ne $relayCommit) { throw 'SBOM version mismatch for nexus-web-relay: BOM and SBOM commits differ' }
if ($sbomRefs -notcontains 'artifact:rustdesk-pro-web-client') {
    throw 'SBOM is missing rustdesk-pro-web-client artifact provenance'
}

$proWebClient = ([regex]::Match($bom, '(?ms)^\[rustdesk_pro_web_client\](.*?)(?=^\[|\z)')).Groups[1].Value
foreach ($key in @('version', 'web_client_version', 'archive_url', 'sha256', 'static_path')) {
    if ($proWebClient -notmatch ('(?m)^' + $key + '\s*=\s*"[^"]+"')) {
        throw "BOM rustdesk_pro_web_client.$key is missing"
    }
}
if ($proWebClient -notmatch '(?m)^archive_url\s*=\s*"https://github\.com/rustdesk/rustdesk-server-pro/releases/download/[^"]+"' -or
    $proWebClient -notmatch '(?m)^sha256\s*=\s*"[0-9a-f]{64}"') {
    throw 'BOM rustdesk_pro_web_client provenance is invalid'
}

$dockerfile = Get-Content -Raw (Join-Path $Root 'components/nexus-platform/control-plane/Dockerfile')
if ($dockerfile -notmatch 'FROM\s+[^\s@]+@sha256:[0-9a-f]{64}') {
    throw 'Control-plane Dockerfile base images must be pinned by immutable sha256 digest'
}
if ($dockerfile -match 'nexus-tunnel') {
    throw 'Control-plane Dockerfile must not copy or link retired nexus-tunnel runtime source'
}
foreach ($requiredCopy in @(
    'COPY components/nexus-platform/admin-web /admin-web',
    'COPY components/nexus-platform/migrations /migrations'
)) {
    if ($dockerfile -notmatch [regex]::Escape($requiredCopy)) {
        throw "Control-plane Dockerfile must include compile-time asset input: $requiredCopy"
    }
}
if ($dockerfile -notmatch 'cargo build --locked --release') {
    throw 'Control-plane Dockerfile must use its locked Cargo dependency graph'
}
if (-not (Test-Path (Join-Path $Root '.dockerignore'))) {
    throw 'Repository-root Docker build context requires a .dockerignore'
}
$compose = Get-Content -Raw (Join-Path $Root 'components/nexus-platform/control-plane/docker-compose.yml')
if ($compose -notmatch 'context:\s+\.\./\.\./\.\.' -or $compose -notmatch 'dockerfile:\s+components/nexus-platform/control-plane/Dockerfile') {
    throw 'Control-plane Compose build must use the repository root context'
}

$webRelay = ([regex]::Match($bom, '(?ms)^\[nexus_web_relay\](.*?)(?=^\[|\z)')).Groups[1].Value
foreach ($key in @('source', 'dockerfile', 'kubernetes_manifest')) {
    $value = ([regex]::Match($webRelay, '(?m)^' + $key + ' = "([^"]+)"')).Groups[1].Value
    if (-not $value -or -not (Test-Path (Join-Path $Root $value))) {
        throw "BOM nexus_web_relay.$key must name an existing release input"
    }
}
if ($webRelay -notmatch '(?m)^commit = "[0-9a-f]{40}"') {
    throw 'BOM nexus_web_relay.commit must pin its first-party source baseline'
}
$webRelayDockerfile = Get-Content -Raw (Join-Path $Root 'deploy/docker/nexus-web-relay.Dockerfile')
if ($webRelayDockerfile -notmatch 'cargo build --locked --release --bin nexus-web-relay' -or $webRelayDockerfile -notmatch 'HEALTHCHECK') {
    throw 'WebRelay artifact must use the locked graph and expose a container health check'
}
$webRelayManifest = Get-Content -Raw (Join-Path $Root 'deploy/kubernetes/nexus-web-relay.yaml')
if ($webRelayManifest -notmatch 'readinessProbe' -or $webRelayManifest -notmatch 'NEXUS_WEB_RELAY_TOKEN') {
    throw 'WebRelay manifest must have readiness and Secret-provided internal credentials'
}

Write-Host 'Release inputs verified: BOM/source URLs, submodules, upstream licensing inputs, SBOM, locks, embedded web assets, migration, container digests, build context.'
