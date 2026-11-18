# LTDEV-104 – Cards do Jira (rascunho para revisão)

Padrão: LTDEV-15 (epic CRAWFORD-36 → 4 cards "Desenvolvimento Avulso", um por semana).
Projeto: CRAWFORD. Epic já criado pelo Bruno: **CRAWFORD-48** (título com erro de digitação: "LTEDV-104 - Painel Despesas Financeiro").
Prazo: **4 semanas, de 19/11/2026 a 16/12/2026** (20/11 é feriado). Estimativa de 90 a 126 h; a folga das 4 semanas cobre as dependências abaixo e os ajustes do PR.

---

## Epic CRAWFORD-48: descrição sugerida

**Objetivo**
Criar a aba "Despesas" na tela inicial do OneAdjust. Nela o regulador logado acompanha as próprias despesas de reembolso de vistoria: pagamento agendado, a receber, em análise e recusadas com o motivo. A aba é só de consulta e exportação.

**Escopo**
Somente o Brasil, conforme a reunião de 17/11/2026. A consulta escolhe a fonte pelo `ParameterRoot.hasFinance`: com 0, lê do BRS2; com 1, lê do BRSCloud. Assim, quando o Brasil migrar, a mesma tela passa a ler do BRSCloud sem nova entrega.

**Contexto técnico** (levantamento no `main` em 18/11/2026)
- A despesa fica em `dbo.ClaimMovement` (`IsFee = 0`; regulador quando `ClaimMovementPayToId = 3`).
- No BRS2 ela vira `sin_movto`, com `unique_id = ClaimMovement.UniqueId`. O vínculo é por esse GUID, e não por `nro_sinistro + cod_sinmov`.
- A situação, a aprovação, a recusa e a baixa do Brasil existem só no BRS2:
  - a Service-IntegracaoBRS não sincroniza despesas;
  - o update vindo do BRS2 mantém `IsPayed`/`IsInvoiced` originais.
- A leitura do BRS2 usa o linked server `[BDC-CRAWFORD].bd_corp`, que já é usado no `main` (`Vw_ExportClaimChubbFilter`), e a view `vw_crw_sinistro_movto`.

**Critérios de sucesso**
- O regulador vê só as despesas em que é a pessoa a pagar, também na API e na exportação, mesmo quando é gestor.
- Os três indicadores batem com a `affOpBaixaPagto` do BRS2 para os mesmos reguladores.
- Os filtros, a busca e a exportação respeitam o ano fiscal e os critérios do documento.
- O clique na despesa abre o sinistro na aba Despesas, em outra aba do navegador.
- A tela tem permissão própria, traduções e o padrão visual do OneAdjust.

**Dependências**
- **Respostas do Marco:**
  - dia do corte do ano fiscal;
  - despesa recusada que tem baixa: entra ou não em "Pagamento agendado";
  - linked server liberado para o usuário da API em produção.
- **Acesso de leitura** à base de staging do BRS2 (`bd_stg_brasil`) ou ao linked server no ambiente de desenvolvimento.

**Outras informações**
- Documentos:
  - `Novos Projetos\LTDEV-104 .docx` (análise);
  - `Novos Projetos\LTDEV-104 - Entendimento.docx`;
  - `Transcricoes\Saneamento de dúvidas - LTDEV-104 ...txt`.
- O documento precisa ser corrigido: escopo só Brasil e vínculo pelo `UniqueId`.

---

## Card 0 — Entendimento do projeto e análise técnica
(Somente para o apontamento da reunião de 17/11 e do levantamento de 18/11. As horas são informadas pelo Nelson.)

**Checklist**
- [ ] Reunião de saneamento de dúvidas (17/11)
- [ ] Leitura da análise, do entendimento e do relatório do Rafael
- [ ] Levantamento no código: BRSCloud (backend e frontend), Service-IntegracaoBRS, BRS-Integracao-Brasil e Service-Finance
- [ ] Estimativa, cards e perguntas em aberto enviadas ao Marco

---

## Card 1 — Consulta e regras (backend)
**Datas:** 19/11 a 25/11 · **Estimativa:** 32 a 44 h

**Checklist**
- [ ] Endpoint da aba no `DashboardController` (padrão do `GetExpenseToReceived`), com o regulador sempre tirado do usuário logado e nunca de parâmetro
- [ ] Consulta Brasil (`hasFinance = 0`): `ClaimMovement` ligado à `vw_crw_sinistro_movto` pelo `UniqueId`, mais `sin_movto_recusa` (última recusa), `motivo_recusadespesa`, `tp_despesa` e `sinistro`, pelo linked server
- [ ] Consulta Cloud (`hasFinance = 1`): os mesmos campos lidos do próprio `ClaimMovement` (`WorkflowStatusId`, `ApprovedDate`, `Declined*`, `IsPayed`/`PayedDate`)
- [ ] Indicadores (Pagamento agendado, A receber, Em análise) desde o início do ano fiscal, sem efeito dos filtros
- [ ] Filtros: período de criação (padrão 90 dias), período de aprovação, situação, pagamento agendado, grupo; busca livre; ordenação e paginação no padrão `SelectPagination`
- [ ] Critérios da `affOpBaixaPagto`:
  - despesa paga ao regulador;
  - não excluída;
  - não é débito/crédito do sistema;
  - não é honorário;
  - sinistro não cancelado.
- [ ] Despesa do Cloud sem par no BRS2 (o BRS2 recusa lançamento em sinistro encerrado) tratada conforme decisão
- [ ] Script `_executar/LTDEV-104 OneCrawfordDB.sql`: PageComponent próprio da aba (a permissão `Expense` já é da aba "online") e permissões; traduções no LocalizationsDB
- [ ] Injeções, mapeamentos e testes da consulta com SQL real

**Critérios de sucesso**
- Os indicadores e a tabela batem com a consulta feita direto no BRS2.
- Nenhuma despesa de outro regulador sai pela API.
- Os scripts rodam duas vezes sem erro.

**Riscos técnicos**
- Linked server não liberado em produção: o desenho muda, com cópia dos campos pela integração, e o card cresce.
- Desempenho do join pelo linked server com o volume do ano fiscal.

---

## Card 2 — Exportação e fechamento do backend
**Datas:** 26/11 a 02/12 · **Estimativa:** 10 a 16 h, mais a folga das dependências

**Checklist**
- [ ] Exportação Excel com os mesmos filtros e colunas da tabela, pelo mecanismo assíncrono do sistema (`ExportExcelHelper` / download do WIP) ou pelo padrão do `ExportAdjusterExpenses`
- [ ] Verificar se o Service-GenerateReport precisa de um tipo de relatório novo
- [ ] Restrição ao regulador logado também na exportação
- [ ] Ajustes do Card 1 depois das respostas do Marco (recusada com baixa, corte do ano fiscal)

**Critérios de sucesso**
- O arquivo exportado tem as mesmas linhas da tabela filtrada, e só do regulador logado.

**Riscos técnicos**
- Um relatório novo no Service-GenerateReport inclui um terceiro repositório na entrega.

---

## Card 3 — Aba Despesas (frontend)
**Datas:** 03/12 a 09/12 · **Estimativa:** 28 a 38 h

**Checklist**
- [ ] Aba `expense` no `dashboard-gateway` (já há a linha comentada e a tradução `PANELS.EXPENSE`), visível pela permissão nova
- [ ] Três indicadores no padrão da aba Timesheet de Produtividade (azul, laranja, amarelo)
- [ ] Filtros com `crw-date2` e `crw-combo` (multiple); `crw-table` com "Filtro para a tabela", paginação e cor por linha (`colorRow`)
- [ ] Legenda das cores no padrão da tela de aprovação: Emitido sem cor, Checado amarelo, Aprovado laranja, Pagamento agendado azul, Recusado vermelho
- [ ] Clique na linha abre `/#/claim/{código}/expense` em outra aba
- [ ] Botão de exportar, ligado ao Card 2
- [ ] Traduções nos 8 idiomas; `tsc`, `eslint`, `prettier` e build AOT

**Critérios de sucesso**
- A tela segue o modelo da Figura 4 do documento.
- Os indicadores não mudam com os filtros.
- A aba aparece só com permissão.

---

## Card 4 — Testes, roteiro da QA e entrega
**Datas:** 10/12 a 16/12 · **Estimativa:** 20 a 28 h

**Checklist**
- [ ] Regras:
  - [ ] indicadores;
  - [ ] recusadas e última recusa;
  - [ ] ano fiscal;
  - [ ] critérios de exclusão;
  - [ ] regulador sem despesas.
- [ ] Segurança: outro regulador por parâmetro alterado, gestor que faz vistoria, exportação
- [ ] Troca pela `hasFinance`: Brasil lendo do BRS2 e país com `hasFinance = 1` lendo do Cloud
- [ ] Comparação com a `affOpBaixaPagto` para 2 ou 3 reguladores reais na homologação
- [ ] Ciclo completo na homologação: lançar, conferir, aprovar, dar baixa e recusar; ver o reflexo no painel
- [ ] Roteiro da QA no modelo do LTDEV-2 (para o Vinicius)
- [ ] PRs do backend e do frontend

**Critérios de sucesso**
- Todos os critérios de aceitação do documento (CA-001 a CA-017) cobertos no roteiro.
- Painel igual ao BRS2 na homologação.
