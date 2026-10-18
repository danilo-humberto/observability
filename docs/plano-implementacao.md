# Plano de implementação incremental

## Regras de execução

Cada etapa precisa de autorização explícita. Antes da implementação, apresentar os arquivos previstos e alinhar as decisões materiais ainda abertas. Ao concluir, informar mudanças, decisões, comandos de validação, resultados, limitações e pendências; parar e solicitar autorização para continuar.

As descrições abaixo são planejamento. Não representam funcionalidades já implementadas. A Etapa 1 entrega exclusivamente estrutura e documentação.

## Etapa 1 — Estrutura inicial e documentação de arquitetura

- **Entregáveis:** pastas dos serviços, banco, observabilidade, testes e documentação; README, AGENTS.md, este plano, arquitetura e `.gitignore`.
- **Validação:** conferir árvore, links locais, diagramas e consistência entre os documentos; verificar ausência de implementação fora do escopo.
- **Conclusão:** estrutura preparada e documentos distinguindo claramente a arquitetura planejada do estado atual, sem APIs, SQL ou ambiente executável.

## Etapa 2 — PostgreSQL, modelagem e dados reproduzíveis

- **Entregáveis:** definição aprovada da versão do PostgreSQL, modelo de clientes e pedidos relacionados por `cliente_id`, inicialização do banco e geração reproduzível de dados. Preparar apenas a infraestrutura necessária ao banco nesta etapa.
- **Validação:** executar o banco, confirmar 1.000 clientes e 10.000 pedidos por padrão, integridade do relacionamento e reprodução do conjunto de dados em uma inicialização limpa e isolada. Verificar quantidades ajustáveis e documentar como repetir a carga sem destruir dados inadvertidamente.
- **Conclusão:** banco executável e dados reproduzíveis demonstrados por verificações reais, com procedimento de inicialização documentado.

## Etapa 3 — APIs Node.js e comunicação HTTP

- **Entregáveis:** dois serviços executáveis, com a pedidos-api chamando a dados-api por HTTP; configuração de conexão ao banco e integração dos serviços ao ambiente de execução. Definir versões, biblioteca HTTP, rotas internas, timeouts e comportamento de falhas antes da implementação.
- **Validação:** verificar comunicação real entre processos, conexão com o banco e resposta controlada quando o serviço de dados estiver indisponível ou exceder o timeout.
- **Conclusão:** serviços executáveis, fluxo HTTP e tratamento básico de falhas validados, sem antecipar os endpoints N+1 e JOIN.

## Etapa 4 — Endpoints N+1 e otimizado

- **Entregáveis:** `GET /pedidos/lento?limit=100` e `GET /pedidos/otimizado?limit=100`; definição da resposta JSON, validação de `limit` e ordenação estável. O acesso SQL permanece na dados-api.
- **Validação:** comparar respostas completas com o mesmo conjunto de dados e limites; verificar entradas inválidas e conjunto vazio; comprovar consultas reais de 1 + N no caminho lento e uma consulta com JOIN no otimizado, sem atrasos artificiais.
- **Conclusão:** mesmos registros, estrutura JSON e ordenação nos dois caminhos, com diferença na estratégia SQL comprovada e testes proporcionais executados.

## Etapa 5 — Instrumentação com OpenTelemetry e Jaeger

- **Entregáveis:** instrumentação HTTP e `pg`, propagação de contexto entre serviços, exportação de traces e Jaeger no ambiente.
- **Validação:** executar os dois endpoints e inspecionar traces correlacionando a entrada HTTP, a chamada entre serviços e as consultas SQL; confirmar as consultas repetidas do caminho lento e o JOIN do otimizado.
- **Conclusão:** traces reais permitem identificar o N+1 e seguir uma requisição pelos dois serviços até o banco, sem exposição de segredos na telemetria.

## Etapa 6 — Métricas e estatísticas SQL

- **Entregáveis:** pg_stat_statements habilitado, postgres_exporter, Prometheus e Grafana configurados; consultas de investigação e painéis úteis ao experimento. Verificar quais estatísticas o exporter realmente disponibiliza.
- **Validação:** confirmar coleta ativa no Prometheus, métricas reais nos painéis e estatísticas SQL coerentes com requisições executadas. Documentar a janela de medição e qualquer necessidade de isolar estatísticas anteriores.
- **Conclusão:** indicadores e estatísticas reais são acessíveis e podem ser relacionados ao experimento; o ambiente completo está orquestrado por Docker Compose.

## Etapa 7 — Testes de carga, análise e comparação

- **Entregáveis:** procedimento reproduzível de carga, parâmetros de execução, resultados e análise da latência e das consultas para os dois caminhos.
- **Validação:** executar comparações com os mesmos dados, limite, concorrência, duração e configuração; controlar aquecimento e ordem dos cenários, registrar erros e considerar o efeito da instrumentação e dos recursos disponíveis.
- **Conclusão:** resultados medidos e reproduzíveis, com metodologia, condições e limitações registradas, sem pressupor ganhos numéricos.

## Etapa 8 — Documentação final e roteiro da apresentação

- **Entregáveis:** instruções de execução, configuração, validação e encerramento do ambiente; roteiro de demonstração do N+1, JOIN, traces, métricas e estatísticas; explicação dos resultados e limitações.
- **Validação:** seguir o roteiro completo em ambiente local, conferir comandos e links e garantir que a documentação corresponda ao sistema implementado.
- **Conclusão:** documentação e roteiro permitem executar, demonstrar e explicar os resultados reais do projeto.

## Próximo ponto de decisão

Após a entrega da Etapa 1, a Etapa 2 depende de autorização. Antes de implementá-la, alinhar versão do PostgreSQL, colunas e restrições do modelo, mecanismo de inicialização e estratégia de geração reproduzível. Não criar migrações, SQL ou configuração de contêineres antecipadamente.
