# LTDEV-104 – Perguntas para o Marco

## Perguntas
1. **Ano fiscal:** o corte é 1º/11/2026? Ele vale para a tabela, os indicadores e a exportação?
2. **Recusada com baixa:** se uma despesa recusada tiver baixa no BRS2 (`son_pago_sinmov = 'S'`), ela entra em "Pagamento agendado"? A RN-002 diz que sim, mas a RN-005 diz que recusada não entra em nenhum indicador.
3. **Linked server:** o `[BDC-CRAWFORD]` está liberado para o usuário da API em produção e na homologação? A ideia é ler o BRS2 por ele, como o sistema já faz na view do Chubb (`Vw_ExportClaimChubbFilter`).

## Pedido
Acesso de leitura ao staging do BRS2 (`bd_stg_brasil`), ou ao linked server, no ambiente de desenvolvimento. Sem isso, a parte do Brasil só pode ser testada na homologação.

## Correções no documento
1. **Escopo:** só Brasil, como combinado na reunião de 17/11. O documento ainda fala em LATAM.
2. **Vínculo com o BRS2:** é o `UniqueId` da despesa (`ClaimMovement.UniqueId = sin_movto.unique_id`), e não `nro_sinistro + cod_sinmov`.
