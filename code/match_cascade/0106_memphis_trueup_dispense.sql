-- =============================================================================
-- SUBSTRATE COPY  (scrubbed by CC for public substrate, 2026-05-12)
-- =============================================================================
-- Source        : utopia/migrations/0106_memphis_trueup_dispense.sql
-- Source repo   : johndfitch-bot/utopia (PRIVATE - McKesson IP boundary)
-- Redactions    : NONE - file body is verbatim. No client IDs/names, no seed
--                 inserts, no internal hostnames or IPs were present.
-- Captain ask   : root-cause why CF_OPS.cf_memphis.SCRIPTMASTER rows are
--                 absent from memphis_dispense_cache despite the diagnostic
--                 confirming 100/100 unmatched UPS trackings have zero
--                 dispense hits for run 19.
--                 KEY SECTION: sp_memphis_trueup_refresh_dispense_cache
--                 (line ~120). Note the date filter
--                 "WHERE production_date >= @start AND production_date <= @end"
--                 with no overflow window. Run 19's @start/@end = Mar 1 - Mar 31;
--                 UPS bills arriving in April for returns of Jan/Feb dispenses
--                 would never land. Also see 0115 for the reuse-path override.
-- =============================================================================

-- 0106_memphis_trueup_dispense.sql
-- =============================================================================
-- Memphis True-Up: dispense source-of-truth integration.
--
-- The Access pipeline caches dispense data locally before matching. In SQL
-- Server we keep the same pattern (a per-run cache table) for two reasons:
--   1) Performance -- the match cascade joins repeatedly; caching avoids
--      re-querying the linked server N times.
--   2) Reproducibility -- if we need to re-run the cascade against the
--      same dispense window (debugging, late carrier credit), the cache is
--      stable.
--
-- Source: [10.70.46.4].CF_OPS.CF_Memphis.ScriptMaster (per site_etl_config)
-- Filter: production_date BETWEEN @start_date AND @end_date
-- Window convention: ship_month_first through (ship_month_last + 6 days)
--                    to catch the early-of-next-month invoice arrivals.
--
-- Idempotent.
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
-- 1. memphis_dispense_cache -- per-run snapshot of ScriptMaster
-- =============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name = 'carrier_trueup' AND t.name = 'memphis_dispense_cache'
)
BEGIN
    CREATE TABLE carrier_trueup.memphis_dispense_cache (
        cache_id            INT IDENTITY(1,1) PRIMARY KEY,
        etl_run_id          INT NOT NULL REFERENCES carrier_trueup.etl_run_log(etl_run_id),
        scriptmaster_id_key VARCHAR(100) NULL,
        client_id           INT NULL,
        client_name         VARCHAR(100) NULL,
        production_date     DATE NULL,
        order_number        VARCHAR(50) NULL,
        rx_number           VARCHAR(50) NULL,
        host_order          VARCHAR(50) NULL,
        store_code          VARCHAR(50) NULL,
        pharmacy_store_name VARCHAR(255) NULL,
        pharmacy_state      VARCHAR(20) NULL,
        ship_method         VARCHAR(100) NULL,
        shipping_carrier    VARCHAR(50) NULL,
        tracking_number     VARCHAR(100) NULL,
        loaded_at           DATETIME NOT NULL DEFAULT GETDATE()
    );
    CREATE INDEX IX_dispense_cache_tracking
        ON carrier_trueup.memphis_dispense_cache(tracking_number);
    CREATE INDEX IX_dispense_cache_order
        ON carrier_trueup.memphis_dispense_cache(order_number);
    CREATE INDEX IX_dispense_cache_run
        ON carrier_trueup.memphis_dispense_cache(etl_run_id);
    PRINT '  carrier_trueup.memphis_dispense_cache created';
END
ELSE
    PRINT '  carrier_trueup.memphis_dispense_cache already exists';
GO


-- =============================================================================
-- 2. memphis_unique_tracking_client_map -- pre-computed unambiguous pairings
-- =============================================================================
-- The Access cascade uses cf_client_shipment_pairing + dupe_validation to
-- build a temp table of (tracking, client) pairs where each tracking appears
-- under EXACTLY ONE client (ambiguous pairs are excluded from auto-match).
-- We materialize the same as a per-run table.
-- =============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name = 'carrier_trueup' AND t.name = 'memphis_unique_tracking_client_map'
)
BEGIN
    CREATE TABLE carrier_trueup.memphis_unique_tracking_client_map (
        map_id          INT IDENTITY(1,1) PRIMARY KEY,
        etl_run_id      INT NOT NULL REFERENCES carrier_trueup.etl_run_log(etl_run_id),
        tracking_number VARCHAR(100) NOT NULL,
        client_id       INT NOT NULL REFERENCES carrier_trueup.client(client_id),
        created_at      DATETIME NOT NULL DEFAULT GETDATE()
    );
    CREATE UNIQUE INDEX UX_unique_tracking_map_run_tracking
        ON carrier_trueup.memphis_unique_tracking_client_map(etl_run_id, tracking_number);
    PRINT '  carrier_trueup.memphis_unique_tracking_client_map created';
END
ELSE
    PRINT '  carrier_trueup.memphis_unique_tracking_client_map already exists';
GO


-- =============================================================================
-- 3. sp_memphis_trueup_refresh_dispense_cache
-- =============================================================================
-- Loads ScriptMaster rows in the given window into memphis_dispense_cache for
-- the current etl_run_id, then builds the unique-pairing map.
--
-- The three-part-name uses the path from carrier_trueup.site_etl_config so a
-- future site reorg (e.g. .68 linked server moving) only requires updating
-- one config row.
--
-- Per the Access source, the dispense pull uses Trim() on every column. We
-- replicate that with LTRIM(RTRIM()) which collapses leading/trailing spaces.
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_refresh_dispense_cache
    @etl_run_id INT,
    @start_date DATE,
    @end_date   DATE,
    @site_code  VARCHAR(10) = 'MEM'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @scriptmaster_path NVARCHAR(500);
    SELECT @scriptmaster_path = script_master_path
    FROM carrier_trueup.site_etl_config
    WHERE site_code = @site_code AND is_active = 1;

    IF @scriptmaster_path IS NULL
    BEGIN
        RAISERROR('No active site_etl_config row for site_code = %s', 16, 1, @site_code);
        RETURN;
    END;

    -- step log row -- start
    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'refresh_dispense_cache', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        -- Wipe any rows for this run id (re-run safety)
        DELETE FROM carrier_trueup.memphis_unique_tracking_client_map
            WHERE etl_run_id = @etl_run_id;
        DELETE FROM carrier_trueup.memphis_dispense_cache
            WHERE etl_run_id = @etl_run_id;

        -- Build the dynamic SQL with the three-part-name from config.
        -- Date params bound via sp_executesql to prevent injection.
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

        DECLARE @cache_rows INT = @@ROWCOUNT;

        -- Build unique-pairing map: trackings that appear under exactly one client.
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

        DECLARE @map_rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE',
            completed_at = GETDATE(),
            rows_affected = @cache_rows,
            notes = CONCAT('dispense rows: ', @cache_rows, '; unique trackings: ', @map_rows)
        WHERE step_id = @step_id;
    END TRY
    BEGIN CATCH
        UPDATE carrier_trueup.etl_step_log
        SET status = 'FAILED',
            completed_at = GETDATE(),
            notes = LEFT(ERROR_MESSAGE(), 500)
        WHERE step_id = @step_id;
        THROW;
    END CATCH;
END;
GO


PRINT '=== 0106_memphis_trueup_dispense: complete ===';
PRINT '  Tables added:';
PRINT '    + memphis_dispense_cache';
PRINT '    + memphis_unique_tracking_client_map';
PRINT '  Procedures added:';
PRINT '    + sp_memphis_trueup_refresh_dispense_cache';
GO
