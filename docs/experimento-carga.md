# Etapa 7 — Experimento de carga

## Executar e localizar os resultados

Requisitos: PowerShell 7, Docker com Compose e acesso às imagens já usadas pelo projeto. Não é necessário instalar Node ou bibliotecas no Windows.

```powershell
pwsh -NoProfile -File tests/Test-Load.ps1
```

O script inicia um projeto isolado com portas livres, senha efêmera e banco novo com 1.000 clientes e 10.000 pedidos. Não usa o volume do ambiente principal. Ao terminar, encerra os contêineres e preserva o volume do experimento, inclusive em falha. Não execute outras suítes ou cargas simultaneamente; outros projetos Docker e programas da máquina também disputam recursos.

A execução imprime o diretório `test-results/observability-load-.../`, ignorado pelo Git. Nele ficam:

- `summary.json`: configuração sem credenciais, recursos do Docker, versões, assinatura dos dados, snapshots SQL, resumos e situação final.
- `c1-r1-lento.json` e equivalentes: cada amostra, com início relativo, duração, status e validade; não contêm corpos de resposta.
- `warm-*.json`: aquecimentos separados, excluídos da comparação.
- `expected.json`: hash SHA-256 e quantidade de registros da resposta de referência.
- `report.md`: tabela por execução e mediana das métricas das três rodadas.

Falhas preservam os arquivos já produzidos; confira `metadata.status` antes de interpretar o relatório. Uma falha abrupta do próprio gerador pode impedir que ele salve a execução atual. Não há limpeza automática de volumes.

## Método

O gerador roda em um contêiner Node 22.23.1 separado, acessando `pedidos-api:3000` pela rede interna do Compose. O tempo observado corresponde a esse caminho, sem passagem pela porta publicada no Windows. Node, APIs, banco e observabilidade compartilham os recursos do Docker.

Primeiro, o script compara o corpo completo das duas rotas, confere 100 registros e ordem crescente dos IDs. Durante a carga, cada resposta HTTP 200 deve ter o mesmo hash dessa referência; respostas diferentes são erros, mesmo com status 200.

São três rodadas para concorrência 1 e três para concorrência 5, sempre com `limit=100`. Em cada rodada as duas rotas são exercitadas separadamente. A ordem é lenta/otimizada, otimizada/lenta, lenta/otimizada. A alternância reduz o favorecimento por ordem, mas três rodadas não constituem um balanceamento perfeito nem uma análise estatística de significância.

Cada execução tem 10 segundos de aquecimento e 30 segundos de envio medido. O modelo é de **carga fechada**: cada trabalhador aguarda a resposta completa antes de enviar a próxima chamada. Há até 1 ou 5 chamadas em andamento; não se impõe a mesma quantidade de requisições por segundo às duas rotas. Uma rota mais rápida poderá concluir mais chamadas na mesma janela.

Ao fechar a janela, o gerador não inicia novas chamadas e aguarda as pendentes. A vazão divide sucessos pelo tempo efetivo, incluindo essa drenagem. A duração HTTP usa relógio monotônico e inclui headers e corpo completo. A validação do hash acontece depois da captura da duração, mas ainda consome recursos e influencia o ritmo do gerador. As amostras ficam em memória até o fim da execução; o gerador também pode limitar a vazão. Não são impressas respostas durante a carga.

Os parâmetros mantêm o ambiente principal: timeout entre APIs de 3 segundos, timeout SQL de 1 segundo por consulta, pool de 10 conexões e observabilidade ligada com amostragem `parentbased_always_on`. O gerador usa prazo próprio de 10 segundos para finalizar ou abortar uma leitura HTTP, sem modificar o prazo entre APIs. São aproximadamente oito minutos de aquecimento e carga, além de builds, partida e intervalos.

## Métricas e consultas SQL

Latência média, mediana e p95 consideram somente respostas válidas. **p95** é um percentil: 95% das observações terminam até esse valor. O cálculo usa *nearest rank*, selecionando a posição `ceil(0,95 × quantidade)` da lista ordenada. A mediana usa a mesma definição, com fração 0,5. Sem sucessos, latências são `null` e a vazão é zero.

Erros são contabilizados por status HTTP, corpo inválido e falha de transporte, incluindo prazo excedido durante leitura do corpo. Um HTTP 504 rápido não entra como sucesso e não melhora artificialmente a latência apresentada. O relatório mantém erros ao lado dos tempos; não compare apenas respostas bem-sucedidas se as taxas de falha forem diferentes.

Antes/depois da janela medida, o orquestrador consulta as três estruturas SQL reconhecidas em `observability/postgres-exporter/statements.sql`. Não usa a estimativa `increase` do Prometheus como contagem exata e não reseta estatísticas. Aquecimento e pré-verificação ficam fora dos deltas. Registra também `stats_reset`, `dealloc`, `queryid` e `stats_since`; reset, descarte, desaparecimento ou mudança de entrada invalidam a comparação.

Entre fases, aguarda ausência de consultas de negócio ativas da dados-api e confirma novamente após dois segundos, permitindo atualização das estatísticas. Probes `SELECT 1` não são consideradas trabalho pendente do experimento. Se não houver repouso em até 30 segundos, interrompe a execução e preserva resultados parciais. Se houver deltas inesperados em execução sem erros, também interrompe. Não há chamadas de negócio concorrentes de outros clientes no projeto isolado.

Sem erros, cada resposta lenta deve corresponder a uma consulta de pedidos e 100 consultas de clientes; cada otimizada, a um JOIN. As contagens totais podem ser maiores na rota otimizada porque ela atende mais chamadas. Compare também o trabalho **por resposta**, não apenas o total da janela. Quando há timeout HTTP, a dados-api pode continuar consultando: nesse caso o delta representa trabalho observado, sem atribuição exata a respostas válidas.

O relatório agrega rodadas pela mediana das médias, dos p95 e das vazões. A mediana dos três p95 não é o p95 de todas as amostras juntas. Não há limiar obrigatório de ganho: o teste valida método, respostas e contagens, sem exigir que o JOIN seja um número predeterminado de vezes mais rápido.

## Validação e limites

O orquestrador executa testes do gerador com um servidor HTTP local controlado antes da carga. Cobrem percentis, resumo, limite de concorrência, drenagem, leitura completa, HTTP 503, corpo inválido e timeout durante corpo. Esses testes não substituem a execução real; somente o experimento completo verifica integração e deltas SQL. As assinaturas do conteúdo e das sequences do banco são comparadas antes/depois da carga.

Os números representam esta máquina, esta carga e esta configuração. Docker Desktop, caches, coleta a cada 5 segundos, exportação de spans e outros processos influenciam as medidas. O histórico do Jaeger é limitado e a fila de spans pode perder dados sob volume elevado; não é a fonte exata da contagem SQL. O experimento não mede capacidade máxima, não isola o custo da observabilidade e não demonstra comportamento em produção. Grafana e Jaeger permanecem disponíveis durante a execução nas portas livres do projeto, mas os contêineres são encerrados ao final.

## Resultado medido em 19/10/2026

Comando executado: `pwsh -NoProfile -File tests/Test-Load.ps1`, com saída zero. Projeto `observability-load-20261019182913-e68c50`, de 18:29:13 a 18:41:55 UTC, incluindo preparação e intervalos. Docker informou 8 CPUs e 3.961.131.008 bytes de memória (aproximadamente 3,69 GiB); cliente e servidor Docker 29.7.2. Gerador Node 22.23.1, com as imagens da aplicação e observabilidade identificadas no resumo. A revisão-base registrada foi `594e61c038c2a392809a671a7fa29848f643c712`, com alterações locais da Etapa 7 ainda sem commit.

Valores abaixo são as medianas das métricas das três rodadas; não são percentis calculados juntando todas as amostras:

| Concorrência | Rota | Mediana das médias HTTP (ms) | Mediana dos p95 (ms) | Mediana da vazão (sucessos/s) |
|---|---|---|---|---|
| 1 | Lenta | 95,42 | 167,45 | 10,47 |
| 1 | JOIN | 11,46 | 16,76 | 86,35 |
| 5 | Lenta | 203,84 | 346,95 | 24,38 |
| 5 | JOIN | 21,10 | 38,18 | 234,56 |

As 12 medições totalizaram 31.272 respostas válidas, sem erros HTTP, de transporte ou de conteúdo. Foram observadas 355.472 consultas nas estruturas SQL da aplicação: em todas as execuções, exatamente 101 por resposta lenta e uma por resposta otimizada. A contagem de linhas e a assinatura do conteúdo e das sequences permaneceram iguais antes/depois. Os contêineres do projeto foram encerrados e o volume PostgreSQL preservado.

Nesta execução, JOIN apresentou menor latência e maior vazão nos dois níveis de concorrência. Com cinco chamadas simultâneas, a vazão aumentou e a latência por chamada também: mais trabalho concorre pelos mesmos recursos. Essa observação não identifica um gargalo específico nem uma capacidade máxima.

Os três testes Node do gerador passaram. Também passaram a análise sintática PowerShell e `git diff --check`. A conferência independente das amostras recalculou médias, p95 e vazões e verificou contagens, limites das janelas e deltas SQL. A revisão encontrou uma falha de apresentação no agrupamento dos dicionários do PowerShell: a tabela agregada ficava vazia. O agrupamento foi corrigido e conferido com quatro grupos de valores conhecidos; o relatório local foi regenerado a partir das mesmas medições, sem modificar amostras nem repetir a carga. As suítes das etapas anteriores não foram repetidas, pois suas APIs, banco e configuração principal não foram alterados.

Artefatos locais desta execução: `test-results/observability-load-20261019182913-e68c50/`. Eles não são versionados; a tabela acima preserva os principais resultados e o método permite novas execuções. A Etapa 8 continua responsável pelo roteiro final de apresentação.
