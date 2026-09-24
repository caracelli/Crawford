/* ============================================================================
   LTDEV - Gerador de SEED consistente (LTDEV-2 + LTDEV-72)   [v1 - dry-run]
   ----------------------------------------------------------------------------
   Gera INSERTs de um subconjunto pequeno e COERENTE da CarolOneCrawfordDB:
     - 5 sinistros ancora (ClaimCode 'BR' + 8 digitos, com cronologia) e a sua
       cadeia (filtrada por ClaimId);
     - tabelas de grupo/permissao do PORTAL (LTDEV-72) inteiras;
     - tabelas de dominio pequenas (<= 5 MB) inteiras.
   Pula as gigantes/irrelevantes (MailMessage*, Attachment, Import*, *History...).

   COMO RODAR:
   A) SSMS: cole tudo, F5. Em Query > Query Options > Results > Grid, DESMARQUE
      "Include column headers". Depois: botao direito na grade > Save Results As
      > seed.sql.
   B) sqlcmd (VPN ligada):
      sqlcmd -S tcp:10.122.0.11 -d CarolOneCrawfordDB -E -N -C -i LTDEV_gerar_seed.sql -o seed.sql -h -1 -W -y 0

   IMPORTANTE: e um DRY-RUN. Revise o seed.sql antes de usar. Se alguma coluna
   de tipo incomum sair torta, me mande a linha que eu ajusto o gerador.

   Tecnica: CHAR(39)=aspa simples, CHAR(44)=virgula, CHAR(78)='N'. Evita
   empilhamento de aspas no SQL-que-gera-SQL.
   ============================================================================ */
-- Obrigatorio: os metodos de XML (FOR XML ... .value()) usados aqui exigem
-- QUOTED_IDENTIFIER ON. Sem isso, da Msg 1934. O sqlcmd costuma vir com OFF.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;

DECLARE @Amostra INT = 5;        -- sinistros ancora
DECLARE @LinhasFull INT = 2000;  -- tabela de dominio: so vem inteira se tiver <= isto

/* 1) sinistros ancora. Guarda Id E UniqueId, porque as tabelas filhas ligam
   ao sinistro ora por ClaimId, ora por ClaimUniqueId. */
IF OBJECT_ID('tempdb..#claims') IS NOT NULL DROP TABLE #claims;
SELECT TOP (@Amostra) c.Id, c.UniqueId
INTO #claims
FROM dbo.Claim c
WHERE c.ClaimCode LIKE 'BR[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
ORDER BY c.Id DESC;

/* 2) plano de tabelas: 'claim' = filtra por ClaimId; 'full' = todas as linhas */
IF OBJECT_ID('tempdb..#plan') IS NOT NULL DROP TABLE #plan;
CREATE TABLE #plan (Ordem INT IDENTITY, Schema_ SYSNAME, Tabela SYSNAME, Modo VARCHAR(10));
INSERT #plan (Schema_, Tabela, Modo) VALUES
 ('dbo','Claim','claim'),
 ('dbo','ClaimChronology','claim'),
 ('dbo','ClaimValue','claim'),
 ('dbo','ClaimItem','claim'),
 ('dbo','ClaimAddress','claim'),
 ('dbo','ClaimObservation','claim'),
 ('dbo','ClaimRequestDocument','claim'),
 ('dbo','GroupUser','full'),
 ('dbo','GroupUserAccess','full'),
 ('dbo','GroupUserPermission','full'),
 ('dbo','GroupUserPageAccess','full'),
 ('dbo','GroupUserExternalBroker','full'),
 ('dbo','GroupUserExternalInsurance','full'),
 ('dbo','GroupUserExternalCoverage','full'),
 ('dbo','GroupUserExternalOperation','full'),
 ('dbo','GroupUserExternalSubOperation','full'),
 ('dbo','GroupUserExternalDefaultProperty','full'),
 ('dbo','ExternalLevelAccess','full');

/* 3) acrescenta as tabelas de dominio ainda nao listadas: criterio por LINHAS,
   nao por MB. O que infla o arquivo e a quantidade de linhas (cada linha vira
   um INSERT verboso), nao o tamanho em disco. Tabela com muitas linhas e
   transacional/log, nao dominio - fica de fora. */
INSERT #plan (Schema_, Tabela, Modo)
SELECT s.name, t.name, 'full'
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN (SELECT object_id, SUM(row_count) AS Linhas
      FROM sys.dm_db_partition_stats WHERE index_id IN (0,1) GROUP BY object_id) sz
     ON sz.object_id = t.object_id
WHERE sz.Linhas <= @LinhasFull
  AND NOT EXISTS (SELECT 1 FROM #plan p WHERE p.Schema_ = s.name AND p.Tabela = t.name)
  AND t.name NOT LIKE 'MailMessage%'
  AND t.name NOT LIKE '%History'
  AND t.name NOT LIKE '%Audit%';

/* 4) geracao */
IF OBJECT_ID('tempdb..#out') IS NOT NULL DROP TABLE #out;
CREATE TABLE #out (Seq INT IDENTITY, Linha NVARCHAR(MAX));
INSERT #out (Linha) VALUES ('-- LTDEV seed ' + CONVERT(VARCHAR(19), GETDATE(), 120));
INSERT #out (Linha) VALUES ('SET NOCOUNT ON;');
INSERT #out (Linha) VALUES ('EXEC sp_MSforeachtable ''ALTER TABLE ? NOCHECK CONSTRAINT ALL'';');

DECLARE @sch SYSNAME, @tab SYSNAME, @modo VARCHAR(10), @full NVARCHAR(300);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Schema_, Tabela, Modo FROM #plan ORDER BY Ordem;
OPEN cur;
FETCH NEXT FROM cur INTO @sch, @tab, @modo;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @full = QUOTENAME(@sch) + '.' + QUOTENAME(@tab);
    IF OBJECT_ID(@full,'U') IS NOT NULL
    BEGIN
        /* colunas inseriveis (pula computadas e timestamp/rowversion) */
        DECLARE @cols NVARCHAR(MAX) =
            STUFF((SELECT ',' + QUOTENAME(c.name)
                   FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
                   WHERE c.object_id = OBJECT_ID(@full) AND c.is_computed = 0 AND ty.name <> 'timestamp'
                   ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'),1,1,'');

        /* expressao dos VALUES: por coluna, com NULL tratado via COALESCE.
           CHAR(39)=aspa, CHAR(44)=virgula separadora, CHAR(78)='N'. */
        DECLARE @vals NVARCHAR(MAX) =
            STUFF((SELECT '+CHAR(44)+' +
                   CASE
                     WHEN ty.name = 'bit'
                       THEN 'COALESCE(CONVERT(NVARCHAR(1),CONVERT(TINYINT,'+QUOTENAME(c.name)+')),''NULL'')'
                     WHEN ty.name IN ('tinyint','smallint','int','bigint','decimal','numeric','money','smallmoney','float','real')
                       THEN 'COALESCE(CONVERT(NVARCHAR(50),'+QUOTENAME(c.name)+'),''NULL'')'
                     WHEN ty.name = 'uniqueidentifier'
                       THEN 'COALESCE(CHAR(39)+CONVERT(NVARCHAR(50),'+QUOTENAME(c.name)+')+CHAR(39),''NULL'')'
                     WHEN ty.name IN ('binary','varbinary','image')
                       THEN 'COALESCE(''0x''+CONVERT(VARCHAR(MAX),'+QUOTENAME(c.name)+',2),''NULL'')'
                     WHEN ty.name IN ('date','time','datetime','datetime2','smalldatetime','datetimeoffset')
                       THEN 'COALESCE(CHAR(39)+CONVERT(NVARCHAR(50),'+QUOTENAME(c.name)+',127)+CHAR(39),''NULL'')'
                     ELSE  /* textos */
                       'COALESCE(CHAR(78)+CHAR(39)+REPLACE(CONVERT(NVARCHAR(MAX),'+QUOTENAME(c.name)+'),CHAR(39),CHAR(39)+CHAR(39))+CHAR(39),''NULL'')'
                   END
                   FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
                   WHERE c.object_id = OBJECT_ID(@full) AND c.is_computed = 0 AND ty.name <> 'timestamp'
                   ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'),1,10,'');

        DECLARE @temId BIT = CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id=OBJECT_ID(@full)) THEN 1 ELSE 0 END;

        DECLARE @where NVARCHAR(400) = '';
        IF @modo = 'claim'
        BEGIN
            IF @tab = 'Claim'
                SET @where = ' WHERE [Id] IN (SELECT Id FROM #claims)';
            ELSE IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(@full) AND name='ClaimId')
                SET @where = ' WHERE [ClaimId] IN (SELECT Id FROM #claims)';
            ELSE IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(@full) AND name='ClaimUniqueId')
                SET @where = ' WHERE [ClaimUniqueId] IN (SELECT UniqueId FROM #claims)';
            ELSE
            BEGIN
                /* usa a FK declarada para dbo.Claim, se houver */
                DECLARE @fkcol SYSNAME = (
                    SELECT TOP 1 pc.name
                    FROM sys.foreign_keys fk
                    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
                    JOIN sys.columns pc ON pc.object_id = fk.parent_object_id AND pc.column_id = fkc.parent_column_id
                    WHERE fk.parent_object_id = OBJECT_ID(@full)
                      AND fk.referenced_object_id = OBJECT_ID('dbo.Claim'));
                IF @fkcol IS NOT NULL
                    SET @where = ' WHERE ' + QUOTENAME(@fkcol) + ' IN (SELECT Id FROM #claims)';
                ELSE
                    SET @where = ' WHERE 1=0';  /* sem ligacao conhecida com Claim: nao traz dados */
            END
        END

        INSERT #out (Linha) VALUES ('-- ' + @full + ' (' + @modo + ')');
        IF @temId = 1 INSERT #out (Linha) VALUES ('SET IDENTITY_INSERT ' + @full + ' ON;');

        DECLARE @sql NVARCHAR(MAX) =
            'INSERT #out (Linha) SELECT ''INSERT INTO ' + @full + ' (' + @cols + ') VALUES (''+' + @vals + '+'');'' FROM ' + @full + @where + ';';
        EXEC sp_executesql @sql;

        IF @temId = 1 INSERT #out (Linha) VALUES ('SET IDENTITY_INSERT ' + @full + ' OFF;');
        INSERT #out (Linha) VALUES ('GO');
    END
    FETCH NEXT FROM cur INTO @sch, @tab, @modo;
END
CLOSE cur; DEALLOCATE cur;

INSERT #out (Linha) VALUES ('EXEC sp_MSforeachtable ''ALTER TABLE ? WITH CHECK CHECK CONSTRAINT ALL'';');
INSERT #out (Linha) VALUES ('GO');

/* 5) resultado: salve como seed.sql */
SELECT Linha FROM #out ORDER BY Seq;
