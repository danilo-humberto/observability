# Como o projeto vai funcionar

## Onde estamos e o que queremos mostrar

Este documento distingue o que existe do que vamos construir. As Etapas 1 e 2 prepararam a organização, o PostgreSQL, o modelo e a carga inicial. A Etapa 3 implementa as APIs, comunicação HTTP e verificação do acesso ao banco. As consultas N+1 e JOIN e a observabilidade ainda são planejadas.

## O caminho de uma requisição

```mermaid
flowchart LR
    Cliente[Cliente HTTP] -->|HTTP| Pedidos[pedidos-api: Node.js]
    Pedidos -->|HTTP| Dados[dados-api: Node.js]
    Dados -->|SQL via pg| Banco[(PostgreSQL)]
```

A resposta volta pelo caminho inverso. Cada API é um serviço separado, com seu próprio processo, e elas conversam por HTTP. A instrumentação para acompanhar esse percurso em traces virá na Etapa 5.

| Parte | Responsabilidade atual ou planejada |
| --- | --- |
| pedidos-api | Já recebe HTTP, responde `/health` e chama `/ready` da dados-api; consultas de pedidos virão na Etapa 4. |
| dados-api | Já responde `/health` e verifica o banco com `SELECT 1` em `/ready`, usando pool de `pg`. |
| PostgreSQL | Já guarda clientes e pedidos; as consultas das duas versões virão na Etapa 4. |
| OpenTelemetry | Registrar as operações e levar as informações que ligam uma chamada à outra. |
| Jaeger | Receber e mostrar o percurso das requisições, chamado de trace. |
| postgres_exporter | Consultar o PostgreSQL e disponibilizar seus números para coleta. |
| Prometheus | Coletar esses números e guardar seu histórico. |
| Grafana | Buscar os dados no Prometheus e mostrá-los em painéis. |
| pg_stat_statements | Reunir estatísticas das consultas executadas no PostgreSQL. |
| Docker Compose | Já executa o banco e as duas APIs; observabilidade virá depois. |

Somente a `dados-api` acessa o banco durante o atendimento HTTP, usando o usuário `postgres` já criado na primeira inicialização do PostgreSQL. A pedidos-api não recebe credenciais do banco.

As APIs usam Node.js 22.23.1, TypeScript compilado em ESM e Express 5. Cada uma tem pacote e lockfile próprios, sem workspaces. Configuração, aplicação HTTP e inicialização são separadas; a dados-api possui módulo de acesso ao banco e a pedidos-api possui cliente HTTP com `fetch` nativo.

O comando `docker compose -p observability up --build -d --wait` constrói e inicia tudo. A sequência é banco saudável → dados-api pronta → pedidos-api pronta. A pedidos-api é publicada em loopback na porta 3000, ajustável; a dados-api usa 3001 apenas na rede interna. `/health` indica processo vivo e `/ready` verifica dependências. Na pedidos-api, `/ready` percorre os dois serviços até `SELECT 1` no banco.

A dados-api retorna 503 quando o banco falha. A pedidos-api retorna 503 para dependência não pronta, 502 para comunicação/resposta inválida e 504 para timeout. Os erros têm `error.code` e `error.message`, sem detalhes internos. O pool tem 10 conexões, aquisição/conexão limitada a 1 segundo, SQL a 1 segundo por consulta e HTTP a 3 segundos incluindo o corpo, configuráveis. Não existem retries automáticos. Uma dependência indisponível não derruba o processo: ele pode recuperar prontidão quando ela voltar. Os limites serão revistos antes da Etapa 4.

## As versões lenta e otimizada

A `pedidos-api` terá duas rotas públicas:

- `GET /pedidos/lento?limit=100`: a dados-api busca os pedidos e depois consulta o cliente de cada pedido. Com N pedidos, isso gera 1 + N consultas SQL.
- `GET /pedidos/otimizado?limit=100`: a dados-api busca os mesmos pedidos e seus clientes com uma consulta usando JOIN, que combina dados de tabelas relacionadas.

Cada rota poderá chamar a dados-api uma vez para escolher a busca desejada. As consultas repetidas acontecerão dentro da dados-api, no acesso ao banco.

As duas versões deverão retornar os mesmos registros, na mesma ordem e com o mesmo formato JSON. Na Etapa 4, vamos definir esse formato, as regras do limite de pedidos e a ordenação.

A comparação usará o mesmo limite, os mesmos dados e condições equivalentes. Não haverá esperas artificiais. O tempo de resposta dependerá do trabalho real e do ambiente; só saberemos a diferença depois de medir.

## Traces: acompanhando uma requisição

Um **trace distribuído** mostra o caminho de uma requisição entre as partes do sistema. Cada operação desse caminho, como uma chamada HTTP ou consulta SQL, é chamada de **span**.

```mermaid
flowchart LR
    Pedidos[pedidos-api com OpenTelemetry] -->|Contexto da requisição no HTTP| Dados[dados-api com OpenTelemetry]
    Pedidos -->|Traces| Jaeger[Jaeger]
    Dados -->|Traces com consultas SQL| Jaeger
```

O OpenTelemetry deverá permitir reunir as chamadas dos dois serviços e as consultas feitas com `pg` no mesmo trace. No Jaeger, poderemos ver as consultas repetidas da versão lenta e a consulta com JOIN da otimizada.

Na Etapa 5, vamos escolher as versões e a forma de enviar esses registros. A pasta `observability/otel/` guardará os arquivos dessa configuração. Sua existência não significa que usaremos um OpenTelemetry Collector separado, um componente opcional para receber e encaminhar esses registros.

## Métricas: acompanhando os números do banco

Uma **métrica** é um número acompanhado ao longo do tempo, como a quantidade de conexões abertas. Essa coleta acontecerá separadamente das requisições da aplicação.

```mermaid
flowchart LR
    Exporter[postgres_exporter] -->|Consulta números do banco| Banco[(PostgreSQL)]
    Prometheus[Prometheus] -->|Coleta métricas periodicamente| Exporter
    Grafana[Grafana] -->|Consulta o histórico| Prometheus
```

O Prometheus buscará periodicamente as métricas disponibilizadas pelo exporter. O Grafana usará esse histórico para montar os painéis. Na Etapa 6, vamos escolher os números úteis ao experimento, os intervalos de coleta e os painéis.

## Estatísticas das consultas

O `pg_stat_statements` será habilitado no PostgreSQL para acompanhar, por exemplo, quantas vezes uma consulta foi executada e quanto tempo levou. Ele pode agrupar consultas com a mesma estrutura, mesmo quando os valores usados na busca mudam.

Essas estatísticas ajudam a entender o conjunto de consultas executadas. Já os traces ajudam a acompanhar uma requisição específica. Na Etapa 6, vamos verificar quais estatísticas o exporter consegue fornecer e quais precisaremos consultar diretamente.

## Dados e execução

O banco implementado tem duas tabelas:

| Tabela | Campos |
| --- | --- |
| `clients` | `id integer` por identidade e chave primária, `name text`, `created_at timestamptz` |
| `orders` | `id integer` por identidade e chave primária, `client_id integer`, `description text`, `amount numeric(12,2)`, `created_at timestamptz` |

Todos os campos são obrigatórios. A chave estrangeira de `orders.client_id` referencia `clients.id`, impede pedidos sem cliente e bloqueia a exclusão de clientes com pedidos. Há um índice em `orders.client_id`. `amount` não aceita números negativos. Não existem outras entidades ou regras de negócio nesta etapa.

O Compose executa `postgres:18.6-alpine`, publica o banco em `127.0.0.1:${POSTGRES_PORT:-5432}` e mantém um volume por projeto montado em `/var/lib/postgresql`. Banco e usuário são `observability` e `postgres`. A mesma `POSTGRES_PASSWORD` configura o banco e o acesso da dados-api, simplificando a apresentação local. Isso dá à dados-api permissões administrativas no PostgreSQL. As APIs não executam como root nos contêineres.

Não há provisionamento de usuários na partida. Repetir o Compose reutiliza o banco persistente e não recria usuários ou registros. Alterar a senha no `.env` não altera a credencial já armazenada no volume. Um usuário `dados_api` criado pela configuração anterior pode permanecer no banco, mas não é mais utilizado; a simplificação não remove usuários de volumes existentes.

Na primeira inicialização, `database/init/00-init.sh` valida as quantidades e chama o `psql` com `ON_ERROR_STOP` e `--single-transaction` para executar modelo e carga juntos. A transação protege tabelas e registros da aplicação; a criação do diretório do PostgreSQL pela imagem ocorre antes dela. Por isso, um volume cuja inicialização falhou não deve ser reaproveitado como carga válida.

A geração usa SQL, sem bibliotecas externas ou aleatoriedade. O padrão é 1.000 clientes e 10.000 pedidos; nomes, descrições, datas UTC e valores são calculados de maneira fixa. Os pedidos são distribuídos circularmente entre os clientes. Aceitamos ao menos um cliente e zero pedidos. A distribuição simples ajuda a repetir o experimento, mas não simula uma carga comercial real.

Reiniciar preserva os dados. Para gerar outra carga, usa-se outro nome de projeto Compose e outra porta, mantendo o volume anterior. Os comandos de execução, validação e encerramento estão no [README](../README.md). Não há recarga destrutiva nem mecanismo de evolução de esquema nesta etapa.

O ambiente atual já usa Docker Compose para banco e APIs. Os componentes de observabilidade serão incorporados nas etapas correspondentes. O [README](../README.md) descreve execução, variáveis, contratos, falhas e validação.

O [plano de implementação](plano-implementacao.md) mostra o que será feito e conferido em cada etapa.
