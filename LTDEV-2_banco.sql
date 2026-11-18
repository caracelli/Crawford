-- =============================================================================
-- LTDEV-2 - Integracao Outlook X BRS Cloud - SETUP COMPLETO DO BANCO
-- (rodar no CarolOneCrawfordDB - HML/local para teste; PRD idem, idempotente)
--
-- Tudo ADITIVO e IDEMPOTENTE ("se nao existir, cria"). Pode rodar varias vezes.
-- Secoes:
--   1) Card 5: coluna "Comunicacao/e-mail recebido" (ClaimChronology)
--   2) Idempotencia: coluna ExternalMessageId + indice filtrado (AttachmentClaim)
--   3) Parametrizacao por pais (colunas em ParameterRoot)
--   4) Garante as pastas mestre Emails/Documents por Root (cria se faltar)
--   5) POPULA a parametrizacao (Brasil preenchido; demais paises = template)
--
-- ATENCAO: as TRADUCOES (Localizations) NAO entram aqui - a tabela Localizations
-- fica em OUTRO banco (LocalizationsConnection). Rodar o LTDEV-2_localizations.sql
-- contra aquele banco.
-- =============================================================================
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- 1) Card 5 ----------------------------------------------------------------
if not exists (select 1 from sys.columns where object_id=object_id('ClaimChronology') and name='LastEmailReceivedDoneDate')
    alter table ClaimChronology add LastEmailReceivedDoneDate datetimeoffset(7) null
GO

-- 2) Idempotencia ----------------------------------------------------------
if not exists (select 1 from sys.columns where object_id=object_id('AttachmentClaim') and name='ExternalMessageId')
    alter table AttachmentClaim add ExternalMessageId varchar(255) null
GO
if not exists (select 1 from sys.indexes where name='IX_AttachmentClaim_ExternalMessageId' and object_id=object_id('AttachmentClaim'))
    create nonclustered index IX_AttachmentClaim_ExternalMessageId
        on AttachmentClaim (ExternalMessageId) where ExternalMessageId is not null
GO

-- 3) Parametrizacao por pais: colunas em ParameterRoot ---------------------
if not exists (select 1 from sys.columns where object_id=object_id('ParameterRoot') and name='EmailIndexingMailbox')
    alter table ParameterRoot add EmailIndexingMailbox varchar(255) null
GO
if not exists (select 1 from sys.columns where object_id=object_id('ParameterRoot') and name='EmailIndexingManualBox')
    alter table ParameterRoot add EmailIndexingManualBox varchar(255) null
GO
if not exists (select 1 from sys.columns where object_id=object_id('ParameterRoot') and name='EmailIndexingStore')
    alter table ParameterRoot add EmailIndexingStore bit null
GO
if not exists (select 1 from sys.columns where object_id=object_id('ParameterRoot') and name='EmailIndexingStoreDays')
    alter table ParameterRoot add EmailIndexingStoreDays int null
GO
if not exists (select 1 from sys.columns where object_id=object_id('ParameterRoot') and name='EmailIndexingLocalDomains')
    alter table ParameterRoot add EmailIndexingLocalDomains varchar(500) null
GO
if not exists (select 1 from sys.columns where object_id=object_id('ParameterRoot') and name='EmailIndexingAlertBox')
    alter table ParameterRoot add EmailIndexingAlertBox varchar(255) null
GO

-- 4) Garante as pastas mestre Emails(11)/Documents(7) por Root -------------
--    Cria a pasta mestre do tipo para todo Root que ainda nao tiver. Idempotente.
insert into AttachmentFolder
    (UniqueId, RootId, AttachmentTypeId, Name, Description, IsMaster, IsAdditionalFolder, IsDeleted,
     CreateDate, UpdatedDate, DeletedDate, CreateByPersonId, UpdatedByPersonId, DeletedByPersonId,
     IsBasicDocument, IsPreliminarDocument, IsFinalDocument)
select NEWID(), r.Id, t.TypeId, t.Nome,
       'Pasta mestre criada para a indexacao automatica (LTDEV-2)',
       1,0,0, GETUTCDATE(), GETUTCDATE(), null, 1,1, null, 0,0,0
from RootX r
cross join (values (11,'Emails'),(7,'Documentos')) as t(TypeId, Nome)
where not exists (select 1 from AttachmentFolder af
                   where af.RootId=r.Id and af.IsMaster=1 and af.AttachmentTypeId=t.TypeId)
GO

-- 5) POPULA a parametrizacao ----------------------------------------------
-- Brasil (valores da doc):
update pr set
    pr.EmailIndexingMailbox   = 'central.recebimento@crawfordbrasil.com.br',
    pr.EmailIndexingManualBox = 'rejeitados@crawfordbrasil.com.br',
    pr.EmailIndexingStore     = 1,
    pr.EmailIndexingStoreDays = 3,
    pr.EmailIndexingLocalDomains = 'crawfordbrasil.com.br',
    pr.EmailIndexingAlertBox  = 'sistemas@crawfordbrasil.com.br'
from ParameterRoot pr
inner join RootX r on r.Id = pr.RootId
where r.UniqueId = '63F09D57-0D63-472F-B63D-144D5BBCB3BB';  -- Brasil
GO

-- TEMPLATE para os demais paises (a Carol preenche caixa/grupo de cada um e descomenta):
-- update pr set
--     pr.EmailIndexingMailbox   = '<caixa do pais>',
--     pr.EmailIndexingManualBox = '<grupo de tratamento manual do pais>',
--     pr.EmailIndexingStore     = 1,
--     pr.EmailIndexingStoreDays = 3,
--     pr.EmailIndexingLocalDomains = '<dominio interno do pais>',  -- varios: 'a.com;b.com'
--     pr.EmailIndexingAlertBox  = '<quem recebe o aviso de erro critico>'
-- from ParameterRoot pr inner join RootX r on r.Id = pr.RootId
-- where r.UniqueId = '<RootUniqueId do pais>';
-- GO
