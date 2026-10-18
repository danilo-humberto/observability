# Orientações do projeto

## Objetivo e comunicação

Este projeto de Sistemas Distribuídos vai mostrar como observar o PostgreSQL e entender o problema N+1. Responda em português brasileiro, com explicações simples e diretas. Explique os termos técnicos importantes e as vantagens e desvantagens das escolhas. Deixe claro o que já existe, o que está planejado e o que é uma sugestão.

## Trabalhe uma etapa por vez

- Consulte o [plano de implementação](docs/plano-implementacao.md) e faça apenas a etapa autorizada pelo usuário.
- Antes de começar a implementação, diga quais arquivos pretende criar ou alterar.
- Leia os arquivos do projeto antes de afirmar como ele funciona.
- Ao terminar uma etapa, explique o que mudou, o que foi verificado, as limitações e o próximo passo. Pare e peça autorização para continuar.
- Não comece a próxima etapa por conta própria nem adiante suas funcionalidades.
- No modo de planejamento, investigue e proponha soluções, sem alterar arquivos de implementação.

## Onde colocar cada coisa

- `services/pedidos-api/`: recebe chamadas HTTP e conversa com o serviço de dados.
- `services/dados-api/`: consulta o PostgreSQL usando `pg` e SQL.
- `database/`: arquivos para criar o banco e gerar dados que possam ser repetidos nos testes.
- `observability/`: configurações para acompanhar requisições, consultas e números do sistema.
- `tests/`: testes e experimentos de cada etapa.
- `docs/`: explicações sobre a organização, o plano e o funcionamento do projeto.

Mantenha os dois serviços no mesmo repositório. Evite adicionar ferramentas ou formas de organizar o código sem uma necessidade clara e sem conversar com o usuário. Isso inclui workspaces, que permitem gerenciar vários pacotes juntos.

Prefira código simples e fácil de ler, mudanças pequenas e as convenções já usadas no projeto.

## Regras do experimento

- As rotas lenta e otimizada devem retornar os mesmos registros, na mesma ordem e com o mesmo formato JSON.
- A versão lenta deve buscar os pedidos e depois consultar o cliente de cada pedido. A otimizada deve usar JOIN.
- Não adicione esperas artificiais para aumentar o tempo de resposta.
- A geração inicial deve permitir repetir os mesmos dados, com 1.000 clientes e 10.000 pedidos por padrão e quantidades ajustáveis.
- Compare as duas versões em condições equivalentes e explique as limitações dos resultados.

## Cuidados e autorizações

- Preserve o trabalho existente. Quando houver Git, confira seu estado e as diferenças entre os arquivos antes de alterar o projeto.
- Não inicialize Git, crie commits, branches, tags ou pull requests, nem envie alterações para o repositório remoto sem autorização.
- Não remova arquivos importantes nem faça ações que possam apagar trabalho sem autorização explícita.
- Peça aprovação antes de adicionar ou mudar de forma importante bibliotecas, estrutura do banco, migrações, contratos das APIs, segurança ou infraestrutura. Migrações são arquivos que registram mudanças na estrutura do banco. Contratos das APIs definem como enviar pedidos e receber respostas. Se esses itens já foram aprovados dentro da etapa, não é preciso pedir novamente para o mesmo trabalho.
- Não publique a aplicação nem execute comandos em produção sem autorização explícita.
- Não coloque senhas, tokens ou dados pessoais no código, na documentação, nos logs ou nos testes. Use valores fictícios nos exemplos de configuração.

## Como conferir e documentar

- Faça testes adequados ao tamanho e ao risco da mudança. Comece pelas verificações mais próximas do que foi alterado.
- Não invente resultados. Dados simulados em testes não comprovam que uma consulta ou integração real funcionou.
- Informe os comandos executados, os resultados e o que não foi possível verificar.
- Revise os arquivos e as diferenças disponíveis para encontrar mudanças fora do pedido, arquivos temporários e informações sensíveis.
- Atualize a documentação quando houver mudanças que afetem o entendimento ou o uso do projeto. Deixe claro quando algo ainda é apenas planejado.
- Na Etapa 1, faça somente as pastas, a documentação e o `.gitignore`. APIs, SQL, Compose funcional e integrações ficam para depois.
