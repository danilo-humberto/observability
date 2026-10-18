# Observabilidade de Banco de Dados

Projeto para o seminário de Sistemas Distribuídos do IFPE. Vamos mostrar como encontrar consultas repetidas no PostgreSQL e comparar duas formas de buscar os mesmos dados: uma com o problema N+1 e outra usando JOIN.

**Observabilidade** é a capacidade de entender o que acontece dentro de um sistema a partir das informações que ele gera. Aqui, vamos acompanhar o caminho das requisições, os números do banco e as estatísticas das consultas.

## Onde estamos

A Etapa 1 preparou as pastas e a documentação. A Etapa 2 entrega **PostgreSQL 18.6 executável com Docker Compose**, modelo relacional e dados reproduzíveis. As APIs e as ferramentas de observabilidade ainda estão planejadas. O repositório Git já está inicializado.

## Executar o banco

Requisitos: Docker com suporte a contêineres Linux e Docker Compose. Os comandos abaixo usam PowerShell e devem ser executados na raiz do projeto.

```powershell
Copy-Item .env.example .env
```

Edite `.env` e preencha `POSTGRES_PASSWORD` com uma senha local. Não repita a cópia se já tiver um `.env` configurado. Ele está ignorado pelo Git. Senhas que contenham `$` devem ficar entre aspas simples no arquivo. Não publique a saída de `docker compose config` sem `--quiet`, pois ela inclui a senha interpolada.

```powershell
docker compose -p observability config --quiet
docker compose -p observability up -d --wait --wait-timeout 60
docker compose -p observability ps
docker compose -p observability exec postgres psql -U postgres -d observability -c "SELECT (SELECT count(*) FROM clients) AS clients, (SELECT count(*) FROM orders) AS orders;"
```

O padrão é 1.000 clientes e 10.000 pedidos. O banco fica acessível em `127.0.0.1:5432`, com banco `observability` e usuário administrativo `postgres`. `POSTGRES_PORT` permite escolher outra porta local. Este ambiente é didático e local; as credenciais da futura API serão tratadas na Etapa 3.

O Compose usa a imagem oficial `postgres:18.6-alpine`. O volume nomeado é montado em `/var/lib/postgresql`, conforme a organização da imagem a partir do PostgreSQL 18. O healthcheck usa `pg_isready` via TCP para aguardar o servidor definitivo, após a inicialização.

### Modelo e carga inicial

| Tabela | Colunas |
| --- | --- |
| `clients` | `id`, `name`, `created_at` |
| `orders` | `id`, `client_id`, `description`, `amount`, `created_at` |

Os IDs são inteiros gerados por identidade, um contador mantido pelo banco. Todos os campos são obrigatórios. `client_id` referencia `clients.id`, sem exclusão em cascata: não é permitido excluir um cliente que tenha pedidos. Há um índice nessa coluna. `amount` é `numeric(12,2)` e não aceita valores negativos; as datas são `timestamptz`.

Na primeira inicialização, `database/init/00-init.sh` valida as quantidades e executa `database/sql/schema.sql` e `database/sql/seed.sql` na mesma transação. Se um deles falhar, as tabelas e os registros dessa transação não são confirmados. Não há mecanismo de migrações para alterar bancos existentes nesta etapa.

Os nomes e descrições são fictícios. As datas partem de instantes fixos em UTC; o valor de cada pedido é calculado pelo seu número. Os pedidos são distribuídos circularmente entre clientes: com três clientes, os primeiros pedidos pertencem aos clientes 1, 2, 3, 1, 2, 3. Isso garante reprodução, mas não representa a distribuição de compras de um sistema real.

`CLIENTS_COUNT` aceita inteiros de 1 a 2.147.483.647; `ORDERS_COUNT`, de 0 a 2.147.483.647. O limite é o tipo inteiro dos IDs, não uma promessa de capacidade: cargas grandes dependem de memória, disco e tempo disponíveis.

### Repetir sem substituir os dados existentes

Os scripts rodam **somente quando o volume está vazio**. Reiniciar o serviço ou mudar as variáveis não refaz a carga nem altera a senha já gravada. Para testar outras quantidades, escolha um nome de projeto novo e outra porta:

```powershell
$env:CLIENTS_COUNT = '3'
$env:ORDERS_COUNT = '8'
$env:POSTGRES_PORT = '5433'
docker compose -p observability-small config --quiet
docker compose -p observability-small up -d --wait --wait-timeout 60
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

## O que vamos comparar

O problema N+1 acontece quando fazemos uma consulta inicial e depois outra consulta para cada resultado. Por exemplo: buscar 100 pedidos e consultar o cliente de cada um gera 101 consultas ao banco. Isso acontece mesmo se vários pedidos forem do mesmo cliente.

A `pedidos-api` terá duas rotas públicas, também chamadas de endpoints:

| Rota planejada | Como vai funcionar |
| --- | --- |
| `GET /pedidos/lento?limit=100` | A `dados-api` busca os pedidos e consulta o cliente de cada pedido separadamente. |
| `GET /pedidos/otimizado?limit=100` | A `dados-api` busca pedidos e clientes juntos, em uma consulta com JOIN. |

JOIN é o recurso do SQL que permite combinar dados de tabelas relacionadas. As duas rotas deverão retornar os mesmos registros, na mesma ordem e com o mesmo formato JSON. O formato da resposta e as regras do parâmetro `limit` serão definidos na Etapa 4.

A carga inicial já gera 1.000 clientes e 10.000 pedidos por padrão. A geração produz os mesmos dados quando repetida com os mesmos parâmetros, e as quantidades podem ser ajustadas em uma inicialização nova.

A comparação usará os mesmos dados, parâmetros e condições de execução. Não vamos adicionar esperas artificiais: a diferença no tempo de resposta deverá vir do trabalho real feito pelo sistema.

## Como as partes vão se conectar

O caminho principal será `cliente HTTP → pedidos-api → dados-api → PostgreSQL`.

- **pedidos-api:** serviço Node.js que recebe a requisição, chama a `dados-api` por HTTP e devolve a resposta.
- **dados-api:** serviço Node.js que usa a biblioteca `pg` para consultar o PostgreSQL.
- **PostgreSQL:** já guarda clientes (`clients`) e pedidos (`orders`), ligados pelo campo `client_id`.
- **OpenTelemetry e Jaeger:** ajudam a acompanhar uma requisição pelos serviços e pelas consultas ao banco. Esse registro do percurso é chamado de trace.
- **postgres_exporter, Prometheus e Grafana:** coletam e mostram números do banco ao longo do tempo, chamados de métricas.
- **pg_stat_statements:** reúne estatísticas das consultas, como quantas vezes foram executadas e quanto tempo levaram.
- **Docker Compose:** já inicia o banco; os outros componentes serão integrados nas etapas seguintes.

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

As pastas ainda vazias têm um arquivo `.gitkeep` para que possam ser incluídas no Git. A pasta interna `observability/` guardará as configurações de observabilidade; `database/`, os arquivos do banco; e `tests/`, os testes e experimentos.

## Uma etapa por vez

O [plano de implementação](docs/plano-implementacao.md) descreve as oito etapas e como conferir cada entrega. Só vamos começar uma nova etapa depois da autorização do usuário. As orientações para os agentes estão em [AGENTS.md](AGENTS.md).

O PostgreSQL está fixado em 18.6. A biblioteca HTTP, as versões de Node.js e os componentes de observabilidade serão definidos nas etapas correspondentes. Nenhuma dependência Node.js foi instalada.
