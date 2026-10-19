# Requer PowerShell e Docker Compose. Cria somente projetos isolados.
# Encerra os contêineres ao final e preserva TODOS os volumes criados.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$composeArgs = @('--file', (Join-Path $repoRoot 'compose.yaml'), '--env-file', (Join-Path $repoRoot '.env.example'))
$prefix = 'observability-test-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$projects = [System.Collections.Generic.List[string]]::new()
$savedEnv = @{}
foreach ($key in @('POSTGRES_PASSWORD', 'POSTGRES_PORT', 'CLIENTS_COUNT', 'ORDERS_COUNT')) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}

function Invoke-Compose {
    param([string]$Project, [string[]]$Arguments)
    $output = & docker compose @composeArgs --project-name $Project @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Compose falhou em ${Project}: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-Sql {
    param([string]$Project, [string]$Sql)
    $output = $Sql | & docker compose @composeArgs --project-name $Project exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d observability 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL falhou em ${Project}: $($output -join [Environment]::NewLine)" }
    return ($output -join "`n").Trim()
}

function Start-Scenario {
    param([string]$Name, [string]$Clients, [string]$Orders)
    $env:CLIENTS_COUNT = $Clients
    $env:ORDERS_COUNT = $Orders
    $project = "$prefix-$Name"
    $projects.Add($project)
    Invoke-Compose $project @('up', '-d', '--wait', '--wait-timeout', '60', 'postgres') | Out-Null
    return $project
}

function Assert-Counts {
    param([string]$Project, [int]$Clients, [int]$Orders)
    $actual = Invoke-Sql $Project 'SELECT (SELECT count(*) FROM clients) || ''|'' || (SELECT count(*) FROM orders);'
    if ($actual -ne "$Clients|$Orders") { throw "Contagens inesperadas em ${Project}: $actual" }
    Write-Host "PASS contagens ${Project}: $actual"
}

function Assert-Constraints {
    param([string]$Project)
    $before = Invoke-Sql $Project $signatureSql
    Invoke-Sql $Project $checks | Out-Null
    if ((Invoke-Sql $Project $signatureSql) -ne $before) {
        throw "Verificação de restrições alterou registros ou sequences em $Project"
    }
}

try {
    $env:POSTGRES_PASSWORD = ''
    $output = & docker compose @composeArgs --project-name "$prefix-config" config --quiet 2>&1
    if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -notmatch 'POSTGRES_PASSWORD') {
        throw 'Configuração sem senha não foi rejeitada como esperado'
    }
    Write-Host 'PASS senha obrigatória'

    # Credencial efêmera apenas na memória do processo; não é impressa.
    $env:POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N')
    $env:POSTGRES_PORT = '0' # Docker atribui porta livre, sempre em loopback.
    $env:CLIENTS_COUNT = '1000'
    $env:ORDERS_COUNT = '10000'
    Invoke-Compose "$prefix-config" @('config', '--quiet') | Out-Null
    Write-Host 'PASS docker compose config --quiet'

    $first = Start-Scenario 'default-a' '1000' '10000'
    Assert-Counts $first 1000 10000
    $signatureSql = Get-Content -Raw (Join-Path $PSScriptRoot 'database-signature.sql')
    $signature = Invoke-Sql $first $signatureSql
    $second = Start-Scenario 'default-b' '1000' '10000'
    Assert-Counts $second 1000 10000
    if ((Invoke-Sql $second $signatureSql) -ne $signature) { throw 'Cargas padrão divergentes' }
    Write-Host "PASS reprodução em volumes distintos`n$signature"

    # Falha após criar E carregar tabelas: nada deve ser confirmado.
    $output = & docker compose @composeArgs --project-name $second exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 --single-transaction -U postgres -d observability --set=clients_count=3 --set=orders_count=8 --command='CREATE SCHEMA stage2_rollback; SET search_path TO stage2_rollback;' --file=/opt/database/schema.sql --file=/opt/database/seed.sql --command='SELECT 1 / 0;' 2>&1
    if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -notmatch 'division by zero') {
        throw 'Falha transacional não foi provocada como esperado'
    }
    if ((Invoke-Sql $second "SELECT to_regnamespace('stage2_rollback') IS NULL;") -ne 't') {
        throw 'Transação com erro deixou o esquema de teste gravado'
    }
    if ((Invoke-Sql $second $signatureSql) -ne $signature) { throw 'Teste transacional alterou a carga original' }
    Write-Host 'PASS rollback de modelo e carga após erro SQL'

    $checks = Get-Content -Raw (Join-Path $PSScriptRoot 'database-checks.sql')
    Assert-Constraints $first
    Assert-Counts $first 1000 10000
    Write-Host 'PASS integridade, NOT NULL, valor não negativo e exclusão sem cascata'

    Invoke-Compose $first @('restart', 'postgres') | Out-Null
    Invoke-Compose $first @('up', '-d', '--wait', '--wait-timeout', '60', 'postgres') | Out-Null
    if ((Invoke-Sql $first $signatureSql) -ne $signature) { throw 'Reinício alterou os dados' }
    Write-Host 'PASS persistência após reinício'

    $small = Start-Scenario 'small' '3' '8'
    Assert-Counts $small 3 8
    $distribution = Invoke-Sql $small 'SELECT string_agg(client_id::text, '','' ORDER BY id) FROM orders;'
    if ($distribution -ne '1,2,3,1,2,3,1,2') { throw 'Distribuição circular incorreta' }
    Assert-Constraints $small
    Write-Host 'PASS quantidades ajustáveis e distribuição circular'

    $empty = Start-Scenario 'empty' '1' '0'
    Assert-Counts $empty 1 0
    Assert-Constraints $empty
    Write-Host 'PASS conjunto de pedidos vazio'

    $invalidCases = @(
        @('no-clients', '0', '1'),
        @('negative-orders', '1', '-1'),
        @('fraction', '1.5', '1'),
        @('text', '1', 'abc'),
        @('blank', '', '1'),
        @('overflow', '2147483648', '1')
    )
    foreach ($case in $invalidCases) {
        $project = "$prefix-$($case[0])"
        $projects.Add($project)
        $env:CLIENTS_COUNT = $case[1]
        $env:ORDERS_COUNT = $case[2]
        $output = & docker compose @composeArgs --project-name $project up -d --wait --wait-timeout 30 postgres 2>&1
        if ($LASTEXITCODE -eq 0) { throw "Parâmetro inválido aceito: $($case[0])" }
        $logs = Invoke-Compose $project @('logs', '--no-color', 'postgres')
        if (($logs -join "`n") -notmatch 'COUNT deve ser um inteiro') {
            throw "Falha sem diagnóstico esperado em ${project}: $($output -join "`n")"
        }
        Write-Host "PASS parâmetro inválido: $($case[0])"
    }
    Write-Host 'PASS todas as verificações da Etapa 2'
}
finally {
    foreach ($project in $projects) {
        & docker compose @composeArgs --project-name $project down --timeout 5 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Não foi possível encerrar $project" }
    }
    foreach ($key in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process')
    }
    if ($projects.Count -gt 0) {
        Write-Host "Volumes preservados; projetos usados:`n$($projects -join "`n")"
    }
}
