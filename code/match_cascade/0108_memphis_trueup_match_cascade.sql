-- =============================================================================
-- SUBSTRATE COPY  (scrubbed by CC for public substrate, 2026-05-12)
-- =============================================================================
-- Source        : utopia/migrations/0108_memphis_trueup_match_cascade.sql
-- Source repo   : johndfitch-bot/utopia (PRIVATE - McKesson IP boundary)
-- Redactions    : 2 comment-only edits replaced a literal <client_id>=<name>
--                 reference for the default fallback client with the token
--                 "<REDACTED-CLIENT>". No code logic changed. The
--                 default_client_id COLUMN reference is kept verbatim so the
--                 join logic in sp_memphis_trueup_match_04_cs_override (line
--                 ~196) reads exactly as it does in production.
-- Captain ask   : Q1 -- does match_01_direct propagate a tracking_no match
--                       across sibling rows with the same tracking_number?
--                       (see sp_memphis_trueup_match_01_direct, line ~46)
--                 Q2 -- does match_04_cs_override actually read from the CS
--                       return log? what table/column? why 0 closures?
--                       (see sp_memphis_trueup_match_04_cs_override, line ~196)
-- =============================================================================

-- 0108_memphis_trueup_match_cascade.sql
-- =============================================================================
-- Memphis True-Up: the 5-strategy match cascade.
--
-- Each SP updates carrier_trueup.audit_detail in-place, stamping client_id +
-- match_type + is_closed=1 on the rows that match its strategy. Rows that
-- pass through all five SPs still open at the end are the audit failures.
--
-- Execution order matters: strategies are tried from most-specific to most-
-- general. DIRECT match handles the bulk; later steps only see the leftovers.
--
-- Strategies (in order):
--   01 sp_memphis_trueup_match_01_direct          tracking# -> client_id via dispense pairing
--   02 sp_memphis_trueup_match_02_ep_pretransit   EasyPost status="pre_transit" (no client)
--   03 sp_memphis_trueup_match_03_ep_returns      EasyPost status="return_to_sender" (no client)
--   04 sp_memphis_trueup_match_04_cs_override     manual ops log -> client (default <REDACTED-CLIENT>)
--   05 sp_memphis_trueup_match_05_ups_returns     UPS return ref# -> CF order# -> client
--
-- Every SP logs to etl_step_log; failures throw and leave the audit_detail
-- consistent (the run can be re-driven safely).
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
-- 01. DIRECT CARRIER SHIPMENT ID MATCH
-- =============================================================================
-- Join audit_detail to the unique-tracking-client map built during dispense
-- refresh. Tracking #s that appear under exactly one client get an unambiguous
-- client_id stamp. Closes the bulk of lines.
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_match_01_direct
    @etl_run_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'match_01_direct', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        UPDATE ad
        SET client_id    = map.client_id,
            match_type   = 'DIRECT CARRIER SHIPMENT ID MATCH',
            is_closed    = 1,
            evaluated_at = GETDATE()
        FROM carrier_trueup.audit_detail ad
        INNER JOIN carrier_trueup.memphis_unique_tracking_client_map map
            ON ad.carrier_shipment_id = map.tracking_number
           AND map.etl_run_id = ad.etl_run_id
        WHERE ad.etl_run_id = @etl_run_id
          AND ad.is_closed = 0;

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' direct matches closed')
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
-- 02. EasyPost pre-transit  (label generated, never shipped, no client billed)
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_match_02_ep_pretransit
    @etl_run_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'match_02_ep_pretransit', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        UPDATE ad
        SET match_type   = 'EASYPOST PRE-TRANSIT PER STATUS',
            comments     = CONCAT('EasyPost Status Code: ', ep.status),
            is_closed    = 1,
            evaluated_at = GETDATE()
        FROM carrier_trueup.audit_detail ad
        INNER JOIN carrier_trueup.easypost_invoice_landing ep
            ON ad.carrier_shipment_id = ep.tracking_code
           AND ep.site_code = ad.site_code
        WHERE ad.etl_run_id = @etl_run_id
          AND ad.is_closed  = 0
          AND ad.client_id  IS NULL
          AND ad.carrier    = 'EasyPost'
          AND ep.status     = 'pre_transit';

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' EasyPost pre-transit closed (no client billed)')
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
-- 03. EasyPost return-to-sender
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_match_03_ep_returns
    @etl_run_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'match_03_ep_returns', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        UPDATE ad
        SET match_type   = 'EASYPOST RETURN PER STATUS',
            comments     = CONCAT('EasyPost Status Code: ', ep.status),
            is_closed    = 1,
            evaluated_at = GETDATE()
        FROM carrier_trueup.audit_detail ad
        INNER JOIN carrier_trueup.easypost_invoice_landing ep
            ON ad.carrier_shipment_id = ep.tracking_code
           AND ep.site_code = ad.site_code
        WHERE ad.etl_run_id = @etl_run_id
          AND ad.is_closed  = 0
          AND ad.client_id  IS NULL
          AND ad.carrier    = 'EasyPost'
          AND ep.status     = 'return_to_sender';

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' EasyPost returns closed')
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
-- 04. Customer service log override
-- =============================================================================
-- Tracking #s in cs_return_override_log get force-stamped.
-- force_client_id wins; if NULL, falls back to default_client_id (typically <REDACTED-CLIENT>).
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_match_04_cs_override
    @etl_run_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'match_04_cs_override', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        UPDATE ad
        SET client_id    = ISNULL(cs.force_client_id, cs.default_client_id),
            match_type   = 'CUSTOMER SERVICE LOG MATCH',
            comments     = ISNULL(cs.notes, 'CS log default override'),
            is_closed    = 1,
            evaluated_at = GETDATE()
        FROM carrier_trueup.audit_detail ad
        INNER JOIN carrier_trueup.cs_return_override_log cs
            ON ad.carrier_shipment_id = cs.carrier_shipment_id
           AND cs.site_code = ad.site_code
        WHERE ad.etl_run_id = @etl_run_id
          AND ad.is_closed  = 0
          AND cs.is_active  = 1;

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' CS-override matches closed')
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
-- 05. UPS return-reference decode  (pt1 -> pt5 collapsed to one SP)
-- =============================================================================
-- UPS return labels carry the original CF order number in Shipment Reference
-- Number 1 (with Package Reference Number 1 as fallback). The Access pipeline
-- did this in 5 chained queries; here it's one CTE.
--
-- Steps the CTE captures:
--   1. Pull raw_ref from raw_invoice_data for unmatched UPS lines
--   2. Strip first 2 chars; keep only 11-char remainders; drop empties / "test"
--   3. Keep only carrier_shipment_ids whose ref is unambiguous (one occurrence)
--   4. Look up the formatted_ref in memphis_dispense_cache.order_number -> client_id
--   5. Stamp audit_detail with the resolved client_id
-- =============================================================================

CREATE OR ALTER PROCEDURE carrier_trueup.sp_memphis_trueup_match_05_ups_returns
    @etl_run_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id INT;
    INSERT INTO carrier_trueup.etl_step_log (etl_run_id, step_name, status)
    VALUES (@etl_run_id, 'match_05_ups_returns', 'RUNNING');
    SET @step_id = SCOPE_IDENTITY();

    BEGIN TRY
        WITH refs_per_unmatched AS (
            SELECT
                ad.audit_detail_id,
                ad.carrier_shipment_id,
                MAX(LTRIM(RTRIM(riv.Shipment_Reference_Number_1))) AS shp_ref_1,
                MAX(LTRIM(RTRIM(riv.Package_Reference_Number_1)))  AS pkg_ref_1
            FROM carrier_trueup.audit_detail ad
            INNER JOIN carrier_trueup.raw_invoice_data riv
                ON ad.carrier_shipment_id = riv.Lead_Shipment_Number
               AND riv.site_code = ad.site_code
            WHERE ad.etl_run_id = @etl_run_id
              AND ad.is_closed  = 0
              AND ad.carrier    = 'UPS'
            GROUP BY ad.audit_detail_id, ad.carrier_shipment_id
        ),
        candidates AS (
            SELECT
                audit_detail_id,
                carrier_shipment_id,
                ISNULL(NULLIF(shp_ref_1, ''), NULLIF(pkg_ref_1, '')) AS raw_ref
            FROM refs_per_unmatched
        ),
        formatted AS (
            SELECT
                audit_detail_id,
                carrier_shipment_id,
                raw_ref,
                SUBSTRING(raw_ref, 3, 11) AS formatted_ref
            FROM candidates
            WHERE raw_ref IS NOT NULL
              AND raw_ref <> ''
              AND raw_ref <> 'test'
              AND LEN(raw_ref) >= 13  -- need >= 13 chars to have an 11-char tail after stripping 2
        ),
        unique_refs AS (
            SELECT carrier_shipment_id
            FROM formatted
            GROUP BY carrier_shipment_id
            HAVING COUNT(*) = 1
        ),
        resolved AS (
            SELECT
                f.audit_detail_id,
                f.formatted_ref,
                mdc.client_id
            FROM formatted f
            INNER JOIN unique_refs ur
                ON f.carrier_shipment_id = ur.carrier_shipment_id
            INNER JOIN carrier_trueup.memphis_dispense_cache mdc
                ON f.formatted_ref = mdc.order_number
               AND mdc.etl_run_id = @etl_run_id
            WHERE mdc.client_id IS NOT NULL
        )
        UPDATE ad
        SET client_id    = r.client_id,
            match_type   = 'UPS RETURN REFERENCE DIRECT MATCH CF ORDER NO',
            ref_fld_1    = r.formatted_ref,
            is_closed    = 1,
            evaluated_at = GETDATE()
        FROM carrier_trueup.audit_detail ad
        INNER JOIN resolved r ON ad.audit_detail_id = r.audit_detail_id
        WHERE ad.etl_run_id = @etl_run_id
          AND ad.is_closed  = 0;

        DECLARE @rows INT = @@ROWCOUNT;

        UPDATE carrier_trueup.etl_step_log
        SET status = 'COMPLETE', completed_at = GETDATE(),
            rows_affected = @rows,
            notes = CONCAT(@rows, ' UPS return-reference matches closed')
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


PRINT '=== 0108_memphis_trueup_match_cascade: complete ===';
PRINT '  Procedures added (5 cascade strategies):';
PRINT '    + sp_memphis_trueup_match_01_direct';
PRINT '    + sp_memphis_trueup_match_02_ep_pretransit';
PRINT '    + sp_memphis_trueup_match_03_ep_returns';
PRINT '    + sp_memphis_trueup_match_04_cs_override';
PRINT '    + sp_memphis_trueup_match_05_ups_returns';
GO
