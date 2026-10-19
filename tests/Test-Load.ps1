# PowerShell 7 e Docker. Experimento local isolado; não remove volumes.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$project = 'observability-load-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$resultDir = Join-Path $repoRoot "test-results/$project"
$composeArgs = @('--file', (Join-Path $repoRoot 'compose.yaml'), '--file', (Join-Path $PSScriptRoot 'load.compose.yaml'), '--env-file', (Join-Path $repoRoot '.env.example'), '--project-name', $project)
$savedEnv = @{}
$settings = @{
    POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N'); LOAD_RESULTS_DIR = $resultDir.Replace('\', '/')
    POSTGRES_PORT = '0'; PEDIDOS_PORT = '0'; JAEGER_PORT = '0'; PROMETHEUS_PORT = '0'; GRAFANA_PORT = '0'
    CLIENTS_COUNT = '1000'; ORDERS_COUNT = '10000'; HTTP_TIMEOUT_MS = '3000'
    OTEL_TRACES_SAMPLER = 'parentbased_always_on'; PGPOOL_MAX = '10'
    PGCONNECT_TIMEOUT_MS = '1000'; PGSTATEMENT_TIMEOUT_MS = '1000'
}
$runs = [System.Collections.Generic.List[object]]::new()
$metadata = [ordered]@{ project = $project; startedUtc = [DateTime]::UtcNow.ToString('o'); status = 'running'; limit = 100; warmupSeconds = 10; durationSeconds = 30; rounds = 3; concurrency = @(1, 5); settings = @{} }
function Invoke-Compose {
    param([string[]]$Arguments)
    $output = & docker compose @composeArgs @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Compose falhou: $($Arguments[0]) (saída omitida para preservar credenciais)" }
    return $output
}
function Invoke-Sql {
    param([string]$Sql)
    $output = $Sql | & docker compose @composeArgs exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d observability 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Falha na inspeção SQL' }
    return ($output -join "`n").Trim()
}
function Wait-Idle {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $active = Invoke-Sql "SELECT count(*) FROM pg_stat_activity WHERE application_name='dados-api' AND state IS DISTINCT FROM 'idle' AND query NOT LIKE 'SELECT 1%';"
        if ($active -eq '0') {
            # Estatísticas acumuladas podem atrasar; confirmar repouso após dois segundos.
            Start-Sleep -Seconds 2
            $active = Invoke-Sql "SELECT count(*) FROM pg_stat_activity WHERE application_name='dados-api' AND state IS DISTINCT FROM 'idle' AND query NOT LIKE 'SELECT 1%';"
            if ($active -eq '0') { return }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Sem repouso em 30 segundos; comparação interrompida'
}
function Get-Snapshot {
    $sql = "SELECT json_build_object('capturedUtc', clock_timestamp(), 'info', (SELECT row_to_json(i) FROM pg_stat_statements_info i), 'queries', (SELECT coalesce(json_agg(s), '[]'::json) FROM ($inspectionSql) s));"
    return Invoke-Sql $sql | ConvertFrom-Json
}
function Save-Results {
    [ordered]@{ metadata = $metadata; runs = @($runs.ToArray()) } | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $resultDir 'summary.json') -Encoding utf8
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Resultados da Etapa 7')
    $lines.Add('')
    $lines.Add("Projeto: $project. Estado: $($metadata.status). Datas e janelas no summary.json estão em UTC.")
    $lines.Add('')
    $lines.Add('| Concorrência | Rodada | Rota | Chamadas | Sucessos | Erros | Média ms | Mediana ms | p95 ms | Sucessos/s | Consultas SQL | SQL válido |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($run in $runs) {
        $s = $run.summary
        $errors = $s.started - $s.successes
        $lines.Add("| $($run.concurrency) | $($run.round) | $($run.route) | $($s.started) | $($s.successes) | $errors | $($s.meanMs) | $($s.medianMs) | $($s.p95Ms) | $($s.successesPerSecond) | $($run.sqlCalls) | $($run.sqlValid) |")
    }
    $lines.Add('')
    $lines.Add('## Mediana das três rodadas')
    $lines.Add('')
    $lines.Add('| Concorrência | Rota | Mediana das médias ms | Mediana dos p95 ms | Mediana dos sucessos/s |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($group in ($runs | Group-Object -Property { $_.concurrency }, { $_.route })) {
        $items = @($group.Group)
        if ($items.Count -ne 3 -or @($items | Where-Object { $null -eq $_.summary.meanMs }).Count) { continue }
        $mean = @($items.summary.meanMs | Sort-Object)[1]
        $p95 = @($items.summary.p95Ms | Sort-Object)[1]
        $rate = @($items.summary.successesPerSecond | Sort-Object)[1]
        $lines.Add("| $($items[0].concurrency) | $($items[0].route) | $mean | $p95 | $rate |")
    }
    $lines.Add('')
    $lines.Add('Percentis por nearest rank; p95 agregado acima é a mediana dos p95 de cada rodada, não o p95 de todas as amostras. Latências incluem corpo completo e somente respostas válidas; erros aparecem separadamente. Vazão usa o tempo efetivo incluindo drenagem. Aquecimento é excluído dos deltas SQL. Resultados locais com observabilidade ligada e recursos compartilhados com o gerador; não medem capacidade máxima nem custo isolado da instrumentação. Consultas podem continuar após timeout HTTP. Em execuções com erros, SQL observado não equivale à quantidade de respostas válidas. Dados inválidos ou parciais não sustentam uma comparação de ganho.')
    $lines | Set-Content (Join-Path $resultDir 'report.md') -Encoding utf8
}
try {
    New-Item -ItemType Directory -Path $resultDir | Out-Null
    foreach ($key in $settings.Keys) {
        $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $settings[$key], 'Process')
        if ($key -notin @('POSTGRES_PASSWORD', 'LOAD_RESULTS_DIR')) { $metadata.settings[$key] = $settings[$key] }
    }
    $inspectionSql = (Get-Content -Raw (Join-Path $repoRoot 'observability/postgres-exporter/statements.sql')).Trim().TrimEnd(';')
    $signatureSql = Get-Content -Raw (Join-Path $PSScriptRoot 'database-signature.sql')
    Invoke-Compose @('config', '--quiet') | Out-Null
    $metadata.dockerResources = (& docker info --format '{{json .NCPU}}|{{json .MemTotal}}') -join ''
    if ($LASTEXITCODE -ne 0) { throw 'Docker indisponível' }
    $metadata.dockerVersion = (& docker version --format '{{.Client.Version}}|{{.Server.Version}}') -join ''
    $metadata.gitRevision = (& git -C $repoRoot rev-parse HEAD 2>$null) -join ''
    $metadata.gitDirty = [bool]((& git -C $repoRoot status --porcelain 2>$null) -join '')
    Save-Results
    Write-Host "Projeto: $project; resultados: $resultDir"
    Invoke-Compose @('up', '--build', '-d', '--wait', '--wait-timeout', '180') | Out-Null
    Invoke-Compose @('run', '--rm', '--no-deps', '--entrypoint', 'node', 'load-generator', '--test', '/tests/load.test.mjs') | Write-Host
    $metadata.images = @((Invoke-Compose @('images', '--format', 'json')) | ForEach-Object { $_ | ConvertFrom-Json } | Select-Object Repository, Tag, ID)
    $metadata.generatorImage = 'node:22.23.1-alpine'
    $metadata.nodeVersion = ((Invoke-Compose @('run', '--rm', '--no-deps', '--entrypoint', 'node', 'load-generator', '--version')) -join "`n").Trim()
    $signature = Invoke-Sql $signatureSql
    $metadata.databaseSignatureBefore = $signature
    Invoke-Compose @('run', '--rm', '--no-deps', 'load-generator', 'verify') | Out-Null
    foreach ($concurrency in @(1, 5)) {
        foreach ($round in 1..3) {
            $routes = if ($round % 2 -eq 1) { @('lento', 'otimizado') } else { @('otimizado', 'lento') }
            foreach ($route in $routes) {
                $name = "c$concurrency-r$round-$route"
                Write-Host "Aquecimento e medição: $name"
                Wait-Idle
                Invoke-Compose @('run', '--rm', '--no-deps', 'load-generator', 'run', $route, "$concurrency", '10', "warm-$name") | Out-Null
                Wait-Idle
                $before = Get-Snapshot
                Invoke-Compose @('run', '--rm', '--no-deps', 'load-generator', 'run', $route, "$concurrency", '30', $name) | Out-Null
                $result = Get-Content -Raw (Join-Path $resultDir "$name.json") | ConvertFrom-Json
                $run = [ordered]@{ route = $route; concurrency = $concurrency; round = $round; samplesFile = "$name.json"; startedUtc = $result.startedUtc; endedUtc = $result.endedUtc; summary = $result.summary; before = $before; after = $null; sqlCalls = $null; sqlValid = $false }
                $runs.Add($run)
                Save-Results
                Wait-Idle
                $after = Get-Snapshot
                $run.after = $after
                $valid = $before.info.stats_reset -eq $after.info.stats_reset -and $before.info.dealloc -eq $after.info.dealloc
                $calls = 0L
                $deltas = @{}
                foreach ($kind in @('pedidos', 'cliente', 'join')) {
                    $previous = @($before.queries | Where-Object kind -eq $kind)
                    $current = @($after.queries | Where-Object kind -eq $kind)
                    if ($previous.Count -ne 1 -or $current.Count -ne 1) { $valid = $false; continue }
                    if ($previous[0].queryid -ne $current[0].queryid -or $previous[0].stats_since -ne $current[0].stats_since) { $valid = $false }
                    $delta = [long]$current[0].calls - [long]$previous[0].calls
                    if ($delta -lt 0) { $valid = $false }
                    $deltas[$kind] = $delta
                    $calls += $delta
                }
                $run.sqlCalls = $calls
                $run.sqlDeltas = $deltas
                $run.sqlValid = $valid
                Save-Results
                if (-not $valid) { throw 'Estatísticas SQL inválidas; resultados parciais preservados' }
                if ($result.summary.started -eq $result.summary.successes) {
                    $expected = if ($route -eq 'lento') { @{ pedidos = $result.summary.successes; cliente = 100L * $result.summary.successes; join = 0L } } else { @{ pedidos = 0L; cliente = 0L; join = $result.summary.successes } }
                    foreach ($kind in $expected.Keys) {
                        if ($deltas[$kind] -ne $expected[$kind]) { $run.sqlValid = $false; throw 'Contagem SQL inesperada; resultados parciais preservados' }
                    }
                }
                Write-Host "Medição concluída: $name; sucessos=$($result.summary.successes)/$($result.summary.started); SQL=$calls"
            }
        }
    }
    $metadata.databaseSignatureAfter = Invoke-Sql $signatureSql
    if ($metadata.databaseSignatureAfter -cne $signature) { throw 'Dados ou sequences foram alterados' }
    $metadata.status = 'completed'
} catch {
    $metadata.status = 'failed'
    $metadata.failure = $_.Exception.Message
    throw
} finally {
    if (Test-Path $resultDir) { $metadata.endedUtc = [DateTime]::UtcNow.ToString('o'); Save-Results }
    & docker compose @composeArgs down --timeout 7 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Falha ao encerrar $project; conferir manualmente" }
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    Write-Host "Resultados preservados: $resultDir; volume preservado: ${project}_postgres_data"
}
