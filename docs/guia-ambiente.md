# Guia do ambiente e verificações

Este guia reúne as instruções detalhadas de configuração, execução e validação. Execute os comandos PowerShell na raiz do repositório. Para uma demonstração em sequência, consulte o [roteiro de apresentação](roteiro-apresentacao.md).

## Executar o ambiente completo

Requisitos: Docker com suporte a contêineres Linux e Docker Compose atualizado, com suporte a `--wait`. Não é necessário instalar Node.js no Windows. Os comandos abaixo usam PowerShell e devem ser executados na raiz do projeto; os scripts de testes requerem PowerShell 7.

```powershell
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
```

Edite `.env` e preencha `POSTGRES_PASSWORD` com uma senha local. Se já tiver um `.env` configurado, mantenha a senha do banco existente. O arquivo está ignorado pelo Git. Senhas que contenham `$` ou `#` devem ficar entre aspas simples no arquivo. Não publique a saída de `docker compose config` sem `--quiet`, pois ela inclui a senha interpolada.

Depois dessa configuração inicial, um comando constrói as imagens e inicia todo o sistema:

```powershell
docker compose -p observability up --build -d --wait
```

Para conferir:

```powershell
docker compose -p observability ps
Invoke-RestMethod http://127.0.0.1:3000/health
Invoke-RestMethod http://127.0.0.1:3000/ready
docker compose -p observability exec postgres psql -U postgres -d observability -c "SELECT (SELECT count(*) FROM clients) AS clients, (SELECT count(*) FROM orders) AS orders;"
```

O padrão é 1.000 clientes e 10.000 pedidos. A pedidos-api fica em `127.0.0.1:3000` (`PEDIDOS_PORT` altera essa porta). A dados-api usa a porta 3001 somente na rede interna do Docker. O banco continua acessível em `127.0.0.1:5432` (`POSTGRES_PORT` altera essa porta), com banco `observability` e administrador `postgres`. Este é um ambiente didático local.

### Inicialização e credenciais

A sequência é PostgreSQL saudável → dados-api pronta → pedidos-api pronta. A dados-api usa o usuário `postgres` e a mesma `POSTGRES_PASSWORD` já configurada para o banco. Não existe etapa de criação de usuário ou concessão de permissões na partida.

Essa escolha simplifica a apresentação local, mas dá à dados-api permissões administrativas no banco. O exporter e o serviço de preparação da extensão também usam esse administrador e a mesma senha, conforme a decisão para a apresentação local. A pedidos-api, o Prometheus e o Grafana não recebem credenciais do PostgreSQL. As APIs continuam executando como usuário não root nos contêineres.

### Rotas e falhas

| Rota                    | Verificação                                     |
| ----------------------- | ----------------------------------------------- |
| `/health` nas duas APIs | Processo HTTP vivo, sem consultar dependências. |
| `/ready` na dados-api   | Consulta real `SELECT 1` ao PostgreSQL.         |
| `/ready` na pedidos-api | Chamada HTTP à dados-api, que consulta o banco. |

O sucesso retorna `{"status":"ok","service":"pedidos-api"}` ou `dados-api`, conforme o serviço. Erros usam `{"error":{"code":"CODIGO","message":"Mensagem segura"}}`.

Na dados-api, falha do banco retorna `503 DATABASE_UNAVAILABLE`. Na pedidos-api: dependência não pronta retorna `503 DEPENDENCY_UNAVAILABLE`; falha de conexão ou resposta inválida retorna `502 BAD_GATEWAY`; prazo excedido retorna `504 GATEWAY_TIMEOUT`. Rotas desconhecidas retornam `404 NOT_FOUND`; erros inesperados recebem `500 INTERNAL_ERROR`. As rotas de pedidos estão descritas abaixo.

Ao parar a dados-api, o Docker pode recusar a conexão ou demorar na resolução do nome interno. Por isso, a falha real pode aparecer como 502 ou 504, conforme a conexão falhe antes ou depois do prazo configurado.

| Variável no `.env`       | Padrão | Finalidade                                        |
| ------------------------ | ------ | ------------------------------------------------- |
| `PGPOOL_MAX`             | 10     | Máximo de conexões reutilizáveis da dados-api.    |
| `PGCONNECT_TIMEOUT_MS`   | 1000   | Prazo para adquirir/abrir conexão.                |
| `PGSTATEMENT_TIMEOUT_MS` | 1000   | Limite de execução SQL no servidor, por consulta. |
| `HTTP_TIMEOUT_MS`        | 3000   | Prazo HTTP incluindo leitura do corpo.            |

Os limites devem ser inteiros positivos. Não há retries automáticos ou esperas artificiais nas APIs. Healthchecks consultam `/ready`; `depends_on` ordena a partida, mas não reinicia automaticamente APIs quando uma dependência falha depois. Os processos continuam vivos e podem se recuperar quando a dependência volta. Limites do healthcheck são fixos para esta etapa e precisarão ser alinhados se os timeouts forem aumentados.

Ao encerrar, as APIs deixam de aceitar novas conexões e finalizam requisições e pool, com prazo de 5 segundos; o Docker permite 7 segundos antes de forçar a parada. Os logs usam eventos e códigos seguros, sem imprimir objetos de configuração ou mensagens SQL.

### Diagnosticar uma falha

```powershell
docker compose -p observability ps -a
docker compose -p observability logs --tail 50 postgres dados-api pedidos-api
```

Alterar `POSTGRES_PASSWORD` no `.env` não altera a senha já gravada no volume. Ao reutilizar um banco da Etapa 2, mantenha sua senha original. Se houver falha de autenticação, confira essa configuração; não apague o volume para contornar o erro.

É possível iniciar somente o banco para inspeção com `docker compose -p observability up -d --wait postgres`; isso não inicia as APIs.

O Compose usa a imagem oficial `postgres:18.6-alpine`. O volume nomeado é montado em `/var/lib/postgresql`, conforme a organização da imagem a partir do PostgreSQL 18. O healthcheck usa `pg_isready` via TCP para aguardar o servidor definitivo, após a inicialização.

### Modelo e carga inicial

| Tabela    | Colunas                                                  |
| --------- | -------------------------------------------------------- |
| `clients` | `id`, `name`, `created_at`                               |
| `orders`  | `id`, `client_id`, `description`, `amount`, `created_at` |

Os IDs são inteiros gerados por identidade, um contador mantido pelo banco. Todos os campos são obrigatórios. `client_id` referencia `clients.id`, sem exclusão em cascata: não é permitido excluir um cliente que tenha pedidos. Há um índice nessa coluna. `amount` é `numeric(12,2)` e não aceita valores negativos; as datas são `timestamptz`.

Na primeira inicialização, `database/init/00-init.sh` valida as quantidades e executa `database/sql/schema.sql` e `database/sql/seed.sql` na mesma transação. Se um deles falhar, as tabelas e os registros dessa transação não são confirmados. Não há mecanismo de migrações para alterar bancos existentes nesta etapa.

Os nomes e descrições são fictícios. As datas partem de instantes fixos em UTC; o valor de cada pedido é calculado pelo seu número. Os pedidos são distribuídos circularmente entre clientes: com três clientes, os primeiros pedidos pertencem aos clientes 1, 2, 3, 1, 2, 3. Isso garante reprodução, mas não representa a distribuição de compras de um sistema real.

`CLIENTS_COUNT` aceita inteiros de 1 a 2.147.483.647; `ORDERS_COUNT`, de 0 a 2.147.483.647. O limite é o tipo inteiro dos IDs, não uma promessa de capacidade: cargas grandes dependem de memória, disco e tempo disponíveis.

### Repetir sem substituir os dados existentes

Os scripts de modelo e carga inicial rodam **somente quando o volume está vazio**. Reiniciar o serviço ou mudar as variáveis não refaz a carga nem altera a senha já gravada. Para testar outras quantidades, escolha um nome de projeto novo e outra porta:

```powershell
$env:CLIENTS_COUNT = '3'
$env:ORDERS_COUNT = '8'
$env:POSTGRES_PORT = '5433'
docker compose -p observability-small config --quiet
docker compose -p observability-small up -d --wait --wait-timeout 60 postgres
docker compose -p observability-small exec postgres psql -U postgres -d observability -c "SELECT id, client_id, description, amount, created_at FROM orders ORDER BY id;"
docker compose -p observability-small down
Remove-Item Env:CLIENTS_COUNT, Env:ORDERS_COUNT, Env:POSTGRES_PORT
```

O nome do projeto separa redes e volumes automaticamente. Reutilizar `observability-small` reutiliza seus dados: escolha outro nome para uma nova carga limpa. `down` encerra o ambiente e preserva o volume; não acrescente `--volumes` ou `-v` se quiser preservar os dados.

Se a inicialização falhar, consulte `docker compose -p NOME logs postgres`, encerre com `docker compose -p NOME down`, corrija a causa e use **outro nome de projeto**. A imagem pode deixar o diretório do banco inicializado mesmo após uma falha nos scripts; simplesmente reiniciá-lo pode pular a criação das tabelas. Não trate esse volume como uma carga válida.

Para encerrar o ambiente principal preservando os dados:

```powershell
docker compose -p observability down
```

### Verificar a Etapa 2

```powershell
./tests/Test-Database.ps1
```

O teste usa PostgreSQL real, credencial efêmera em memória, portas livres e projetos com nomes únicos. Confere senha obrigatória, contagens, conteúdo ordenado em dois volumes distintos, rollback após erro SQL, restrições, reinício, distribuição circular, pedidos vazios e parâmetros inválidos. Ao terminar, encerra seus contêineres e **preserva todos os volumes**, inclusive os cenários de erro, imprimindo os nomes dos projetos. Executá-lo novamente cria outros volumes; a remoção deles é uma ação separada e explícita.

As assinaturas MD5 comparam todos os campos dos registros ordenados por ID; servem para reprodução do experimento, não para proteção criptográfica. Também conferimos os contadores de identidade (sequences) antes e depois dos testes de restrições e do reinício. Esses contadores podem avançar mesmo quando uma inserção falha; por isso, os testes de rejeição usam IDs explícitos para preservar seu estado. Esses testes não medem latência, N+1, JOIN, traces ou métricas.

## Verificar a Etapa 3

```powershell
./tests/Test-Unit.ps1
./tests/Test-Services.ps1
```

Ambos dispensam Node.js no Windows. O primeiro compila e executa os testes de contrato em contêineres temporários, com dependências simuladas em servidores HTTP de teste. Cobre sucesso, falhas, JSON inválido, timeout antes dos headers e durante o corpo e rejeição de configuração inválida pelos processos. Testa ainda SIGTERM na pedidos-api com requisição em curso: conclusão normal ou encerramento forçado pela aplicação em 5 segundos. O segundo inicia ambientes reais isolados com PostgreSQL e as duas APIs, verifica o comando único, acesso como `postgres`, recuperação e uso de banco existente sem criar usuários. Esses testes não medem N+1 ou desempenho e não exercitam encerramento da dados-api com uma consulta SQL longa em andamento.

Os testes de integração usam portas livres, senhas efêmeras em memória e encerram os contêineres, preservando todos os volumes. Os testes de contrato preservam suas imagens Docker e removem apenas os contêineres descartáveis ao terminar. A suíte anterior continua disponível em `./tests/Test-Database.ps1` e inicia somente o banco.

## O que vamos comparar

O problema N+1 acontece quando fazemos uma consulta inicial e depois outra consulta para cada resultado. Por exemplo: buscar 100 pedidos e consultar o cliente de cada um gera 101 consultas ao banco. Isso acontece mesmo se vários pedidos forem do mesmo cliente.

A `pedidos-api` oferece dois endpoints:

| Rota                               | Como funciona                                                                     |
| ---------------------------------- | --------------------------------------------------------------------------------- |
| `GET /pedidos/lento?limit=100`     | A `dados-api` busca os pedidos e consulta o cliente de cada pedido separadamente. |
| `GET /pedidos/otimizado?limit=100` | A `dados-api` busca pedidos e clientes juntos, em uma consulta com JOIN.          |

As duas rotas retornam os mesmos registros, em ordem crescente de `orders.id`, com o mesmo formato JSON.

### Contrato das rotas de pedidos

```powershell
Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/lento?limit=100'
Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/otimizado?limit=100'
```

O retorno é uma lista direta; os nomes das colunas são preservados. Exemplo com o primeiro pedido da carga padrão:

```json
[
  {
    "id": 1,
    "client_id": 1,
    "description": "Order 1",
    "amount": "1.38",
    "created_at": "2024-02-01T00:00:00.000Z",
    "client": { "id": 1, "name": "Client 1" }
  }
]
```

Sem pedidos, o retorno é HTTP 200 com `[]`.

O `limit` ausente vale 100. Quando informado, deve ser um único valor composto por dígitos, entre 1 e 1.000; zeros à esquerda são aceitos. Valores vazios, negativos, decimais, fora da faixa, repetidos ou estruturados (`limit[]=1`, por exemplo) recebem HTTP 400 com `{"error":{"code":"INVALID_LIMIT","message":"limit deve ser um inteiro entre 1 e 1000."}}`. As duas APIs validam antes de consultar a dependência. Outros parâmetros não alteram a busca.

Cada requisição válida faz uma chamada HTTP à dados-api. A rota lenta consulta pedidos e depois o cliente de cada um sequencialmente, sem cache: `1 + N` consultas, mesmo com clientes repetidos. A otimizada faz uma consulta com `INNER JOIN`. Com zero pedidos, ambas executam uma consulta. Não há contagem SQL, tempos ou metadados adicionais no JSON.

As respostas não são armazenadas em cache (`Cache-Control: no-store`). Falhas não retornam listas parciais. A pedidos-api confere campos, tipos, ordem, limite e relação entre os IDs antes de encaminhar o JSON da dados-api.

Os timeouts continuam em 3 segundos para HTTP e 1 segundo por consulta SQL. O prazo de uma consulta não limita a soma das consultas N+1. Se o HTTP expirar ou o cliente desconectar, as consultas já iniciadas na dados-api podem continuar; não há cancelamento propagado ao banco. O limite de 1.000 reduz o trabalho por requisição, mas não garante sucesso dentro de 3 segundos em qualquer máquina ou sob concorrência. Alterar `HTTP_TIMEOUT_MS` também exige considerar os limites fixos dos healthchecks e do encerramento.

### Verificar a Etapa 4

```powershell
./tests/Test-Unit.ps1
./tests/Test-Orders.ps1
./tests/Test-Services.ps1
```

`Test-Orders.ps1` inicia ambientes isolados para carga padrão, clientes repetidos (3 clientes e 8 pedidos) e pedidos vazios. Compara o conteúdo completo com uma consulta independente ao banco, verifica respostas idênticas e conta as consultas reais pelos logs do PostgreSQL, excluindo os healthchecks. O arquivo `tests/orders.compose.yaml` habilita SQL nos logs somente nesses ambientes, sem registrar os valores dos parâmetros. Não aplique esse arquivo ao ambiente principal.

O teste verifica os limites 1, 100 e 1.000, parâmetros inválidos nas duas APIs, falha/recuperação do banco e preservação dos registros. Exercita 1.000 pedidos com timeout HTTP de 3 e 30 segundos, este último apenas no teste. Os contêineres são encerrados e os volumes preservados. A comparação usa dados estáveis, sem escritas concorrentes: várias consultas podem observar momentos diferentes do banco. Esses testes comprovam comportamento e quantidade de consultas; não são um benchmark nem demonstram ganho de desempenho.

A carga inicial já gera 1.000 clientes e 10.000 pedidos por padrão. A geração produz os mesmos dados quando repetida com os mesmos parâmetros, e as quantidades podem ser ajustadas em uma inicialização nova.

O [experimento de carga](experimento-carga.md) comparou as rotas com os mesmos dados, limite e configuração, alternando a ordem das medições. Não há esperas artificiais nas APIs. Os números representam aquela execução local, com observabilidade ligada.

## Acompanhar uma requisição no Jaeger — Etapa 5

Com o ambiente iniciado pelo comando Compose acima, abra [Jaeger local](http://127.0.0.1:16686). `JAEGER_PORT` permite mudar essa porta; a interface é publicada apenas em loopback. O recebimento OTLP fica somente na rede Docker, sem porta publicada.

```powershell
Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/lento?limit=100' | Out-Null
Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/otimizado?limit=100' | Out-Null
```

Na interface, selecione o serviço `pedidos-api`, clique em **Find Traces** e abra uma requisição. Aguarde alguns segundos para os lotes chegarem. O **trace** mostra o percurso completo; cada **span** representa uma operação. As entradas das duas APIs e a chamada HTTP devem pertencer ao mesmo trace, com consultas SQL descendentes da dados-api. Com 100 pedidos, a lenta tem 101 consultas e a otimizada uma com JOIN. O total de spans é maior, porque inclui HTTP e Express. Os spans SQL se chamam `SELECT observability`; o atributo `db.query.text` permite distinguir as consultas. Conexões e aquisição do pool não geram spans.

A instrumentação de HTTP/Express acompanha as entradas; Undici acompanha o `fetch` nativo; `pg` acompanha o SQL. O contexto W3C (`traceparent` e `tracestate`) liga os serviços pelo HTTP. O preload e o hook oficial do OpenTelemetry inicializam a instrumentação antes dos módulos ESM da aplicação.

`OTEL_TRACES_SAMPLER=parentbased_always_on` registra todas as chamadas locais sem contexto externo e respeita a decisão recebida de um cliente instrumentado. É possível usar `always_off` para desabilitar a gravação, por exemplo em um experimento posterior, recriando as APIs. `/health` e `/ready` são excluídos, inclusive suas chamadas internas e consultas de prontidão. SQL exige contexto ativo, evitando consultas órfãs dessas verificações.

Um filtro antes da exportação mantém somente atributos selecionados de método, rota conhecida, status e SQL parametrizado. Não exporta parâmetros SQL, resultados, corpos, headers, URLs com query strings, mensagens livres de erro ou eventos de exceção. As falhas continuam identificadas pelo status do span e pelos códigos seguros dos logs. Essa proteção é específica das consultas atuais, que usam parâmetros; SQL futuro com valores literais precisa ser revisado antes de ser instrumentado.

As APIs enviam OTLP/HTTP Protobuf diretamente para `http://jaeger:4318/v1/traces`. Há uma fila de até 4.096 spans por API, lotes de até 512 e intervalo de 1 segundo, com prazo de exportação de 1 segundo. O atendimento HTTP não aguarda o envio do lote. O encerramento normal tenta exportar o restante dentro do prazo total existente de 5 segundos. A fila é em memória: falhas, saturação ou parada forçada podem perder spans. O evento seguro `trace_export_failed` indica falha de exportação, sem imprimir a mensagem original.

O Jaeger usa memória limitada a 1.000 traces, descartando registros antigos conforme necessário. Reiniciar o processo apaga o histórico, e `docker compose down` também o perde. Não há Collector separado nem armazenamento persistente. As APIs não dependem da disponibilidade do Jaeger para iniciar ou atender; novas requisições voltam a ser exportadas quando ele se recupera. Não há garantia de recuperar os spans perdidos durante a falha.

Criar, acompanhar e transmitir spans consome CPU, memória e rede. Os tempos mostrados no Jaeger não constituem um benchmark. A Etapa 7 mediu as rotas com observabilidade ligada, mas não isolou o custo da instrumentação. Não há exportação de métricas ou logs pelo SDK.

### Verificar a Etapa 5

```powershell
./tests/Test-Tracing.ps1
```

O teste usa PostgreSQL, APIs e Jaeger reais em projeto isolado, portas livres e credencial efêmera. Identifica chamadas por contextos conhecidos e verifica respostas iguais, relações entre spans, 101 e 1.001 consultas contra uma, ausência de probes e dados sensíveis, amostragem de chamada sem contexto e respeito a pai remoto não amostrado. Confere também partida e atendimento sem Jaeger, recuperação, perda do histórico ao reiniciar, erro real do banco e exportação pendente no encerramento normal. O prazo HTTP de 30 segundos e o intervalo ampliado dos lotes para testar o encerramento existem somente no override de teste. O teste encerra contêineres e preserva o volume do PostgreSQL.

As suítes anteriores continuam válidas; `Test-Orders.ps1` e `Test-Services.ps1` agora também iniciam Jaeger com porta livre. Nenhum desses testes mede ganho de desempenho.

## Métricas e estatísticas SQL — Etapa 6

Abra [Grafana local](http://127.0.0.1:3002/d/postgres-experiment) e [Prometheus local](http://127.0.0.1:9090). `GRAFANA_PORT` e `PROMETHEUS_PORT` alteram as portas, publicadas somente em loopback. O exporter atende em `postgres-exporter:9187` apenas na rede Docker. Grafana permite visualização anônima com papel **Viewer**, sem criação do administrador inicial, formulário de login ou cadastro. Dashboard e datasource são provisionados por arquivos; não é necessário importar painéis nem instalar plugins.

O Prometheus coleta a cada 5 segundos, com timeout de 3 segundos. Seu histórico fica no sistema de arquivos do contêiner, em `/tmp/prometheus`, sem volume persistente, limitado por retenção de 24 horas e tamanho de 256 MB (não é um teto rígido de disco). `stop` seguido de `start` preserva esse histórico; recriar o contêiner ou executar `down` e outro `up` o perde. O Grafana também usa dados temporários e reprovisiona os arquivos ao iniciar. Os dados e as estatísticas do PostgreSQL têm ciclo de vida separado: perder o histórico do Prometheus **não zera** os contadores SQL.

Na primeira aplicação da Etapa 6 a um ambiente existente, o Compose recria o PostgreSQL para habilitar `shared_preload_libraries=pg_stat_statements`. Isso interrompe temporariamente as APIs locais. Em seguida, `metrics-init` executa `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` no banco `observability`, inclusive em volumes já inicializados. O estado `Exited (0)` desse serviço é esperado. Não há recarga das tabelas, alteração de senha ou criação de usuários. As APIs não dependem dele nem dos componentes de métricas.

O painel mostra disponibilidade da coleta (`up`), acesso ao banco (`pg_up`), conexões do banco (`pg_stat_database_numbackends`) e, por `queryid`, execuções (`pg_stat_statements_calls_total`), tempo SQL em segundos (`pg_stat_statements_seconds_total`) e linhas (`pg_stat_statements_rows_total`). Conexões incluem APIs, exporter e outras sessões; não representam requisições HTTP. O exporter limita conexão a 1 segundo e coleta a 2 segundos. Se não conseguir concluir a resposta antes do prazo do Prometheus, `up=0` e `pg_up` pode ficar ausente; se conseguir informar a falha, `pg_up=0`. Confira os dois sinais.

O coletor nativo `stat_statements` é habilitado explicitamente, sem texto SQL nos labels. Ele seleciona consultas acima do percentil 10 de tempo acumulado e limita a saída a 100 consultas. Assim, **série ausente é ausência de dados, não zero execuções**. O painel permite selecionar queryids, mas também lista consultas internas; o SQL abaixo identifica somente as três estruturas atuais da aplicação. Não fixe esses identificadores entre versões ou ambientes. [Implementação do coletor 0.20.1](https://github.com/prometheus-community/postgres_exporter/blob/v0.20.1/collector/pg_stat_statements.go).

### Conferir uma janela sem misturar contagens anteriores

Use um ambiente sem outras chamadas às rotas durante a conferência. Probes e consultas do exporter continuam acontecendo, mas o filtro SQL abaixo não as inclui. Antes da primeira chamada, a inspeção pode não retornar linhas: a estrutura ainda não foi executada.

```powershell
# Snapshot anterior (o SQL só lê estatísticas; não executa reset).
Get-Date -AsUTC -Format o
Get-Content -Raw observability/postgres-exporter/statements.sql |
    docker compose -p observability exec -T postgres psql -X -U postgres -d observability -v ON_ERROR_STOP=1

Invoke-RestMethod 'http://127.0.0.1:3000/pedidos/lento?limit=100' | Out-Null

# Snapshot posterior. Registre também: rota=lento, limit=100, chamadas=1.
Get-Date -AsUTC -Format o
Get-Content -Raw observability/postgres-exporter/statements.sql |
    docker compose -p observability exec -T postgres psql -X -U postgres -d observability -v ON_ERROR_STOP=1
```

Subtraia `calls` anterior de posterior para cada `kind`: `pedidos` deve aumentar 1 e `cliente`, 100. Uma consulta ausente no snapshot anterior vale zero para essa conferência inicial. Repita os dois snapshots envolvendo uma chamada a `/pedidos/otimizado?limit=100`: somente `join` deve aumentar 1. O campo `stats_since` deve permanecer igual nas entradas já existentes; reset ou descarte de estatísticas invalida a comparação. A suíte automatizada verifica esses deltas, imprime início/fim em UTC e compara as respostas completas. Não execute `pg_stat_statements_reset()` no ambiente compartilhado para preparar a demonstração.

No Grafana, selecione o período e os queryids encontrados. Aguarde pelo menos duas coletas. O painel com `increase` **estima** o crescimento entre amostras, podendo mostrar valores fracionários; os snapshots SQL dão a contagem exata. Acumulados abrangem o histórico das estatísticas SQL, e não apenas o intervalo selecionado no gráfico. Tempo SQL não inclui todo o percurso HTTP e não equivale à latência da API. A Etapa 7 mediu latência HTTP e vazão com o monitoramento ligado, sem medir seu custo isoladamente.

### Validação e reversão

```powershell
pwsh -NoProfile -File tests/Test-Metrics.ps1
```

A suíte usa PostgreSQL, exporter, Prometheus e Grafana reais, projetos únicos, portas livres e senha efêmera. Somente nela, o prazo HTTP é ampliado para 30 segundos, pois verifica estatísticas e não desempenho; o ambiente principal continua com 3 segundos. Testa volume anterior à extensão e volume novo, idempotência, deltas SQL, evolução de amostras, valores de tempo/linhas, datasource, acesso Viewer sem gravação, falhas/recuperação, independência das APIs, privacidade e perda do histórico na recriação. Encerra seus contêineres e preserva volumes do banco. A opção `-KeepRunning` mantém somente o ambiente novo após sucesso para inspeção manual; ao terminar use `docker compose -p NOME_IMPRESSO down`. Sem `.env`, defina `POSTGRES_PASSWORD` no processo com um valor fictício não vazio apenas para satisfazer a interpolação desse comando: `down` não autentica no banco. A senha efêmera do teste não é impressa nem necessária para encerrá-lo.

Para reverter a Etapa 6, remova os serviços de métricas e a configuração de preload do Compose, restaure os overrides correspondentes e recrie os contêineres afetados com `up -d --build --wait --remove-orphans`. Não remova volumes. Isso interrompe o banco e perde o histórico temporário do Prometheus. A extensão pode permanecer instalada e inativa, sem apagar tabelas ou executar `DROP EXTENSION`.

## Comparar desempenho — Etapa 7

```powershell
pwsh -NoProfile -File tests/Test-Load.ps1
```

O experimento usa serviços reais em projeto isolado, `limit=100`, concorrências 1 e 5 e três rodadas por cenário. Cada execução tem 10 segundos de aquecimento e 30 segundos de medição, com observabilidade ligada e timeouts originais. A execução leva aproximadamente oito minutos de carga, além de preparação e intervalos.

Os resultados ficam em `test-results/observability-load-.../`: `report.md` apresenta tempos, vazão, erros e consultas SQL; `summary.json` e os arquivos de amostras permitem conferir os cálculos e as condições. Os contêineres são encerrados e os volumes preservados. Não rode outras suítes ou cargas ao mesmo tempo. Consulte o [método e as limitações do experimento](experimento-carga.md) antes de interpretar os números. Nenhum ganho mínimo de desempenho é exigido pelo teste.

Veja também a [arquitetura](arquitetura.md), o [experimento de carga](experimento-carga.md) e o [README](../README.md) para um início rápido.
