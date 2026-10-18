# Observabilidade de Banco de Dados

Projeto didático para o seminário de Sistemas Distribuídos do IFPE. O objetivo é demonstrar como investigar o problema N+1 no PostgreSQL e comparar uma implementação ineficiente com outra que utiliza JOIN, com apoio de traces, métricas e estatísticas SQL.

## Estado atual

A Etapa 1 prepara somente a estrutura de pastas e a documentação. **Ainda não há aplicação ou ambiente executável.** Não existem APIs, scripts SQL, Docker Compose funcional ou ferramentas de observabilidade configuradas. Não há comandos de instalação ou execução disponíveis nesta etapa.

## Experimento planejado

O problema N+1 ocorre quando uma consulta inicial é seguida por uma consulta adicional para cada registro retornado. Neste experimento, buscar N pedidos e consultar o cliente de cada pedido produzirá 1 + N consultas SQL, mesmo quando vários pedidos pertencerem ao mesmo cliente.

Serão implementados dois endpoints públicos na `pedidos-api`:

| Endpoint planejado | Comportamento |
| --- | --- |
| `GET /pedidos/lento?limit=100` | Busca pedidos e realiza uma consulta de cliente por pedido na `dados-api`. |
| `GET /pedidos/otimizado?limit=100` | Recupera pedidos e clientes por meio de uma consulta com JOIN na `dados-api`. |

Ambos deverão retornar exatamente os mesmos registros e a mesma estrutura JSON, com ordenação estável. O formato do JSON e as regras de validação de `limit` serão definidos na etapa dos endpoints. Não serão usados atrasos artificiais.

O conjunto inicial planejado terá 1.000 clientes e 10.000 pedidos, gerados de maneira reproduzível. As quantidades poderão ser ajustadas nos testes. As comparações de latência deverão utilizar dados, parâmetros e condições de execução equivalentes.

## Arquitetura planejada

O fluxo principal será `cliente HTTP → pedidos-api → dados-api → PostgreSQL`.

- **pedidos-api:** serviço Node.js que recebe requisições HTTP, chama o serviço de dados por HTTP e retorna as respostas.
- **dados-api:** serviço Node.js que acessa o PostgreSQL com a biblioteca `pg` e executa as consultas SQL.
- **PostgreSQL:** armazena clientes e pedidos, relacionados por `cliente_id`.
- **OpenTelemetry e Jaeger:** instrumentação e visualização dos traces distribuídos, incluindo chamadas HTTP e consultas ao banco.
- **postgres_exporter, Prometheus e Grafana:** exposição, coleta e visualização de métricas do PostgreSQL.
- **pg_stat_statements:** estatísticas agregadas de execução das consultas SQL dentro do PostgreSQL.
- **Docker Compose:** orquestração futura dos contêineres do ambiente completo.

As responsabilidades e os fluxos de observabilidade estão detalhados em [Arquitetura](docs/arquitetura.md).

## Organização

```text
observability/
├── README.md
├── AGENTS.md
├── .gitignore
├── services/
│   ├── pedidos-api/
│   └── dados-api/
├── database/
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

As pastas sem implementação contêm apenas `.gitkeep`, um arquivo vazio usado para preservar diretórios quando o projeto for versionado. A pasta interna `observability/` reúne as futuras configurações de observabilidade; `database/` reunirá os artefatos do banco e `tests/`, os testes e experimentos.

## Desenvolvimento incremental

As oito etapas e seus critérios estão no [Plano de implementação](docs/plano-implementacao.md). Cada etapa exige autorização própria; concluir uma etapa não autoriza iniciar a seguinte. As convenções para agentes estão em [AGENTS.md](AGENTS.md).

Versões das tecnologias, bibliotecas HTTP e detalhes operacionais serão definidos nas etapas correspondentes. Nenhuma dependência foi instalada e o repositório Git ainda não foi inicializado.
