# PowerShell 7 e Docker. PostgreSQL real; nenhum Node.js necessário no Windows.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$composeArgs = @('--file', (Join-Path $repoRoot 'compose.yaml'), '--file', (Join-Path $PSScriptRoot 'tracing.compose.yaml'), '--env-file', (Join-Path $repoRoot '.env.example'))
$project = 'observability-tracing-test-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$savedEnv = @{}
foreach ($key in @('POSTGRES_PASSWORD', 'POSTGRES_PORT', 'PEDIDOS_PORT', 'JAEGER_PORT', 'CLIENTS_COUNT', 'ORDERS_COUNT', 'PGPOOL_MAX', 'PGCONNECT_TIMEOUT_MS', 'PGSTATEMENT_TIMEOUT_MS', 'OTEL_TRACES_SAMPLER', 'TEST_SECRET', 'TRACE_TEST_BATCH_DELAY')) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
function Invoke-Compose {
    param([string[]]$Arguments)
    $output = & docker compose @composeArgs --project-name $project @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Compose falhou: $($output | Select-Object -Last 8 | Out-String)" }
    return $output
}
function Invoke-TraceTest {
    param([string]$Stage)
    & docker run --rm --network "${project}_default" --mount "type=bind,source=$PSScriptRoot,target=/tests,readonly" --env TEST_SECRET node:22.23.1-alpine node /tests/tracing.mjs $Stage
    if ($LASTEXITCODE -ne 0) { throw "Verificação dos traces falhou: $Stage" }
}
try {
    $env:POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N')
    $env:TEST_SECRET = $env:POSTGRES_PASSWORD
    $env:POSTGRES_PORT = '0'
    $env:PEDIDOS_PORT = '0'
    $env:JAEGER_PORT = '0'
    $env:CLIENTS_COUNT = '1000'
    $env:ORDERS_COUNT = '10000'
    $env:PGPOOL_MAX = '10'
    $env:PGCONNECT_TIMEOUT_MS = '1000'
    $env:PGSTATEMENT_TIMEOUT_MS = '1000'
    $env:OTEL_TRACES_SAMPLER = 'parentbased_always_on'
    $env:TRACE_TEST_BATCH_DELAY = '1000'
    Invoke-Compose @('config', '--quiet') | Out-Null
    Invoke-Compose @('up', '--build', '-d', '--wait', '--wait-timeout', '120') | Out-Null
    Invoke-TraceTest 'verify'

    Invoke-Compose @('stop', 'jaeger') | Out-Null
    Invoke-Compose @('up', '-d', '--force-recreate', '--wait', '--wait-timeout', '120', 'dados-api', 'pedidos-api') | Out-Null
    Invoke-TraceTest 'offline'
    Invoke-Compose @('start', 'jaeger') | Out-Null
    Invoke-TraceTest 'recovered'

    Invoke-Compose @('stop', 'postgres') | Out-Null
    Invoke-TraceTest 'database-error'
    Invoke-Compose @('up', '-d', '--wait', '--wait-timeout', '120', 'postgres') | Out-Null

    # Long batch interval makes shutdown, rather than the timer, flush these spans.
    # The dedicated override is applied only to the two API processes in this project.
    Invoke-Compose @('stop', 'pedidos-api', 'dados-api') | Out-Null
    $env:TRACE_TEST_BATCH_DELAY = '60000'
    Invoke-Compose @('up', '-d', '--wait', '--wait-timeout', '120', 'dados-api', 'pedidos-api') | Out-Null
    Invoke-TraceTest 'before-shutdown'
    Invoke-Compose @('stop', 'pedidos-api', 'dados-api') | Out-Null
    Invoke-TraceTest 'after-shutdown'
    foreach ($service in @('pedidos-api', 'dados-api')) {
        $id = (Invoke-Compose @('ps', '-a', '-q', $service) -join '').Trim()
        $exitCode = & docker inspect --format '{{.State.ExitCode}}' $id
        if ($LASTEXITCODE -ne 0 -or $exitCode -ne '0') { throw "Encerramento não foi normal: $service" }
        $entries = foreach ($line in (Invoke-Compose @('logs', '--no-color', '--no-log-prefix', $service))) {
            try { ConvertFrom-Json -InputObject ([string]$line) -ErrorAction Stop } catch { }
        }
        $listening = @($entries | Where-Object { $_.event -eq 'listening' })
        if ($listening.Count -eq 0) { throw "Evento listening ausente nos logs de $service" }
        foreach ($entry in $listening) {
            if ($entry.service -cne $service) { throw "Nome de serviço incorreto no evento listening de $service" }
        }
    }
    Write-Host 'PASS eventos listening identificam corretamente cada serviço'
    $logs = (Invoke-Compose @('logs', '--no-color')) -join "`n"
    foreach ($marker in @($env:POSTGRES_PASSWORD, 'fictional-header-marker', 'fictional-query-marker', 'fictional-path-marker')) {
        if ($logs.Contains($marker)) { throw 'Dado sensível encontrado nos logs' }
    }
    Write-Host 'PASS logs sem credencial e marcadores fictícios; processos encerrados normalmente'
} finally {
    & docker compose @composeArgs --project-name $project down --timeout 7 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Não foi possível encerrar $project" }
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    Write-Host "Volume preservado; projeto usado: $project"
}
