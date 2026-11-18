-- =============================================================================
-- LTDEV-2 - Traducoes do campo "Comunicacao/e-mail recebido"
--
-- RODAR CONTRA O BANCO DE LOCALIZACOES (connection string "LocalizationsConnection"),
-- NAO o CarolOneCrawfordDB. A tabela Localizations vive nesse banco separado.
-- Idempotente por chave + locale.
-- =============================================================================
if not exists (select 1 from Localizations where ResourceId='ClaimChronology.LastEmailReceivedDoneDate.IsGreaterThanOrNull' and LocaleId='')
    insert into Localizations (ResourceId,[Value],LocaleId,ResourceSet,ValueType,Updated)
    values ('ClaimChronology.LastEmailReceivedDoneDate.IsGreaterThanOrNull','Informe uma data válida','','Validation',0,GETDATE())
GO
if not exists (select 1 from Localizations where ResourceId='ClaimChronology.LastEmailReceivedDoneDate.IsGreaterThanOrNull' and LocaleId='en-US')
    insert into Localizations (ResourceId,[Value],LocaleId,ResourceSet,ValueType,Updated)
    values ('ClaimChronology.LastEmailReceivedDoneDate.IsGreaterThanOrNull','Enter a valid date','en-US','Validation',0,GETDATE())
GO
if not exists (select 1 from Localizations where ResourceId='ClaimChronology.LastEmailReceivedDoneDate.IsGreaterThanOrNull' and LocaleId='es-ES')
    insert into Localizations (ResourceId,[Value],LocaleId,ResourceSet,ValueType,Updated)
    values ('ClaimChronology.LastEmailReceivedDoneDate.IsGreaterThanOrNull','Informar una fecha válida','es-ES','Validation',0,GETDATE())
GO
