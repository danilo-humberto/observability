# Requer apenas PowerShell e Docker Compose. Usa projetos isolados e preserva volumes.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$composeArgs = @('--file', (Join-Path $repoRoot 'compose.yaml'), '--env-file', (Join-Path $repoRoot '.env.example'))
$prefix = 'observability-api-test-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$projects = [System.Collections.Generic.List[string]]::new()
$savedEnv = @{}
foreach ($key in @('POSTGRES_PASSWORD', 'POSTGRES_PORT', 'PEDIDOS_PORT', 'CLIENTS_COUNT', 'ORDERS_COUNT', 'PGPOOL_MAX', 'PGCONNECT_TIMEOUT_MS', 'PGSTATEMENT_TIMEOUT_MS', 'HTTP_TIMEOUT_MS')) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}

function Invoke-Compose {
    param([string]$Project, [string[]]$Arguments)
    $output = & docker compose @composeArgs --project-name $Project @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $diagnostic = & docker compose @composeArgs --project-name $Project logs --no-color dados-api pedidos-api 2>&1
        throw "Compose falhou em ${Project}: $($output | Select-Object -Last 8 | Out-String) $($diagnostic -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-Sql {
    param([string]$Project, [string]$Sql)
    $output = $Sql | & docker compose @composeArgs --project-name $Project exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d observability 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL falhou em $Project" }
    return ($output -join "`n").Trim()
}

function Get-Endpoint {
    param([string]$Project)
    $port = Invoke-Compose $Project @('port', 'pedidos-api', '3000')
    return 'http://' + ($port -join '').Trim()
}

function Assert-Http {
    param([string]$Endpoint, [string]$Path, [int[]]$Status, [string]$Code = '')
    $response = Invoke-WebRequest -Uri ($Endpoint + $Path) -SkipHttpErrorCheck -TimeoutSec 8
    if ($Status -notcontains [int]$response.StatusCode) { throw "HTTP inesperado em ${Path}: $($response.StatusCode), esperado $Status" }
    $json = $response.Content | ConvertFrom-Json
    if ($Code -and $json.error.code -ne $Code) { throw "Código inesperado em $Path" }
    if ([int]$response.StatusCode -eq 200 -and ($json.status -ne 'ok' -or $json.service -ne 'pedidos-api')) { throw 'Contrato de sucesso inválido' }
    if ([int]$response.StatusCode -eq 502 -and $json.error.code -ne 'BAD_GATEWAY') { throw 'Contrato de gateway inválido' }
    if ([int]$response.StatusCode -eq 504 -and $json.error.code -ne 'GATEWAY_TIMEOUT') { throw 'Contrato de timeout inválido' }
}

function Wait-Ready {
    param([string]$Endpoint)
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try { Assert-Http $Endpoint '/ready' 200; return } catch { Start-Sleep -Milliseconds 300 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Serviços não se recuperaram dentro do prazo'
}

try {
    $env:POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N')
    $env:POSTGRES_PORT = '0'
    $env:PEDIDOS_PORT = '0'
    $env:CLIENTS_COUNT = '1000'
    $env:ORDERS_COUNT = '10000'
    $env:PGPOOL_MAX = '10'
    $env:PGCONNECT_TIMEOUT_MS = '1000'
    $env:PGSTATEMENT_TIMEOUT_MS = '1000'
    $env:HTTP_TIMEOUT_MS = '3000'
    foreach ($key in @('POSTGRES_PASSWORD')) {
        $value = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, '', 'Process')
        $output = & docker compose @composeArgs config --quiet 2>&1
        if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -notmatch $key) { throw "Credencial obrigatória aceita: $key" }
        [Environment]::SetEnvironmentVariable($key, $value, 'Process')
    }
    Invoke-Compose "$prefix-config" @('config', '--quiet') | Out-Null
    $services = @(Invoke-Compose "$prefix-config" @('config', '--services'))
    if (@(Compare-Object ($services | Sort-Object) @('dados-api', 'pedidos-api', 'postgres')).Count -ne 0) { throw 'O Compose deve conter somente banco e duas APIs' }
    Write-Host 'PASS configuração válida e rejeição de credenciais ausentes'

    $signatureSql = Get-Content -Raw (Join-Path $PSScriptRoot 'database-signature.sql')
    $fresh = "$prefix-fresh"
    $projects.Add($fresh)
    Invoke-Compose $fresh @('up', '--build', '-d', '--wait', '--wait-timeout', '120') | Out-Null
    $endpoint = Get-Endpoint $fresh
    Assert-Http $endpoint '/health' 200
    Assert-Http $endpoint '/ready' 200
    Assert-Http $endpoint '/pedidos/lento' 404 'NOT_FOUND'
    $freshSignature = Invoke-Sql $fresh $signatureSql
    if ((Invoke-Sql $fresh 'SELECT (SELECT count(*) FROM clients) || ''|'' || (SELECT count(*) FROM orders);') -ne '1000|10000') { throw 'Carga padrão inválida' }
    $dataId = (Invoke-Compose $fresh @('ps', '-q', 'dados-api') -join '').Trim()
    $ports = & docker inspect --format '{{json .NetworkSettings.Ports}}' $dataId
    if ($LASTEXITCODE -ne 0 -or $ports -notmatch '"3001/tcp":null') { throw 'dados-api tem publicação de porta inesperada' }
    foreach ($service in @('dados-api', 'pedidos-api')) {
        $uid = Invoke-Compose $fresh @('exec', '-T', $service, 'id', '-u')
        if (($uid -join '').Trim() -eq '0') { throw 'API executando como root' }
    }
    Invoke-Compose $fresh @('exec', '-T', 'pedidos-api', 'node', '-e', 'process.exit(process.env.PGPASSWORD || process.env.POSTGRES_PASSWORD ? 1 : 0)') | Out-Null
    Write-Host 'PASS comando único em volume novo, contratos, isolamento e usuário não root'

    $access = Get-Content -Raw (Join-Path $PSScriptRoot 'database-access.mjs')
    $output = $access | & docker compose @composeArgs --project-name $fresh exec -T dados-api node --input-type=module 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Teste de acesso ao banco falhou: $($output -join "`n")" }
    Write-Host ($output -join "`n")
    $roleBefore = Invoke-Sql $fresh "SELECT oid || '|' || rolpassword FROM pg_authid WHERE rolname = 'postgres';"
    Invoke-Compose $fresh @('up', '--build', '-d', '--wait', '--wait-timeout', '120') | Out-Null
    if ((Invoke-Sql $fresh $signatureSql) -ne $freshSignature) { throw 'Repetir up alterou dados' }
    if ((Invoke-Sql $fresh "SELECT oid || '|' || rolpassword FROM pg_authid WHERE rolname = 'postgres';") -ne $roleBefore) { throw 'Repetir up alterou usuário ou senha' }
    Write-Host 'PASS repetição idempotente preserva dados, identidade e senha do usuário'

    Invoke-Compose $fresh @('stop', 'dados-api') | Out-Null
    # Docker pode recusar a conexão ou deixar a resolução DNS exceder o prazo HTTP.
    Assert-Http $endpoint '/ready' @(502, 504)
    Assert-Http $endpoint '/health' 200
    Invoke-Compose $fresh @('start', 'dados-api') | Out-Null
    Wait-Ready $endpoint
    Invoke-Compose $fresh @('stop', 'postgres') | Out-Null
    Assert-Http $endpoint '/ready' 503 'DEPENDENCY_UNAVAILABLE'
    Assert-Http $endpoint '/health' 200
    Invoke-Compose $fresh @('start', 'postgres') | Out-Null
    Wait-Ready $endpoint
    Write-Host 'PASS indisponibilidade e recuperação reais da dados-api e PostgreSQL'

    Invoke-Compose $fresh @('stop', 'pedidos-api', 'dados-api') | Out-Null
    foreach ($service in @('dados-api', 'pedidos-api')) {
        $id = (Invoke-Compose $fresh @('ps', '-aq', $service) -join '').Trim()
        $exit = & docker inspect --format '{{.State.ExitCode}}' $id
        if ($LASTEXITCODE -ne 0 -or $exit -ne '0') { throw "Encerramento incorreto de $service" }
    }
    Write-Host 'PASS encerramento gracioso das duas APIs'

    $existing = "$prefix-existing"
    $projects.Add($existing)
    Invoke-Compose $existing @('up', '-d', '--wait', '--wait-timeout', '60', 'postgres') | Out-Null
    $before = Invoke-Sql $existing $signatureSql
    $rolesBefore = Invoke-Sql $existing 'SELECT string_agg(rolname, '','' ORDER BY rolname) FROM pg_roles;'
    Invoke-Compose $existing @('up', '--build', '-d', '--wait', '--wait-timeout', '120') | Out-Null
    Assert-Http (Get-Endpoint $existing) '/ready' 200
    if ((Invoke-Sql $existing $signatureSql) -ne $before) { throw 'Partida das APIs alterou dados' }
    if ((Invoke-Sql $existing 'SELECT string_agg(rolname, '','' ORDER BY rolname) FROM pg_roles;') -ne $rolesBefore) { throw 'Partida das APIs criou ou removeu usuários' }
    Write-Host 'PASS APIs usam banco existente sem alterar registros ou criar usuários'

    foreach ($project in $projects) {
        $logs = Invoke-Compose $project @('logs', '--no-color')
        foreach ($secret in @($env:POSTGRES_PASSWORD)) {
            if (($logs -join "`n").Contains($secret)) { throw 'Credencial encontrada nos logs' }
        }
    }
    Write-Host 'PASS logs sem credenciais de teste; todas as verificações da Etapa 3'
} finally {
    foreach ($project in $projects) {
        & docker compose @composeArgs --project-name $project down --timeout 7 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Não foi possível encerrar $project" }
    }
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    Write-Host "Volumes preservados; projetos usados:`n$($projects -join "`n")"
}
