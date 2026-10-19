# PowerShell 7 e Docker. Todos os testes usam serviços reais e projetos isolados.
param([switch]$KeepRunning)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$composeArgs = @('--file', (Join-Path $repoRoot 'compose.yaml'), '--env-file', (Join-Path $repoRoot '.env.example'))
$prefix = 'observability-metrics-test-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$project = "$prefix-fresh"
$existing = "$prefix-existing"
$savedEnv = @{}
foreach ($key in @('POSTGRES_PASSWORD', 'POSTGRES_PORT', 'PEDIDOS_PORT', 'JAEGER_PORT', 'PROMETHEUS_PORT', 'GRAFANA_PORT', 'CLIENTS_COUNT', 'ORDERS_COUNT', 'HTTP_TIMEOUT_MS', 'OTEL_TRACES_SAMPLER', 'PGPOOL_MAX', 'PGCONNECT_TIMEOUT_MS', 'PGSTATEMENT_TIMEOUT_MS')) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
$completed = $false
function Invoke-Compose {
    param([string[]]$Arguments, [string]$ProjectName = $project)
    $output = & docker compose @composeArgs --project-name $ProjectName @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Compose falhou em ${ProjectName}: $($output | Select-Object -Last 12 | Out-String)" }
    return $output
}
function Invoke-Sql {
    param([string]$Sql, [string]$ProjectName = $project)
    $output = $Sql | & docker compose @composeArgs --project-name $ProjectName exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d observability 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL de verificação falhou em $ProjectName" }
    return ($output -join "`n").Trim()
}
function Get-Endpoint {
    param([string]$Service, [string]$Port)
    return 'http://' + ((Invoke-Compose @('port', $Service, $Port)) -join '').Trim()
}
function Wait-Until {
    param([scriptblock]$Condition, [string]$Description, [int]$Seconds = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Prazo excedido: $Description"
}
function Get-Prometheus {
    param([string]$Query, [string]$BaseUrl = $prometheus)
    $response = Invoke-RestMethod -Uri "$BaseUrl/api/v1/query?query=$([Uri]::EscapeDataString($Query))" -TimeoutSec 8
    if ($response.status -ne 'success') { throw 'PromQL falhou' }
    return @($response.data.result)
}
function Test-MetricValue {
    param([string]$Query, [double]$Value)
    $rows = @(Get-Prometheus $Query)
    return $rows.Count -eq 1 -and [double]$rows[0].value[1] -eq $Value
}
function Get-Snapshot {
    $rows = ConvertFrom-Json -InputObject (Invoke-Sql "SELECT coalesce(json_agg(s), '[]'::json) FROM ($inspectionSql) s;")
    $snapshot = @{}
    foreach ($row in $rows) { $snapshot[$row.kind] = $row }
    return $snapshot
}
function Get-Calls {
    param([hashtable]$Snapshot, [string]$Kind)
    if ($Snapshot.ContainsKey($Kind)) { return [long]$Snapshot[$Kind].calls }
    return 0L
}
function Assert-Deltas {
    param([string]$Mode, [int]$Orders, [int]$Clients, [int]$Joins)
    $before = Get-Snapshot
    $started = [DateTime]::UtcNow.ToString('o')
    $response = Invoke-WebRequest -Uri "$pedidos/pedidos/${Mode}?limit=100" -TimeoutSec 40
    $ended = [DateTime]::UtcNow.ToString('o')
    $after = Get-Snapshot
    $expected = @{ pedidos = $Orders; cliente = $Clients; join = $Joins }
    foreach ($kind in $expected.Keys) {
        if ((Get-Calls $after $kind) - (Get-Calls $before $kind) -ne $expected[$kind]) { throw "Delta SQL incorreto: $Mode / $kind" }
        if ($before.ContainsKey($kind) -and $after[$kind].stats_since -ne $before[$kind].stats_since) { throw 'Estatísticas foram reiniciadas durante a comparação' }
    }
    Write-Host "PASS snapshot UTC $started -> $ended; rota=$Mode; limit=100; chamadas=1; deltas=$($expected | ConvertTo-Json -Compress)"
    return $response.Content
}
function Get-ExporterText {
    $probe = 'fetch("http://postgres-exporter:9187/metrics",{signal:AbortSignal.timeout(8000)}).then(async r=>{if(!r.ok)process.exit(1);console.log(await r.text())}).catch(()=>process.exit(1))'
    return (Invoke-Compose @('exec', '-T', 'dados-api', 'node', '-e', $probe)) -join "`n"
}
try {
    $env:POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N')
    foreach ($key in @('POSTGRES_PORT', 'PEDIDOS_PORT', 'JAEGER_PORT', 'PROMETHEUS_PORT', 'GRAFANA_PORT')) { [Environment]::SetEnvironmentVariable($key, '0', 'Process') }
    $env:CLIENTS_COUNT = '1000'
    $env:ORDERS_COUNT = '10000'
    # Confere estatísticas, não desempenho. Evita impor o prazo de 3s ao N+1
    # enquanto a máquina inicializa e instrumenta os componentes de observabilidade.
    $env:HTTP_TIMEOUT_MS = '30000'
    $env:OTEL_TRACES_SAMPLER = 'parentbased_always_on'
    $env:PGPOOL_MAX = '10'
    $env:PGCONNECT_TIMEOUT_MS = '1000'
    $env:PGSTATEMENT_TIMEOUT_MS = '1000'
    $signatureSql = Get-Content -Raw (Join-Path $PSScriptRoot 'database-signature.sql')
    $inspectionSql = (Get-Content -Raw (Join-Path $repoRoot 'observability/postgres-exporter/statements.sql')).Trim().TrimEnd(';')
    Invoke-Compose @('config', '--quiet') | Out-Null

    # Um volume realmente inicializado sem preload nem extensão.
    $oldArgs = @('--file', (Join-Path $PSScriptRoot 'metrics-existing.compose.yaml'))
    Invoke-Compose ($oldArgs + @('up', '-d', '--wait', '--wait-timeout', '90', 'postgres')) $existing | Out-Null
    if ((Invoke-Sql "SELECT current_setting('shared_preload_libraries') = '' AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements');" $existing) -ne 't') { throw 'Cenário anterior à Etapa 6 inválido' }
    $signature = Invoke-Sql $signatureSql $existing
    $roles = Invoke-Sql "SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles;" $existing
    Invoke-Compose @('up', '-d', '--wait', '--wait-timeout', '90', 'postgres-exporter') $existing | Out-Null
    if ((Invoke-Sql "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements';" $existing) -ne '1') { throw 'Extensão ausente em volume existente' }
    if ((Invoke-Sql $signatureSql $existing) -ne $signature -or (Invoke-Sql "SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles;" $existing) -ne $roles) { throw 'Ativação alterou dados, sequences ou usuários' }
    Invoke-Compose @('up', '-d', '--wait', '--wait-timeout', '90', 'postgres-exporter') $existing | Out-Null
    if ((Invoke-Sql $signatureSql $existing) -ne $signature) { throw 'Repetir ativação alterou dados' }
    Invoke-Compose @('down', '--timeout', '7') $existing | Out-Null
    Write-Host 'PASS ativação idempotente em volume anterior à Etapa 6; dados, sequences e usuários preservados'

    Invoke-Compose @('up', '--build', '-d', '--wait', '--wait-timeout', '180') | Out-Null
    $pedidos = Get-Endpoint 'pedidos-api' '3000'
    $prometheus = Get-Endpoint 'prometheus' '9090'
    $grafana = Get-Endpoint 'grafana' '3000'
    Write-Host "Projeto: $project; Pedidos: $pedidos; Prometheus: $prometheus; Grafana: $grafana/d/postgres-experiment"
    Invoke-Compose @('exec', '-T', 'prometheus', 'promtool', 'check', 'config', '/etc/prometheus/prometheus.yml') | Out-Null
    Wait-Until { try { Test-MetricValue 'up{job="postgres"}' 1 } catch { $false } } 'primeira coleta'
    Wait-Until { Test-MetricValue 'pg_up{job="postgres"}' 1 } 'banco acessível'
    if ((Invoke-Sql "SELECT current_setting('pg_stat_statements.track') || '|' || current_setting('compute_query_id');") -ne 'top|auto') { throw 'Configuração das estatísticas incorreta' }
    $signature = Invoke-Sql $signatureSql

    $slow = Assert-Deltas 'lento' 1 100 0
    $fast = Assert-Deltas 'otimizado' 0 0 1
    if ($slow -cne $fast -or @($slow | ConvertFrom-Json).Count -ne 100) { throw 'Respostas divergentes ou incompletas' }
    $snapshot = Get-Snapshot
    Write-Host "INFO queryids desta execução: pedidos=$($snapshot.pedidos.queryid); cliente=$($snapshot.cliente.queryid); join=$($snapshot.join.queryid)"
    Wait-Until {
        $exported = @(Get-Prometheus 'pg_stat_statements_calls_total{datname="observability",user="postgres"}')
        @($exported | Where-Object { $_.metric.queryid -eq $snapshot.cliente.queryid -and [double]$_.value[1] -eq $snapshot.cliente.calls }).Count -eq 1
    } 'contador de clientes coletado'
    $first = @(Get-Prometheus "pg_stat_statements_calls_total{queryid=`"$($snapshot.cliente.queryid)`"}")[0]
    $slowAgain = Assert-Deltas 'lento' 1 100 0
    if ($slowAgain -cne $slow) { throw 'Repetição mudou a resposta' }
    Wait-Until { Test-MetricValue "pg_stat_statements_calls_total{queryid=`"$($snapshot.cliente.queryid)`"}" 200 } 'segunda amostra com evolução'
    $range = Invoke-RestMethod -Uri "$prometheus/api/v1/query?query=$([Uri]::EscapeDataString('pg_stat_statements_calls_total{queryid="' + $snapshot.cliente.queryid + '"}[2m]'))"
    if (@($range.data.result[0].values).Count -lt 2) { throw 'Menos de duas amostras reais' }
    $snapshot = Get-Snapshot
    $exported = @(Get-Prometheus 'pg_stat_statements_calls_total{datname="observability",user="postgres"}')
    foreach ($kind in @('pedidos', 'cliente', 'join')) {
        $series = @($exported | Where-Object { $_.metric.queryid -eq $snapshot[$kind].queryid })
        if ($series.Count -eq 0) { Write-Host "INFO coletor nativo não selecionou $kind; contagem SQL confirmada"; continue }
        if ($series.Count -ne 1 -or [double]$series[0].value[1] -ne $snapshot[$kind].calls) { throw "Métrica diverge do SQL: $kind" }
    }
    foreach ($name in @('pg_stat_statements_seconds_total', 'pg_stat_statements_rows_total')) {
        $series = @(Get-Prometheus "$name{queryid=`"$($snapshot.cliente.queryid)`"}")
        $expected = if ($name -eq 'pg_stat_statements_rows_total') { $snapshot.cliente.rows } else { $snapshot.cliente.total_exec_ms / 1000 }
        if ($series.Count -ne 1 -or [math]::Abs([double]$series[0].value[1] - $expected) -gt 0.000001) { throw "Métrica diverge do SQL: $name" }
    }
    Write-Host 'PASS respostas idênticas, contagens SQL exatas e métricas reais coerentes em pelo menos duas amostras'

    Wait-Until { try { (Invoke-RestMethod "$grafana/api/health" -TimeoutSec 5).database -eq 'ok' } catch { $false } } 'Grafana disponível'
    Wait-Until { try { (Invoke-RestMethod "$grafana/api/dashboards/uid/postgres-experiment" -TimeoutSec 5).meta.provisioned } catch { $false } } 'dashboard provisionado'
    $dashboard = Invoke-RestMethod "$grafana/api/dashboards/uid/postgres-experiment"
    if (-not $dashboard.meta.provisioned -or $dashboard.meta.canSave -or $dashboard.meta.canEdit -or $dashboard.meta.canAdmin) { throw 'Dashboard ou permissões incorretos' }
    $denied = Invoke-WebRequest "$grafana/api/dashboards/db" -Method Post -ContentType 'application/json' -Body '{"dashboard":{"title":"forbidden-test","uid":"forbidden-test"}}' -SkipHttpErrorCheck
    if ($denied.StatusCode -notin @(401, 403)) { throw 'Viewer conseguiu tentar gravar dashboard' }
    $proxy = Get-Prometheus 'pg_up{job="postgres"}' "$grafana/api/datasources/proxy/uid/prometheus"
    if ($proxy.Count -ne 1 -or [double]$proxy[0].value[1] -ne 1) { throw 'Datasource Grafana não consulta Prometheus' }
    foreach ($panel in $dashboard.dashboard.panels) {
        foreach ($target in $panel.targets) {
            $expression = $target.expr.Replace('${queryid:regex}', '.*').Replace('$__range', '2m')
            if (@(Get-Prometheus $expression).Count -eq 0) { throw "Painel sem dados no experimento: $($panel.title)" }
        }
    }
    $connections = @(Get-Prometheus 'pg_stat_database_numbackends{datname="observability"}')
    if ($connections.Count -ne 1 -or [double]$connections[0].value[1] -lt 1) { throw 'Métrica real de conexões ausente' }
    $text = Get-ExporterText
    if ($text -match 'pg_stat_statements_query_id|query="' -or $text.Contains($env:POSTGRES_PASSWORD)) { throw 'SQL ou credencial exportados' }
    $configuration = (Invoke-Compose @('config', '--format', 'json')) -join "`n" | ConvertFrom-Json
    foreach ($service in @('prometheus', 'grafana')) {
        foreach ($port in $configuration.services.$service.ports) { if ($port.host_ip -ne '127.0.0.1') { throw 'Porta de métricas fora de loopback' } }
    }
    if ($configuration.services.'postgres-exporter'.ports) { throw 'Exporter publicou porta' }
    Write-Host 'PASS Grafana provisionado, acesso Viewer, datasource real, conexões e privacidade'

    Invoke-Compose @('stop', 'postgres-exporter') | Out-Null
    Wait-Until { Test-MetricValue 'up{job="postgres"}' 0 } 'exporter indisponível'
    if ((Invoke-WebRequest "$pedidos/pedidos/otimizado?limit=1").StatusCode -ne 200) { throw 'API depende do exporter' }
    Invoke-Compose @('start', 'postgres-exporter') | Out-Null
    Wait-Until { Test-MetricValue 'pg_up{job="postgres"}' 1 } 'recuperação exporter'
    Invoke-Compose @('stop', 'postgres') | Out-Null
    Wait-Until { (Test-MetricValue 'pg_up{job="postgres"}' 0) -or (Test-MetricValue 'up{job="postgres"}' 0) } 'falha banco observada (banco inacessível ou coleta falhou)'
    Invoke-Compose @('up', '-d', '--wait', '--wait-timeout', '90', 'postgres') | Out-Null
    Wait-Until { Test-MetricValue 'pg_up{job="postgres"}' 1 } 'recuperação banco'
    Invoke-Compose @('stop', 'prometheus', 'grafana') | Out-Null
    if ((Invoke-WebRequest "$pedidos/pedidos/otimizado?limit=1").StatusCode -ne 200) { throw 'API depende de Prometheus/Grafana' }
    Invoke-Compose @('start', 'prometheus', 'grafana') | Out-Null
    # Publicação em porta 0 pode receber outra porta até em stop/start.
    $prometheus = Get-Endpoint 'prometheus' '9090'
    $grafana = Get-Endpoint 'grafana' '3000'
    Wait-Until { try { @(Get-Prometheus "pg_stat_statements_calls_total{queryid=`"$($snapshot.cliente.queryid)`"} @ $($first.value[0])").Count -eq 1 } catch { $false } } 'histórico preservado após stop/start'
    Invoke-Compose @('up', '-d', '--no-deps', '--force-recreate', 'prometheus') | Out-Null
    $prometheus = Get-Endpoint 'prometheus' '9090'
    Wait-Until { try { Test-MetricValue 'up{job="postgres"}' 1 } catch { $false } } 'Prometheus recriado'
    if (@(Get-Prometheus "pg_stat_statements_calls_total{queryid=`"$($snapshot.cliente.queryid)`"} @ $($first.value[0])").Count -ne 0) { throw 'Prometheus recuperou histórico anterior à recriação' }
    if ((Invoke-Sql $signatureSql) -ne $signature) { throw 'Experimento alterou dados ou sequences' }
    $logs = (Invoke-Compose @('logs', '--no-color')) -join "`n"
    if ($logs.Contains($env:POSTGRES_PASSWORD)) { throw 'Credencial encontrada nos logs' }
    if ($logs -match 'Plugin successfully installed|Downloaded and extracted grafana-') { throw 'Grafana instalou plugins adicionais na partida' }
    Wait-Until { try { (Invoke-RestMethod "$grafana/api/dashboards/uid/postgres-experiment" -TimeoutSec 5).meta.provisioned } catch { $false } } 'dashboard após stop/start' 120
    Write-Host "Inspeção: $grafana/d/postgres-experiment; Prometheus: $prometheus"
    Write-Host 'PASS falhas/recuperação, independência das APIs, histórico temporário e dados preservados'
    $completed = $true
} finally {
    foreach ($name in @($existing, $project)) {
        if ($name -eq $project -and $KeepRunning -and $completed) { continue }
        & docker compose @composeArgs --project-name $name down --timeout 7 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Não foi possível encerrar $name" }
    }
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    Write-Host "Volumes preservados: $existing e $project"
    if ($KeepRunning -and $completed) { Write-Host "Inspeção manual: $project permanece ativo; encerrar com docker compose -p $project down após a inspeção." }
}
