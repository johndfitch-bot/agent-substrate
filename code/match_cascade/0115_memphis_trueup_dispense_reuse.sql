-- =============================================================================
-- SUBSTRATE COPY  (scrubbed by CC for public substrate, 2026-05-12)
-- =============================================================================
-- Source        : utopia/migrations/0115_memphis_trueup_dispense_reuse.sql
-- Source repo   : johndfitch-bot/utopia (PRIVATE - McKesson IP boundary)
-- Redactions    : NONE - file body is verbatim. No client IDs/names, no seed
--                 inserts, no internal hostnames or IPs were present.
-- Note          : SUPERSEDES the 0106 version of refresh_dispense_cache.
--                 CREATE OR ALTER PROCEDURE at line ~72 is the production
--                 version live on .158 (REUSE path + memphis_dispense_pull_log
--                 table at line ~48). The big-run step log for run 19 showed
--                 "REUSED run 12 (1199 min old)" which is THIS SP's reuse
--                 branch firing. Worth checking: when reuse fires, does it
--                 copy the cache rows to the new etl_run_id, or just alias
--                 the older run? The diag's safety probe showed 304,963
--                 cache rows tagged with run_id=19, so apparently rows ARE
--                 re-tagged. But that means the @start/@end window of the
--                 ORIGINAL run (run 12) is what's actually represented in
--                 cache, not run 19's window. If run 12 had a tighter window
--                 than what run 19 needs, that's a second-order miss.
-- =============================================================================

-- 0115_memphis_trueup_dispense_reuse.sql
-- =============================================================================
-- Memphis True-Up: reuse the ScriptMaster pull across runs over the same
-- ship window. Cuts testing-iteration time from ~6 min to ~10 sec when
-- iterating on cascade logic against the same April-2026 sample data.
--
-- Strategy: a per-pull log lets us look up "have we already pulled this
-- window recently?" If yes (within @max_reuse_age_minutes, default 24h),
-- copy the rows internally (sub-second) instead of round-tripping the
-- linked server (5+ minutes for 285K rows).
--
-- The cache rows themselves stay keyed by etl_run_id so downstream cascade
-- SPs don't need to change -- the copy just stamps the new run_id on a
-- fresh set. Storage cost: ~50 MB per cached run. Worth it for the speed.
--
-- Force a fresh pull anytime with @max_reuse_age_minutes = 0.
--
-- Also wires the orchestrator (sp_memphis_trueup_run) to accept and pass
-- through the max-age parameter so CLI / big-run can control it.
--
-- Idempotent (CREATE OR ALTER + IF NOT EXISTS).
-- =============================================================================

IF DB_ID('UTOPIA') IS NULL
BEGIN
    PRINT 'WRONG SERVER: ' + @@SERVERNAME;
    SET NOEXEC ON;
END
GO

USE [UTOPIA];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO


-- =============================================================================
-- 1. memphis_dispense_pull_log -- one row per linked-server pull
-- =============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name = 'carrier_trueup' AND t.name = 'memphis_dispense_pull_log'
)
BEGIN
    CREATE TABLE carrier_trueup.memphis_dispense_pull_log (
        pull_id               INT IDENTITY(1,1) PRIMARY KEY,
        window_start          DATE NOT NULL,
        window_end            DATE NOT NULL,
        source_etl_run_id     INT NOT NULL REFERENCES carrier_trueup.etl_run_log(etl_run_id),
        pulled_at             DATETIME NOT NULL DEFAULT GETDATE(),
        row_count             INT NULL,
        unique_tracking_count INT NULL,
        pull_seconds          INT NULL,
        notes                 VARCHAR(500) NULL
    );
    CREATE INDEX IX_dispense_pull_log_window
        ON carrier_trueup.memphis_dispense_pull_log(window_start, window_end, pulled_at DESC);
    PRINT '  memphis_dispense_pull_log created';
END
ELSE
    PRINT '  memphis_dispense_pull_log already exists';
GO


-- =============================================================================
-- 2. sp_memphis_trueup_refresh_dispense_cache -- now with REUSE PATH
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_refresh_dispense_cache
    @etl_run_id            INT,
    @start_date            DATE,
    @end_date              DATE,
    @site_code             VARCHAR(10) = 'MEM',
    @max_reuse_age_minutes INT = 1440      -- 24h default; 0 = always pull fresh
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'refresh_dispense_cache', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        -- Wipe rows for THIS run id (re-run safety inside the same run id)
        DELETE FROM carrier_trueup.memphis_unique_tracking_client_map
            WHERE etl_run_id = @etl_run_id;
        DELETE FROM carrier_trueup.memphis_dispense_cache
            WHERE etl_run_id = @etl_run_id;

        -- ----- Look for a reusable prior pull -----
        DECLARE @source_run_id      INT;
        DECLARE @prior_pull_age_min INT;
        DECLARE @prior_row_count    INT;

        IF @max_reuse_age_minutes > 0
        BEGIN
            SELECT TOP 1
                @source_run_id      = pl.source_etl_run_id,
                @prior_pull_age_min = DATEDIFF(MINUTE, pl.pulled_at, GETDATE()),
                @prior_row_count    = pl.row_count
            FROM carrier_trueup.memphis_dispense_pull_log pl
            WHERE pl.window_start = @start_date
              AND pl.window_end   = @end_date
              AND pl.row_count    > 0
              AND DATEDIFF(MINUTE, pl.pulled_at, GETDATE()) <= @max_reuse_age_minutes
              AND EXISTS (
                  SELECT 1 FROM carrier_trueup.memphis_dispense_cache c
                  WHERE c.etl_run_id = pl.source_etl_run_id
              )
            ORDER BY pl.pulled_at DESC;
        END;

        DECLARE @cache_rows INT = 0;
        DECLARE @map_rows   INT = 0;

        IF @source_run_id IS NOT NULL
        BEGIN
            -- ===== REUSE PATH =====
            INSERT INTO carrier_trueup.memphis_dispense_cache
                (etl_run_id, scriptmaster_id_key, client_id, client_name,
                 production_date, order_number, rx_number, host_order,
                 store_code, pharmacy_store_name, pharmacy_state,
                 ship_method, shipping_carrier, tracking_number)
            SELECT
                @etl_run_id, scriptmaster_id_key, client_id, client_name,
                production_date, order_number, rx_number, host_order,
                store_code, pharmacy_store_name, pharmacy_state,
                ship_method, shipping_carrier, tracking_number
            FROM carrier_trueup.memphis_dispense_cache
            WHERE etl_run_id = @source_run_id;
            SET @cache_rows = @@ROWCOUNT;

            INSERT INTO carrier_trueup.memphis_unique_tracking_client_map
                (etl_run_id, tracking_number, client_id)
            SELECT @etl_run_id, tracking_number, client_id
            FROM carrier_trueup.memphis_unique_tracking_client_map
            WHERE etl_run_id = @source_run_id;
            SET @map_rows = @@ROWCOUNT;

            UPDATE carrier_trueup.etl_step_log
            SET status        = 'COMPLETE',
                completed_at  = GETDATE(),
                rows_affected = @cache_rows,
                notes         = CONCAT('REUSED run ', @source_run_id,
                                       ' (', @prior_pull_age_min, ' min old); ',
                                       @cache_rows, ' rows; ',
                                       @map_rows,  ' unique trackings.')
            WHERE step_id = @step_id;
        END
        ELSE
        BEGIN
            -- ===== FRESH PULL PATH =====
            DECLARE @scriptmaster_path NVARCHAR(500);
            SELECT @scriptmaster_path = script_master_path
            FROM carrier_trueup.site_etl_config
            WHERE site_code = @site_code AND is_active = 1;

            IF @scriptmaster_path IS NULL
            BEGIN
                RAISERROR('No active site_etl_config row for site_code = %s', 16, 1, @site_code);
                RETURN;
            END;

            DECLARE @pull_start DATETIME = GETDATE();

            DECLARE @sql NVARCHAR(MAX) = N'
INSERT INTO carrier_trueup.memphis_dispense_cache (
    etl_run_id, scriptmaster_id_key, client_id, client_name,
    production_date, order_number, rx_number, host_order,
    store_code, pharmacy_store_name, pharmacy_state,
    ship_method, shipping_carrier, tracking_number
)
SELECT
    @run_id,
    LTRIM(RTRIM(CAST(id_key             AS NVARCHAR(100)))),
    TRY_CAST(LTRIM(RTRIM(CAST(client_id AS NVARCHAR(50)))) AS INT),
    LTRIM(RTRIM(CAST(client_name        AS NVARCHAR(100)))),
    TRY_CAST(LTRIM(RTRIM(CAST(production_date AS NVARCHAR(50)))) AS DATE),
    LTRIM(RTRIM(CAST(order_number       AS NVARCHAR(50)))),
    LTRIM(RTRIM(CAST(rx_number          AS NVARCHAR(50)))),
    LTRIM(RTRIM(CAST(host_order         AS NVARCHAR(50)))),
    LTRIM(RTRIM(CAST(store_code         AS NVARCHAR(50)))),
    LTRIM(RTRIM(CAST(pharmacy_store_name AS NVARCHAR(255)))),
    LTRIM(RTRIM(CAST(pharmacy_state     AS NVARCHAR(20)))),
    LTRIM(RTRIM(CAST(ship_method        AS NVARCHAR(100)))),
    LTRIM(RTRIM(CAST(shipping_carrier   AS NVARCHAR(50)))),
    LTRIM(RTRIM(CAST(tracking_number    AS NVARCHAR(100))))
FROM ' + @scriptmaster_path + N'
WHERE production_date >= @start AND production_date <= @end;';

            EXEC sp_executesql @sql,
                N'@run_id INT, @start DATE, @end DATE',
                @run_id = @etl_run_id, @start = @start_date, @end = @end_date;
            SET @cache_rows = @@ROWCOUNT;

            INSERT INTO carrier_trueup.memphis_unique_tracking_client_map
                (etl_run_id, tracking_number, client_id)
            SELECT @etl_run_id, tracking_number, MAX(client_id)
            FROM carrier_trueup.memphis_dispense_cache
            WHERE etl_run_id = @etl_run_id
              AND tracking_number IS NOT NULL
              AND tracking_number <> ''
              AND client_id IS NOT NULL
            GROUP BY tracking_number
            HAVING COUNT(DISTINCT client_id) = 1;
            SET @map_rows = @@ROWCOUNT;

            DECLARE @pull_seconds INT = DATEDIFF(SECOND, @pull_start, GETDATE());

            INSERT INTO carrier_trueup.memphis_dispense_pull_log
                (window_start, window_end, source_etl_run_id,
                 row_count, unique_tracking_count, pull_seconds, notes)
            VALUES
                (@start_date, @end_date, @etl_run_id,
                 @cache_rows, @map_rows, @pull_seconds,
                 CONCAT('Fresh pull from ', @scriptmaster_path));

            UPDATE carrier_trueup.etl_step_log
            SET status        = 'COMPLETE',
                completed_at  = GETDATE(),
                rows_affected = @cache_rows,
                notes         = CONCAT('FRESH PULL (', @pull_seconds, 's): ',
                                       @cache_rows, ' rows; ',
                                       @map_rows,  ' unique trackings.')
            WHERE step_id = @step_id;
        END;
    END TRY
    BEGIN CATCH
        UPDATE carrier_trueup.etl_step_log
        SET status       = 'FAILED',
            completed_at = GETDATE(),
            notes        = LEFT(ERROR_MESSAGE(), 500)
        WHERE step_id = @step_id;
        THROW;
    END CATCH;
END;
GO


-- =============================================================================
-- 3. sp_memphis_trueup_run -- pass-through param so CLI can control reuse age
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_run
    @ship_month_start      DATE,
    @ship_month_end        DATE,
    @run_by                VARCHAR(100) = NULL,
    @site_code             VARCHAR(10)  = 'MEM',
    @max_reuse_age_minutes INT          = 1440,        -- 0 = always pull fresh
    @etl_run_id            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO carrier_trueup.etl_run_log
        (site_code, carrier, dt_start, dt_end, run_by, status, notes)
    VALUES
        (@site_code, 'MULTI',
         @ship_month_start, @ship_month_end, @run_by,
         'RUNNING',
         CONCAT('Memphis True-Up run for ship window ',
                CONVERT(VARCHAR(10), @ship_month_start, 23),
                ' to ',
                CONVERT(VARCHAR(10), @ship_month_end, 23),
                ' (reuse_age_min=', @max_reuse_age_minutes, ')'));
    SET @etl_run_id = SCOPE_IDENTITY();

    BEGIN TRY
        -- Dispense pull window is ship_month + 6-day overflow
        DECLARE @dispense_end DATE = DATEADD(DAY, 6, @ship_month_end);

        EXEC carrier_trueup.sp_memphis_trueup_refresh_dispense_cache
            @etl_run_id            = @etl_run_id,
            @start_date            = @ship_month_start,
            @end_date              = @dispense_end,
            @site_code             = @site_code,
            @max_reuse_age_minutes = @max_reuse_age_minutes;

        EXEC carrier_trueup.sp_memphis_trueup_purge_audit_detail        @etl_run_id;
        EXEC carrier_trueup.sp_memphis_trueup_normalize_easypost        @etl_run_id, @site_code;
        EXEC carrier_trueup.sp_memphis_trueup_normalize_fedex           @etl_run_id, @site_code;
        EXEC carrier_trueup.sp_memphis_trueup_normalize_ups             @etl_run_id, @site_code;
        EXEC carrier_trueup.sp_memphis_trueup_populate_audit_detail     @etl_run_id, @site_code;
        EXEC carrier_trueup.sp_memphis_trueup_match_01_direct           @etl_run_id;
        EXEC carrier_trueup.sp_memphis_trueup_match_02_ep_pretransit    @etl_run_id;
        EXEC carrier_trueup.sp_memphis_trueup_match_03_ep_returns       @etl_run_id;
        EXEC carrier_trueup.sp_memphis_trueup_match_04_cs_override      @etl_run_id;
        EXEC carrier_trueup.sp_memphis_trueup_match_05_ups_returns      @etl_run_id;
        IF OBJECT_ID('carrier_trueup.sp_memphis_trueup_match_06_fedex_refs', 'P') IS NOT NULL
            EXEC carrier_trueup.sp_memphis_trueup_match_06_fedex_refs   @etl_run_id;

        DECLARE @total INT, @closed INT, @open INT;
        SELECT
            @total  = COUNT(*),
            @closed = SUM(CASE WHEN is_closed = 1 THEN 1 ELSE 0 END),
            @open   = SUM(CASE WHEN is_closed = 0 THEN 1 ELSE 0 END)
        FROM carrier_trueup.audit_detail
        WHERE etl_run_id = @etl_run_id;

        UPDATE carrier_trueup.etl_run_log
        SET status          = 'COMPLETE',
            completed_at    = GETDATE(),
            rows_loaded     = @total,
            rows_classified = @closed,
            rows_unclass    = @open,
            notes           = CONCAT(notes, ' | total=', @total,
                                     ' closed=', @closed,
                                     ' open=',   @open)
        WHERE etl_run_id = @etl_run_id;
    END TRY
    BEGIN CATCH
        DECLARE @errMsg  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @errNum  INT            = ERROR_NUMBER();
        DECLARE @errLine INT            = ERROR_LINE();

        IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
        ELSE IF XACT_STATE() = 1 COMMIT TRANSACTION;

        UPDATE carrier_trueup.etl_run_log
        SET status        = 'FAILED',
            completed_at  = GETDATE(),
            error_message = CONCAT('[', @errNum, ' line ', @errLine, '] ', @errMsg)
        WHERE etl_run_id = @etl_run_id;

        DECLARE @reraise NVARCHAR(4000) = CONCAT(
            'sp_memphis_trueup_run failed: [SQL ', @errNum, ' line ', @errLine, '] ', @errMsg);
        THROW 50000, @reraise, 1;
    END CATCH;
END;
GO


PRINT '=== 0115_memphis_trueup_dispense_reuse: complete ===';
PRINT '  Tables added:';
PRINT '    + memphis_dispense_pull_log';
PRINT '  Procedures altered:';
PRINT '    ~ sp_memphis_trueup_refresh_dispense_cache (+ reuse path)';
PRINT '    ~ sp_memphis_trueup_run                    (+ @max_reuse_age_minutes)';
PRINT '  Default behavior: REUSE if a same-window pull is < 24h old.';
PRINT '  Pass @max_reuse_age_minutes = 0 for a forced fresh pull.';
GO
