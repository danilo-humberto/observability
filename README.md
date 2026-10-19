# Observabilidade de Banco de Dados

Projeto para o seminário de Sistemas Distribuídos do IFPE. Vamos mostrar como encontrar consultas repetidas no PostgreSQL e comparar duas formas de buscar os mesmos dados: uma com o problema N+1 e outra usando JOIN.

**Observabilidade** é a capacidade de entender o que acontece dentro de um sistema a partir das informações que ele gera. Aqui, vamos acompanhar o caminho das requisições, os números do banco e as estatísticas das consultas.

## Onde estamos

A Etapa 5 acrescenta **traces distribuídos com OpenTelemetry e Jaeger** às rotas N+1 e JOIN. As APIs Node.js 22, TypeScript e Express 5, o PostgreSQL e o Jaeger iniciam pelo mesmo Docker Compose. Métricas, estatísticas agregadas e testes de carga continuam nas etapas seguintes. O repositório Git já está inicializado.

## Executar o ambiente completo

Requisitos: Docker com suporte a contêineres Linux e Docker Compose atualizado, com suporte a `--wait`. Não é necessário instalar Node.js no Windows. Os comandos abaixo usam PowerShell e devem ser executados na raiz do projeto; os scripts de testes requerem PowerShell 7.

```powershell
Copy-Item .env.example .env
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

Essa escolha simplifica a apresentação local, mas dá à dados-api permissões administrativas no banco. A pedidos-api não recebe credenciais do PostgreSQL. As APIs continuam executando como usuário não root nos contêineres.

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

A comparação usará os mesmos dados, parâmetros e condições de execução. Não vamos adicionar esperas artificiais: a diferença no tempo de resposta deverá vir do trabalho real feito pelo sistema.

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

Criar, acompanhar e transmitir spans consome CPU, memória e rede. Esta etapa comprova o rastreamento; os tempos mostrados não constituem um benchmark. A comparação de desempenho e o controle desse custo ficam para a Etapa 7. Não há exportação de métricas ou logs pelo SDK nesta etapa.

### Verificar a Etapa 5

```powershell
./tests/Test-Tracing.ps1
```

O teste usa PostgreSQL, APIs e Jaeger reais em projeto isolado, portas livres e credencial efêmera. Identifica chamadas por contextos conhecidos e verifica respostas iguais, relações entre spans, 101 e 1.001 consultas contra uma, ausência de probes e dados sensíveis, amostragem de chamada sem contexto e respeito a pai remoto não amostrado. Confere também partida e atendimento sem Jaeger, recuperação, perda do histórico ao reiniciar, erro real do banco e exportação pendente no encerramento normal. O prazo HTTP de 30 segundos e o intervalo ampliado dos lotes para testar o encerramento existem somente no override de teste. O teste encerra contêineres e preserva o volume do PostgreSQL.

As suítes anteriores continuam válidas; `Test-Orders.ps1` e `Test-Services.ps1` agora também iniciam Jaeger com porta livre. Nenhum desses testes mede ganho de desempenho.

## Como as partes se conectam

O caminho de `/ready` já é `cliente HTTP → pedidos-api → dados-api → PostgreSQL`.

- **pedidos-api:** serviço Node.js que recebe a requisição, chama a `dados-api` por HTTP e devolve a resposta.
- **dados-api:** serviço Node.js que usa a biblioteca `pg` para consultar o PostgreSQL.
- **PostgreSQL:** já guarda clientes (`clients`) e pedidos (`orders`), ligados pelo campo `client_id`.
- **OpenTelemetry e Jaeger:** ajudam a acompanhar uma requisição pelos serviços e pelas consultas ao banco. Esse registro do percurso é chamado de trace.
- **postgres_exporter, Prometheus e Grafana:** coletam e mostram números do banco ao longo do tempo, chamados de métricas.
- **pg_stat_statements:** reúne estatísticas das consultas, como quantas vezes foram executadas e quanto tempo levaram.
- **Docker Compose:** inicia banco, APIs e Jaeger; os componentes de métricas serão integrados na Etapa 6.

O documento de [arquitetura](docs/arquitetura.md) explica melhor o papel de cada parte.

## Organização das pastas

```text
observability/
├── README.md
├── AGENTS.md
├── .gitignore
├── .gitattributes
├── .env.example
├── compose.yaml
├── services/
│   ├── pedidos-api/
│   └── dados-api/
├── database/
│   ├── init/00-init.sh
│   └── sql/
│       ├── schema.sql
│       └── seed.sql
├── observability/
│   ├── otel/
│   ├── jaeger/
│   ├── postgres-exporter/
│   ├── prometheus/
│   └── grafana/
├── tests/
└── docs/
    ├── arquitetura.md
    └── plano-implementacao.md
```

As pastas ainda vazias têm um arquivo `.gitkeep` para que possam ser incluídas no Git. Cada serviço contém `src/`, `package.json`, `package-lock.json`, `tsconfig.json`, `Dockerfile` e `.dockerignore`. A configuração do Jaeger fica em `observability/jaeger/config.yaml`; a configuração do SDK fica no módulo `src/telemetry.ts` de cada API. `tests/` contém testes e experimentos.

## Uma etapa por vez

O [plano de implementação](docs/plano-implementacao.md) descreve as oito etapas e como conferir cada entrega. Só vamos começar uma nova etapa depois da autorização do usuário. As orientações para os agentes estão em [AGENTS.md](AGENTS.md).

O PostgreSQL está fixado em 18.6, as imagens das APIs usam Node.js 22.23.1 Alpine e o Jaeger usa 2.22.0. As dependências diretas têm versões exatas e os lockfiles são versionados. Os demais componentes de observabilidade serão definidos na Etapa 6.
