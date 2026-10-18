# Plano de implementação

## Uma etapa por vez

Cada etapa precisa de autorização do usuário. Antes de começar, vamos apresentar os arquivos previstos e conversar sobre as escolhas importantes que ainda estiverem abertas.

Ao terminar, vamos explicar o que mudou, as decisões tomadas, os comandos usados nas verificações, os resultados e as pendências. Depois, vamos parar e pedir autorização para continuar.

Este plano descreve o trabalho por etapas. A Etapa 1 entregou pastas e documentação. A Etapa 2 foi autorizada para implementar somente o banco e os dados; as etapas seguintes continuam dependendo de autorização própria.

## Etapa 1 — Pastas e documentação inicial

- **O que fazer:** criar as pastas dos serviços, banco, observabilidade, testes e documentação, além do README, AGENTS.md, arquitetura, plano e `.gitignore`.
- **Como conferir:** revisar a estrutura, os links, os diagramas e a coerência dos textos. Confirmar que nada das próximas etapas foi implementado.
- **Quando termina:** as pastas e os documentos estão prontos e explicam o que existe e o que ainda será feito, sem APIs, SQL ou ambiente executável.

## Etapa 2 — PostgreSQL e dados para os testes

- **Decisões aprovadas e implementadas:** PostgreSQL 18.6 na imagem oficial Alpine; tabelas `clients` e `orders` ligadas por `client_id`; campos e restrições descritos na arquitetura; inicialização transacional e dados determinísticos gerados por SQL. Compose apenas com banco, volume persistente, healthcheck e porta em loopback. Novas cargas usam projetos isolados.
- **Como conferir:** executar o banco e verificar os 1.000 clientes e 10.000 pedidos, as ligações entre eles e a possibilidade de gerar os mesmos dados em um banco de teste novo e separado. Conferir se as quantidades podem ser ajustadas e explicar como repetir a carga sem apagar dados por engano.
- **Quando termina:** o banco funciona, os dados podem ser gerados novamente com o mesmo resultado e o procedimento está documentado e verificado com consultas reais.
- **Validação realizada em 18/10/2026:** `./tests/Test-Database.ps1` passou usando PostgreSQL real e `docker compose config --quiet`. Foram confirmados 1.000 clientes e 10.000 pedidos em dois volumes com assinaturas idênticas, rollback após erro SQL, integridade e campos obrigatórios, rejeição de valor negativo, preservação dos registros e contadores de identidade nos testes de restrições e após reinício, carga de 3 clientes e 8 pedidos, 1 cliente sem pedidos e rejeição de parâmetros inválidos e senha ausente. Os contêineres de teste são encerrados e os volumes preservados. APIs, N+1, JOIN e observabilidade não foram implementados nem medidos nesta etapa.

## Etapa 3 — APIs Node.js e comunicação HTTP

- **O que fazer:** criar os dois serviços, fazer a pedidos-api chamar a dados-api por HTTP, conectar a dados-api ao banco e incluir os serviços no ambiente de execução. Antes disso, definir versões, biblioteca HTTP, rotas internas, limites de espera por resposta e tratamento de falhas.
- **Como conferir:** testar a comunicação real entre os serviços, a conexão com o banco e a resposta quando a dados-api estiver indisponível ou demorar além do limite de espera, chamado de timeout.
- **Quando termina:** os serviços executam, conversam por HTTP e tratam as falhas básicas. As rotas N+1 e JOIN ficam para a próxima etapa.

## Etapa 4 — Rotas lenta e otimizada

- **O que fazer:** criar `GET /pedidos/lento?limit=100` e `GET /pedidos/otimizado?limit=100`, definir o formato JSON, as regras de `limit` e a ordem dos resultados. As consultas ao banco ficam na dados-api.
- **Como conferir:** comparar as respostas completas usando os mesmos dados e limites; testar valores inválidos e uma busca sem resultados; comprovar 1 + N consultas reais na versão lenta e uma consulta com JOIN na otimizada. Não adicionar esperas artificiais.
- **Quando termina:** as duas rotas retornam os mesmos registros, na mesma ordem e com o mesmo formato, e os testes mostram a diferença na forma de consultar o banco.

## Etapa 5 — OpenTelemetry e Jaeger

- **O que fazer:** configurar o OpenTelemetry para acompanhar chamadas HTTP e consultas feitas com `pg`, ligar os registros dos dois serviços e enviá-los ao Jaeger.
- **Como conferir:** chamar as duas rotas e acompanhar, no mesmo trace, a entrada da requisição, a chamada entre os serviços e as consultas SQL. Verificar as consultas repetidas e o JOIN.
- **Quando termina:** os traces reais permitem seguir uma requisição até o banco e identificar o N+1, sem mostrar senhas, tokens ou outras informações secretas.

## Etapa 6 — Métricas e estatísticas das consultas

- **O que fazer:** habilitar pg_stat_statements, configurar postgres_exporter, Prometheus e Grafana e preparar consultas e painéis úteis ao experimento. Verificar quais estatísticas o exporter realmente fornece.
- **Como conferir:** confirmar que o Prometheus coleta dados, que os painéis mostram números reais e que as estatísticas SQL correspondem às requisições feitas. Registrar o período medido e como evitar misturar resultados antigos com os do teste.
- **Quando termina:** podemos consultar e relacionar as métricas e estatísticas ao experimento, e o ambiente completo pode ser executado com Docker Compose.

## Etapa 7 — Testes de carga e comparação

- **O que fazer:** preparar testes com várias requisições, registrar como repeti-los e comparar os tempos de resposta e as consultas das duas versões.
- **Como conferir:** usar os mesmos dados, limites, quantidade de chamadas simultâneas, duração e configuração. Definir o aquecimento, ou seja, as chamadas de preparação antes da medição, e a ordem dos testes. Registrar erros e considerar o impacto das ferramentas de observabilidade e dos recursos da máquina.
- **Quando termina:** temos resultados medidos que podem ser repetidos, com explicação do método, das condições e das limitações. Nenhum ganho numérico será prometido antes da medição.

## Etapa 8 — Documentação final e apresentação

- **O que fazer:** documentar como configurar, executar, verificar e encerrar o ambiente. Criar um roteiro para mostrar N+1, JOIN, traces, métricas, estatísticas e os resultados encontrados.
- **Como conferir:** seguir o roteiro completo localmente, testar os comandos, conferir os links e comparar a documentação com o sistema que foi construído.
- **Quando termina:** a documentação e o roteiro permitem executar a demonstração e explicar os resultados reais do projeto.

## Próxima etapa

A Etapa 3 depende de autorização. Antes de implementar as APIs, vamos alinhar versões de Node.js e dependências, biblioteca HTTP, rotas internas, timeouts, credenciais de acesso ao banco e comportamento de falhas. Não implementar os endpoints N+1 e JOIN antecipadamente.
