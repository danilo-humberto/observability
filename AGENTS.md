# Convenções do projeto

## Objetivo e comunicação

Este é um projeto acadêmico de Sistemas Distribuídos para demonstrar observabilidade do PostgreSQL e o problema N+1. Responda em português brasileiro e explique decisões técnicas e seus trade-offs de forma acessível. Diferencie comportamento implementado, arquitetura planejada e recomendações.

## Implementação incremental

- Consulte o [plano de implementação](docs/plano-implementacao.md) e execute exclusivamente a etapa autorizada pelo usuário.
- Antes de implementar, apresente brevemente os arquivos que pretende criar ou modificar.
- Investigue os arquivos reais antes de afirmar como o projeto funciona.
- Ao concluir uma etapa, relate mudanças, validações, limitações e próxima etapa; pare e solicite autorização para continuar.
- Não avance automaticamente nem acrescente funcionalidades de etapas futuras.
- Em modo de planejamento, investigue e proponha; não altere arquivos de implementação.

## Organização e simplicidade

- `services/pedidos-api/`: entrada HTTP e comunicação com o serviço de dados.
- `services/dados-api/`: acesso ao PostgreSQL com `pg` e execução de SQL.
- `database/`: futuros artefatos de modelagem, inicialização e dados reproduzíveis.
- `observability/`: futuras configurações de instrumentação, traces e métricas.
- `tests/`: testes e experimentos proporcionais às etapas.
- `docs/`: arquitetura, plano e documentação necessária ao entendimento do projeto.
- Mantenha os dois serviços no mesmo repositório. Não introduza workspaces, frameworks, padrões ou abstrações sem necessidade demonstrada e alinhamento com o usuário.
- Priorize código simples, legível e mudanças pequenas e revisáveis. Respeite as convenções que forem estabelecidas na implementação.

## Invariantes do experimento

- Os endpoints lento e otimizado devem retornar os mesmos registros, estrutura JSON e ordenação estável.
- O caminho lento deve executar uma consulta inicial de pedidos e uma consulta de cliente por pedido; o otimizado deve utilizar JOIN.
- Não use atrasos artificiais para produzir diferenças de latência.
- Os dados iniciais devem ser reproduzíveis, com 1.000 clientes e 10.000 pedidos por padrão e quantidades ajustáveis.
- Compare as implementações sob condições equivalentes e registre as limitações dos resultados.

## Aprovações e preservação

- Preserve trabalho existente. Inspecione o estado Git e os diffs quando houver repositório inicializado.
- Não inicialize Git, crie commits, branches, tags, pull requests ou faça pushes sem autorização.
- Não execute ações destrutivas nem remova arquivos importantes sem autorização explícita.
- Solicite aprovação antes de adicionar ou alterar materialmente dependências, esquemas, migrações, contratos públicos, segurança ou infraestrutura. A aprovação explícita desses itens dentro de uma etapa cobre o escopo aprovado.
- Não realize deploys nem execute comandos em produção sem autorização explícita.
- Não registre segredos ou dados pessoais em código, documentação, logs ou testes. Use placeholders em exemplos de ambiente.

## Validação e documentação

- Utilize testes proporcionais ao comportamento alterado e execute primeiro as verificações mais direcionadas.
- Não invente resultados nem apresente mocks como evidência de consultas ou integrações reais.
- Relate os comandos executados, seus resultados e o que não foi possível validar.
- Revise o conteúdo final e os diffs disponíveis para evitar mudanças fora do escopo, arquivos temporários e segredos.
- Atualize documentação quando o comportamento durável mudar. Não descreva componentes planejados como já executáveis.
- Durante a Etapa 1, crie somente estrutura, documentação e `.gitignore`: sem APIs, SQL, Compose funcional ou integrações.
