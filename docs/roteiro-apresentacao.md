# Etapa 8 — Roteiro da apresentação

Este roteiro mostra, em um ambiente local, por que uma busca de 100 pedidos pode gerar 101 consultas SQL, como o JOIN reduz essa quantidade a uma e o que ocorre quando o banco fica indisponível. Use PowerShell 7 na raiz do repositório. Os comandos pressupõem as portas padrão do `.env.example`; se você as alterou, substitua as URLs. Não execute outra carga ou suíte de testes durante a comparação de contadores.

## 1. Preparar e iniciar

É necessário Docker com contêineres Linux e Compose com suporte a `--wait`. Copie o exemplo somente se ainda não existir `.env`; preencha `POSTGRES_PASSWORD` com uma senha local e mantenha a senha original se estiver reutilizando um volume. O banco usa esse valor apenas na primeira inicialização do volume. Nunca apresente o conteúdo de `.env` ou a saída de `docker compose config` sem `--quiet`.

```powershell
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
# Edite .env e preencha POSTGRES_PASSWORD antes de continuar.
docker compose -p observability config --quiet
docker compose -p observability up --build -d --wait
docker compose -p observability ps -a
```

Confirme que `/health` e `/ready` respondem e que a carga padrão está presente. O serviço `metrics-init` termina com código zero depois de habilitar `pg_stat_statements`; não precisa ficar em execução. As contagens de 1.000 clientes e 10.000 pedidos valem para um volume novo com os valores padrão. Em um volume existente, os dados originais são preservados.

```powershell
Invoke-RestMethod 'http://127.0.0.1:3000/health'
Invoke-RestMethod 'http://127.0.0.1:3000/ready'
docker compose -p observability exec -T postgres psql -X -U postgres -d observability -v ON_ERROR_STOP=1 -c 'SELECT (SELECT count(*) FROM clients) AS clients, (SELECT count(*) FROM orders) AS orders;'
```

Se algum serviço falhar, use `docker compose -p observability ps -a` e `docker compose -p observability logs --tail 50 postgres dados-api pedidos-api postgres-exporter prometheus grafana jaeger`. Uma troca de senha em `.env` não atualiza a senha já armazenada no banco. Veja [diagnóstico e configuração](guia-ambiente.md#diagnosticar-uma-falha) antes de repetir a partida; preserve o volume.

## 2. Mostrar que as rotas entregam a mesma resposta

**N+1** é uma consulta inicial seguida de uma consulta para cada registro retornado. Nesta aplicação, a pedidos-api faz uma chamada HTTP à dados-api nas duas rotas. A diferença está nas consultas que a dados-api faz ao PostgreSQL: `1 + N` na lenta, uma com `INNER JOIN` na otimizada. Não há atrasos artificiais. A verificação abaixo compara o corpo completo, o status e a quantidade de pedidos, sem despejar a lista na tela.

```powershell
$lento = Invoke-WebRequest 'http://127.0.0.1:3000/pedidos/lento?limit=100'
$otimizado = Invoke-WebRequest 'http://127.0.0.1:3000/pedidos/otimizado?limit=100'
$pedidos = ConvertFrom-Json -InputObject $lento.Content -NoEnumerate
if ($lento.StatusCode -ne 200 -or $otimizado.StatusCode -ne 200 -or $pedidos.Count -ne 100 -or $lento.Content -cne $otimizado.Content) {
    throw 'As rotas não retornaram os mesmos 100 pedidos.'
}
'PASS: 100 pedidos e corpos JSON idênticos.'
```

Se o volume tiver menos de 100 pedidos, adapte a expectativa ou use um projeto novo com a carga padrão. Um timeout na rota lenta pode ocorrer sob concorrência ou em máquina mais lenta: o prazo HTTP padrão é de 3 segundos, enquanto o SQL tem até 1 segundo **por consulta**. Isso não altera a regra N+1; confira os logs e não trate uma resposta incompleta como medição válida.

## 3. Seguir uma requisição no Jaeger

Abra [Jaeger](http://127.0.0.1:16686), selecione `pedidos-api`, escolha um período recente e clique em **Find Traces**. Gere uma chamada de cada rota e aguarde alguns segundos pelo envio em lotes:

```powershell
Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/lento?limit=100' | Out-Null
Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/otimizado?limit=100' | Out-Null
```

Abra um trace de cada rota. **Trace** é o percurso da requisição entre serviços; **span** é uma operação dentro dele. Mostre a entrada na pedidos-api, a chamada HTTP à dados-api e os spans SQL descendentes. Com 100 pedidos, espere 101 spans de consulta na lenta e um JOIN na otimizada; o total de spans inclui operações HTTP e Express, então será maior. Os spans SQL têm o nome `SELECT observability`; o atributo `db.query.text` identifica as consultas parametrizadas. `/health` e `/ready` são excluídos. O Jaeger guarda até 1.000 traces em memória, então traces antigos podem sumir durante demonstrações intensas ou após reinício.

## 4. Contar as consultas SQL sem zerar estatísticas

Escolha um momento sem outras chamadas às rotas. O arquivo `statements.sql` identifica as três estruturas atuais por seu SQL, sem depender de `queryid` fixo. Faça um snapshot imediatamente antes e outro depois **de uma** chamada lenta; compare a coluna `calls` por `kind`. Repita com a rota otimizada. Os comandos abaixo mostram as contagens; anote também a janela UTC com `Get-Date`.

```powershell
Get-Date -AsUTC -Format o
Get-Content -Raw observability/postgres-exporter/statements.sql |
    docker compose -p observability exec -T postgres psql -X -U postgres -d observability -v ON_ERROR_STOP=1

Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/lento?limit=100' | Out-Null

Get-Date -AsUTC -Format o
Get-Content -Raw observability/postgres-exporter/statements.sql |
    docker compose -p observability exec -T postgres psql -X -U postgres -d observability -v ON_ERROR_STOP=1
```

Para `limit=100`, `pedidos` deve crescer 1 e `cliente`, 100. Rode os mesmos dois snapshots em torno de **uma** chamada a `/pedidos/otimizado?limit=100`:

```powershell
Get-Date -AsUTC -Format o
Get-Content -Raw observability/postgres-exporter/statements.sql |
    docker compose -p observability exec -T postgres psql -X -U postgres -d observability -v ON_ERROR_STOP=1

Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/otimizado?limit=100' | Out-Null

Get-Date -AsUTC -Format o
Get-Content -Raw observability/postgres-exporter/statements.sql |
    docker compose -p observability exec -T postgres psql -X -U postgres -d observability -v ON_ERROR_STOP=1
```

Somente `join` deve crescer 1. Verifique que `stats_since` não mudou para entradas existentes. Contadores são acumulados; compare diferenças, não seus valores absolutos. Uma estrutura ainda não executada pode faltar no snapshot anterior. Se outras chamadas, reset ou descarte de entradas ocorrerem na janela, repita a demonstração em um ambiente sem concorrência. Não use `pg_stat_statements_reset()` para preparar a apresentação.

## 5. Mostrar as métricas no Grafana

Abra o [painel PostgreSQL — N+1 e JOIN](http://127.0.0.1:3002/d/postgres-experiment) e o [Prometheus](http://127.0.0.1:9090). No painel, mostre disponibilidade da coleta (`up`), acesso ao banco (`pg_up`), conexões, número de execuções, tempo SQL e linhas por consulta. Selecione o período recente e os `queryid` encontrados pelo SQL da seção anterior. Espere pelo menos duas coletas de 5 segundos para ver a variação.

O `postgres_exporter` consulta o banco, o Prometheus armazena as amostras e o Grafana as apresenta. O painel usa `increase` para **estimar** deltas entre amostras; valores fracionários são possíveis. O snapshot SQL fornece a contagem exata na janela isolada. O coletor limita consultas e pode omitir uma série: ausência de série não significa zero. Tempo SQL mede execução no banco, não a duração HTTP vista pelo usuário.

## 6. Explicar o resultado de desempenho

O [experimento reproduzível](experimento-carga.md) executou 12 medições com dados padrão, `limit=100`, concorrências 1 e 5, três rodadas por cenário, 10 segundos de aquecimento e 30 segundos de medição por rota. A ordem alternou entre as versões. Foram 31.272 respostas válidas e nenhum erro; cada resposta lenta correspondeu a 101 consultas da aplicação e cada resposta otimizada a uma. Em 19/10/2026, nesta máquina, as medianas das **médias** HTTP das três rodadas foram:

| Concorrência | Lenta | JOIN |
| --- | ---: | ---: |
| 1 | 95,42 ms | 11,46 ms |
| 5 | 203,84 ms | 21,10 ms |

Esses números mostram menor latência do JOIN nesta execução. Não são garantia de ganho em outra máquina, volume, distribuição de dados ou concorrência. A carga fechada permite que a rota mais rápida conclua mais chamadas na mesma janela. Gerador, APIs, banco e observabilidade compartilharam recursos do Docker; o teste não isolou o custo da instrumentação nem mediu capacidade máxima. O relatório histórico está em `docs/experimento-carga.md`; os arquivos em `test-results/` são locais e ignorados pelo Git. Para obter números novos, execute `pwsh -NoProfile -File tests/Test-Load.ps1` **separadamente** da apresentação; a suíte cria outro projeto, leva cerca de oito minutos de carga e encerra seus contêineres ao final.

## 7. Simular falha e recuperação do PostgreSQL

Depois da comparação de desempenho, interrompa somente o banco **local**. O volume permanece intacto. Use `-SkipHttpErrorCheck` para inspecionar respostas HTTP de erro:

```powershell
docker compose -p observability stop postgres
$health = Invoke-WebRequest 'http://127.0.0.1:3000/health' -SkipHttpErrorCheck
$ready = Invoke-WebRequest 'http://127.0.0.1:3000/ready' -SkipHttpErrorCheck
$pedidos = Invoke-WebRequest 'http://127.0.0.1:3000/pedidos/otimizado?limit=5' -SkipHttpErrorCheck
$health.StatusCode, $ready.StatusCode, $pedidos.StatusCode
$pedidos.Content
```

Mostre que `/health` continua em 200, pois verifica o processo, enquanto `/ready` e a busca falham ao depender do banco. Em um teste local, as duas retornaram 503 `DEPENDENCY_UNAVAILABLE`; um timeout pode produzir 504 `GATEWAY_TIMEOUT`. No Grafana, aguarde as coletas de 5 segundos: `pg_up=0` indica que o exporter respondeu e não alcançou o banco; se a coleta falhar, `up=0` e `pg_up` pode ficar ausente. Consulte `docker compose -p observability logs --tail 50 postgres dados-api pedidos-api` e procure no Jaeger o trace da chamada com erro. Recupere o serviço e confira a prontidão:

```powershell
docker compose -p observability up -d --wait postgres
Invoke-RestMethod 'http://127.0.0.1:3000/ready'
Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/otimizado?limit=5' | Out-Null
```

Após nova coleta, `pg_up` deve voltar a 1. Se a API ainda estiver reconectando, repita a verificação depois de alguns segundos. Esta demonstração altera apenas o estado dos contêineres locais; não use `down --volumes`.

## 8. Encerrar preservando os dados

```powershell
docker compose -p observability down
```

`down` encerra os contêineres e a rede; mantém o volume do PostgreSQL. Não acrescente `--volumes` ou `-v` se quiser preservar os dados. O histórico temporário do Jaeger, Prometheus e Grafana se perde quando os contêineres são removidos. A próxima partida reutiliza as tabelas e os dados do volume existente.
