-- =============================================================================
-- SUBSTRATE COPY  (scrubbed by CC for public substrate, 2026-05-12)
-- =============================================================================
-- Source        : utopia/migrations/0107_memphis_trueup_normalize.sql
-- Source repo   : johndfitch-bot/utopia (PRIVATE - McKesson IP boundary)
-- Redactions    : NONE - file body is verbatim. No client IDs/names, no seed
--                 inserts, no internal hostnames or IPs were present.
-- Captain ask   : analyze sp_memphis_trueup_normalize_ups (line ~191) -- the
--                 multi-row UPS shipment collapse logic feeds the cascade.
-- =============================================================================

-- 0107_memphis_trueup_normalize.sql
-- =============================================================================
-- Memphis True-Up: normalize the three carrier landings into normalized_invoice.
--
-- Ports the three Access procs verbatim:
--   etl_append_normalized_easypost   ->  sp_memphis_trueup_normalize_easypost
--   etl_append_normalized_fedex      ->  sp_memphis_trueup_normalize_fedex
--   etl_append_normalized_ups        ->  sp_memphis_trueup_normalize_ups
--   etl_populate_stg_wip_audit_detail-> sp_memphis_trueup_populate_audit_detail
--   etl_purge_stg_wip_audit_detail   ->  sp_memphis_trueup_purge_audit_detail
--
-- All write to carrier_trueup.normalized_invoice and audit_detail keyed by
-- @etl_run_id so a partial re-run only wipes the rows it owns.
--
-- UPS reuses the existing raw_invoice_data table (loaded by the
-- sp_etl_ups_* chain for site_code='MEM'). The normalize SP aggregates
-- multi-row UPS shipments to one row per (Invoice_Number, Lead_Shipment_Number).
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
-- 1. Purge audit_detail for a run id
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_purge_audit_detail
    @etl_run_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'purge_audit_detail', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    DELETE FROM carrier_trueup.audit_detail WHERE etl_run_id = @etl_run_id;
    DECLARE @rows INT = @@ROWCOUNT;

    DELETE FROM carrier_trueup.normalized_invoice WHERE etl_run_id = @etl_run_id;
    DECLARE @norm_rows INT = @@ROWCOUNT;

    UPDATE carrier_trueup.etl_step_log
    SET status = 'COMPLETE',
        completed_at = GETDATE(),
        rows_affected = @rows,
        notes = CONCAT('audit_detail wiped: ', @rows, '; normalized wiped: ', @norm_rows)
    WHERE step_id = @step_id;
END;
GO


-- =============================================================================
-- 2. Normalize EasyPost
-- =============================================================================
-- Source: easypost_invoice_landing (47 cols)
-- Filter: status <> 'cancelled' (matches Access pattern)
-- created_at format: "2026-04-23T21:34:29Z" -> take first 10 chars, cast DATE
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_normalize_easypost
    @etl_run_id INT,
    @site_code  VARCHAR(10) = 'MEM'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'normalize_easypost', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        INSERT INTO carrier_trueup.normalized_invoice
            (etl_run_id, site_code, carrier, invoice_date, invoice_number,
             carrier_shipment_id, delivery_zone, service_rate, shipment_weight)
        SELECT
            @etl_run_id,
            @site_code,
            'EasyPost',
            TRY_CAST(LEFT(created_at_src, 10) AS DATE),
            'N/A',                            -- EasyPost has no invoice number
            tracking_code,
            TRY_CAST(usps_zone   AS INT),
            TRY_CAST(rate        AS DECIMAL(18,4)),
            TRY_CAST(weight      AS DECIMAL(10,3))
        FROM carrier_trueup.easypost_invoice_landing
        WHERE site_code = @site_code
          AND (status IS NULL OR status <> 'cancelled');

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' EasyPost lines normalized')
        WHERE step_id = @step_id;
    END TRY
    BEGIN CATCH
        UPDATE carrier_trueup.etl_step_log
        SET status = 'FAILED', completed_at = GETDATE(),
            notes = LEFT(ERROR_MESSAGE(), 500)
        WHERE step_id = @step_id;
        THROW;
    END CATCH;
END;
GO


-- =============================================================================
-- 3. Normalize FedEx
-- =============================================================================
-- Source: fedex_invoice_landing
-- invoice_date arrives as "20260401" (yyyymmdd) -> TRY_CAST handles it
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_normalize_fedex
    @etl_run_id INT,
    @site_code  VARCHAR(10) = 'MEM'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'normalize_fedex', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        INSERT INTO carrier_trueup.normalized_invoice
            (etl_run_id, site_code, carrier, invoice_date, invoice_number,
             carrier_shipment_id, delivery_zone, service_rate, shipment_weight)
        SELECT
            @etl_run_id,
            @site_code,
            'FedEx',
            TRY_CAST(invoice_date AS DATE),    -- works for both "20260401" and "2026-04-01"
            invoice_number,
            express_or_ground_tracking_id,
            TRY_CAST(ISNULL(zone_code, '0') AS INT),
            TRY_CAST(net_charge_amount    AS DECIMAL(18,4)),
            TRY_CAST(ISNULL(rated_weight_amount, '0') AS DECIMAL(10,3))
        FROM carrier_trueup.fedex_invoice_landing
        WHERE site_code = @site_code;

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' FedEx lines normalized')
        WHERE step_id = @step_id;
    END TRY
    BEGIN CATCH
        UPDATE carrier_trueup.etl_step_log
        SET status = 'FAILED', completed_at = GETDATE(),
            notes = LEFT(ERROR_MESSAGE(), 500)
        WHERE step_id = @step_id;
        THROW;
    END CATCH;
END;
GO


-- =============================================================================
-- 4. Normalize UPS
-- =============================================================================
-- Source: existing carrier_trueup.raw_invoice_data filtered to site_code='MEM'
-- UPS comes in multi-row per shipment (FRT, FSC, ACC charge components).
-- Aggregate to one row per (Invoice_Number, Lead_Shipment_Number) by SUM-ing
-- the dollars and weights; zone is the same across components so MAX is safe.
--
-- The Access source aggregates without a site filter (the source DB is
-- Memphis-only); we add the site filter so a future multi-site raw_invoice_data
-- doesn't cross-contaminate.
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_normalize_ups
    @etl_run_id INT,
    @site_code  VARCHAR(10) = 'MEM'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'normalize_ups', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        INSERT INTO carrier_trueup.normalized_invoice
            (etl_run_id, site_code, carrier, invoice_date, invoice_number,
             carrier_shipment_id, delivery_zone, service_rate, shipment_weight)
        SELECT
            @etl_run_id,
            @site_code,
            'UPS',
            MIN(TRY_CAST(Invoice_Date AS DATE)),
            Invoice_Number,
            ISNULL(NULLIF(Lead_Shipment_Number, ''), 'N/A'),
            MAX(TRY_CAST(ISNULL(Zone, '0') AS INT)),
            SUM(TRY_CAST(ISNULL(Net_Amount, '0')    AS DECIMAL(18,4))),
            SUM(TRY_CAST(ISNULL(Billed_Weight, '0') AS DECIMAL(10,3)))
        FROM carrier_trueup.raw_invoice_data
        WHERE site_code = @site_code
        GROUP BY Invoice_Number, ISNULL(NULLIF(Lead_Shipment_Number, ''), 'N/A');

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' UPS shipments normalized (multi-row collapsed)')
        WHERE step_id = @step_id;
    END TRY
    BEGIN CATCH
        UPDATE carrier_trueup.etl_step_log
        SET status = 'FAILED', completed_at = GETDATE(),
            notes = LEFT(ERROR_MESSAGE(), 500)
        WHERE step_id = @step_id;
        THROW;
    END CATCH;
END;
GO


-- =============================================================================
-- 5. Populate audit_detail from normalized_invoice
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_populate_audit_detail
    @etl_run_id INT,
    @site_code  VARCHAR(10) = 'MEM'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'populate_audit_detail', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        INSERT INTO carrier_trueup.audit_detail
            (etl_run_id, site_code, carrier, invoice_date, invoice_number,
             carrier_shipment_id, delivery_zone, service_rate, shipment_weight,
             is_closed)
        SELECT
            @etl_run_id, @site_code, carrier, invoice_date, invoice_number,
            carrier_shipment_id, delivery_zone, service_rate, shipment_weight,
            0
        FROM carrier_trueup.normalized_invoice
        WHERE etl_run_id = @etl_run_id
          AND site_code  = @site_code;

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' audit_detail rows staged (is_closed=0)')
        WHERE step_id = @step_id;
    END TRY
    BEGIN CATCH
        UPDATE carrier_trueup.etl_step_log
        SET status = 'FAILED', completed_at = GETDATE(),
            notes = LEFT(ERROR_MESSAGE(), 500)
        WHERE step_id = @step_id;
        THROW;
    END CATCH;
END;
GO


PRINT '=== 0107_memphis_trueup_normalize: complete ===';
PRINT '  Procedures added:';
PRINT '    + sp_memphis_trueup_purge_audit_detail';
PRINT '    + sp_memphis_trueup_normalize_easypost';
PRINT '    + sp_memphis_trueup_normalize_fedex';
PRINT '    + sp_memphis_trueup_normalize_ups';
PRINT '    + sp_memphis_trueup_populate_audit_detail';
GO
