-- =============================================================================
-- SUBSTRATE COPY  (scrubbed by CC for public substrate, 2026-05-12)
-- =============================================================================
-- Source        : utopia/migrations/0116_memphis_trueup_match_06_v2_prefix.sql
-- Source repo   : johndfitch-bot/utopia (PRIVATE - McKesson IP boundary)
-- Redactions    : NONE - file body is verbatim. No client IDs/names, no seed
--                 inserts, no internal hostnames or IPs were present.
-- Note          : production version of match_06 (supersedes 0114). v2 looks
--                 for the FedEx customer_ref as a PREFIX of CF order numbers.
-- =============================================================================

-- 0116_memphis_trueup_match_06_v2_prefix.sql
-- =============================================================================
-- Memphis True-Up: Strategy 06 v2 -- FedEx customer-ref is a PREFIX of CF
-- order_number, not an exact match.
--
-- Diagnostic from run 9 (2026-05-11_110544) proved that the FedEx invoice
-- "Original Customer Reference" column carries the FIRST 6 digits of an
-- 11-digit CF order number, not the full order number. Example:
--
--   FedEx invoice orig_ref:        381890
--   CF dispense order_number:      38189059999  (UPS shipment, irrelevant)
--   CF dispense order_number:      38189096895  (FEDEX 2DAY -- THIS one)
--
-- The 6-digit prefix collides across UPS AND FedEx shipments under the
-- same CF order group. Solution: join with order_number LIKE ref + '%' AND
-- filter dispense rows to ship_method LIKE 'FEDEX%' so we only resolve
-- against the actual FedEx-shipped dispense.
--
-- Keeps the "unambiguous client_id only" guard: if a single FedEx invoice
-- ref maps to FedEx dispenses across multiple distinct clients, skip rather
-- than guess.
--
-- v1 (in 0114) used `mdc.order_number = ref` (exact) and matched 0 of 3
-- sample rows. v2 is expected to match 1 of 3 (the case where dispense
-- HAS a corresponding FedEx shipment); the other 2 sample refs are real
-- audit failures (FedEx billed shipments with no dispense record at all,
-- likely internal/non-billing transfers).
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
        prefix_candidates AS (
            -- Find dispense rows whose order_number STARTS with the FedEx ref.
            -- Filter to FedEx-shipped dispenses only so we don't pick the UPS
            -- row that shares the same CF-order prefix.
            SELECT
                r.audit_detail_id,
                r.customer_ref,
                mdc.client_id,
                mdc.order_number
            FROM refs r
            INNER JOIN carrier_trueup.memphis_dispense_cache mdc
                ON  mdc.order_number LIKE r.customer_ref + '%'
                AND mdc.etl_run_id = @etl_run_id
            WHERE r.customer_ref IS NOT NULL
              AND LEN(r.customer_ref) >= 4              -- guard against super-short refs
              AND mdc.ship_method LIKE 'FEDEX%'         -- only FedEx-shipped dispenses
              AND mdc.client_id   IS NOT NULL
        ),
        resolved AS (
            SELECT
                audit_detail_id,
                MIN(customer_ref) AS customer_ref,
                MIN(client_id)    AS client_id
            FROM prefix_candidates
            GROUP BY audit_detail_id
            HAVING COUNT(DISTINCT client_id) = 1        -- one client per ref
        )
        UPDATE ad
        SET client_id    = r.client_id,
            match_type   = 'FEDEX CUSTOMER REFERENCE PREFIX MATCH (FEDEX-only)',
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
            notes         = CONCAT(@rows, ' FedEx prefix-matches closed (v2: prefix + ship_method=FEDEX)')
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


PRINT '=== 0116_memphis_trueup_match_06_v2_prefix: complete ===';
PRINT '  Procedure altered:';
PRINT '    ~ sp_memphis_trueup_match_06_fedex_refs  (now uses LIKE prefix + FEDEX ship_method)';
GO
