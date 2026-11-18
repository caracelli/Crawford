Marco, bom dia! Sobre o LTDEV-104, li a documentação e a reunião de ontem e já olhei o código. Ficou estimado em 4 semanas, de 19/11 a 16/12, e os cards estão no Jira, no epic CRAWFORD-48.

Duas correções para o documento:
1. **Escopo:** só Brasil, como combinamos na reunião. O documento ainda fala em LATAM.
2. **Vínculo com o BRS2:** não é `nro_sinistro + cod_sinmov`, e sim o `UniqueId` da despesa (`ClaimMovement.UniqueId = sin_movto.unique_id`).

Também vi que a Service-IntegracaoBRS não traz despesas. Por isso, a situação, a aprovação, a recusa e a baixa do Brasil só existem no BRS2. A ideia é ler o BRS2 pelo linked server `[BDC-CRAWFORD].bd_corp`, que já é usado no sistema, na view do Chubb. A escolha da fonte fica pelo `hasFinance` do país: quando o Brasil migrar, a tela passa a ler do Cloud sem mudar nada.

Para fechar as regras, preciso de três respostas:
1. **Ano fiscal:** o corte é 1º/11/2026? Vale para a tabela, os indicadores e a exportação?
2. **Recusada com baixa:** se uma despesa recusada tiver baixa (`son_pago_sinmov = 'S'`), ela entra em "Pagamento agendado"? A RN-002 diz que sim, mas a RN-005 diz que recusada não entra em nenhum indicador.
3. **Linked server:** o `[BDC-CRAWFORD]` está liberado para o usuário da API em produção e na homologação?

E um pedido: preciso de acesso de leitura ao staging do BRS2 (`bd_stg_brasil`), ou ao linked server, no ambiente de desenvolvimento. Sem isso, a parte do Brasil só consigo testar na homologação.

Obrigado!
