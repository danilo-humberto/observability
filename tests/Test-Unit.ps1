# Compila e executa testes dentro de imagens Docker; dispensa Node.js no Windows.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
foreach ($service in @('dados-api', 'pedidos-api')) {
    $image = "observability-$service-tests:local"
    & docker build --target build --tag $image (Join-Path $repoRoot "services/$service")
    if ($LASTEXITCODE -ne 0) { throw "Build de testes falhou: $service" }
    & docker run --rm --mount "type=bind,source=$PSScriptRoot,target=/tests,readonly" --env SERVICE_DIST_URL=file:///app/dist/ $image node --test "/tests/$service.test.mjs"
    if ($LASTEXITCODE -ne 0) { throw "Testes falharam: $service" }
}
