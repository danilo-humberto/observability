# PowerShell 7 e Docker. Projetos isolados; encerra contêineres e preserva volumes.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$composeArgs = @('--file', (Join-Path $repoRoot 'compose.yaml'), '--file', (Join-Path $PSScriptRoot 'orders.compose.yaml'), '--env-file', (Join-Path $repoRoot '.env.example'))
$prefix = 'observability-orders-test-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$projects = [System.Collections.Generic.List[string]]::new()
$savedEnv = @{}
foreach ($key in @('POSTGRES_PASSWORD', 'POSTGRES_PORT', 'PEDIDOS_PORT', 'CLIENTS_COUNT', 'ORDERS_COUNT', 'PGPOOL_MAX', 'PGCONNECT_TIMEOUT_MS', 'PGSTATEMENT_TIMEOUT_MS', 'HTTP_TIMEOUT_MS')) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}

function Invoke-Compose {
    param([string]$Project, [string[]]$Arguments)
    $output = & docker compose @composeArgs --project-name $Project @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Compose falhou em ${Project}: $($output | Select-Object -Last 10 | Out-String)" }
    return $output
}
function Invoke-Sql {
    param([string]$Project, [string]$Sql)
    $output = $Sql | & docker compose @composeArgs --project-name $Project exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d observability 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL de verificação falhou em $Project" }
    return ($output -join "`n").Trim()
}
function Get-Counts {
    param([string]$Project)
    $logs = (Invoke-Compose $Project @('logs', '--no-color', 'postgres')) -join "`n"
    return @{
        Orders = [regex]::Matches($logs, '(?:statement:|execute [^:]+:) SELECT (?:o\.id|id, client_id)').Count
        Clients = [regex]::Matches($logs, '(?:statement:|execute [^:]+:) SELECT id, name FROM clients WHERE id = \$1').Count
        Joins = [regex]::Matches($logs, 'FROM orders o INNER JOIN clients c ON c.id = o.client_id').Count
    }
}
function Assert-Orders {
    param([string]$Project, [string]$Endpoint, [int]$Limit, [switch]$Default)
    $expected = Invoke-Sql $Project "SELECT COALESCE(json_agg(result ORDER BY id), '[]'::json) FROM (SELECT o.id, o.client_id, o.description, o.amount::text AS amount, to_char(o.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD`"T`"HH24:MI:SS.MS`"Z`"') AS created_at, json_build_object('id', c.id, 'name', c.name) AS client FROM orders o JOIN clients c ON c.id = o.client_id ORDER BY o.id LIMIT $Limit) result;"
    $expectedRows = ConvertFrom-Json -InputObject $expected -NoEnumerate
    $expectedJson = ConvertTo-Json -InputObject $expectedRows -Depth 8 -Compress
    $responses = @{}
    foreach ($mode in @('lento', 'otimizado')) {
        $before = Get-Counts $Project
        $path = "/pedidos/$mode"
        if (-not $Default) { $path += "?limit=$Limit" }
        $response = Invoke-WebRequest -Uri ($Endpoint + $path) -SkipHttpErrorCheck -TimeoutSec 40
        if ($response.StatusCode -ne 200) { throw "Falha em ${path}: HTTP $($response.StatusCode)" }
        $rows = ConvertFrom-Json -InputObject $response.Content -NoEnumerate
        if ($rows -isnot [array]) { throw 'A resposta deve ser uma lista direta' }
        $json = ConvertTo-Json -InputObject $rows -Depth 8 -Compress
        if ($json -cne $expectedJson) { throw "Conteúdo inesperado em $path" }
        $after = Get-Counts $Project
        $clientQueries = if ($mode -eq 'lento') { $rows.Count } else { 0 }
        $joins = if ($mode -eq 'otimizado') { 1 } else { 0 }
        if (($after.Orders - $before.Orders) -ne 1 -or ($after.Clients - $before.Clients) -ne $clientQueries -or ($after.Joins - $before.Joins) -ne $joins) {
            throw "Contagem SQL inesperada em ${path}: antes=$($before | ConvertTo-Json -Compress), depois=$($after | ConvertTo-Json -Compress)"
        }
        $responses[$mode] = $response.Content
        Write-Host "PASS $Project $path : $($rows.Count) pedidos; $(1 + $clientQueries) consultas reais; JOIN=$joins"
    }
    if ($responses.lento -cne $responses.otimizado) { throw 'Respostas completas diferem entre as rotas' }
}

try {
    $env:POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N')
    $env:POSTGRES_PORT = '0'
    $env:PEDIDOS_PORT = '0'
    $env:PGPOOL_MAX = '10'
    $env:PGCONNECT_TIMEOUT_MS = '1000'
    $env:PGSTATEMENT_TIMEOUT_MS = '1000'
    $env:HTTP_TIMEOUT_MS = '3000'
    foreach ($scenario in @(
        @{ Name = 'standard'; Clients = 1000; Orders = 10000 },
        @{ Name = 'repeated'; Clients = 3; Orders = 8 },
        @{ Name = 'empty'; Clients = 1; Orders = 0 }
    )) {
        $project = "$prefix-$($scenario.Name)"
        $projects.Add($project)
        $env:CLIENTS_COUNT = [string]$scenario.Clients
        $env:ORDERS_COUNT = [string]$scenario.Orders
        Invoke-Compose $project @('config', '--quiet') | Out-Null
        Invoke-Compose $project @('up', '--build', '-d', '--wait', '--wait-timeout', '120') | Out-Null
        $endpoint = 'http://' + ((Invoke-Compose $project @('port', 'pedidos-api', '3000')) -join '').Trim()
        $signatureSql = Get-Content -Raw (Join-Path $PSScriptRoot 'database-signature.sql')
        $beforeSignature = Invoke-Sql $project $signatureSql
        Assert-Orders $project $endpoint 100 -Default
        Assert-Orders $project $endpoint 1
        Assert-Orders $project $endpoint 1000
        if ($scenario.Name -eq 'standard') {
            Write-Host 'PASS limite 1000 com HTTP_TIMEOUT_MS=3000 (sem medir desempenho)'
            # Exercita também um prazo maior apenas no ambiente de teste.
            $env:HTTP_TIMEOUT_MS = '30000'
            Invoke-Compose $project @('up', '-d', '--wait', '--wait-timeout', '120', 'pedidos-api') | Out-Null
            $endpoint = 'http://' + ((Invoke-Compose $project @('port', 'pedidos-api', '3000')) -join '').Trim()
            Assert-Orders $project $endpoint 1000
            $env:HTTP_TIMEOUT_MS = '3000'
            Invoke-Compose $project @('up', '-d', '--wait', '--wait-timeout', '120', 'pedidos-api') | Out-Null
            $endpoint = 'http://' + ((Invoke-Compose $project @('port', 'pedidos-api', '3000')) -join '').Trim()
        }
        foreach ($mode in @('lento', 'otimizado')) {
            foreach ($query in @('limit=', 'limit=0', 'limit=-1', 'limit=1.5', 'limit=1001', 'limit=abc', 'limit=1&limit=2', 'limit[]=1', 'limit[x]=1')) {
                $before = Get-Counts $project
                $response = Invoke-WebRequest -Uri "$endpoint/pedidos/${mode}?$query" -SkipHttpErrorCheck
                if ($response.StatusCode -ne 400 -or ($response.Content | ConvertFrom-Json).error.code -ne 'INVALID_LIMIT') { throw "limit inválido aceito: $query" }
                $after = Get-Counts $project
                if ($before.Orders -ne $after.Orders -or $before.Clients -ne $after.Clients) { throw 'limit inválido acessou o banco' }
            }
        }
        # A dados-api não publica porta; valida seu contrato diretamente pela rede interna.
        $probe = @'
for (const mode of ['lento', 'otimizado']) {
  for (const query of ['limit=', 'limit=1001', 'limit=1&limit=2', 'limit[]=1', 'limit[x]=1']) {
    const response = await fetch(`http://127.0.0.1:3001/pedidos/${mode}?${query}`);
    if (response.status !== 400 || (await response.json()).error.code !== 'INVALID_LIMIT') process.exit(1);
  }
}
'@
        Invoke-Compose $project @('exec', '-T', 'dados-api', 'node', '--input-type=module', '-e', $probe) | Out-Null
        if ((Invoke-Sql $project $signatureSql) -ne $beforeSignature) { throw 'As leituras alteraram os dados' }
        if ($scenario.Name -eq 'repeated') {
            Invoke-Compose $project @('stop', 'postgres') | Out-Null
            foreach ($mode in @('lento', 'otimizado')) {
                $response = Invoke-WebRequest -Uri "$endpoint/pedidos/$mode" -SkipHttpErrorCheck -TimeoutSec 10
                if ($response.StatusCode -ne 503 -or ($response.Content | ConvertFrom-Json).error.code -ne 'DEPENDENCY_UNAVAILABLE') { throw 'Falha do banco não foi propagada' }
            }
            Invoke-Compose $project @('up', '-d', '--wait', '--wait-timeout', '120') | Out-Null
            Assert-Orders $project $endpoint 100
        }
        $logs = (Invoke-Compose $project @('logs', '--no-color')) -join "`n"
        if ($logs.Contains($env:POSTGRES_PASSWORD)) { throw 'Credencial encontrada nos logs' }
        Write-Host 'PASS parâmetros nas duas APIs, dados preservados e logs sem credencial de teste'
        Invoke-Compose $project @('down', '--timeout', '7') | Out-Null
    }
} finally {
    foreach ($project in $projects) {
        & docker compose @composeArgs --project-name $project down --timeout 7 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Não foi possível encerrar $project" }
    }
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    Write-Host "Volumes preservados; projetos usados:`n$($projects -join "`n")"
}
