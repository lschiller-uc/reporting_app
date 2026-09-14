-- metadb:function Acq_Approvals_SumTotals
DROP FUNCTION IF EXISTS Acq_Approvals_SumTotals(date);

CREATE OR REPLACE FUNCTION Acq_Approvals_SumTotals(
    run_date date DEFAULT current_date
)
RETURNS TABLE (
    bill_to TEXT,
    vendor TEXT,
    pol_fund_codes TEXT,
    pol_requester TEXT,
    pol_account TEXT,
    pol_estimated_cost_total NUMERIC(19,4),
    invoice_fund_code TEXT,
    invoice_line_total NUMERIC(19,4)
)
AS
$$
    WITH
    invoice_report AS (
        SELECT
            jsonb_extract_path_text(il.jsonb, 'poLineId')::uuid AS pol_id,
            jsonb_extract_path_text(fundDis.jsonb, 'code') AS invoice_fund_code,
            sum(jsonb_extract_path_text(il.jsonb, 'total')::numeric(19,4)) AS invoice_line_total
        FROM folio_invoice.invoices__t it
        LEFT JOIN folio_invoice.invoice_lines il ON jsonb_extract_path_text(il.jsonb, 'invoiceId')::uuid = it.id
            LEFT JOIN LATERAL jsonb_array_elements(jsonb_extract_path(il.jsonb, 'fundDistributions')) AS fundDis (jsonb) ON TRUE
        WHERE it.status != 'Cancelled'
        GROUP BY jsonb_extract_path_text(il.jsonb, 'poLineId'), jsonb_extract_path_text(fundDis.jsonb, 'code') -- need to check effective fund code vs fund code from invoice
    ),
    po_fund_codes AS (
        SELECT
            string_agg((fundDis.jsonb #>> '{code}'), ' | ') AS funds,
            --string_agg(ft.code, ' | ') AS funds2,
            pol3.id AS id
        FROM folio_orders.po_line pol3 
            CROSS JOIN LATERAL jsonb_array_elements(jsonb_extract_path(jsonb, 'fundDistribution')) AS fundDis (jsonb)
        --LEFT JOIN folio_finance.fund__t ft ON ft.id = (fundDis.jsonb #>> '{fundId}')::uuid
        --fundDis.jsonb #>> '{encumbrance}' has uuid for encumbrances associated with that fund
        GROUP BY pol3.id
    )
    SELECT
        cd.value::json#>>'{name}' AS bill_to,
        org.code AS vendor,
        pfc.funds AS pol_fund_codes,
        jsonb_extract_path_text(pol.jsonb, 'requester') AS pol_requester,
        jsonb_extract_path_text (pol. jsonb, 'vendorDetail', 'vendorAccount') AS pol_account,
        sum(jsonb_extract_path_text(pol.jsonb, 'cost', 'poLineEstimatedPrice')::numeric(19,4)) AS pol_estimated_cost_total,
        ir.invoice_fund_code AS invoice_fund_code,
        sum(ir.invoice_line_total) AS invoice_line_total
    FROM folio_orders.po_line pol
    LEFT JOIN folio_orders.purchase_order__t pot ON pot.id = pol.purchaseorderid
    LEFT JOIN invoice_report ir ON ir.pol_id = pol.id
    LEFT JOIN folio_configuration.config_data__t cd ON cd.id = pot.bill_to
    LEFT JOIN folio_organizations.organizations__t org ON pot.vendor = org.id
    LEFT JOIN po_fund_codes AS pfc ON pfc.id = pol.id
    LEFT JOIN folio_orders.acquisition_method__t amt on amt.id = jsonb_extract_path_text(pol.jsonb, 'acquisitionMethod')::uuid
    WHERE 
        amt.value = 'Approval Plan' 
        --jsonb_extract_path_text(pol.jsonb, 'acquisitionMethod') = '796596c4-62b5-4b64-a2ce-524c747afaa2' -- UUID for Approval Plan
        AND pol.creation_date::date >= '2026-07-01'   -- Beginning of Fiscal Year
        AND pol.creation_date::date < run_date --run_date    -- Enter Friday report is being run
    GROUP BY org.code,
        cd.value::json#>>'{name}', pfc.funds, jsonb_extract_path_text (pol. jsonb, 'vendorDetail', 'vendorAccount'), 
        jsonb_extract_path_text(pol.jsonb, 'requester'), ir.invoice_fund_code
 $$
 LANGUAGE SQL
 STABLE
 PARALLEL SAFE;