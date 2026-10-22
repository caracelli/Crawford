# LTDEV-15 – Distribuição automática de processos: análise da construção

Origem: branch BRL-735 (BRSCloud-Backend e BRSCloud-Frontend). Análise de 21/10/2026, só de leitura.

Fontes: código da BRL-735 e do `main` atual (backend `70132fee3`, frontend `fb7826e71`); todos os PRs abertos e fechados ligados à BRL-735, à BRL-718 e a assuntos relacionados; os documentos "Distribuição de processos - QA.docx" e "Distribuição de processos (1).docx"; a passagem de sessão `LTDEV-15_passagem_de_sessao.txt`; o banco local `CarolOneCrawfordDB` (cópia reduzida).

---

## 1. Resumo

- **A BRL-735 nunca foi rejeitada.** Foi aprovada duas vezes, mas não chegou ao `main`:
  - o merge em staging (jul/2025) se perdeu quando refizeram o staging;
  - os PRs finais (#45 no backend e #67 no frontend), já aprovados, fecharam sozinhos quando a branch base `test-brazil` foi apagada.
- **O que dá para aproveitar:** a estrutura das parametrizações (entidades, repositórios, controllers, telas) e a ideia do fluxo. Os 37 arquivos novos do backend já estão no padrão II.
- **O motor de distribuição tem que ser reescrito.** Três defeitos impedem o uso como está:
  1. **Escala de hierarquia errada:** a tela grava o nível de 1 a 10 (1 Trainee … 10 Presidente), mas a consulta compara com `RoleX.HierarchicalPosition`, que no banco vai de 1 = Presidente a 5 = todo o resto. No Brasil, Júnior, Pleno e Sênior estão todos no 5. Uma regra "Júnior" (3) procura **Gerentes**. É a causa direta do defeito apontado pela QA em 03/10/2025.
  2. **Quem tem 0 casos abertos nunca recebe:** a consulta parte da tabela `Claim` com `COUNT(*)`.
  3. **Roda dentro da transação do cadastro:** uma falha na troca de situação ou de regulador desfaz o cadastro do sinistro inteiro, depois de ele já ter sido enviado à integração.
- **O frontend da BRL-735 não funciona do jeito que está:**
  - o diálogo de troca de regulador quebra ao abrir;
  - o Ramo "obrigatório" só fica vermelho e não impede salvar;
  - as telas novas não verificam permissão;
  - o Chile fica sem tradução.
- **O `main` já tem regras que a BRL-735 ignora:**
  - DEV-545 (#172): o regulador principal é quem assume a situação "Avisado";
  - DV-137 (#307): trocar o regulador principal atualiza a trava de sistema.
  
  A troca de regulador da LTDEV-15 tem que estender o `ClaimService.ChangeMainAdjuster` do `main`, e não usar o caminho paralelo da BRL-735.
- **Já existe na base:**
  - gestor = líder da equipe (`Squad`/`SquadLeader`/`SquadMember`), com tela de equipes e dashboard de casos pendentes;
  - template de e-mail "Alteração de Regulador Principal" (ação 6);
  - precedente de flag por país (`ParameterRoot.IsBillingTypeRequired`).
- **Estimativa revisada: 125 a 165 horas (16 a 21 dias úteis de 8 h).** Os 105 h anteriores não incluíam o novo nível de hierarquia, o backend do fluxo de aprovação nem as correções do frontend.

---

## 2. Requisitos consolidados

| # | Requisito | Fonte |
|---|---|---|
| R1 | Nível de hierarquia de 1 a 10 vinculado ao cargo, como **campo ou tabela nova**, sem mexer em `HierarchicalPosition` | Documento D3, anotação 1, banco |
| R2 | Tela Ramo (Susep) × Regulador | D4 |
| R3 | Ramo no sinistro para todos os países (hoje fica em `brl.Claim`) | D6, anotação 3 |
| R4 | Ramo obrigatório por flag no `ParameterRoot`, ligada só no Brasil | D5, anotação 2, QA |
| R5 | Tela de parametrização: Operação, Sub-operação, Seguradora, Ramo, Estimativa de prejuízo ("a partir de") e Hierarquia | D7, print da QA |
| R6 | Após o cadastro, escolher automaticamente o regulador com menos casos abertos, **incluindo quem tem 0**, filtrando pelo nível | D8, D16, anotação 6 |
| R7 | Desempate (a definir, ver seção 9) | D9 × anotação 6 |
| R8 | Sem parametrização, a escolha continua manual | Anotação 4 |
| R9 | Primeira situação em nome de quem cadastrou; depois o sistema troca o regulador e lança a mesma situação em nome dele | D13 |
| R10 | O regulador da situação não muda | D11 |
| R11 | Permissão no botão de regulador principal; com parametrização, só gestores | D10, D17, anotações 5 e 7 |
| R12 | Observação obrigatória de no mínimo 30 caracteres na troca | D12, anotação 8 |
| R13 | Pedido de troca enviado por e-mail ao gestor, que aprova | Anotação 9 |
| R14 | Tela de aprovações | Anotação 11 |
| R15 | Tela de equipes (avaliar se a `/Squad` atual basta) | Anotação 10 |
| R16 | Traduções, Tags, exportação do campo, integração BRS2 | D18 |
| R17 | Registrar e notificar as falhas da distribuição | Análise |
| R18 | Não quebrar a DEV-545 (Avisado) nem a DV-137 (trava) | PRs #172 e #307 |

---

## 3. Histórico dos PRs e decisões da equipe

| Repositório | PR | O que foi | Resultado |
|---|---|---|---|
| Backend | #2, #3 | versões "old" (William) | fechados para o Dalben refazer em nome dele |
| Backend | #4 (735), #5 (718) | Dalben → staging | mesclados em 15/07/2025; o merge se perdeu quando o staging foi refeito |
| Backend | #10 | ajuste do ActivityAreaService | mesclado em staging |
| Backend | **#45** | BRL-735 → test-brazil | aprovado em 05/11/2025; **fechou sem merge** em 29/04/2026 (base apagada) |
| Frontend | #7 (718), #8 (735) | → staging | mesclados em 15/07/2025 |
| Frontend | **#67** | BRL-735 → test-brazil | aprovado em 05/11/2025; **fechou sem merge** em 15/09/2026 (base apagada) |

**Pedidos de revisão ainda pendentes** (a LTDEV-15 deve atender):
1. `with(nolock)` no `from Claim` da consulta de candidatos (#45).
2. Chaves de tradução que faltam: `DistributionClaimService.Message.ChangeSituationReason`, `ChangeMainAdjusterService.*.IsGuid` (#45).
3. Usings sobrando, principalmente no `ClaimObservation.cs` (#4, #45).
4. `this.` no serviço de troca de regulador (#4).
5. A lista de níveis vir do backend e ser traduzida (#67; o William pediu, o Dalben não fez).
6. Chave de menu e permissão da tela de Distribuição em `page.utils.ts` (#67).
7. Padrão de subscribes no Angular novo (#8).

**Decisões da equipe a respeitar:**
- Padrão II (`BaseServiceII`, `EntitiesII`), sem abstrações próprias; criação e exclusão no Service; todo Service com `_mapper`, `_authProvider`, `_eventBus` e `_cache` (#4, #5).
- Enums em `Domain/Entities/Enums.cs` (#4).
- **O William pediu para levar o ActivityArea para `Cores`** (#4). Depois disso o `main` reescreveu o ActivityArea no padrão II, mas em `Claims`. Ver a pergunta P3.
- Scripts em `OneCrawford.Infra.Database.SqlServer/_executar/`.

---

## 4. Como a BRL-735 funciona (backend)

1. `ClaimService.AfterRegister` chama `DistributionClaimService.DistributionClaimForAdjuster(claimCode)` em **todos os países**, sem flag, e ignora o resultado.
2. O serviço:
   - lê o sinistro e a última situação (só segue se for a primeira);
   - procura a regra (`ParameterDistribuitionClaimRepository.GetParameterByFilter`);
   - busca os candidatos (`ClaimAdjusterRepository.SelectAdjustersForDistribution`);
   - se a regra tem Ramo, cruza com `ParameterActivityAreaAdjuster`;
   - pega o primeiro por quantidade de casos;
   - lança a mesma situação para o escolhido e troca o regulador principal (`ChangeMainAdjusterService`).
3. Busca da regra: cada campo casa se for igual ao do sinistro ou nulo na regra; a estimativa funciona como piso (`EstimateLossValue <= estimativa do sinistro`); ordem por estimativa decrescente.

Consulta de candidatos da BRL-735 (`OneCrawford.Infra.Data/Repositories/Claims/ClaimAdjusterRepository.cs`):
```sql
select MainAdjuster.Id, ..., Count(*) as NroClaim
from Claim                                   -- sem nolock; parte do Claim: 0 casos fica de fora
join Situation ... join Person as MainAdjuster on MainAdjuster.Id = Claim.MainAdjusterId
join Usr.UserX as CUser on CUser.PersonId = MainAdjuster.Id
join RoleX on RoleX.Id = CUser.RoleId
where Claim.IsDeleted = 0 and Situation.IsCancelled = 0 and Situation.IsLast = 0
  and Claim.RootId = @0 and CUser.IsActive = 1
  and RoleX.HierarchicalPosition = @1        -- escala errada (ver seção 5)
  [and CUser.OperationId = @2]
group by ... order by NroClaim asc           -- sem desempate
```

---

## 5. Defeitos encontrados

**Backend – motor de distribuição**
| # | Defeito | Onde |
|---|---|---|
| B1 | Escala de hierarquia: nível de 1 a 10 crescente comparado com `HierarchicalPosition` de 1 a 5 decrescente | `ClaimAdjusterRepository.cs:49`, `Domain/Entities/Enums.cs` |
| B2 | Regulador com 0 casos abertos nunca é candidato | `ClaimAdjusterRepository.cs:28-30` |
| B3 | Roda dentro do `TransactionScope` do cadastro: falha desfaz o sinistro depois de ele já ter ido para a integração; o front recebe o regulador antigo | `ClaimService.AfterRegister` |
| B4 | A troca de situação passa pela checagem `CanChangeClaimSituationOfAnotherAdjuster`: falha em silêncio para o cadastrador comum | `ClaimSituationService.cs:373` (main) |
| B5 | Usa sempre o serviço de situação comum, nunca o do país | `NativeInjectorBootStrapperCommon.cs:162` |
| B6 | Sem desempate e sem controle de concorrência (dois cadastros ao mesmo tempo escolhem o mesmo regulador) | — |
| B7 | Mensagens trocadas (Cancelado × Encerrado); a fase da situação se perde; o motivo gravado é a própria chave de tradução | `DistributionClaimService.cs:62-65, 114-131` |
| B8 | Import em massa distribui e depois troca de novo pela planilha; roda a consulta a cada linha | `ImportClaimService.cs:253-266` |
| B9 | Ramo só é resolvido no Brasil: regras com Ramo nunca casam nos outros países | `ClaimBrazilService.Validation` |

**Backend – parametrizações e troca de regulador**
| # | Defeito | Onde |
|---|---|---|
| B10 | Exclusão de regra nunca é gravada (falta `scope.Complete()`) | `ParameterDistribuitionClaimService.RemoveByUniqueId` |
| B11 | NullReference ao salvar sem Operação ou Seguradora; código não encontrado vira regra genérica sem aviso | `ParameterDistribuitionClaimService.cs:66, 80` |
| B12 | Prioridade de regras invertida (a genérica vem antes da específica); `ExistParameter` não trata nulos | `ParameterDistribuitionClaimRepository.cs:86-95, 148-190` |
| B13 | Repositórios sem filtro de país; chaves de tradução erradas nas validações | repositórios e entidades de parâmetro |
| B14 | `ChangeMainAdjusterService`: NullReference com motivo vazio; sem checagem de permissão; ignora a trava (DV-137), o participante e o e-mail CC do fluxo do main | `ChangeMainAdjusterService.cs:116, 146` |
| B15 | Controllers só com `[Authorize]`, sem permissão | `Controllers/Parameters/*` |
| B16 | Dois `ActivityAreaController` na mesma rota (Claims e Cores): erro de rota ambígua | — |
| B17 | O `ActivityAreaRepository` do **main** tem Insert/Update/Delete com `NotImplementedException`: o CRUD de Ramo já está quebrado no main | `Infra.Data/Repositories/Claims/ActivityAreaRepository.cs` |

**Scripts BRL-735-1..4**
- Nenhum é idempotente.
- Não criam `GroupUserPermission`, então os menus ficam invisíveis.
- O nome da PK foi copiado de outra tabela.
- O -2 cria a estimativa como nula, contra um `decimal` não nulo na entidade.
- **O -3 (Ramo em `dbo.Claim`) quebra a `PROC_ParameterMovementFee`** (coluna ambígua) e deixa desatualizados `PROC_ParameterMovementExpense`, `Vw_ClaimReportTag_Brazil`, `Vw_ExportClaimFilter_Brazil` e o dashboard do Brasil.
- O -4 está em ISO-8859-1, sem `N''`, e faltam chaves.

**Frontend**
| # | Defeito | Onde (`BRSCloud.FrontEnd/ClientApp/src/`) |
|---|---|---|
| F1 | Diálogo de troca de regulador quebra: o form não tem `reason` nem `claimUniqueId`; o `uniqueId` obrigatório nunca recebe valor | `app/modules/claims/dialog-claim-situation-main-adjuster/` |
| F2 | Motivo limitado a 50 caracteres (padrão do `crw-input`) e sem mínimo | idem |
| F3 | Ramo "obrigatório" só visual: o `crw-combo` não propaga o validador; `setFormFieldRequired()` nunca é chamado | `claim-basic-main`, `claim-basic-brazil`, `@brscloud/components/fields/crw-combo` |
| F4 | Telas novas sem permissão; menu com `isVisible: true`; tela de Distribuição usa o GUID da tela de Ramo | `parameters/menu-parameter`, telas novas |
| F5 | Tela de Distribuição aceita regra vazia; modelo com `activityUniqueId` × form `activityAreaUniqueId`; troca de idioma corrompe a lista de cargos | `parameters/parameter-distribuition-claim/` |
| F6 | i18n: `pa` em vez de `cl` (Chile sem texto); chaves faltando; texto em espanhol no `br`; menu em português nos 8 idiomas | telas novas e `@brscloud/translates/i18n/` |
| F7 | `formClearUniqueIdEmpty` aplicado em todos os países, em todo control "uniqueid" | `claim-basic-main.component.ts` |
| F8 | Textarea duplicado na Argentina; Chile sem combo de Ramo | `claim-policy-argentina`, `claim-policy-chile` |

---

## 6. Modelo de dados relevante (banco)

- `dbo.Claim`: `MainAdjusterId` (→ Person), `SituationId`, `SituationPhaseId`, `OperationId`, `SubOperationId`, `InsuranceId`, `RootId`. **Sem** `ActivityAreaId` (fica em `brl.Claim`).
- Estimativa de prejuízo: `dbo.ClaimValue.EstimateLossValue` (`ClaimValue.Id` = `Claim.Id`).
- Usuário e cargo: `usr.UserX.PersonId` → Person; `usr.UserX.RoleId` → `dbo.RoleX` (`HierarchicalPosition`: 1 Presidente, 2 Diretor, 3 Gerente, 4 Coordenador, 5 demais). Fora do Brasil, os cargos são genéricos ("Empleado"), e na Argentina a escala é invertida.
- Situação aberta: `Situation.IsLast = 0 AND IsCancelled = 0`. A ordem do fluxo vem de `SituationTypeId` (`Situation.Sequence` é quase sempre 0). Histórico em `dbo.ClaimSituation` (`ToPersonId`). O Peru tem `peru.Situation`.
- Ramo: `dbo.ActivityArea` tem 74 ativos, **todos do Brasil**. Os outros países não têm Ramo cadastrado.
- Equipes: `Squad`/`SquadLeader`/`SquadMember` por `UserId`, com dados em todos os países (BR: 12 equipes, 46 líderes, 186 membros). **263 membros têm mais de um líder**, e 28 usuários do Brasil não estão em equipe.
- Permissão: `usr.PageX`, `usr.PageComponent` (179 = "Change Main Adjuster", liberado para quase todos os grupos), `usr.GroupUserPermission`, flags `usr.GroupUser.Can*`.
- E-mail: `TemplateEmailAction` 6 = ChangeMainAdjuster (template nos roots 1 e 5); ações 12 e 20 já mandam e-mail ao líder.
- `HierarchyOfPerson`: sem uso e vazia.
- O banco local **não serve para dimensionar** carga, porque tem só 5 sinistros. Volumes reais dependem de homologação ou produção.

---

## 7. Proposta de construção (branch LTDEV-15)

**Reaproveitar (copiar e ajustar namespace para o ActivityArea do main)**
- Entidades, filtros, interfaces, models e controllers das parametrizações: `ParameterActivityAreaAdjuster*`, `ParameterDistribuitionClaim*`.
- Esqueleto dos dois repositórios de parâmetro e mapeamentos do AutoMapper.
- Frontend: estrutura das telas de parâmetro, services e combos (o merge já está preparado na LTDEV-15).

**Corrigir**
- Defeitos B10 a B13, B15 e B17.
- Frontend: F4 a F8.
- Pedidos de revisão pendentes (seção 3).

**Reescrever**
- **Motor de distribuição:**
  - consulta partindo de `UserX`, com 0 casos, país, `IsDeleted` e acesso por operação;
  - novo nível de hierarquia (R1);
  - desempate e lock contra concorrência;
  - execução **depois** do `scope.Complete()` do cadastro;
  - serviço de situação do país (factory), num caminho interno sem a checagem `CanChangeClaimSituationOfAnotherAdjuster`;
  - flag "distribuição ativa" por país;
  - log e aviso das falhas;
  - não distribuir no import.
- **Troca de regulador:** estender o `ClaimService.ChangeMainAdjuster` do main com motivo (mínimo de 30) e permissão `GroupUser.CanChangeMainAdjuster`. Descartar o `ChangeMainAdjusterService` paralelo.
- **Diálogo do frontend:** refazer (F1, F2).
- **Scripts:** idempotentes, com FKs, índices, PageX/PageComponent/GroupUserPermission para todos os países e Localizations em UTF-8 com `N''`.

**Construir (itens novos)**
- Nível de hierarquia de 1 a 10 no cargo, com cadastro no cargo.
- Flag de Ramo obrigatório no `ParameterRoot`, com validador real no front.
- Botão de troca escondido quando há parametrização e liberado só para gestores.
- Pedido de troca: tabela, serviço, endpoints, e-mail ao líder pelo Service-Email e status no sinistro.
- Tela de aprovações: lista do líder logado, aprovar ou reprovar com motivo.
- Carga por regulador: reaproveitar o `dashboard-squad-claim-pending` ou um componente leve na tela de aprovação.

**Descartar:** a reestruturação dos `ClaimSituation*Service`, `SendMailByParametrization`, `SelectPersonByUniqueIds`, os `.csproj` e o `appsettings` da branch, e a mudança do ActivityArea para `Cores` (se a P3 confirmar).

**Ramo em `dbo.Claim` (R3)** – duas opções:
- **A (menor risco, 3–4 h):** manter em `brl.Claim` e expor por um método virtual no `ClaimService`, que o Brasil sobrescreve. Procs, views e dashboard não mudam.
- **B (requisito literal, 8–12 h):** migrar para `dbo.Claim` e ajustar `PROC_ParameterMovementFee`/`Expense`, as 2 views, o dashboard e o `ClaimBrazilRepository`, removendo a coluna do brl.

SQL sugerido para os candidatos (`HierarchyLevel` é o campo novo de R1, nome provisório):
```sql
WITH Candidatos AS (                         -- parte do usuário: entra quem tem 0 casos
  SELECT DISTINCT u.PersonId
  FROM usr.UserX u
  JOIN dbo.RoleX r ON r.Id = u.RoleId AND r.IsActive = 1 AND r.IsDeleted = 0
  WHERE u.RootId = @RootId AND u.IsActive = 1 AND u.IsDeleted = 0 AND u.IsBlocked = 0 AND u.IsExternal = 0
    AND r.HierarchyLevel = @Nivel
    AND (@ActivityAreaId IS NULL OR EXISTS (SELECT 1 FROM dbo.ParameterActivityAreaAdjuster a
         WHERE a.RootId = @RootId AND a.IsDeleted = 0 AND a.AdjusterId = u.PersonId AND a.ActivityAreaId = @ActivityAreaId))
),
Abertos AS (
  SELECT c.MainAdjusterId AS PersonId, c.Id, c.UpdatedDate, s.SituationTypeId
  FROM dbo.Claim c WITH (NOLOCK)
  JOIN dbo.Situation s WITH (NOLOCK) ON s.Id = c.SituationId
  WHERE c.RootId = @RootId AND c.IsDeleted = 0 AND s.IsLast = 0 AND s.IsCancelled = 0
)
SELECT ca.PersonId, COUNT(a.Id) AS QtdAbertos,
       MAX(<ordem da fase por SituationTypeId>) AS FaseMaisAvancada,  -- desempate opção 1
       MAX(a.UpdatedDate) AS UltimaAtualizacao                       -- desempate opção 2
FROM Candidatos ca LEFT JOIN Abertos a ON a.PersonId = ca.PersonId
GROUP BY ca.PersonId
ORDER BY QtdAbertos, FaseMaisAvancada DESC, ca.PersonId;
```

---

## 8. Estimativa revisada

| Bloco | Horas |
|---|---|
| **Backend** | |
| Reaproveitar parametrizações (copiar e ajustar) | 6–8 |
| Corrigir serviços e repositórios de parâmetro, permissão, ActivityArea do main | 8–10 |
| Motor de distribuição (reescrever) | 14–18 |
| Nível de hierarquia de 1 a 10 no cargo (campo, script, endpoint) | 5–7 |
| Troca de regulador no fluxo do main (motivo, permissão) | 4–6 |
| Flag de Ramo obrigatório (ParameterRoot e validação) | 2–3 |
| Pedido de troca e aprovação (tabela, serviço, endpoints, e-mail ao líder) | 12–16 |
| Ramo – opção A / opção B | 3–4 / 8–12 |
| Scripts SQL idempotentes | 5–7 |
| **Frontend** | |
| Telas de parâmetro: correções, permissão, i18n, menu | 13–20 |
| Ramo obrigatório parametrizável (6 países, incluindo o Chile) | 6–8 |
| Diálogo de troca (refazer) e botão com permissão e "Solicitar troca" | 6–9 |
| Pedido de troca (service, diálogo, status) | 6–8 |
| Tela de aprovações | 12–16 |
| Nível no cadastro de cargo; carga por regulador (opcional) | 3–8 |
| **Testes e entrega** | |
| Testes do motor, ponta a ponta por país, concorrência, import; apoio à QA; PRs | 14–18 |
| **Total (Ramo opção A)** | **127–171 h ≈ 16 a 21 dias úteis** |
| Total com Ramo opção B | +5–8 h |

---

## 9. Perguntas pendentes

**Para a Carol**
- **P1. Desempate.** O documento diz "casos mais atualizados" (última atualização); o Nelson diz "quem vai fechar primeiro" (fase do processo). Qual vale? Se for a fase, a ordem por `SituationTypeId` precisa ser validada.
- **P2. Nível de hierarquia.** O `HierarchicalPosition` atual não serve (escala invertida, Júnior/Pleno/Sênior iguais). O nível novo de 1 a 10 fica como campo no `RoleX` ou numa tabela própria? Quem cadastra o nível dos cargos fora do Brasil, onde só existe "Empleado"?
- **P3. ActivityArea:** levar para `Cores`, como o William pediu no #4, ou deixar em `Claims`, onde o main o reescreveu? E o Ramo em `dbo.Claim` (R3): opção A ou B?
- **P4.** Os outros países vão cadastrar Ramos? Hoje só o Brasil tem.
- **P5.** "Pirâmide de Property" e "somente situações parametrizadas" (D15, D16): o que significam exatamente?
- **P6.** A estimativa de prejuízo é só piso ("a partir de") ou uma faixa?
- **P7.** Import e cadastro externo devem distribuir?
- **P8.** Exportação, Tags e BRS2 precisam do Ramo e da distribuição?

**Para o Nelson**
- **P9.** Gestor = líder da equipe, mas 263 membros têm mais de um líder. Notificar todos? Qualquer um aprova? E quem não está em equipe?
- **P10.** O gestor troca direto, sem pedido?
- **P11.** "Com parametrização, não trocar o regulador" vale só para a troca manual, mantendo a automática (D13)?
- **P12.** Restringir o botão por grupo (`GroupUserPermission`), por ser líder, ou pelas duas coisas?
- **P13.** Acesso a uma base com dados reais (homologação) para medir a carga por regulador e os sinistros sem Ramo.

---

## 10. Estado local (nada no GitHub)

- `BRSCloud-Backend-LTDEV-15`: branch LTDEV-15 = `main` (`70132fee3`), sem alterações.
- `BRSCloud-Frontend-LTDEV-15`: branch LTDEV-15 = `main` + merge da BRL-735 preparado e **sem commit**.
- `BRSCloud-Backend-BRL-735` / `BRSCloud-Frontend-BRL-735`: branch original BRL-735 e branch de estudo `estudo/BRL-735-main` (frontend com o merge do main resolvido; backend igual à BRL-735).
