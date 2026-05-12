-- =============================================================================
-- SUBSTRATE COPY  (scrubbed by CC for public substrate, 2026-05-12)
-- =============================================================================
-- Source        : utopia/migrations/0114_memphis_trueup_match_06_fedex.sql
-- Source repo   : johndfitch-bot/utopia (PRIVATE - McKesson IP boundary)
-- Redactions    : NONE - file body is verbatim. No client IDs/names, no seed
--                 inserts, no internal hostnames or IPs were present.
-- Note          : superseded in production by migration 0116 (v2 prefix logic).
--                 Captain wanted both v1 and v2 for the cascade analysis.
-- =============================================================================

-- 0114_memphis_trueup_match_06_fedex.sql
-- =============================================================================
-- Memphis True-Up: 6th match strategy -- FedEx customer-reference -> CF order#.
--
-- Hypothesis (from April 2026 sample data): FedEx invoices carry the CF order
-- number in the "Original Customer Reference" / "Updated Customer Reference"
-- columns, NOT the tracking ID. Tracking IDs (380008528816, ...) are
-- carrier-internal and don't appear in cf_dispense_records.tracking_number.
-- But the customer reference (381890, 381959, ...) maps directly to
-- cf_dispense_records.order_number.
--
-- This SP mirrors the UPS-returns chain (match_05_ups_returns) but for FedEx.
-- It runs AFTER match_05 in the orchestrator (added by 0109 update).
--
-- Match flow:
--   1. Pull unmatched FedEx audit_detail lines
--   2. Get customer_ref = COALESCE(updated, original) from fedex_invoice_landing
--   3. Join customer_ref -> memphis_dispense_cache.order_number
--   4. Where exactly one distinct client_id surfaces, stamp it on audit_detail
--      with match_type = 'FEDEX CUSTOMER REFERENCE MATCH CF ORDER NO'
--
-- Idempotent (CREATE OR ALTER).
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


CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_match_06_fedex_refs
    @etl_run_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'match_06_fedex_refs', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        WITH refs AS (
            SELECT
                ad.audit_detail_id,
                ad.carrier_shipment_id,
                COALESCE(
                    NULLIF(LTRIM(RTRIM(fx.updated_customer_reference)),  ''),
                    NULLIF(LTRIM(RTRIM(fx.original_customer_reference)), '')
                ) AS customer_ref
            FROM carrier_trueup.audit_detail ad
            INNER JOIN carrier_trueup.fedex_invoice_landing fx
                ON ad.carrier_shipment_id = fx.express_or_ground_tracking_id
               AND fx.site_code = ad.site_code
            WHERE ad.etl_run_id = @etl_run_id
              AND ad.is_closed  = 0
              AND ad.carrier    = 'FedEx'
        ),
        resolved AS (
            SELECT
                r.audit_detail_id,
                MIN(r.customer_ref) AS customer_ref,
                MIN(mdc.client_id)  AS client_id
            FROM refs r
            INNER JOIN carrier_trueup.memphis_dispense_cache mdc
                ON r.customer_ref = mdc.order_number
               AND mdc.etl_run_id = @etl_run_id
            WHERE r.customer_ref IS NOT NULL
              AND mdc.client_id  IS NOT NULL
            GROUP BY r.audit_detail_id
            HAVING COUNT(DISTINCT mdc.client_id) = 1  -- unambiguous match only
        )
        UPDATE ad
        SET client_id    = r.client_id,
            match_type   = 'FEDEX CUSTOMER REFERENCE MATCH CF ORDER NO',
            ref_fld_1    = r.customer_ref,
            is_closed    = 1,
            evaluated_at = GETDATE()
        FROM carrier_trueup.audit_detail ad
        INNER JOIN resolved r ON ad.audit_detail_id = r.audit_detail_id
        WHERE ad.etl_run_id = @etl_run_id
          AND ad.is_closed  = 0;

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status        = 'COMPLETE',
            completed_at  = GETDATE(),
            rows_affected = @rows,
            notes         = CONCAT(@rows, ' FedEx customer-reference matches closed')
        WHERE step_id = @step_id;
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


PRINT '=== 0114_memphis_trueup_match_06_fedex: complete ===';
PRINT '  Procedure added:';
PRINT '    + sp_memphis_trueup_match_06_fedex_refs';
PRINT '  NOTE: 0109 orchestrator update (this same migration session) calls it in cascade.';
GO
