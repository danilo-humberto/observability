# Observabilidade de Banco de Dados

Projeto do seminário de Sistemas Distribuídos do IFPE. Comparamos a busca de pedidos com **N+1** (uma consulta de pedidos e outra por pedido) e com **JOIN** (uma consulta que combina pedidos e clientes). As duas rotas retornam os mesmos dados; Jaeger, Prometheus e Grafana ajudam a observar o que acontece.

## Iniciar

Requisitos: Docker com contêineres Linux, Docker Compose com `--wait` e PowerShell 7. Execute na raiz do repositório:

```powershell
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
# Preencha POSTGRES_PASSWORD em .env; preserve a senha de um volume já existente.
docker compose -p observability config --quiet
docker compose -p observability up --build -d --wait
```

O banco novo recebe 1.000 clientes e 10.000 pedidos por padrão. As portas locais padrão são 3000 (pedidos-api), 5432 (PostgreSQL), 16686 (Jaeger), 9090 (Prometheus) e 3002 (Grafana). Valores diferentes podem ser definidos no `.env`.

## Reproduzir a demonstração

As URLs abaixo usam as portas padrão. Ajuste-as se alterou o `.env`. Faça as comparações sem outra carga ou suíte de testes rodando.

**1. Compare as respostas.** As duas rotas devem devolver os mesmos 100 pedidos, na mesma ordem e no mesmo JSON:

```powershell
Invoke-RestMethod 'http://127.0.0.1:3000/ready'
$lento = Invoke-WebRequest 'http://127.0.0.1:3000/pedidos/lento?limit=100'
$join = Invoke-WebRequest 'http://127.0.0.1:3000/pedidos/otimizado?limit=100'
$pedidos = ConvertFrom-Json -InputObject $lento.Content -NoEnumerate
if ($pedidos.Count -ne 100) { throw 'A carga não retornou 100 pedidos.' }
if ($lento.Content -cne $join.Content) { throw 'As respostas são diferentes.' }
'Respostas idênticas.'
```

**2. Veja as consultas.** Abra [Jaeger](http://127.0.0.1:16686), selecione `pedidos-api` e procure os traces recentes das duas rotas. Para 100 pedidos, a lenta faz **101 consultas SQL** (pedidos + um cliente por pedido); a otimizada faz **uma**, com `JOIN`. No [Grafana](http://127.0.0.1:3002/d/postgres-experiment), acompanhe disponibilidade, conexões e estatísticas do PostgreSQL. Os gráficos são amostrados a cada 5 segundos. Para confirmar as contagens exatas, faça snapshots antes e depois de **uma chamada por vez** com `observability/postgres-exporter/statements.sql`, seguindo o [roteiro de apresentação](docs/roteiro-apresentacao.md#4-contar-as-consultas-sql-sem-zerar-estatísticas). Não zere os contadores: compare a diferença da coluna `calls`.

**3. Compare o desempenho medido.** O [experimento de carga](docs/experimento-carga.md) registra método, resultados e limitações. Na execução de 19/10/2026, a mediana das médias HTTP com concorrência 1 foi 95,42 ms na rota lenta e 11,46 ms no `JOIN`. São resultados daquela máquina, não uma garantia para outras condições. Para produzir medições locais novas, execute `pwsh -NoProfile -File tests/Test-Load.ps1` separadamente da demonstração.

## Reproduzir uma falha e a recuperação

Este cenário interrompe **somente o PostgreSQL local**. O volume e os dados permanecem. Depois de parar o banco, verifique os códigos HTTP sem fazer o PowerShell interromper a leitura de respostas de erro:

```powershell
docker compose -p observability stop postgres
$health = Invoke-WebRequest 'http://127.0.0.1:3000/health' -SkipHttpErrorCheck
$ready = Invoke-WebRequest 'http://127.0.0.1:3000/ready' -SkipHttpErrorCheck
$pedidos = Invoke-WebRequest 'http://127.0.0.1:3000/pedidos/otimizado?limit=5' -SkipHttpErrorCheck
$health.StatusCode, $ready.StatusCode, $pedidos.StatusCode
$pedidos.Content
```

O esperado é `/health` **200**, pois o processo HTTP continua ativo, enquanto `/ready` e a rota de pedidos falham. Nesta máquina, ambas retornaram **503 `DEPENDENCY_UNAVAILABLE`**. Se a comunicação estourar o prazo, a pedidos-api pode retornar **504 `GATEWAY_TIMEOUT`**. No Grafana, após algumas coletas, `pg_up=0` indica que o exporter respondeu e não alcançou o banco; se a coleta falhar, `up=0` e `pg_up` pode ficar ausente. Consulte `docker compose -p observability logs --tail 50 postgres dados-api pedidos-api` para diagnosticar. Reative o banco e confirme a recuperação:

```powershell
docker compose -p observability up -d --wait postgres
Invoke-RestMethod 'http://127.0.0.1:3000/ready'
Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/otimizado?limit=5' | Out-Null
```

`/ready` deve voltar a responder 200 e `pg_up` deve voltar a 1 após nova coleta. Se a API ainda estiver reconectando, repita a verificação após alguns segundos. O [guia do ambiente](docs/guia-ambiente.md#rotas-e-falhas) explica os códigos de erro; o [roteiro](docs/roteiro-apresentacao.md) traz a apresentação completa.

## Encerrar

```powershell
docker compose -p observability down
```

O comando preserva o volume do PostgreSQL. O histórico temporário de traces e métricas é perdido quando os contêineres são removidos.

## Documentação

- [Guia do ambiente](docs/guia-ambiente.md): configuração, rotas, falhas, dados, observabilidade e comandos de verificação.
- [Roteiro de apresentação](docs/roteiro-apresentacao.md): demonstração passo a passo.
- [Arquitetura](docs/arquitetura.md): responsabilidades e fluxo entre os componentes.
- [Experimento de carga](docs/experimento-carga.md): método, números medidos e limitações.
- [Plano de implementação](docs/plano-implementacao.md): escopo e validação das oito etapas.

Os resultados de desempenho são locais e históricos; execute o experimento novamente para medir sua máquina. As [orientações do projeto](AGENTS.md) explicam como trabalhar nas próximas mudanças.
