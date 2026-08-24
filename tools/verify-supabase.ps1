param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$MigrationDatabaseUrl = $env:MIGRATION_DATABASE_URL,
    [string]$SupabaseUrl = $env:SUPABASE_URL,
    [string]$ServiceRoleKey = $env:SUPABASE_SERVICE_ROLE_KEY,
    [string]$AnonKey = $env:SUPABASE_ANON_KEY,
    [string]$TenantAId = $env:NEXUS_TENANT_A_ID,
    [string]$TenantBId = $env:NEXUS_TENANT_B_ID,
    [string]$TenantAAccessToken = $env:NEXUS_TENANT_A_ACCESS_TOKEN,
    [string]$TenantBAccessToken = $env:NEXUS_TENANT_B_ACCESS_TOKEN,
    [string]$RemovedMemberTenantId = $env:NEXUS_REMOVED_MEMBER_TENANT_ID,
    [string]$RemovedMemberAccessToken = $env:NEXUS_REMOVED_MEMBER_ACCESS_TOKEN,
    [string]$RevokedAccessToken = $env:NEXUS_REVOKED_ACCESS_TOKEN,
    [string]$PrivateBucket = $(if ($env:SUPABASE_PRIVATE_BUCKET) { $env:SUPABASE_PRIVATE_BUCKET } else { 'nexus-private' }),
    [string]$StorageObjectKey = $env:NEXUS_STORAGE_OBJECT_KEY,
    [string]$StorageObjectSha256 = $env:NEXUS_STORAGE_OBJECT_SHA256,
    [string]$ControlPlaneUrl = $env:NEXUS_CONTROL_PLANE_URL,
    [string]$RevokedFileGrantId = $env:NEXUS_REVOKED_FILE_GRANT_ID,
    [string]$PsqlPath = $env:NEXUS_PSQL_PATH
)

$ErrorActionPreference = 'Stop'
$localTlsFixture = $env:NEXUS_LOCAL_TLS_FIXTURE -eq '1'
$tlsArgs = @{}
if ($localTlsFixture) {
    # Python's local TLS bridge is HTTP/1.1-only; keep production requests untouched.
    $tlsArgs = @{ SkipCertificateCheck = $true; HttpVersion = [Version]'1.1' }
}

function Invoke-LocalFixture([string]$Method, [string]$Uri, [hashtable]$Headers = @{}, [string]$Body = $null, [string]$OutFile = $null) {
    $args = @('-k', '-sS', '-X', $Method, '-w', "`n%{http_code}")
    foreach ($name in $Headers.Keys) { $args += @('-H', "$name`: $($Headers[$name])") }
    if ($null -ne $Body) { $args += @('-H', 'Content-Type: application/json', '--data-binary', $Body) }
    if ($OutFile) { $args += @('-o', $OutFile) }
    $raw = & curl.exe @args $Uri 2>&1
    $rawText = $raw -join "`n"
    $match = [regex]::Match($rawText, "(?s)\n(\d{3})$")
    $status = if ($match.Success) { [int]$match.Groups[1].Value } else { 0 }
    $content = if ($match.Success) { $rawText.Substring(0, $match.Index) } else { $rawText }
    if ($LASTEXITCODE -ne 0 -and $status -notin 200..399) { throw ($raw -join "`n") }
    [PSCustomObject]@{ StatusCode = $status; Content = $content }
}

foreach ($setting in @(
    [PSCustomObject]@{ Name = 'DATABASE_URL'; Value = $DatabaseUrl }
    [PSCustomObject]@{ Name = 'MIGRATION_DATABASE_URL'; Value = $MigrationDatabaseUrl }
    [PSCustomObject]@{ Name = 'SUPABASE_URL'; Value = $SupabaseUrl }
    [PSCustomObject]@{ Name = 'SUPABASE_SERVICE_ROLE_KEY'; Value = $ServiceRoleKey }
    [PSCustomObject]@{ Name = 'SUPABASE_ANON_KEY'; Value = $AnonKey }
    [PSCustomObject]@{ Name = 'NEXUS_TENANT_A_ID'; Value = $TenantAId }
    [PSCustomObject]@{ Name = 'NEXUS_TENANT_B_ID'; Value = $TenantBId }
    [PSCustomObject]@{ Name = 'NEXUS_TENANT_A_ACCESS_TOKEN'; Value = $TenantAAccessToken }
    [PSCustomObject]@{ Name = 'NEXUS_TENANT_B_ACCESS_TOKEN'; Value = $TenantBAccessToken }
    [PSCustomObject]@{ Name = 'NEXUS_REMOVED_MEMBER_TENANT_ID'; Value = $RemovedMemberTenantId }
    [PSCustomObject]@{ Name = 'NEXUS_REMOVED_MEMBER_ACCESS_TOKEN'; Value = $RemovedMemberAccessToken }
    [PSCustomObject]@{ Name = 'NEXUS_REVOKED_ACCESS_TOKEN'; Value = $RevokedAccessToken }
    [PSCustomObject]@{ Name = 'NEXUS_STORAGE_OBJECT_KEY'; Value = $StorageObjectKey }
    [PSCustomObject]@{ Name = 'NEXUS_STORAGE_OBJECT_SHA256'; Value = $StorageObjectSha256 }
    [PSCustomObject]@{ Name = 'NEXUS_CONTROL_PLANE_URL'; Value = $ControlPlaneUrl }
    [PSCustomObject]@{ Name = 'NEXUS_REVOKED_FILE_GRANT_ID'; Value = $RevokedFileGrantId }
)) {
    if ([string]::IsNullOrWhiteSpace($setting.Value)) {
        throw "Missing $($setting.Name). This production gate was not executed; all database, Supabase, tenant, revoked-principal, Storage-object, and control-plane fixtures are required before network access."
    }
}

function Get-PostgresConnectionParts([string]$Name, [string]$Url) {
    try { $uri = [Uri]$Url } catch { throw "$Name must be a valid PostgreSQL connection URL." }
    if ($uri.Scheme -notin @('postgres', 'postgresql')) { throw "$Name must use the postgres or postgresql scheme." }
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        throw "$Name must include database host and credentials."
    }
    $user, $password = $uri.UserInfo.Split(':', 2)
    $database = $uri.AbsolutePath.Trim('/')
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($password) -or [string]::IsNullOrWhiteSpace($database)) {
        throw "$Name must include a database user, password, and database name."
    }
    $sslModeMatch = [regex]::Match($uri.Query.TrimStart('?'), '(?:^|&)sslmode=([^&]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $sslMode = if ($sslModeMatch.Success) { [Uri]::UnescapeDataString($sslModeMatch.Groups[1].Value).ToLowerInvariant() } else { '' }
    if ($sslMode -notin @('require', 'verify-ca', 'verify-full')) {
        throw "$Name must require TLS with sslmode=require, verify-ca, or verify-full."
    }
    [PSCustomObject]@{
        Host = $uri.Host
        Port = $(if ($uri.IsDefaultPort) { 5432 } else { $uri.Port })
        User = [Uri]::UnescapeDataString($user)
        Password = [Uri]::UnescapeDataString($password)
        Database = [Uri]::UnescapeDataString($database)
        SslMode = $sslMode
    }
}

$projectUri = [Uri]$SupabaseUrl
if ($projectUri.Scheme -ne 'https') { throw 'SUPABASE_URL must use HTTPS.' }
$controlPlaneUri = [Uri]$ControlPlaneUrl
if ($controlPlaneUri.Scheme -ne 'https') { throw 'NEXUS_CONTROL_PLANE_URL must use HTTPS.' }
if ($localTlsFixture) {
    $allowedFixtureHosts = @('127.0.0.1', 'localhost', '172.16.0.0/12', '192.168.0.0/16', '10.0.0.0/8')
    foreach ($fixtureUri in @($projectUri, $controlPlaneUri)) {
        $ip = $null
        $isPrivate = [System.Net.IPAddress]::TryParse($fixtureUri.Host, [ref]$ip) -and (
            ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) -and
            (($ip.GetAddressBytes()[0] -eq 10) -or
             ($ip.GetAddressBytes()[0] -eq 172 -and $ip.GetAddressBytes()[1] -ge 16 -and $ip.GetAddressBytes()[1] -le 31) -or
             ($ip.GetAddressBytes()[0] -eq 192 -and $ip.GetAddressBytes()[1] -eq 168)))
        if (($fixtureUri.Host -notin @('127.0.0.1', 'localhost')) -and -not $isPrivate) {
            throw 'NEXUS_LOCAL_TLS_FIXTURE may only disable certificate checks for loopback/private HTTPS endpoints.'
        }
    }
}
if ($StorageObjectSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'NEXUS_STORAGE_OBJECT_SHA256 must be a SHA-256 hex digest.' }
if ($TenantAId -eq $TenantBId -or $TenantAId -eq $RemovedMemberTenantId -or $TenantBId -eq $RemovedMemberTenantId) {
    throw 'Tenant A, Tenant B, and removed-member tenant fixtures must identify different tenants.'
}
$runtimeConnection = Get-PostgresConnectionParts 'DATABASE_URL' $DatabaseUrl
$migrationConnection = Get-PostgresConnectionParts 'MIGRATION_DATABASE_URL' $MigrationDatabaseUrl

$psql = if (-not [string]::IsNullOrWhiteSpace($PsqlPath)) {
    Get-Command $PsqlPath -ErrorAction SilentlyContinue
} else {
    Get-Command psql -ErrorAction SilentlyContinue
}
if (-not $psql) { throw 'psql is required to verify PostgreSQL RLS.' }

# Storage authenticates the backend credential without creating any object.
$bucketUri = "$($SupabaseUrl.TrimEnd('/'))/storage/v1/bucket/$([Uri]::EscapeDataString($PrivateBucket))"
$headers = @{ apikey = $ServiceRoleKey; Authorization = "Bearer $ServiceRoleKey" }
try {
    if ($localTlsFixture) { $bucket = (Invoke-LocalFixture GET $bucketUri $headers).Content | ConvertFrom-Json }
    else { $bucket = Invoke-RestMethod -Method Get -Uri $bucketUri -Headers $headers @tlsArgs }
} catch {
    throw "Cannot read private Storage bucket '$PrivateBucket': $($_.Exception.Message)"
}
if ($bucket.name -ne $PrivateBucket) { throw "Unexpected Storage bucket response for '$PrivateBucket'." }
if ($bucket.public -ne $false) { throw "Storage bucket '$PrivateBucket' must be private (public=false)." }

function Get-RejectedStatus([string]$Name, [scriptblock]$Request) {
    try {
        & $Request | Out-Null
    } catch {
        if ($localTlsFixture -and $_.Exception.Message -match 'HTTP (\d{3})') {
            $status = [int]$Matches[1]
            if ($status -in @(401, 403, 404)) { return $status }
        }
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $status = [int]$response.StatusCode
            if ($status -in @(401, 403, 404)) { return $status }
            throw "$Name must be rejected with 401, 403, or 404; received HTTP $status."
        }
        throw "$Name request did not return an HTTP rejection: $($_.Exception.Message)"
    }
    throw "$Name unexpectedly succeeded."
}

function Get-StorageObjectPath([string]$Key) {
    if ($Key.StartsWith('/') -or $Key.Split('/') | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }) {
        throw 'NEXUS_STORAGE_OBJECT_KEY must be a non-empty relative object path.'
    }
    ($Key.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
}

$escapedBucket = [Uri]::EscapeDataString($PrivateBucket)
$escapedObjectPath = Get-StorageObjectPath $StorageObjectKey
    $signed = if ($localTlsFixture) {
    $signedResponse = Invoke-LocalFixture POST "$($SupabaseUrl.TrimEnd('/'))/storage/v1/object/sign/$escapedBucket/$escapedObjectPath" $headers '{"expiresIn":60}'
    if ($signedResponse.StatusCode -notin @(200, 201)) { throw "Storage signing failed with HTTP $($signedResponse.StatusCode)." }
    $signedResponse.Content.Trim() | ConvertFrom-Json
} else { Invoke-RestMethod -Method Post -Uri "$($SupabaseUrl.TrimEnd('/'))/storage/v1/object/sign/$escapedBucket/$escapedObjectPath" -Headers $headers -ContentType 'application/json' -Body '{"expiresIn":60}' @tlsArgs }
$signedUrl = $signed.signedURL
if ([string]::IsNullOrWhiteSpace($signedUrl)) { throw 'Storage signed URL response was empty.' }
$signedObjectUri = if ([Uri]::IsWellFormedUriString($signedUrl, [UriKind]::Absolute)) { $signedUrl } else {
    $path = $signedUrl.TrimStart('/')
    if ($path.StartsWith('object/')) { $path = "storage/v1/$path" }
    "$($SupabaseUrl.TrimEnd('/'))/$path"
}
$temporaryObject = Join-Path ([IO.Path]::GetTempPath()) ("nexusflow-supabase-" + [Guid]::NewGuid().ToString('N'))
try {
    if ($localTlsFixture) {
        Invoke-LocalFixture HEAD $signedObjectUri @{} $null | Out-Null
        Invoke-LocalFixture GET $signedObjectUri @{} $null $temporaryObject | Out-Null
    } else {
        Invoke-WebRequest -Method Head -Uri $signedObjectUri @tlsArgs | Out-Null
        Invoke-WebRequest -Uri $signedObjectUri -OutFile $temporaryObject @tlsArgs | Out-Null
    }
    $actualObjectHash = (Get-FileHash -LiteralPath $temporaryObject -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualObjectHash -ne $StorageObjectSha256.ToLowerInvariant()) {
        throw "Storage object SHA-256 mismatch for '$StorageObjectKey'."
    }
} finally {
    Remove-Item -LiteralPath $temporaryObject -Force -ErrorAction SilentlyContinue
}

$migrationRoot = Join-Path $PSScriptRoot '..\components\nexus-platform\migrations'
$expectedTables = @(Get-ChildItem -LiteralPath $migrationRoot -Filter '*.sql' -File | ForEach-Object {
    [regex]::Matches((Get-Content -Raw -LiteralPath $_.FullName), 'CREATE TABLE IF NOT EXISTS "([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value }
} | Sort-Object -Unique)
if ($expectedTables.Count -eq 0) { throw 'Could not derive expected Nexus tables from migrations.' }
$schemaVersions = @(Get-ChildItem -LiteralPath $migrationRoot -Filter '*.sql' -File | ForEach-Object {
    [regex]::Matches((Get-Content -Raw -LiteralPath $_.FullName),
        'INSERT INTO\s+"NexusSchemaVersion"\s*\([^)]*\)\s*VALUES\s*\(\s*TRUE\s*,\s*(\d+)\s*\)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase) |
        ForEach-Object { [int]$_.Groups[1].Value }
} | Sort-Object -Unique)
if ($schemaVersions.Count -ne 1) {
    throw "Could not derive one NexusSchemaVersion from migrations; found: $($schemaVersions -join ', ')."
}
$expectedSchemaVersion = $schemaVersions[0]

$previousPassword = $env:PGPASSWORD
$previousSslMode = $env:PGSSLMODE
try {
    # Keep the password out of psql's command line and restore the caller's environment.
    $env:PGPASSWORD = $runtimeConnection.Password
    $env:PGSSLMODE = $runtimeConnection.SslMode
    $runtimeQuery = & $psql.Source --no-psqlrc --tuples-only --no-align --quiet `
        --host $runtimeConnection.Host --port $runtimeConnection.Port `
        --username $runtimeConnection.User --dbname $runtimeConnection.Database `
        --command 'SELECT 1;'
    if ($LASTEXITCODE -ne 0 -or $runtimeQuery -notcontains '1') { throw 'PostgreSQL runtime pooler query failed.' }

    $env:PGPASSWORD = $migrationConnection.Password
    $env:PGSSLMODE = $migrationConnection.SslMode
    $missingRls = & $psql.Source --no-psqlrc --tuples-only --no-align --quiet `
        --host $migrationConnection.Host --port $migrationConnection.Port `
        --username $migrationConnection.User --dbname $migrationConnection.Database `
        --command "SELECT relname FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND relname LIKE 'Nexus%' AND NOT relrowsecurity ORDER BY relname;"
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL RLS query failed.' }
    $actualTables = @(& $psql.Source --no-psqlrc --tuples-only --no-align --quiet `
        --host $migrationConnection.Host --port $migrationConnection.Port `
        --username $migrationConnection.User --dbname $migrationConnection.Database `
        --command "SELECT relname FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND relname LIKE 'Nexus%' ORDER BY relname;" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL Nexus table inventory query failed.' }
    $missingTables = @($expectedTables | Where-Object { $_ -notin $actualTables })
    $unexpectedTables = @($actualTables | Where-Object { $_ -notin $expectedTables })
    if ($missingTables -or $unexpectedTables) {
        throw "NexusFlow table set mismatch. Missing: $($missingTables -join ', '); unexpected: $($unexpectedTables -join ', ')."
    }
    $schemaVersion = & $psql.Source --no-psqlrc --tuples-only --no-align --quiet `
        --host $migrationConnection.Host --port $migrationConnection.Port `
        --username $migrationConnection.User --dbname $migrationConnection.Database `
        --command 'SELECT "version" FROM "NexusSchemaVersion" WHERE "id" = TRUE;'
    if ($LASTEXITCODE -ne 0 -or @($schemaVersion | Where-Object { $_.Trim() -eq [string]$expectedSchemaVersion }).Count -ne 1) {
        throw "NexusFlow schema version probe failed: expected NexusSchemaVersion=$expectedSchemaVersion."
    }
    $directGrants = @(& $psql.Source --no-psqlrc --tuples-only --no-align --quiet `
        --host $migrationConnection.Host --port $migrationConnection.Port `
        --username $migrationConnection.User --dbname $migrationConnection.Database `
        --command "SELECT grantee || ':' || table_name || ':' || privilege_type FROM information_schema.role_table_grants WHERE grantee IN ('anon', 'authenticated') AND table_schema = 'public' AND table_name LIKE 'Nexus%' ORDER BY 1;" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL direct-grant query failed.' }
    if ($directGrants.Count -gt 0) { throw "NexusFlow direct grants for anon/authenticated are forbidden: $($directGrants -join ', ')" }
} finally {
    $env:PGPASSWORD = $previousPassword
    $env:PGSSLMODE = $previousSslMode
}

if ($missingRls) { throw "NexusFlow tables without RLS: $($missingRls -join ', ')" }

# Nexus tables deliberately have no anon/authenticated Data API grants.  Tenant
# visibility is therefore verified through the production control-plane boundary,
# which is also where the application evaluates membership and revoked identities.
Get-RejectedStatus 'Anonymous Nexus Data API read' {
    $anonymousHeaders = @{ apikey = $AnonKey; Authorization = "Bearer $AnonKey" }
    $anonymousUri = "$($SupabaseUrl.TrimEnd('/'))/rest/v1/NexusSchemaVersion?select=version&limit=1"
    if ($localTlsFixture) {
        $response = Invoke-LocalFixture GET $anonymousUri $anonymousHeaders
        if ($response.StatusCode -in 401, 403, 404) { throw "HTTP $($response.StatusCode)" }
        return
    }
    Invoke-WebRequest -Method Get -Uri $anonymousUri -Headers $anonymousHeaders @tlsArgs
} | Out-Null

function Get-ControlPlaneTenants([string]$Token) {
    try {
        $h = @{ Authorization = "Bearer $Token" }
        if ($localTlsFixture) { @((Invoke-LocalFixture GET "$($ControlPlaneUrl.TrimEnd('/'))/v1/tenants" $h).Content | ConvertFrom-Json) }
        else { @(Invoke-RestMethod -Method Get -Uri "$($ControlPlaneUrl.TrimEnd('/'))/v1/tenants" -Headers $h @tlsArgs) }
    } catch {
        throw "Control-plane tenant visibility probe failed: $($_.Exception.Message)"
    }
}

$tenantAIds = @(Get-ControlPlaneTenants $TenantAAccessToken | ForEach-Object { $_.id })
$tenantBIds = @(Get-ControlPlaneTenants $TenantBAccessToken | ForEach-Object { $_.id })
$removedMemberIds = @(Get-ControlPlaneTenants $RemovedMemberAccessToken | ForEach-Object { $_.id })
if ($TenantAId -notin $tenantAIds -or $TenantBId -notin $tenantBIds) {
    throw 'Tenant authorization probe failed: a current member cannot read its own tenant through the control plane.'
}
if ($TenantBId -in $tenantAIds -or $TenantAId -in $tenantBIds) {
    throw 'Tenant authorization probe failed: a current member can read another tenant through the control plane.'
}
if ($RemovedMemberTenantId -in $removedMemberIds) {
    throw 'Tenant authorization probe failed: a removed member can still read its former tenant through the control plane.'
}

$controlHeaders = @{ Authorization = "Bearer $TenantAAccessToken" }
$profile = if ($localTlsFixture) { (Invoke-LocalFixture GET "$($ControlPlaneUrl.TrimEnd('/'))/v1/account/profile" $controlHeaders).Content | ConvertFrom-Json } else { Invoke-RestMethod -Method Get -Uri "$($ControlPlaneUrl.TrimEnd('/'))/v1/account/profile" -Headers $controlHeaders @tlsArgs }
if ([string]::IsNullOrWhiteSpace($profile.id)) { throw 'Control-plane Auth mapping probe returned no account ID.' }
Get-RejectedStatus 'Revoked Supabase user profile' {
        if ($localTlsFixture) { $r = Invoke-LocalFixture GET "$($ControlPlaneUrl.TrimEnd('/'))/v1/account/profile" @{ Authorization = "Bearer $RevokedAccessToken" }; if ($r.StatusCode -in 401,403,404) { throw "HTTP $($r.StatusCode)" }; return }
        Invoke-WebRequest -Method Get -Uri "$($ControlPlaneUrl.TrimEnd('/'))/v1/account/profile" -Headers @{ Authorization = "Bearer $RevokedAccessToken" } @tlsArgs
} | Out-Null
foreach ($operation in @('download-session', 'upload-session')) {
    Get-RejectedStatus "Revoked remote file grant $operation" {
        if ($localTlsFixture) { $r = Invoke-LocalFixture POST "$($ControlPlaneUrl.TrimEnd('/'))/api/v1/remote-desktop/files/$([Uri]::EscapeDataString($RevokedFileGrantId))/$operation" $controlHeaders; if ($r.StatusCode -in 401,403,404) { throw "HTTP $($r.StatusCode)" }; return }
        Invoke-WebRequest -Method Post -Uri "$($ControlPlaneUrl.TrimEnd('/'))/api/v1/remote-desktop/files/$([Uri]::EscapeDataString($RevokedFileGrantId))/$operation" -Headers $controlHeaders @tlsArgs
    } | Out-Null
}

$verificationScope = if ($localTlsFixture) { 'Local test-only Supabase fixture' } else { 'Production Supabase inputs' }
Write-Host "$verificationScope verified: schema version $expectedSchemaVersion, runtime pooler reachable, private bucket '$PrivateBucket' is private with signed URL HEAD/SHA-256 verification, all NexusFlow tables have RLS enabled, control-plane tenant allow/deny and removed-member probes passed, revoked Auth and remote file grants are rejected."
