# Checkpoint de retorno: terça-feira, 03/11/2026

Gravado na sexta, 30/10/2026. Sessão: `369f7ad0-1f7c-4d31-aee3-e4888794205d`.
Ao retomar: ler este arquivo e o fim da conversa (de trás para frente), rodar `git fetch` neste repositório e ver se chegou algo da CRW-3584 ou da Carol.

---

## 1. LTDEV-2: EmailIndexingService no staging (prioridade)

**Estado em 28/10 (últimos logs: `Erros/Debug.log` e `Erros/internal-nlog.txt`, commit 6d3c192)**

O serviço `_Staging OneCrawford EmailIndexingService HostedService` roda em `D:\Sites\services\staging\EmailIndexingService\publish\` e varre a caixa a cada 10 min. O erro de ConnectionString de 22/10 foi resolvido: o serviço já lê o ParameterRoot.

Problemas abertos:

1. **E-mail não indexado** (28/10, 12:35 e 14:29, mesmo e-mail reprocessado):
   - Erro: `InvalidOperationException: Usuário autenticado inválido; The operation is not valid for the state of the transaction.`
   - Local: `ClaimEmailService.IndexEmail`, linha 128 (Service-ClaimEmailAutomation).
   - Hipóteses a verificar:
     - o `ServiceUser.UserName` (GUID) não é um usuário ativo do `usr.UserX` no banco de **staging**, ou não tem acesso à operação do sinistro;
     - a falha de autenticação dentro do `TransactionScope` deixa a transação abortada, e é daí que vem a 2ª mensagem.
   - **Próximo passo:** conferir o GUID no StagingOneCrawfordDB com
     `select UniqueId, UserName, IsActive from usr.UserX where UniqueId = '<GUID do appsettings>'`.
     Depois, ler o `ClaimEmailService.cs:128` na `main` e na `LTDEV-2-brscloud-connection`.
2. **Log no banco falha:** `Cannot open database "StagingLogDB" requested by the login` (660 vezes). A conta do serviço não tem login no StagingLogDB. Pedir permissão à Carol ou à infra, ou tirar o target `database` da regra.
3. **Log em arquivo sem permissão:** `UnauthorizedAccessException` em `publish\log\Debug.log`. Dar escrita na pasta `publish\log` para a conta do serviço.
4. **Verificação de produção na CRW-3584** (26/10, `LTDEV-2 - Instalar servico (producao).saida.txt`): 1 erro e 8 avisos. A conta `CRAWFORDBRASIL\nelson.diniz` não abre o `StagingLocalizationsDB`. Nada foi instalado, foi só verificação (`-SoVerificar`).

**Branch pendente:** `LTDEV-2-brscloud-connection` (Service-ClaimEmailAutomation, commit 5cb0e1e de 23/10). Ela traz o fallback BRSCloudConnection → DefaultConnection e os ajustes de anexos, nomes e datas. Está no GitHub, **mas não foi mesclada na `main`**. Confirmar se há PR aberto, e se o staging foi publicado com ou sem ela.

**Padrão de connection string:** o backend lê só `DefaultConnection` (FluentDataContext). O framework marca essa chave como obsoleta em favor de `BRSCloudConnection`, mas nenhuma branch do backend lê a chave nova. No servidor, ter as duas com o mesmo valor é o caminho seguro.

**RabbitMQ na CRW-3584** (26/10): o serviço está ok, nas portas 5672 e 15672. O `rabbitmqctl` falhava por `ERLANG_HOME` não carregado na sessão; abrir um PowerShell novo resolve. Confirmar se o vhost e o usuário `enviroment` foram criados.

**Para a Carol:** a pasta `Para a Carol/` tem `Instalar EmailIndexingService.ps1` e `.cmd` (26/10). Está sem commit.

## 2. LTDEV-15: Distribuição automática de processos (origem BRL-735)

- **Decisão:** reaproveitar a BRL-735 e ajustar, numa branch nova `LTDEV-15` a partir da `main`.
- **Worktrees locais, sem push:**
  - `Antlia\Crawford\BRSCloud-Backend-LTDEV-15`
  - `Antlia\Crawford\BRSCloud-Frontend-LTDEV-15`
  - a BRL-735 original fica em `...-BRL-735`.
- **Análise completa:** `LTDEV-15_analise.md`. Tem alteração local sem commit (2 linhas).
- **Cards:** `LTDEV-15 - Cards Jira (rascunho).md` e `(mockup).html`, sem commit. São 4 subtarefas, totalizando **119 a 166 h (15 a 21 dias úteis)**:
  - Card 1: 29–39 h
  - Card 2: 30–40 h
  - Card 3: 28–45 h
  - Card 4: 32–42 h
- **Perguntas abertas** (seção 9 da análise):
  - P1 desempate: fase do processo × "mais atualizados";
  - P2 nível de hierarquia: campo no `RoleX` ou tabela própria;
  - P3 Ramo em `dbo.Claim`: opção A ou B;
  - P9 gestor com mais de um líder;
  - P10 a P12: fluxo de aprovação e permissão do botão.
- **Próximo passo:** o Nelson revisar os cards. Levar P1 a P3 para a Carol.
- **Lembrete:** estimativas em horas e dias úteis, nunca com datas. Cards com checklist no topo.

## 3. Outras pendências

- O Backend na `main` tinha o erro `DpapiConfigurationSource` ausente (commit 80ffb8f98 do William). Foi dado como encerrado por ora; reverificar se ainda compila.
- `LTDEV-2 appsettings.json` (com segredos): **não vai para o Git** em texto puro. Já está no GitHub como `LTDEV-2 appsettings.zip` (AES-256). A senha foi passada no chat em 22/10.
- O repositório `caracelli/Crawford` é **público**. Ler cada arquivo antes de subir. Prints e configs de staging (IP do banco, senha do RabbitMQ) já foram publicados por outra máquina; vale avaliar removê-los.
- Arquivos locais fora do Git por decisão: `CHECKPOINT_REINICIO_16-10.md`, `LTDEV-2_banco.sql`, `LTDEV-2_localizations.sql`, `schema_log.txt`, `seed_log.txt`.

## 4. Estado do Git (30/10)

- `Doctos Crawford\Crawford`: `main` igual a `origin/main` (6d3c192).
- Sem commit:
  - `LTDEV-15_analise.md` (alterado)
  - os dois arquivos de cards da LTDEV-15
  - a pasta `Para a Carol/`
- Nenhum monitor ou processo em segundo plano precisa ser religado.

## 5. Ordem sugerida para terça

1. `git fetch` e ler o que chegou: logs novos do staging ou retorno da Carol.
2. LTDEV-2: diagnosticar o "Usuário autenticado inválido" (item 1.1).
3. LTDEV-2: permissões do log (itens 1.2 e 1.3) e o merge da `LTDEV-2-brscloud-connection`.
4. LTDEV-15: revisão dos cards com o Nelson e perguntas para a Carol.
