# LTDEV-15 – Cards do Jira (rascunho para revisão)

Padrão: DocWise Monitor (DOCW-160 + subtarefas DOCW-161..164).
Projeto: CRAWFORD. Estrutura proposta: Epic **LTDEV-15** (como o CRAWFORD-21 do LTDEV-2) → Desenvolvimento Avulso (pai) → 4 Subtarefas, uma por semana.

---

## Pai — Desenvolvimento Avulso
**Título:** LTDEV-15 - Distribuição automática de processos

**Checklist**
- [ ] Card 1 — Banco, parametrizações e nível de hierarquia
- [ ] Card 2 — Motor de distribuição e troca de regulador
- [ ] Card 3 — Telas de parâmetro, Ramo obrigatório e troca de regulador
- [ ] Card 4 — Pedido de troca, tela de aprovações, testes e entrega

**Objetivo**
Escolher automaticamente o regulador principal ao cadastrar um sinistro, pela senioridade e pela quantidade de processos em aberto de cada regulador, em todos os países LATAM, com telas de parametrização e controle da troca manual.

**Contexto**
A frente nasceu na branch BRL-735 (Leonardo Dalben e William Huang, 2025), aprovada duas vezes mas nunca mesclada no `main`: o merge em staging se perdeu e os PRs finais (#45 no backend, #67 no frontend) fecharam com a base `test-brazil` apagada. A análise de 21/10/2026 (`LTDEV-15_analise.md`) concluiu: reaproveitar a estrutura das parametrizações (37 arquivos novos no padrão II), reescrever o motor de distribuição (escala de hierarquia invertida, regulador com 0 casos fora da escolha, execução dentro da transação do cadastro) e refazer o diálogo de troca de regulador. A troca de regulador estende o `ClaimService.ChangeMainAdjuster` do `main`, respeitando a DEV-545 (situação "Avisado") e a DV-137 (trava de sistema).
A construção está dividida em 4 subtarefas, uma por semana.

**Critérios de sucesso**
- Sinistro cadastrado com parametrização vai para o regulador do nível certo com menos casos abertos, incluindo quem tem 0
- Sem parametrização, o cadastro continua manual, como hoje
- Com parametrização, a troca manual só por pedido aprovado pelo gestor, com motivo de 30 caracteres ou mais
- Ramo obrigatório por flag no país (ligada só no Brasil)
- Telas de parâmetro com permissão, tradução nos 8 idiomas e menu no padrão
- DEV-545 (Avisado) e DV-137 (trava) continuam funcionando

**Riscos técnicos**
O `main` andou cerca de 2.000 commits desde a BRL-735: os ganchos no núcleo do sinistro (`ClaimService`, `ClaimRepository`, `Claim.cs`, `NativeInjectorBootStrapper`) são reaplicados à mão. Perguntas em aberto (P1 a P13 da análise: desempate, nível de hierarquia, Ramo em `dbo.Claim`, quem aprova) podem mudar o desenho dos Cards 2 e 4. Volume real de carga por regulador só é mensurável em homologação.

**Outras informações**
Estimativa: 119 a 166 h (15 a 21 dias úteis). Origem: BRL-735. Análise completa: `Doctos Crawford\Crawford\LTDEV-15_analise.md`. Código em worktrees locais sem push: `BRSCloud-Backend-LTDEV-15` e `BRSCloud-Frontend-LTDEV-15` (branch LTDEV-15, a partir do `main`).

---

## Card 1 — Subtarefa
**Título:** LTDEV-15 — Card 1 — Banco, parametrizações e nível de hierarquia

**Checklist**
- [ ] Scripts idempotentes em `OneCrawford.Infra.Database.SqlServer/_executar/` (refazendo `BRL-735-1..4.sql`): tabelas `ParameterActivityAreaAdjuster` e `ParameterDistribuitionClaim` com FKs e índices, `PageX`/`PageComponent`/`GroupUserPermission` para todos os países, traduções em UTF-8 com `N''`
- [ ] Portar entidades e filtros: `OneCrawford.Domain/Entities/Parameters/ParameterActivityAreaAdjuster.cs`, `ParameterDistribuitionClaim.cs`, `Filters/ParameterDistribuitionClaimFilter*.cs`
- [ ] Portar repositórios: `OneCrawford.Infra.Data/Repositories/Parameters/ParameterActivityAreaAdjusterRepository.cs` e `ParameterDistribuitionClaimRepository.cs`, com filtro de país (B13)
- [ ] Portar serviços: `OneCrawford.Application/Services/Parameters/ParameterActivityAreaAdjusterService.cs` e `ParameterDistribuitionClaimService.cs`, corrigindo exclusão sem `scope.Complete()` (B10) e NullReference sem Operação/Seguradora (B11)
- [ ] Prioridade das regras (específica antes da genérica) e `ExistParameter` com nulos em `ParameterDistribuitionClaimRepository.cs` (B12)
- [ ] Controllers `OneCrawford.Services.Api/Controllers/Parameters/ParameterActivityAreaAdjusterController.cs` e `ParameterDistribuitionClaimController.cs` com permissão (B15)
- [ ] Uma só rota de Ramo: descartar `Controllers/Cores/ActivityAreaController.cs` da BRL-735 e completar o CRUD do `ActivityAreaRepository` do `main` (B16, B17)
- [ ] Nível de hierarquia 1 a 10 no cargo (`RoleX`), com cadastro e endpoint, sem mexer em `HierarchicalPosition`
- [ ] Flag de Ramo obrigatório no `ParameterRoot` (ligada só no Brasil) e Ramo exposto no `ClaimService` por método virtual sobrescrito no Brasil
- [ ] Injeções em `OneCrawford.Infra.CrossCutting.IoC/NativeInjectorBootStrapper.cs` e mapeamentos em `OneCrawford.Application/AutoMapper/ReverseMappingProfile.cs`

**Objetivo**
Ter no `main` atual a estrutura de parametrização da distribuição — tabelas, entidades, serviços e endpoints — corrigida e no padrão II, mais o nível de hierarquia e a flag de Ramo.

**Contexto**
A BRL-735 trouxe 37 arquivos novos que não conflitam com o `main` e podem ser aproveitados, mas com defeitos: exclusão de regra que não grava, regras genéricas com prioridade sobre as específicas, repositórios sem filtro de país, controllers só com `[Authorize]` e duas rotas `ActivityArea`. A escala de hierarquia usada (1 a 10 crescente) não bate com `RoleX.HierarchicalPosition` (1 Presidente a 5), por isso o nível novo é um campo próprio.

**Critérios de sucesso**
- Scripts rodam duas vezes sem erro e sem duplicar
- CRUD das duas parametrizações funciona pela API, só para quem tem permissão, filtrado pelo país
- Regra mais específica vence a genérica
- Cargo aceita nível de 1 a 10
- Brasil exige Ramo no cadastro; os outros países não

**Riscos técnicos**
Resposta da P2 (nível como campo no `RoleX` ou tabela própria) e da P3 (Ramo em `dbo.Claim`, opção A ou B) podem mudar o desenho. A opção B acrescenta 8 a 12 h (procs `PROC_ParameterMovementFee`/`Expense`, views e dashboard).

**Outras informações**
Estimativa: 29 a 39 h. Não depende de nada; bloqueia os Cards 2 e 3.

---

## Card 2 — Subtarefa
**Título:** LTDEV-15 — Card 2 — Motor de distribuição e troca de regulador

**Checklist**
- [ ] Reescrever a consulta de candidatos em `OneCrawford.Infra.Data/Repositories/Claims/ClaimAdjusterRepository.cs`: partir de `usr.UserX`, incluir quem tem 0 casos, filtrar país, nível e Ramo, `with(nolock)` (B1, B2)
- [ ] Desempate e controle de concorrência (dois cadastros simultâneos não escolhem o mesmo regulador) (B6)
- [ ] `OneCrawford.Application/Services/Claims/Events/DistributionClaimService.cs` rodando depois do `scope.Complete()` do cadastro, sem desfazer o sinistro em caso de falha (B3)
- [ ] Troca de situação pelo serviço do país, sem a checagem `CanChangeClaimSituationOfAnotherAdjuster` (B4, B5)
- [ ] Mensagens corretas (Cancelado × Encerrado) e motivo traduzido, não a chave (B7)
- [ ] Sem parametrização = manual; flag "distribuição ativa" por país
- [ ] Log e aviso das falhas da distribuição
- [ ] Não distribuir no import em massa (`ImportClaimService.cs`) (B8)
- [ ] Troca de regulador: estender `ClaimService.ChangeMainAdjuster` do `main` com motivo (mínimo de 30 caracteres) e permissão; descartar o `ChangeMainAdjusterService` paralelo (B14)
- [ ] Pedido de troca: tabela, serviço, endpoints e e-mail ao gestor pelo Service-Email

**Objetivo**
Distribuir automaticamente cada sinistro cadastrado para o regulador certo, sem nunca desfazer o cadastro, e controlar a troca manual do regulador principal.

**Contexto**
O motor da BRL-735 é chamado em `ClaimService.AfterRegister` em todos os países, sem flag, ignorando o resultado. A consulta parte da tabela `Claim` com `COUNT(*)` (quem tem 0 casos nunca entra), compara o nível na escala errada e roda dentro do `TransactionScope` do cadastro — uma falha desfaz o sinistro depois de ele ter ido para a integração.

**Critérios de sucesso**
- Exemplo do documento: R1=10, R2=9, R3=8 → o próximo vai para R3; regulador com 0 casos também recebe
- Falha na distribuição não desfaz o cadastro e fica registrada
- Sem parametrização, nada muda no cadastro
- Troca manual exige motivo de 30 caracteres e permissão; DEV-545 e DV-137 continuam funcionando
- Pedido de troca chega por e-mail ao gestor

**Riscos técnicos**
Critério de desempate em aberto (P1: fase do processo × última atualização × previsão de encerramento). Gestor com mais de um líder por membro (263 casos no Brasil) e membros sem equipe dependem da P9.

**Outras informações**
Estimativa: 30 a 40 h. Depende do Card 1; bloqueia o Card 4.

---

## Card 3 — Subtarefa
**Título:** LTDEV-15 — Card 3 — Telas de parâmetro, Ramo obrigatório e troca de regulador

**Checklist**
- [ ] Trazer o frontend da BRL-735 (merge sem conflito, já preparado no worktree `BRSCloud-Frontend-LTDEV-15`) e atualizar com o `main`
- [ ] `app/modules/parameters/parameter-distribuition-claim/`: validação de regra vazia, `activityUniqueId` × `activityAreaUniqueId`, lista de cargos vinda do backend e traduzida (F5)
- [ ] `app/modules/parameters/parameter-activity-area-adjuster/`: permissão e menu
- [ ] `app/modules/parameters/menu-parameter` e `app/configuration/pages/page.utils.ts`: GUIDs certos, `isVisible` por permissão (F4)
- [ ] `@brscloud/translates/i18n/`: Chile (`cl`, não `pa`), chaves faltando, menu traduzido nos 8 idiomas (F6)
- [ ] Ramo obrigatório real: validador propagado pelo `crw-combo` e `setFormFieldRequired()` nos 6 países, incluindo o Chile (F3, F8)
- [ ] `formClearUniqueIdEmpty` só onde precisa, em `claim-basic-main.component.ts` (F7)
- [ ] Refazer `app/modules/claims/dialog-claim-situation-main-adjuster/`: form com `reason` e `claimUniqueId`, motivo de 30 a N caracteres (F1, F2)
- [ ] Botão de regulador principal escondido com parametrização e liberado só para gestores
- [ ] Nível de hierarquia no cadastro de cargo

**Objetivo**
Entregar as telas de parametrização e a troca de regulador funcionando, com permissão e tradução, e o Ramo realmente obrigatório no Brasil.

**Contexto**
O frontend da BRL-735 não funciona como está: o diálogo de troca quebra ao abrir, o Ramo "obrigatório" só fica vermelho e não impede salvar, as telas não verificam permissão e o Chile fica sem tradução. O merge com o `main` não tem conflito.

**Critérios de sucesso**
- Telas de parâmetro só para quem tem permissão, nos 8 idiomas
- Não é possível salvar sinistro do Brasil sem Ramo; nos outros países, opcional
- Diálogo de troca abre, exige 30 caracteres e só aparece para quem pode trocar
- Build AOT sem erro

**Riscos técnicos**
A P10/P11 (gestor troca direto ou também por pedido) muda o comportamento do botão.

**Outras informações**
Estimativa: 28 a 45 h. Depende do Card 1. Se passar de 40 h, a folga dos Cards 1 e 2 cobre.

---

## Card 4 — Subtarefa
**Título:** LTDEV-15 — Card 4 — Pedido de troca, tela de aprovações, testes e entrega

**Checklist**
- [ ] Pedido de troca no frontend: diálogo "Solicitar troca" e status no sinistro
- [ ] Tela de aprovações: lista do líder logado, aprovar ou reprovar com motivo
- [ ] Carga por regulador (reaproveitar `dashboard-squad-claim-pending` ou componente leve na aprovação)
- [ ] Testes do motor: 0 casos, empate, concorrência, sem parametrização, import
- [ ] Testes ponta a ponta por país (Brasil, Argentina, Chile, Colômbia, México, Peru)
- [ ] Regressão: DEV-545, DV-137, upload de anexo, cadastro externo
- [ ] Roteiro de testes para a QA e apoio na homologação
- [ ] PRs no backend e no frontend, seguindo o `main`

**Objetivo**
Fechar o fluxo de aprovação da troca de regulador e entregar a funcionalidade testada em todos os países.

**Contexto**
Com parametrização, o regulador não troca direto: pede com motivo, o gestor recebe por e-mail e aprova na tela de aprovações (anotações 5, 8, 9 e 11 da reunião). A tela de equipes atual (`/Squad`) pode bastar para a gestão de equipes (P-b).

**Critérios de sucesso**
- Pedido feito → e-mail ao gestor → aprovação na tela → regulador trocado com o motivo registrado
- Reprovação registra o motivo e mantém o regulador
- Testes por país aprovados pela QA
- PRs aprovados

**Riscos técnicos**
Volume real de casos por regulador só é medido em homologação (P13). Mudança de regra depois da aprovação é reestimada.

**Outras informações**
Estimativa: 32 a 42 h. Depende dos Cards 2 e 3.
