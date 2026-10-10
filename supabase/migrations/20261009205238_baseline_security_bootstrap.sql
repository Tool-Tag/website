--
-- PostgreSQL database dump
--


-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11 (Postgres.app)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: asset_details; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.asset_details WITH (security_invoker='true') AS
 SELECT a.id,
    a.unit_id,
    a.source_expense_id,
    a.origin,
    a.name,
    a.category_id,
    a.serial_number,
    a.warranty_expiration,
    a.status,
    a.notes,
    a.estimated_value,
    a.donated_by,
    a.received_date,
    a.created_at,
    t.amount AS purchase_cost,
    t.vendor,
    t.transaction_date AS purchase_date
   FROM (public.assets a
     LEFT JOIN public.transactions t ON ((t.id = a.source_expense_id)));


ALTER VIEW public.asset_details OWNER TO postgres;

--
-- Name: expense_details; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.expense_details WITH (security_invoker='true') AS
 SELECT e.transaction_id,
    e.unit_id,
    e.paid_by,
    e.lodging,
    e.linked_asset_id,
    t.amount,
    t.transaction_date,
    t.description,
    t.vendor,
    c.is_equipment,
    GREATEST((0)::numeric, ((t.amount - COALESCE(( SELECT sum(r.amount) AS sum
           FROM (public.reimbursements r
             JOIN public.transactions rt ON ((rt.id = r.transaction_id)))
          WHERE ((r.expense_id = e.transaction_id) AND (rt.status <> 'Voided'::text))), (0)::numeric)) - COALESCE(( SELECT sum(ft.amount) AS sum
           FROM (public.refunds f
             JOIN public.transactions ft ON ((ft.id = f.transaction_id)))
          WHERE ((f.original_id = e.transaction_id) AND (ft.status <> 'Voided'::text))), (0)::numeric))) AS reimbursement_due,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM public.documents d
              WHERE ((d.transaction_id = t.id) AND (d.type = 'Receipt'::text) AND (d.status = 'Available'::text) AND (d.drive_file_id IS NOT NULL)))) THEN 'Receipt Attached'::text
            WHEN ((t.amount < (75)::numeric) AND (NOT e.lodging)) THEN 'Receipt Not Required (<$75)'::text
            ELSE 'Receipt Missing — Required'::text
        END AS receipt_status
   FROM ((public.expenses e
     JOIN public.transactions t ON ((t.id = e.transaction_id)))
     LEFT JOIN public.categories c ON ((c.id = t.category_id)))
  WHERE (t.status <> 'Voided'::text);


ALTER VIEW public.expense_details OWNER TO postgres;

--
-- Name: financial_effects; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.financial_effects WITH (security_invoker='true') AS
 SELECT t.id,
    t.unit_id,
    t.transaction_date,
    t.account_id,
        CASE t.type
            WHEN 'COLLECTION'::text THEN t.amount
            WHEN 'OWNER_INJECTION'::text THEN t.amount
            WHEN 'OWNER_DRAW'::text THEN (- t.amount)
            WHEN 'INTER_UNIT_TRANSFER'::text THEN (- t.amount)
            WHEN 'EXPENSE'::text THEN
            CASE
                WHEN (e.paid_by = 'Business'::text) THEN (- t.amount)
                ELSE (0)::numeric
            END
            WHEN 'REFUND'::text THEN
            CASE
                WHEN (r.subtype = 'Customer Refund'::text) THEN (- t.amount)
                WHEN (oe.paid_by = 'Owner'::text) THEN (0)::numeric
                ELSE t.amount
            END
            ELSE (0)::numeric
        END AS cash,
        CASE
            WHEN (t.type = 'SALE'::text) THEN t.amount
            WHEN ((t.type = 'REFUND'::text) AND (r.subtype = 'Customer Refund'::text)) THEN (- t.amount)
            ELSE (0)::numeric
        END AS revenue,
        CASE
            WHEN ((t.type = 'EXPENSE'::text) AND (NOT COALESCE(cat.is_equipment, false))) THEN t.amount
            WHEN ((t.type = 'REFUND'::text) AND (r.subtype = 'Vendor Refund'::text) AND (NOT COALESCE(ocat.is_equipment, false))) THEN (- t.amount)
            ELSE (0)::numeric
        END AS expense,
        CASE
            WHEN ((t.type = 'EXPENSE'::text) AND cat.is_equipment) THEN t.amount
            WHEN ((t.type = 'REFUND'::text) AND (r.subtype = 'Vendor Refund'::text) AND ocat.is_equipment) THEN (- t.amount)
            ELSE (0)::numeric
        END AS equipment,
        CASE
            WHEN (t.type = 'OWNER_INJECTION'::text) THEN t.amount
            ELSE (0)::numeric
        END AS injection
   FROM ((((((public.transactions t
     LEFT JOIN public.expenses e ON ((e.transaction_id = t.id)))
     LEFT JOIN public.categories cat ON ((cat.id = t.category_id)))
     LEFT JOIN public.refunds r ON ((r.transaction_id = t.id)))
     LEFT JOIN public.transactions ot ON ((ot.id = r.original_id)))
     LEFT JOIN public.expenses oe ON ((oe.transaction_id = ot.id)))
     LEFT JOIN public.categories ocat ON ((ocat.id = ot.category_id)))
  WHERE (t.status <> 'Voided'::text)
UNION ALL
 SELECT t.id,
    tr.destination_unit_id AS unit_id,
    t.transaction_date,
    tr.destination_account_id AS account_id,
    t.amount AS cash,
    0 AS revenue,
    0 AS expense,
    0 AS equipment,
    0 AS injection
   FROM (public.inter_unit_transfers tr
     JOIN public.transactions t ON ((t.id = tr.transaction_id)))
  WHERE (t.status <> 'Voided'::text);


ALTER VIEW public.financial_effects OWNER TO postgres;

--
-- Name: finance_summary; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.finance_summary WITH (security_invoker='true') AS
 SELECT b.id AS unit_id,
    b.code,
    COALESCE(sum(f.cash), (0)::numeric) AS operating_balance,
    COALESCE(sum((f.revenue - f.expense)), (0)::numeric) AS net_profit,
    COALESCE(sum(f.equipment), (0)::numeric) AS equipment_investment,
    COALESCE(sum(f.injection), (0)::numeric) AS owner_injection,
    COALESCE(( SELECT sum(e.reimbursement_due) AS sum
           FROM public.expense_details e
          WHERE ((e.unit_id = b.id) AND (e.paid_by = 'Owner'::text))), (0)::numeric) AS owner_reimbursement_due,
    (COALESCE(sum(f.cash), (0)::numeric) - COALESCE(( SELECT sum(e.reimbursement_due) AS sum
           FROM public.expense_details e
          WHERE ((e.unit_id = b.id) AND (e.paid_by = 'Owner'::text))), (0)::numeric)) AS available_balance,
    COALESCE(sum(((f.revenue - f.expense) - f.equipment)), (0)::numeric) AS net_position
   FROM (public.business_units b
     LEFT JOIN public.financial_effects f ON ((f.unit_id = b.id)))
  GROUP BY b.id, b.code;


ALTER VIEW public.finance_summary OWNER TO postgres;

--
-- Name: sale_balances; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.sale_balances WITH (security_invoker='true') AS
 SELECT s.transaction_id,
    s.unit_id,
    s.job_id,
    s.quote_id,
    s.code,
    s.approved_items,
    s.revision,
    t.amount,
    t.customer_id,
    t.transaction_date,
    t.status AS transaction_status,
    COALESCE(p.paid, (0)::numeric) AS collected,
    COALESCE(f.refunded, (0)::numeric) AS refunded,
    GREATEST((0)::numeric, (t.amount - COALESCE(p.paid, (0)::numeric))) AS balance_due,
        CASE
            WHEN (t.status = 'Voided'::text) THEN 'Cancelled'::text
            WHEN (COALESCE(f.refunded, (0)::numeric) >= t.amount) THEN 'Refunded'::text
            WHEN (COALESCE(f.refunded, (0)::numeric) > (0)::numeric) THEN 'Partially Refunded'::text
            WHEN (COALESCE(p.paid, (0)::numeric) >= t.amount) THEN 'Paid'::text
            WHEN (COALESCE(p.paid, (0)::numeric) > (0)::numeric) THEN 'Partially Paid'::text
            ELSE 'Open'::text
        END AS status
   FROM (((public.sales s
     JOIN public.transactions t ON ((t.id = s.transaction_id)))
     LEFT JOIN LATERAL ( SELECT sum(ct.amount) AS paid
           FROM (public.collections c
             JOIN public.transactions ct ON ((ct.id = c.transaction_id)))
          WHERE ((c.sale_id = s.transaction_id) AND (ct.status <> 'Voided'::text))) p ON (true))
     LEFT JOIN LATERAL ( SELECT sum(ft.amount) AS refunded
           FROM ((public.refunds r
             JOIN public.transactions ft ON ((ft.id = r.transaction_id)))
             JOIN public.collections c ON ((c.transaction_id = r.original_id)))
          WHERE ((c.sale_id = s.transaction_id) AND (ft.status <> 'Voided'::text))) f ON (true));


ALTER VIEW public.sale_balances OWNER TO postgres;

--
-- Name: job_commercial_totals; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.job_commercial_totals WITH (security_invoker='true') AS
 SELECT j.id,
    j.unit_id,
    COALESCE(b.amount, (0)::numeric) AS base_amount,
    COALESCE(e.amount, (0)::numeric) AS extensions_amount,
    (COALESCE(b.amount, (0)::numeric) + COALESCE(e.amount, (0)::numeric)) AS grand_total,
    (COALESCE(b.collected, (0)::numeric) + COALESCE(e.collected, (0)::numeric)) AS collected,
    (COALESCE(b.refunded, (0)::numeric) + COALESCE(e.refunded, (0)::numeric)) AS refunded,
    GREATEST((0)::numeric, (((COALESCE(b.amount, (0)::numeric) + COALESCE(e.amount, (0)::numeric)) - COALESCE(b.collected, (0)::numeric)) - COALESCE(e.collected, (0)::numeric))) AS balance_due
   FROM ((public.jobs j
     LEFT JOIN public.sale_balances b ON (((b.job_id = j.id) AND (b.transaction_status <> 'Voided'::text))))
     LEFT JOIN LATERAL ( SELECT sum(s.amount) AS amount,
            sum(s.collected) AS collected,
            sum(s.refunded) AS refunded
           FROM (public.job_extensions x
             JOIN public.sale_balances s ON ((s.transaction_id = x.sale_id)))
          WHERE ((x.job_id = j.id) AND (x.status = ANY (ARRAY['Approved'::text, 'Completed'::text])) AND (s.transaction_status <> 'Voided'::text))) e ON (true));


ALTER VIEW public.job_commercial_totals OWNER TO postgres;

--
-- Name: recent_activity; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.recent_activity WITH (security_invoker='true') AS
 SELECT (min((id)::text))::uuid AS id,
    unit_id,
    entity,
    entity_id,
    actor_id,
    created_at,
    string_agg(field, ', '::text ORDER BY field) AS changed_fields
   FROM public.audit_log
  WHERE (field <> ALL (ARRAY['id'::text, 'unit_id'::text, 'created_at'::text, 'updated_at'::text]))
  GROUP BY unit_id, entity, entity_id, actor_id, created_at;


ALTER VIEW public.recent_activity OWNER TO postgres;

--
-- Name: review_items; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.review_items WITH (security_invoker='true') AS
 SELECT expense_details.unit_id,
    expense_details.transaction_id AS entity_id,
    'Missing Receipt'::text AS kind,
    '/app/finance/expenses'::text AS path
   FROM public.expense_details
  WHERE (expense_details.receipt_status = 'Receipt Missing — Required'::text)
UNION ALL
 SELECT expense_details.unit_id,
    expense_details.transaction_id AS entity_id,
    'Unregistered Equipment Purchase'::text AS kind,
    '/app/equipment'::text AS path
   FROM public.expense_details
  WHERE (expense_details.is_equipment AND (expense_details.linked_asset_id IS NULL))
UNION ALL
 SELECT c.unit_id,
    c.transaction_id AS entity_id,
    'Unlinked Collection'::text AS kind,
    '/app/finance/transactions'::text AS path
   FROM (public.collections c
     JOIN public.transactions t ON ((t.id = c.transaction_id)))
  WHERE ((c.sale_id IS NULL) AND (t.status <> 'Voided'::text))
UNION ALL
 SELECT monthly_closes.unit_id,
    monthly_closes.id AS entity_id,
    monthly_closes.status AS kind,
    '/app/finance/reports'::text AS path
   FROM public.monthly_closes
  WHERE (monthly_closes.status = ANY (ARRAY['Reclose Required'::text, 'Documentation Updated'::text]))
UNION ALL
 SELECT expense_details.unit_id,
    expense_details.transaction_id AS entity_id,
    'Owner Reimbursement Pending'::text AS kind,
    '/app/finance/expenses'::text AS path
   FROM public.expense_details
  WHERE ((expense_details.paid_by = 'Owner'::text) AND (expense_details.reimbursement_due > (0)::numeric))
UNION ALL
 SELECT quotes.unit_id,
    quotes.id AS entity_id,
    'Quote expiring'::text AS kind,
    ('/app/quotes/'::text || quotes.id) AS path
   FROM public.quotes
  WHERE ((quotes.status = ANY (ARRAY['Sent'::text, 'Viewed'::text])) AND (quotes.expires_at < (now() + '2 days'::interval)))
UNION ALL
 SELECT jobs.unit_id,
    jobs.id AS entity_id,
    'Completion acknowledgment pending'::text AS kind,
    ('/app/jobs/'::text || jobs.id) AS path
   FROM public.jobs
  WHERE (jobs.status = 'Delivered – Pending Customer Acceptance'::text)
UNION ALL
 SELECT j.unit_id,
    j.id AS entity_id,
    'Receiving photos missing'::text AS kind,
    ('/app/jobs/'::text || j.id) AS path
   FROM public.jobs j
  WHERE ((j.status = ANY (ARRAY['Authorized'::text, 'Receiving Documentation'::text])) AND (NOT (EXISTS ( SELECT 1
           FROM public.documents d
          WHERE ((d.job_id = j.id) AND (d.type = 'Receiving Evidence'::text) AND (d.status = 'Available'::text))))));


ALTER VIEW public.review_items OWNER TO postgres;

--
-- Name: accepted_pdf_artifacts accepted_pdf_artifacts_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.accepted_pdf_artifacts
    ADD CONSTRAINT accepted_pdf_artifacts_pkey PRIMARY KEY (document_id);


--
-- Name: agreement_sequences agreement_sequences_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.agreement_sequences
    ADD CONSTRAINT agreement_sequences_pkey PRIMARY KEY (year);


--
-- Name: annual_sequences annual_sequences_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.annual_sequences
    ADD CONSTRAINT annual_sequences_pkey PRIMARY KEY (year);


--
-- Name: cancellation_access_links cancellation_access_links_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.cancellation_access_links
    ADD CONSTRAINT cancellation_access_links_pkey PRIMARY KEY (id);


--
-- Name: cancellation_access_links cancellation_access_links_token_hash_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.cancellation_access_links
    ADD CONSTRAINT cancellation_access_links_token_hash_key UNIQUE (token_hash);


--
-- Name: customer_mail_activation customer_mail_activation_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.customer_mail_activation
    ADD CONSTRAINT customer_mail_activation_pkey PRIMARY KEY (unit_id);


--
-- Name: delivery_scopes delivery_scopes_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.delivery_scopes
    ADD CONSTRAINT delivery_scopes_pkey PRIMARY KEY (job_id);


--
-- Name: extension_links extension_links_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.extension_links
    ADD CONSTRAINT extension_links_pkey PRIMARY KEY (extension_id);


--
-- Name: extension_links extension_links_token_hash_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.extension_links
    ADD CONSTRAINT extension_links_token_hash_key UNIQUE (token_hash);


--
-- Name: get_tagged_rate get_tagged_rate_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.get_tagged_rate
    ADD CONSTRAINT get_tagged_rate_pkey PRIMARY KEY (network, bucket);


--
-- Name: get_tagged_receipts get_tagged_receipts_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.get_tagged_receipts
    ADD CONSTRAINT get_tagged_receipts_pkey PRIMARY KEY (id);


--
-- Name: get_tagged_receipts get_tagged_receipts_quote_id_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.get_tagged_receipts
    ADD CONSTRAINT get_tagged_receipts_quote_id_key UNIQUE (quote_id);


--
-- Name: get_tagged_receipts get_tagged_receipts_reference_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.get_tagged_receipts
    ADD CONSTRAINT get_tagged_receipts_reference_key UNIQUE (reference);


--
-- Name: job_mail_links job_mail_links_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.job_mail_links
    ADD CONSTRAINT job_mail_links_pkey PRIMARY KEY (job_id);


--
-- Name: job_review_links job_review_links_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.job_review_links
    ADD CONSTRAINT job_review_links_pkey PRIMARY KEY (id);


--
-- Name: job_review_links job_review_links_token_hash_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.job_review_links
    ADD CONSTRAINT job_review_links_token_hash_key UNIQUE (token_hash);


--
-- Name: job_status_links job_status_links_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.job_status_links
    ADD CONSTRAINT job_status_links_pkey PRIMARY KEY (job_id);


--
-- Name: job_status_links job_status_links_token_hash_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.job_status_links
    ADD CONSTRAINT job_status_links_token_hash_key UNIQUE (token_hash);


--
-- Name: mutation_requests mutation_requests_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.mutation_requests
    ADD CONSTRAINT mutation_requests_pkey PRIMARY KEY (unit_id, request_id);


--
-- Name: pickup_payment_links pickup_payment_links_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.pickup_payment_links
    ADD CONSTRAINT pickup_payment_links_pkey PRIMARY KEY (job_id);


--
-- Name: pickup_payment_links pickup_payment_links_token_hash_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.pickup_payment_links
    ADD CONSTRAINT pickup_payment_links_token_hash_key UNIQUE (token_hash);


--
-- Name: public_links public_links_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.public_links
    ADD CONSTRAINT public_links_pkey PRIMARY KEY (token_hash);


--
-- Name: quote_delivery quote_delivery_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.quote_delivery
    ADD CONSTRAINT quote_delivery_pkey PRIMARY KEY (quote_id);


--
-- Name: request_status_links request_status_links_pkey; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.request_status_links
    ADD CONSTRAINT request_status_links_pkey PRIMARY KEY (request_id);


--
-- Name: request_status_links request_status_links_token_hash_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.request_status_links
    ADD CONSTRAINT request_status_links_token_hash_key UNIQUE (token_hash);


--
-- Name: request_status_links request_status_links_token_key; Type: CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.request_status_links
    ADD CONSTRAINT request_status_links_token_key UNIQUE (token);


--
-- Name: accepted_document_status accepted_document_status_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_document_status
    ADD CONSTRAINT accepted_document_status_pkey PRIMARY KEY (document_id);


--
-- Name: accepted_documents accepted_documents_acceptance_folio_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_acceptance_folio_key UNIQUE (acceptance_folio);


--
-- Name: accepted_documents accepted_documents_agreement_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_agreement_id_key UNIQUE (agreement_id);


--
-- Name: accepted_documents accepted_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_pkey PRIMARY KEY (id);


--
-- Name: accepted_documents accepted_documents_quote_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_quote_id_key UNIQUE (quote_id);


--
-- Name: accounts accounts_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_unit_id_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_unit_id_name_key UNIQUE (unit_id, name);


--
-- Name: agreements agreements_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: agreements agreements_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_pkey PRIMARY KEY (id);


--
-- Name: agreements agreements_quote_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_quote_id_key UNIQUE (quote_id);


--
-- Name: assets assets_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: assets assets_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_pkey PRIMARY KEY (id);


--
-- Name: assets assets_source_expense_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_source_expense_id_key UNIQUE (source_expense_id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: business_units business_units_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_units
    ADD CONSTRAINT business_units_code_key UNIQUE (code);


--
-- Name: business_units business_units_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_units
    ADD CONSTRAINT business_units_pkey PRIMARY KEY (id);


--
-- Name: cancellation_requests cancellation_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cancellation_requests
    ADD CONSTRAINT cancellation_requests_pkey PRIMARY KEY (id);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: categories categories_unit_id_name_kind_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_unit_id_name_kind_key UNIQUE NULLS NOT DISTINCT (unit_id, name, kind);


--
-- Name: collections collections_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_pkey PRIMARY KEY (transaction_id);


--
-- Name: commercial_flows commercial_flows_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.commercial_flows
    ADD CONSTRAINT commercial_flows_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: commercial_flows commercial_flows_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.commercial_flows
    ADD CONSTRAINT commercial_flows_pkey PRIMARY KEY (id);


--
-- Name: commercial_flows commercial_flows_year_sequence_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.commercial_flows
    ADD CONSTRAINT commercial_flows_year_sequence_key UNIQUE (year, sequence);


--
-- Name: customers customers_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_code_key UNIQUE (code);


--
-- Name: customers customers_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: delivery_acknowledgments delivery_acknowledgments_job_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_acknowledgments
    ADD CONSTRAINT delivery_acknowledgments_job_id_key UNIQUE (job_id);


--
-- Name: delivery_acknowledgments delivery_acknowledgments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_acknowledgments
    ADD CONSTRAINT delivery_acknowledgments_pkey PRIMARY KEY (id);


--
-- Name: document_relations document_relations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_relations
    ADD CONSTRAINT document_relations_pkey PRIMARY KEY (document_id, transaction_id);


--
-- Name: documents documents_drive_file_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_drive_file_id_key UNIQUE (drive_file_id);


--
-- Name: documents documents_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: expenses expenses_linked_asset_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_linked_asset_id_key UNIQUE (linked_asset_id);


--
-- Name: expenses expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_pkey PRIMARY KEY (transaction_id);


--
-- Name: expenses expenses_transaction_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_transaction_id_unit_id_key UNIQUE (transaction_id, unit_id);


--
-- Name: inter_unit_transfers inter_unit_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inter_unit_transfers
    ADD CONSTRAINT inter_unit_transfers_pkey PRIMARY KEY (transaction_id);


--
-- Name: job_extensions job_extensions_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_extensions
    ADD CONSTRAINT job_extensions_code_key UNIQUE (code);


--
-- Name: job_extensions job_extensions_job_id_sequence_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_extensions
    ADD CONSTRAINT job_extensions_job_id_sequence_key UNIQUE (job_id, sequence);


--
-- Name: job_extensions job_extensions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_extensions
    ADD CONSTRAINT job_extensions_pkey PRIMARY KEY (id);


--
-- Name: job_extensions job_extensions_request_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_extensions
    ADD CONSTRAINT job_extensions_request_key_key UNIQUE (request_key);


--
-- Name: job_extensions job_extensions_sale_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_extensions
    ADD CONSTRAINT job_extensions_sale_id_key UNIQUE (sale_id);


--
-- Name: job_items job_items_job_id_quote_item_id_unit_index_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_items
    ADD CONSTRAINT job_items_job_id_quote_item_id_unit_index_key UNIQUE (job_id, quote_item_id, unit_index);


--
-- Name: job_items job_items_job_id_sequence_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_items
    ADD CONSTRAINT job_items_job_id_sequence_key UNIQUE (job_id, sequence);


--
-- Name: job_items job_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_items
    ADD CONSTRAINT job_items_pkey PRIMARY KEY (id);


--
-- Name: job_receipts job_receipts_job_id_snapshot_sha256_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_receipts
    ADD CONSTRAINT job_receipts_job_id_snapshot_sha256_key UNIQUE (job_id, snapshot_sha256);


--
-- Name: job_receipts job_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_receipts
    ADD CONSTRAINT job_receipts_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_code_key UNIQUE (code);


--
-- Name: jobs jobs_flow_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_flow_id_key UNIQUE (flow_id);


--
-- Name: jobs jobs_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (unit_id, user_id);


--
-- Name: mileage mileage_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mileage
    ADD CONSTRAINT mileage_pkey PRIMARY KEY (id);


--
-- Name: monthly_closes monthly_closes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.monthly_closes
    ADD CONSTRAINT monthly_closes_pkey PRIMARY KEY (id);


--
-- Name: monthly_closes monthly_closes_unit_id_month_version_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.monthly_closes
    ADD CONSTRAINT monthly_closes_unit_id_month_version_key UNIQUE (unit_id, month, version);


--
-- Name: notifications notifications_dedupe_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_dedupe_key_key UNIQUE (dedupe_key);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: owner_transactions owner_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.owner_transactions
    ADD CONSTRAINT owner_transactions_pkey PRIMARY KEY (transaction_id);


--
-- Name: payment_requests payment_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_requests
    ADD CONSTRAINT payment_requests_pkey PRIMARY KEY (id);


--
-- Name: payment_requests payment_requests_request_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_requests
    ADD CONSTRAINT payment_requests_request_key_key UNIQUE (request_key);


--
-- Name: physical_accounts physical_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.physical_accounts
    ADD CONSTRAINT physical_accounts_pkey PRIMARY KEY (id);


--
-- Name: pick_return_orders pick_return_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_orders
    ADD CONSTRAINT pick_return_orders_pkey PRIMARY KEY (job_id);


--
-- Name: pick_return_routes pick_return_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_routes
    ADD CONSTRAINT pick_return_routes_pkey PRIMARY KEY (id);


--
-- Name: pick_return_routes pick_return_routes_unit_id_route_date_leg_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_routes
    ADD CONSTRAINT pick_return_routes_unit_id_route_date_leg_key UNIQUE (unit_id, route_date, leg);


--
-- Name: pick_return_stops pick_return_stops_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_stops
    ADD CONSTRAINT pick_return_stops_pkey PRIMARY KEY (id);


--
-- Name: pick_return_stops pick_return_stops_route_id_job_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_stops
    ADD CONSTRAINT pick_return_stops_route_id_job_id_key UNIQUE (route_id, job_id);


--
-- Name: pick_return_stops pick_return_stops_route_id_sequence_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_stops
    ADD CONSTRAINT pick_return_stops_route_id_sequence_key UNIQUE (route_id, sequence);


--
-- Name: policies policies_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policies
    ADD CONSTRAINT policies_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: policies policies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policies
    ADD CONSTRAINT policies_pkey PRIMARY KEY (id);


--
-- Name: policies policies_unit_id_version_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policies
    ADD CONSTRAINT policies_unit_id_version_key UNIQUE (unit_id, version);


--
-- Name: quote_items quote_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quote_items
    ADD CONSTRAINT quote_items_pkey PRIMARY KEY (id);


--
-- Name: quotes quotes_flow_id_revision_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_flow_id_revision_key UNIQUE (flow_id, revision);


--
-- Name: quotes quotes_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: quotes quotes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_pkey PRIMARY KEY (id);


--
-- Name: refunds refunds_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_pkey PRIMARY KEY (transaction_id);


--
-- Name: reimbursements reimbursements_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reimbursements
    ADD CONSTRAINT reimbursements_pkey PRIMARY KEY (transaction_id, expense_id);


--
-- Name: sale_versions sale_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sale_versions
    ADD CONSTRAINT sale_versions_pkey PRIMARY KEY (id);


--
-- Name: sale_versions sale_versions_sale_id_revision_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sale_versions
    ADD CONSTRAINT sale_versions_sale_id_revision_key UNIQUE (sale_id, revision);


--
-- Name: sales sales_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_code_key UNIQUE (code);


--
-- Name: sales sales_job_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_job_id_key UNIQUE (job_id);


--
-- Name: sales sales_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_pkey PRIMARY KEY (transaction_id);


--
-- Name: sales sales_transaction_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_transaction_id_unit_id_key UNIQUE (transaction_id, unit_id);


--
-- Name: storage_folders storage_folders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.storage_folders
    ADD CONSTRAINT storage_folders_pkey PRIMARY KEY (id);


--
-- Name: transactions transactions_id_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_id_unit_id_key UNIQUE (id, unit_id);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);


--
-- Name: unit_settings unit_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.unit_settings
    ADD CONSTRAINT unit_settings_pkey PRIMARY KEY (unit_id);


--
-- Name: vendors vendors_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_pkey PRIMARY KEY (id);


--
-- Name: vendors vendors_unit_id_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_unit_id_name_key UNIQUE (unit_id, name);


--
-- Name: cancellation_access_customer_idx; Type: INDEX; Schema: private; Owner: postgres
--

CREATE INDEX cancellation_access_customer_idx ON private.cancellation_access_links USING btree (customer_id, expires_at DESC);


--
-- Name: audit_unit_time_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX audit_unit_time_idx ON public.audit_log USING btree (unit_id, created_at DESC);


--
-- Name: cancellation_requests_job_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX cancellation_requests_job_idx ON public.cancellation_requests USING btree (job_id, requested_at DESC);


--
-- Name: cancellation_requests_one_open_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX cancellation_requests_one_open_idx ON public.cancellation_requests USING btree (job_id) WHERE (status = 'Requested'::text);


--
-- Name: cancellation_requests_unit_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX cancellation_requests_unit_idx ON public.cancellation_requests USING btree (unit_id);


--
-- Name: collection_sale_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX collection_sale_idx ON public.collections USING btree (sale_id);


--
-- Name: customer_email_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX customer_email_idx ON public.customers USING btree (unit_id, lower(email));


--
-- Name: customer_phone_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX customer_phone_idx ON public.customers USING btree (unit_id, phone);


--
-- Name: customers_unit_name_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX customers_unit_name_idx ON public.customers USING btree (unit_id, lower(name));


--
-- Name: documents_accepted_document_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX documents_accepted_document_key ON public.documents USING btree (accepted_document_id) WHERE (accepted_document_id IS NOT NULL);


--
-- Name: documents_customer_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX documents_customer_idx ON public.documents USING btree (customer_id);


--
-- Name: documents_extension_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX documents_extension_idx ON public.documents USING btree (job_extension_id) WHERE (job_extension_id IS NOT NULL);


--
-- Name: documents_job_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX documents_job_idx ON public.documents USING btree (job_id);


--
-- Name: documents_job_item_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX documents_job_item_idx ON public.documents USING btree (job_item_id) WHERE (job_item_id IS NOT NULL);


--
-- Name: documents_job_receipt_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX documents_job_receipt_key ON public.documents USING btree (job_receipt_id) WHERE (job_receipt_id IS NOT NULL);


--
-- Name: documents_pick_return_stop_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX documents_pick_return_stop_idx ON public.documents USING btree (pick_return_stop_id) WHERE (pick_return_stop_id IS NOT NULL);


--
-- Name: documents_quote_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX documents_quote_idx ON public.documents USING btree (quote_id) WHERE (quote_id IS NOT NULL);


--
-- Name: documents_storage_status_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX documents_storage_status_idx ON public.documents USING btree (unit_id, storage_status, folder_kind);


--
-- Name: documents_transaction_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX documents_transaction_idx ON public.documents USING btree (transaction_id);


--
-- Name: documents_unit_logical_key_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX documents_unit_logical_key_key ON public.documents USING btree (unit_id, logical_key);


--
-- Name: job_items_job_stage_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX job_items_job_stage_idx ON public.job_items USING btree (job_id, stage, sequence);


--
-- Name: job_items_quote_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX job_items_quote_idx ON public.job_items USING btree (quote_id);


--
-- Name: job_items_quote_item_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX job_items_quote_item_idx ON public.job_items USING btree (quote_item_id);


--
-- Name: job_items_unit_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX job_items_unit_idx ON public.job_items USING btree (unit_id);


--
-- Name: jobs_unit_status_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX jobs_unit_status_idx ON public.jobs USING btree (unit_id, status);


--
-- Name: notification_pending_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX notification_pending_idx ON public.notifications USING btree (status, due_at);


--
-- Name: payment_requests_job_purpose_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX payment_requests_job_purpose_idx ON public.payment_requests USING btree (job_id, purpose, status);


--
-- Name: payment_requests_one_pending; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX payment_requests_one_pending ON public.payment_requests USING btree (job_id) WHERE (status = 'Pending Verification'::text);


--
-- Name: pick_return_orders_unit_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX pick_return_orders_unit_idx ON public.pick_return_orders USING btree (unit_id);


--
-- Name: pick_return_stops_job_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX pick_return_stops_job_idx ON public.pick_return_stops USING btree (job_id, status);


--
-- Name: pick_return_stops_unit_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX pick_return_stops_unit_idx ON public.pick_return_stops USING btree (unit_id);


--
-- Name: quote_flow_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX quote_flow_idx ON public.quotes USING btree (flow_id, revision DESC);


--
-- Name: quote_items_parent_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX quote_items_parent_idx ON public.quote_items USING btree (quote_id);


--
-- Name: quotes_intake_review_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX quotes_intake_review_idx ON public.quotes USING btree (unit_id, created_at) WHERE ((source = 'public_get_tagged'::text) AND (status = 'Draft'::text) AND (intake_reviewed_at IS NULL));


--
-- Name: refund_original_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX refund_original_idx ON public.refunds USING btree (original_id);


--
-- Name: storage_folders_external_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX storage_folders_external_key ON public.storage_folders USING btree (storage_provider, external_folder_id) WHERE (external_folder_id IS NOT NULL);


--
-- Name: storage_folders_logical_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX storage_folders_logical_key ON public.storage_folders USING btree (unit_id, customer_id, COALESCE(job_id, '00000000-0000-0000-0000-000000000000'::uuid), folder_kind, storage_provider);


--
-- Name: transactions_account_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX transactions_account_idx ON public.transactions USING btree (account_id);


--
-- Name: transactions_unit_date_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX transactions_unit_date_idx ON public.transactions USING btree (unit_id, transaction_date DESC);


--
-- Name: accepted_pdf_artifacts accepted_pdf_immutable; Type: TRIGGER; Schema: private; Owner: postgres
--

CREATE TRIGGER accepted_pdf_immutable BEFORE DELETE OR UPDATE ON private.accepted_pdf_artifacts FOR EACH ROW EXECUTE FUNCTION private.commercial_immutable();


--
-- Name: delivery_scopes delivery_scope_immutable; Type: TRIGGER; Schema: private; Owner: postgres
--

CREATE TRIGGER delivery_scope_immutable BEFORE DELETE OR UPDATE ON private.delivery_scopes FOR EACH ROW EXECUTE FUNCTION private.commercial_immutable();


--
-- Name: get_tagged_receipts get_tagged_mark_converted; Type: TRIGGER; Schema: private; Owner: postgres
--

CREATE TRIGGER get_tagged_mark_converted BEFORE UPDATE OF quote_id ON private.get_tagged_receipts FOR EACH ROW EXECUTE FUNCTION private.mark_get_tagged_converted();


--
-- Name: get_tagged_receipts get_tagged_request_mail; Type: TRIGGER; Schema: private; Owner: postgres
--

CREATE TRIGGER get_tagged_request_mail AFTER INSERT ON private.get_tagged_receipts FOR EACH ROW EXECUTE FUNCTION private.notify_get_tagged_request();


--
-- Name: accepted_documents accepted_document_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER accepted_document_immutable BEFORE DELETE OR UPDATE ON public.accepted_documents FOR EACH ROW EXECUTE FUNCTION private.commercial_immutable();


--
-- Name: accepted_documents accepted_document_metadata_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER accepted_document_metadata_sync AFTER INSERT ON public.accepted_documents FOR EACH ROW EXECUTE FUNCTION private.sync_accepted_document_metadata();


--
-- Name: agreements agreement_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER agreement_immutable BEFORE DELETE OR UPDATE ON public.agreements FOR EACH ROW EXECUTE FUNCTION private.commercial_immutable();


--
-- Name: agreements agreements_create_pick_return_order; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER agreements_create_pick_return_order AFTER INSERT ON public.agreements FOR EACH ROW EXECUTE FUNCTION private.create_pick_return_order_from_agreement();


--
-- Name: accounts audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: agreements audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.agreements FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: assets audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.assets FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: categories audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.categories FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: collections audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.collections FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: customers audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: delivery_acknowledgments audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.delivery_acknowledgments FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: documents audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: expenses audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.expenses FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: job_extensions audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.job_extensions FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: job_receipts audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.job_receipts FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: jobs audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.jobs FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: mileage audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.mileage FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: monthly_closes audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.monthly_closes FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: owner_transactions audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.owner_transactions FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: policies audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.policies FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: quote_items audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.quote_items FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: quotes audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.quotes FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: refunds audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.refunds FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: sales audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.sales FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: transactions audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: unit_settings audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.unit_settings FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: vendors audit_record; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_record AFTER INSERT OR UPDATE ON public.vendors FOR EACH ROW EXECUTE FUNCTION private.audit_change();


--
-- Name: notifications classify_mail; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER classify_mail BEFORE INSERT ON public.notifications FOR EACH ROW EXECUTE FUNCTION private.classify_mail();


--
-- Name: jobs completion_events; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER completion_events AFTER UPDATE ON public.jobs FOR EACH ROW EXECUTE FUNCTION private.queue_commercial_events();


--
-- Name: agreements create_job_status_portal; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER create_job_status_portal AFTER INSERT ON public.agreements FOR EACH ROW EXECUTE FUNCTION private.create_job_status_portal();


--
-- Name: delivery_acknowledgments delivery_ack_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER delivery_ack_immutable BEFORE DELETE OR UPDATE ON public.delivery_acknowledgments FOR EACH ROW EXECUTE FUNCTION private.commercial_immutable();


--
-- Name: inter_unit_transfers destination_close; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER destination_close AFTER INSERT ON public.inter_unit_transfers FOR EACH ROW EXECUTE FUNCTION private.protect_destination_close();


--
-- Name: documents documents_metadata_defaults; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER documents_metadata_defaults BEFORE INSERT OR UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION private.document_metadata_defaults();


--
-- Name: agreements freeze_acceptance; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER freeze_acceptance BEFORE INSERT ON public.agreements FOR EACH ROW EXECUTE FUNCTION private.freeze_acceptance();


--
-- Name: quotes get_tagged_review_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER get_tagged_review_guard BEFORE UPDATE ON public.quotes FOR EACH ROW EXECUTE FUNCTION private.guard_get_tagged_review();


--
-- Name: transactions guard_transaction; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER guard_transaction BEFORE INSERT OR UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION private.transaction_guard();


--
-- Name: job_items job_items_metadata_defaults; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER job_items_metadata_defaults BEFORE INSERT OR UPDATE ON public.job_items FOR EACH ROW EXECUTE FUNCTION private.job_item_metadata_defaults();


--
-- Name: job_receipts job_receipt_metadata_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER job_receipt_metadata_sync AFTER INSERT ON public.job_receipts FOR EACH ROW EXECUTE FUNCTION private.sync_job_receipt_metadata();


--
-- Name: jobs jobs_sync_items; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER jobs_sync_items AFTER INSERT OR UPDATE OF quote_id ON public.jobs FOR EACH ROW EXECUTE FUNCTION private.sync_job_items_trigger();


--
-- Name: transactions movement_integrity; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER movement_integrity BEFORE INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION private.movement_integrity();


--
-- Name: jobs notify_customer_stage_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER notify_customer_stage_change AFTER UPDATE OF customer_stage ON public.jobs FOR EACH ROW EXECUTE FUNCTION private.notify_customer_stage_change();


--
-- Name: owner_transactions owner_integrity; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER owner_integrity BEFORE INSERT ON public.owner_transactions FOR EACH ROW EXECUTE FUNCTION private.owner_integrity();


--
-- Name: policies policy_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER policy_immutable BEFORE DELETE OR UPDATE ON public.policies FOR EACH ROW WHEN ((old.published_at IS NOT NULL)) EXECUTE FUNCTION private.commercial_immutable();


--
-- Name: job_extensions protect_extension; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER protect_extension BEFORE DELETE OR UPDATE ON public.job_extensions FOR EACH ROW EXECUTE FUNCTION private.protect_extension();


--
-- Name: quotes quote_events; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER quote_events AFTER UPDATE ON public.quotes FOR EACH ROW EXECUTE FUNCTION private.queue_commercial_events();


--
-- Name: quote_items quote_items_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER quote_items_guard BEFORE INSERT OR DELETE OR UPDATE ON public.quote_items FOR EACH ROW EXECUTE FUNCTION private.protect_quote_scope();


--
-- Name: quotes quote_scope_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER quote_scope_guard BEFORE UPDATE ON public.quotes FOR EACH ROW EXECUTE FUNCTION private.protect_quote_scope();


--
-- Name: collections receipt_after_collection; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER receipt_after_collection AFTER INSERT ON public.collections FOR EACH ROW EXECUTE FUNCTION private.receipt_after_collection();


--
-- Name: job_receipts receipt_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER receipt_immutable BEFORE DELETE OR UPDATE ON public.job_receipts FOR EACH ROW EXECUTE FUNCTION private.commercial_immutable();


--
-- Name: sale_versions sale_version_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER sale_version_immutable BEFORE DELETE OR UPDATE ON public.sale_versions FOR EACH ROW EXECUTE FUNCTION private.commercial_immutable();


--
-- Name: jobs sync_customer_stage; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER sync_customer_stage BEFORE UPDATE OF status ON public.jobs FOR EACH ROW EXECUTE FUNCTION private.sync_customer_stage();


--
-- Name: payment_requests sync_payment_work_stage; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER sync_payment_work_stage AFTER INSERT OR UPDATE OF status ON public.payment_requests FOR EACH ROW EXECUTE FUNCTION private.sync_payment_work_stage();


--
-- Name: transactions transfer_correction; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER transfer_correction AFTER UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION private.transfer_correction_close();


--
-- Name: notifications work_notified; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER work_notified AFTER UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION private.mark_work_notified();


--
-- Name: accepted_pdf_artifacts accepted_pdf_artifacts_document_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.accepted_pdf_artifacts
    ADD CONSTRAINT accepted_pdf_artifacts_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.accepted_documents(id);


--
-- Name: cancellation_access_links cancellation_access_links_customer_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.cancellation_access_links
    ADD CONSTRAINT cancellation_access_links_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customer_mail_activation customer_mail_activation_unit_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.customer_mail_activation
    ADD CONSTRAINT customer_mail_activation_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: delivery_scopes delivery_scopes_job_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.delivery_scopes
    ADD CONSTRAINT delivery_scopes_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: extension_links extension_links_extension_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.extension_links
    ADD CONSTRAINT extension_links_extension_id_fkey FOREIGN KEY (extension_id) REFERENCES public.job_extensions(id);


--
-- Name: get_tagged_receipts get_tagged_receipts_customer_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.get_tagged_receipts
    ADD CONSTRAINT get_tagged_receipts_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: get_tagged_receipts get_tagged_receipts_quote_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.get_tagged_receipts
    ADD CONSTRAINT get_tagged_receipts_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.quotes(id);


--
-- Name: job_mail_links job_mail_links_job_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.job_mail_links
    ADD CONSTRAINT job_mail_links_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: job_review_links job_review_links_job_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.job_review_links
    ADD CONSTRAINT job_review_links_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: job_status_links job_status_links_job_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.job_status_links
    ADD CONSTRAINT job_status_links_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: mutation_requests mutation_requests_transaction_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.mutation_requests
    ADD CONSTRAINT mutation_requests_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES public.transactions(id);


--
-- Name: mutation_requests mutation_requests_unit_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.mutation_requests
    ADD CONSTRAINT mutation_requests_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: pickup_payment_links pickup_payment_links_job_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.pickup_payment_links
    ADD CONSTRAINT pickup_payment_links_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: public_links public_links_job_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.public_links
    ADD CONSTRAINT public_links_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: public_links public_links_quote_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.public_links
    ADD CONSTRAINT public_links_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.quotes(id);


--
-- Name: public_links public_links_unit_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.public_links
    ADD CONSTRAINT public_links_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: quote_delivery quote_delivery_quote_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.quote_delivery
    ADD CONSTRAINT quote_delivery_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.quotes(id);


--
-- Name: request_status_links request_status_links_request_id_fkey; Type: FK CONSTRAINT; Schema: private; Owner: postgres
--

ALTER TABLE ONLY private.request_status_links
    ADD CONSTRAINT request_status_links_request_id_fkey FOREIGN KEY (request_id) REFERENCES private.get_tagged_receipts(id);


--
-- Name: accepted_document_status accepted_document_status_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_document_status
    ADD CONSTRAINT accepted_document_status_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.accepted_documents(id);


--
-- Name: accepted_document_status accepted_document_status_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_document_status
    ADD CONSTRAINT accepted_document_status_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: accepted_documents accepted_documents_agreement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_agreement_id_fkey FOREIGN KEY (agreement_id) REFERENCES public.agreements(id);


--
-- Name: accepted_documents accepted_documents_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: accepted_documents accepted_documents_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: accepted_documents accepted_documents_quote_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.quotes(id);


--
-- Name: accepted_documents accepted_documents_sale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.sales(transaction_id);


--
-- Name: accepted_documents accepted_documents_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accepted_documents
    ADD CONSTRAINT accepted_documents_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: accounts accounts_physical_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_physical_account_id_fkey FOREIGN KEY (physical_account_id) REFERENCES public.physical_accounts(id);


--
-- Name: accounts accounts_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: agreements agreements_customer_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_customer_id_unit_id_fkey FOREIGN KEY (customer_id, unit_id) REFERENCES public.customers(id, unit_id);


--
-- Name: agreements agreements_job_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_job_id_unit_id_fkey FOREIGN KEY (job_id, unit_id) REFERENCES public.jobs(id, unit_id);


--
-- Name: agreements agreements_policy_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_policy_id_unit_id_fkey FOREIGN KEY (policy_id, unit_id) REFERENCES public.policies(id, unit_id);


--
-- Name: agreements agreements_quote_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_quote_id_unit_id_fkey FOREIGN KEY (quote_id, unit_id) REFERENCES public.quotes(id, unit_id);


--
-- Name: agreements agreements_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: assets assets_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id);


--
-- Name: assets assets_source_expense_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_source_expense_id_unit_id_fkey FOREIGN KEY (source_expense_id, unit_id) REFERENCES public.expenses(transaction_id, unit_id);


--
-- Name: assets assets_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: audit_log audit_log_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: cancellation_requests cancellation_requests_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cancellation_requests
    ADD CONSTRAINT cancellation_requests_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: cancellation_requests cancellation_requests_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cancellation_requests
    ADD CONSTRAINT cancellation_requests_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: cancellation_requests cancellation_requests_quote_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cancellation_requests
    ADD CONSTRAINT cancellation_requests_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.quotes(id);


--
-- Name: cancellation_requests cancellation_requests_refund_transaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cancellation_requests
    ADD CONSTRAINT cancellation_requests_refund_transaction_id_fkey FOREIGN KEY (refund_transaction_id) REFERENCES public.transactions(id);


--
-- Name: cancellation_requests cancellation_requests_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cancellation_requests
    ADD CONSTRAINT cancellation_requests_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: categories categories_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: collections collections_sale_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_sale_id_unit_id_fkey FOREIGN KEY (sale_id, unit_id) REFERENCES public.sales(transaction_id, unit_id);


--
-- Name: collections collections_transaction_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_transaction_id_unit_id_fkey FOREIGN KEY (transaction_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: collections collections_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: commercial_flows commercial_flows_customer_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.commercial_flows
    ADD CONSTRAINT commercial_flows_customer_id_unit_id_fkey FOREIGN KEY (customer_id, unit_id) REFERENCES public.customers(id, unit_id);


--
-- Name: commercial_flows commercial_flows_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.commercial_flows
    ADD CONSTRAINT commercial_flows_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: customers customers_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: delivery_acknowledgments delivery_acknowledgments_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_acknowledgments
    ADD CONSTRAINT delivery_acknowledgments_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: delivery_acknowledgments delivery_acknowledgments_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_acknowledgments
    ADD CONSTRAINT delivery_acknowledgments_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: delivery_acknowledgments delivery_acknowledgments_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_acknowledgments
    ADD CONSTRAINT delivery_acknowledgments_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: documents document_agreement_same_unit; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT document_agreement_same_unit FOREIGN KEY (agreement_id, unit_id) REFERENCES public.agreements(id, unit_id);


--
-- Name: document_relations document_relations_document_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_relations
    ADD CONSTRAINT document_relations_document_id_unit_id_fkey FOREIGN KEY (document_id, unit_id) REFERENCES public.documents(id, unit_id);


--
-- Name: document_relations document_relations_transaction_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_relations
    ADD CONSTRAINT document_relations_transaction_id_unit_id_fkey FOREIGN KEY (transaction_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: document_relations document_relations_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.document_relations
    ADD CONSTRAINT document_relations_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: documents documents_accepted_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_accepted_document_id_fkey FOREIGN KEY (accepted_document_id) REFERENCES public.accepted_documents(id) ON DELETE SET NULL;


--
-- Name: documents documents_agreement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_agreement_id_fkey FOREIGN KEY (agreement_id) REFERENCES public.agreements(id);


--
-- Name: documents documents_cancellation_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_cancellation_request_id_fkey FOREIGN KEY (cancellation_request_id) REFERENCES public.cancellation_requests(id) ON DELETE SET NULL;


--
-- Name: documents documents_customer_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_customer_id_unit_id_fkey FOREIGN KEY (customer_id, unit_id) REFERENCES public.customers(id, unit_id);


--
-- Name: documents documents_job_extension_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_job_extension_id_fkey FOREIGN KEY (job_extension_id) REFERENCES public.job_extensions(id) ON DELETE SET NULL;


--
-- Name: documents documents_job_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_job_id_unit_id_fkey FOREIGN KEY (job_id, unit_id) REFERENCES public.jobs(id, unit_id);


--
-- Name: documents documents_job_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_job_item_id_fkey FOREIGN KEY (job_item_id) REFERENCES public.job_items(id) ON DELETE SET NULL;


--
-- Name: documents documents_job_receipt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_job_receipt_id_fkey FOREIGN KEY (job_receipt_id) REFERENCES public.job_receipts(id) ON DELETE SET NULL;


--
-- Name: documents documents_payment_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_payment_request_id_fkey FOREIGN KEY (payment_request_id) REFERENCES public.payment_requests(id) ON DELETE SET NULL;


--
-- Name: documents documents_pick_return_stop_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pick_return_stop_id_fkey FOREIGN KEY (pick_return_stop_id) REFERENCES public.pick_return_stops(id) ON DELETE SET NULL;


--
-- Name: documents documents_quote_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.quotes(id) ON DELETE SET NULL;


--
-- Name: documents documents_transaction_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_transaction_id_unit_id_fkey FOREIGN KEY (transaction_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: documents documents_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: documents documents_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES auth.users(id);


--
-- Name: expenses expenses_linked_asset_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_linked_asset_id_unit_id_fkey FOREIGN KEY (linked_asset_id, unit_id) REFERENCES public.assets(id, unit_id);


--
-- Name: expenses expenses_transaction_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_transaction_id_unit_id_fkey FOREIGN KEY (transaction_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: expenses expenses_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: inter_unit_transfers inter_unit_transfers_destination_account_id_destination_un_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inter_unit_transfers
    ADD CONSTRAINT inter_unit_transfers_destination_account_id_destination_un_fkey FOREIGN KEY (destination_account_id, destination_unit_id) REFERENCES public.accounts(id, unit_id);


--
-- Name: inter_unit_transfers inter_unit_transfers_destination_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inter_unit_transfers
    ADD CONSTRAINT inter_unit_transfers_destination_unit_id_fkey FOREIGN KEY (destination_unit_id) REFERENCES public.business_units(id);


--
-- Name: inter_unit_transfers inter_unit_transfers_transaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inter_unit_transfers
    ADD CONSTRAINT inter_unit_transfers_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES public.transactions(id);


--
-- Name: inter_unit_transfers inter_unit_transfers_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inter_unit_transfers
    ADD CONSTRAINT inter_unit_transfers_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: job_extensions job_extensions_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_extensions
    ADD CONSTRAINT job_extensions_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: job_extensions job_extensions_sale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_extensions
    ADD CONSTRAINT job_extensions_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.sales(transaction_id);


--
-- Name: job_extensions job_extensions_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_extensions
    ADD CONSTRAINT job_extensions_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: job_items job_items_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_items
    ADD CONSTRAINT job_items_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: job_items job_items_quote_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_items
    ADD CONSTRAINT job_items_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.quotes(id);


--
-- Name: job_items job_items_quote_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_items
    ADD CONSTRAINT job_items_quote_item_id_fkey FOREIGN KEY (quote_item_id) REFERENCES public.quote_items(id);


--
-- Name: job_items job_items_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_items
    ADD CONSTRAINT job_items_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: job_receipts job_receipts_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_receipts
    ADD CONSTRAINT job_receipts_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: job_receipts job_receipts_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.job_receipts
    ADD CONSTRAINT job_receipts_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: jobs jobs_flow_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_flow_id_unit_id_fkey FOREIGN KEY (flow_id, unit_id) REFERENCES public.commercial_flows(id, unit_id);


--
-- Name: jobs jobs_quote_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_quote_id_unit_id_fkey FOREIGN KEY (quote_id, unit_id) REFERENCES public.quotes(id, unit_id);


--
-- Name: jobs jobs_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: memberships memberships_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: memberships memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: mileage mileage_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mileage
    ADD CONSTRAINT mileage_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: monthly_closes monthly_closes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.monthly_closes
    ADD CONSTRAINT monthly_closes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: monthly_closes monthly_closes_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.monthly_closes
    ADD CONSTRAINT monthly_closes_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: notifications notifications_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: owner_transactions owner_transactions_transaction_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.owner_transactions
    ADD CONSTRAINT owner_transactions_transaction_id_unit_id_fkey FOREIGN KEY (transaction_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: owner_transactions owner_transactions_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.owner_transactions
    ADD CONSTRAINT owner_transactions_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: payment_requests payment_requests_confirmed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_requests
    ADD CONSTRAINT payment_requests_confirmed_by_fkey FOREIGN KEY (confirmed_by) REFERENCES auth.users(id);


--
-- Name: payment_requests payment_requests_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_requests
    ADD CONSTRAINT payment_requests_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: payment_requests payment_requests_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_requests
    ADD CONSTRAINT payment_requests_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: pick_return_orders pick_return_orders_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_orders
    ADD CONSTRAINT pick_return_orders_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: pick_return_orders pick_return_orders_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_orders
    ADD CONSTRAINT pick_return_orders_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: pick_return_routes pick_return_routes_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_routes
    ADD CONSTRAINT pick_return_routes_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: pick_return_stops pick_return_stops_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_stops
    ADD CONSTRAINT pick_return_stops_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: pick_return_stops pick_return_stops_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_stops
    ADD CONSTRAINT pick_return_stops_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.pick_return_routes(id) ON DELETE CASCADE;


--
-- Name: pick_return_stops pick_return_stops_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pick_return_stops
    ADD CONSTRAINT pick_return_stops_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: policies policies_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policies
    ADD CONSTRAINT policies_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: quote_items quote_items_quote_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quote_items
    ADD CONSTRAINT quote_items_quote_id_unit_id_fkey FOREIGN KEY (quote_id, unit_id) REFERENCES public.quotes(id, unit_id);


--
-- Name: quote_items quote_items_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quote_items
    ADD CONSTRAINT quote_items_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: quotes quotes_flow_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_flow_id_unit_id_fkey FOREIGN KEY (flow_id, unit_id) REFERENCES public.commercial_flows(id, unit_id);


--
-- Name: quotes quotes_policy_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_policy_id_unit_id_fkey FOREIGN KEY (policy_id, unit_id) REFERENCES public.policies(id, unit_id);


--
-- Name: quotes quotes_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: refunds refunds_original_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_original_id_unit_id_fkey FOREIGN KEY (original_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: refunds refunds_transaction_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_transaction_id_unit_id_fkey FOREIGN KEY (transaction_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: refunds refunds_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: reimbursements reimbursements_expense_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reimbursements
    ADD CONSTRAINT reimbursements_expense_id_unit_id_fkey FOREIGN KEY (expense_id, unit_id) REFERENCES public.expenses(transaction_id, unit_id);


--
-- Name: reimbursements reimbursements_transaction_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reimbursements
    ADD CONSTRAINT reimbursements_transaction_id_unit_id_fkey FOREIGN KEY (transaction_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: reimbursements reimbursements_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reimbursements
    ADD CONSTRAINT reimbursements_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: sale_versions sale_versions_quote_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sale_versions
    ADD CONSTRAINT sale_versions_quote_id_unit_id_fkey FOREIGN KEY (quote_id, unit_id) REFERENCES public.quotes(id, unit_id);


--
-- Name: sale_versions sale_versions_sale_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sale_versions
    ADD CONSTRAINT sale_versions_sale_id_unit_id_fkey FOREIGN KEY (sale_id, unit_id) REFERENCES public.sales(transaction_id, unit_id);


--
-- Name: sale_versions sale_versions_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sale_versions
    ADD CONSTRAINT sale_versions_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: sales sales_job_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_job_id_unit_id_fkey FOREIGN KEY (job_id, unit_id) REFERENCES public.jobs(id, unit_id);


--
-- Name: sales sales_quote_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_quote_id_unit_id_fkey FOREIGN KEY (quote_id, unit_id) REFERENCES public.quotes(id, unit_id);


--
-- Name: sales sales_transaction_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_transaction_id_unit_id_fkey FOREIGN KEY (transaction_id, unit_id) REFERENCES public.transactions(id, unit_id);


--
-- Name: sales sales_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: storage_folders storage_folders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.storage_folders
    ADD CONSTRAINT storage_folders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: storage_folders storage_folders_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.storage_folders
    ADD CONSTRAINT storage_folders_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: storage_folders storage_folders_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.storage_folders
    ADD CONSTRAINT storage_folders_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: transactions transactions_account_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_account_id_unit_id_fkey FOREIGN KEY (account_id, unit_id) REFERENCES public.accounts(id, unit_id);


--
-- Name: transactions transactions_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id);


--
-- Name: transactions transactions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: transactions transactions_customer_id_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_customer_id_unit_id_fkey FOREIGN KEY (customer_id, unit_id) REFERENCES public.customers(id, unit_id);


--
-- Name: transactions transactions_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: unit_settings unit_settings_payment_account_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.unit_settings
    ADD CONSTRAINT unit_settings_payment_account_fkey FOREIGN KEY (payment_account_id, unit_id) REFERENCES public.accounts(id, unit_id);


--
-- Name: unit_settings unit_settings_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.unit_settings
    ADD CONSTRAINT unit_settings_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: vendors vendors_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.business_units(id);


--
-- Name: get_tagged_rate; Type: ROW SECURITY; Schema: private; Owner: postgres
--

ALTER TABLE private.get_tagged_rate ENABLE ROW LEVEL SECURITY;

--
-- Name: get_tagged_receipts; Type: ROW SECURITY; Schema: private; Owner: postgres
--

ALTER TABLE private.get_tagged_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: request_status_links; Type: ROW SECURITY; Schema: private; Owner: postgres
--

ALTER TABLE private.request_status_links ENABLE ROW LEVEL SECURITY;

--
-- Name: accepted_document_status; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.accepted_document_status ENABLE ROW LEVEL SECURITY;

--
-- Name: accepted_document_status accepted_document_status_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY accepted_document_status_read ON public.accepted_document_status FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: accepted_documents; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.accepted_documents ENABLE ROW LEVEL SECURITY;

--
-- Name: accepted_documents accepted_documents_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY accepted_documents_read ON public.accepted_documents FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: physical_accounts account_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY account_read ON public.physical_accounts FOR SELECT TO authenticated USING (private.can_view_physical(id));


--
-- Name: accounts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: agreements; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.agreements ENABLE ROW LEVEL SECURITY;

--
-- Name: assets; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.assets ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: business_units; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.business_units ENABLE ROW LEVEL SECURITY;

--
-- Name: cancellation_requests; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.cancellation_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: cancellation_requests cancellation_requests_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY cancellation_requests_read ON public.cancellation_requests FOR SELECT TO authenticated USING (( SELECT private.can_access(cancellation_requests.unit_id) AS can_access));


--
-- Name: categories; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;

--
-- Name: collections; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.collections ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_flows; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.commercial_flows ENABLE ROW LEVEL SECURITY;

--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_acknowledgments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.delivery_acknowledgments ENABLE ROW LEVEL SECURITY;

--
-- Name: document_relations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.document_relations ENABLE ROW LEVEL SECURITY;

--
-- Name: documents; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

--
-- Name: expenses; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;

--
-- Name: inter_unit_transfers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.inter_unit_transfers ENABLE ROW LEVEL SECURITY;

--
-- Name: job_extensions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.job_extensions ENABLE ROW LEVEL SECURITY;

--
-- Name: job_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.job_items ENABLE ROW LEVEL SECURITY;

--
-- Name: job_items job_items_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY job_items_read ON public.job_items FOR SELECT TO authenticated USING (( SELECT private.can_access(job_items.unit_id) AS can_access));


--
-- Name: job_receipts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.job_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: jobs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: business_units member_units; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY member_units ON public.business_units FOR SELECT TO authenticated USING (private.can_access(id));


--
-- Name: memberships; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: mileage; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.mileage ENABLE ROW LEVEL SECURITY;

--
-- Name: monthly_closes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.monthly_closes ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: memberships own_memberships; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY own_memberships ON public.memberships FOR SELECT TO authenticated USING ((user_id = auth.uid()));


--
-- Name: owner_transactions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.owner_transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_requests; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.payment_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_requests payment_requests_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY payment_requests_read ON public.payment_requests FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: physical_accounts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.physical_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: pick_return_orders; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pick_return_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: pick_return_orders pick_return_orders_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pick_return_orders_read ON public.pick_return_orders FOR SELECT TO authenticated USING (( SELECT private.can_access(pick_return_orders.unit_id) AS can_access));


--
-- Name: pick_return_routes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pick_return_routes ENABLE ROW LEVEL SECURITY;

--
-- Name: pick_return_routes pick_return_routes_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pick_return_routes_read ON public.pick_return_routes FOR SELECT TO authenticated USING (( SELECT private.can_access(pick_return_routes.unit_id) AS can_access));


--
-- Name: pick_return_stops; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pick_return_stops ENABLE ROW LEVEL SECURITY;

--
-- Name: pick_return_stops pick_return_stops_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pick_return_stops_read ON public.pick_return_stops FOR SELECT TO authenticated USING (( SELECT private.can_access(pick_return_stops.unit_id) AS can_access));


--
-- Name: policies; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.policies ENABLE ROW LEVEL SECURITY;

--
-- Name: quote_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.quote_items ENABLE ROW LEVEL SECURITY;

--
-- Name: quotes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.quotes ENABLE ROW LEVEL SECURITY;

--
-- Name: refunds; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.refunds ENABLE ROW LEVEL SECURITY;

--
-- Name: reimbursements; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.reimbursements ENABLE ROW LEVEL SECURITY;

--
-- Name: sale_versions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sale_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: sales; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;

--
-- Name: categories shared_category_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY shared_category_read ON public.categories FOR SELECT TO authenticated USING (((unit_id IS NULL) AND (EXISTS ( SELECT 1
   FROM public.memberships
  WHERE (memberships.user_id = auth.uid())))));


--
-- Name: storage_folders; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.storage_folders ENABLE ROW LEVEL SECURITY;

--
-- Name: storage_folders storage_folders_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY storage_folders_read ON public.storage_folders FOR SELECT TO authenticated USING (( SELECT private.can_access(storage_folders.unit_id) AS can_access));


--
-- Name: delivery_acknowledgments tenant_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY tenant_read ON public.delivery_acknowledgments FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: job_extensions tenant_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY tenant_read ON public.job_extensions FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: job_receipts tenant_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY tenant_read ON public.job_receipts FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: transactions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: inter_unit_transfers transfer_destination; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY transfer_destination ON public.inter_unit_transfers FOR SELECT TO authenticated USING (private.can_access(destination_unit_id));


--
-- Name: transactions transfer_destination; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY transfer_destination ON public.transactions FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.inter_unit_transfers i
  WHERE ((i.transaction_id = transactions.id) AND private.can_access(i.destination_unit_id)))));


--
-- Name: accounts unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.accounts FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: agreements unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.agreements FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: assets unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.assets FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: audit_log unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.audit_log FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: categories unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.categories FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: collections unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.collections FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: commercial_flows unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.commercial_flows FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: customers unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.customers FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: document_relations unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.document_relations FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: documents unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.documents FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: expenses unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.expenses FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: inter_unit_transfers unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.inter_unit_transfers FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: jobs unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.jobs FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: mileage unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.mileage FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: monthly_closes unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.monthly_closes FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: notifications unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.notifications FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: owner_transactions unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.owner_transactions FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: policies unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.policies FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: quote_items unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.quote_items FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: quotes unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.quotes FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: refunds unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.refunds FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: reimbursements unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.reimbursements FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: sale_versions unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.sale_versions FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: sales unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.sales FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: transactions unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.transactions FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: unit_settings unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.unit_settings FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: vendors unit_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY unit_read ON public.vendors FOR SELECT TO authenticated USING (private.can_access(unit_id));


--
-- Name: unit_settings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.unit_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: vendors; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA private; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA private TO authenticated;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION audit_change(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.audit_change() FROM PUBLIC;


--
-- Name: FUNCTION can_access(u uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.can_access(u uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.can_access(u uuid) TO authenticated;


--
-- Name: FUNCTION can_view_physical(p_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.can_view_physical(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.can_view_physical(p_id uuid) TO authenticated;


--
-- Name: FUNCTION create_get_tagged_draft(p_receipt uuid, p_customer uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.create_get_tagged_draft(p_receipt uuid, p_customer uuid) FROM PUBLIC;


--
-- Name: FUNCTION create_job_status_portal(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.create_job_status_portal() FROM PUBLIC;


--
-- Name: FUNCTION ensure_job_status_link(p_job uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.ensure_job_status_link(p_job uuid) FROM PUBLIC;


--
-- Name: FUNCTION freeze_accepted_document(p_quote uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.freeze_accepted_document(p_quote uuid) FROM PUBLIC;


--
-- Name: FUNCTION get_tagged_phone(p text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.get_tagged_phone(p text) FROM PUBLIC;


--
-- Name: FUNCTION get_tagged_scope(p_items jsonb); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.get_tagged_scope(p_items jsonb) FROM PUBLIC;


--
-- Name: FUNCTION guard_get_tagged_review(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.guard_get_tagged_review() FROM PUBLIC;


--
-- Name: FUNCTION job_payment_snapshot(p_job uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.job_payment_snapshot(p_job uuid) FROM PUBLIC;


--
-- Name: FUNCTION job_portal_snapshot(p_job uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.job_portal_snapshot(p_job uuid) FROM PUBLIC;


--
-- Name: FUNCTION movement_integrity(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.movement_integrity() FROM PUBLIC;


--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.notifications TO service_role;
GRANT SELECT ON TABLE public.notifications TO authenticated;


--
-- Name: FUNCTION notification_mail(n public.notifications); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.notification_mail(n public.notifications) FROM PUBLIC;


--
-- Name: FUNCTION notification_mail_base(n public.notifications); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.notification_mail_base(n public.notifications) FROM PUBLIC;


--
-- Name: FUNCTION notify_customer_stage_change(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.notify_customer_stage_change() FROM PUBLIC;


--
-- Name: FUNCTION notify_get_tagged_request(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.notify_get_tagged_request() FROM PUBLIC;


--
-- Name: FUNCTION owner_integrity(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.owner_integrity() FROM PUBLIC;


--
-- Name: FUNCTION priced_scope(p_items jsonb); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.priced_scope(p_items jsonb) FROM PUBLIC;


--
-- Name: FUNCTION protect_destination_close(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.protect_destination_close() FROM PUBLIC;


--
-- Name: FUNCTION receipt_after_collection(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.receipt_after_collection() FROM PUBLIC;


--
-- Name: FUNCTION record_movement(p jsonb); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.record_movement(p jsonb) FROM PUBLIC;


--
-- Name: FUNCTION require_admin(u uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.require_admin(u uuid) FROM PUBLIC;


--
-- Name: FUNCTION store_get_tagged_items(p_quote uuid, p_scope jsonb); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.store_get_tagged_items(p_quote uuid, p_scope jsonb) FROM PUBLIC;


--
-- Name: FUNCTION sync_customer_stage(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.sync_customer_stage() FROM PUBLIC;


--
-- Name: FUNCTION sync_payment_work_stage(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.sync_payment_work_stage() FROM PUBLIC;


--
-- Name: FUNCTION transaction_guard(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.transaction_guard() FROM PUBLIC;


--
-- Name: FUNCTION transfer_correction_close(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.transfer_correction_close() FROM PUBLIC;


--
-- Name: FUNCTION accept_agreement(p_token text, p_name text, p_email text, p_phone text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.accept_agreement(p_token text, p_name text, p_email text, p_phone text) FROM PUBLIC;


--
-- Name: FUNCTION accept_quote(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.accept_quote(p_token text) FROM PUBLIC;


--
-- Name: FUNCTION accept_review(p_token text, p_quote_confirmed boolean, p_agreement_confirmed boolean, p_name text, p_email text, p_phone text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.accept_review(p_token text, p_quote_confirmed boolean, p_agreement_confirmed boolean, p_name text, p_email text, p_phone text) TO anon;
GRANT ALL ON FUNCTION public.accept_review(p_token text, p_quote_confirmed boolean, p_agreement_confirmed boolean, p_name text, p_email text, p_phone text) TO authenticated;


--
-- Name: FUNCTION accepted_pdf_file(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.accepted_pdf_file(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.accepted_pdf_file(p_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.accepted_pdf_file(p_id uuid) TO service_role;


--
-- Name: FUNCTION activate_customer_mail(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.activate_customer_mail() FROM PUBLIC;
GRANT ALL ON FUNCTION public.activate_customer_mail() TO authenticated;


--
-- Name: FUNCTION add_document(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.add_document(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_document(p jsonb) TO authenticated;


--
-- Name: FUNCTION advance_job(p_id uuid, p_action text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.advance_job(p_id uuid, p_action text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.advance_job(p_id uuid, p_action text) TO authenticated;


--
-- Name: FUNCTION advance_job_item(p_item uuid, p_action text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.advance_job_item(p_item uuid, p_action text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.advance_job_item(p_item uuid, p_action text) TO authenticated;


--
-- Name: FUNCTION advance_pick_return_stop(p_stop uuid, p_action text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.advance_pick_return_stop(p_stop uuid, p_action text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.advance_pick_return_stop(p_stop uuid, p_action text) TO authenticated;


--
-- Name: FUNCTION approve_get_tagged(p_id uuid, p_customer uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.approve_get_tagged(p_id uuid, p_customer uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.approve_get_tagged(p_id uuid, p_customer uuid) TO authenticated;


--
-- Name: FUNCTION authorize_document_live_copies(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.authorize_document_live_copies(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.authorize_document_live_copies(p_id uuid) TO authenticated;


--
-- Name: FUNCTION cancel_job_extension(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.cancel_job_extension(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancel_job_extension(p_id uuid) TO authenticated;


--
-- Name: FUNCTION cancellation_access(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.cancellation_access(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancellation_access(p_token text) TO anon;
GRANT ALL ON FUNCTION public.cancellation_access(p_token text) TO authenticated;


--
-- Name: FUNCTION claim_accepted_copy(p_id uuid, p_copy text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.claim_accepted_copy(p_id uuid, p_copy text) FROM PUBLIC;


--
-- Name: FUNCTION claim_accepted_pdf(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.claim_accepted_pdf(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_accepted_pdf(p_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.claim_accepted_pdf(p_id uuid) TO service_role;


--
-- Name: FUNCTION claim_document_copy(p_id uuid, p_copy text, p_mode text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.claim_document_copy(p_id uuid, p_copy text, p_mode text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_document_copy(p_id uuid, p_copy text, p_mode text) TO authenticated;
GRANT ALL ON FUNCTION public.claim_document_copy(p_id uuid, p_copy text, p_mode text) TO service_role;


--
-- Name: FUNCTION claim_get_tagged_mail(p_id uuid, p_recipient text, p_mode text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.claim_get_tagged_mail(p_id uuid, p_recipient text, p_mode text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_get_tagged_mail(p_id uuid, p_recipient text, p_mode text) TO service_role;


--
-- Name: FUNCTION claim_mail_for_mode(p_quote uuid, p_test_recipient text, p_mode text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.claim_mail_for_mode(p_quote uuid, p_test_recipient text, p_mode text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_mail_for_mode(p_quote uuid, p_test_recipient text, p_mode text) TO authenticated;
GRANT ALL ON FUNCTION public.claim_mail_for_mode(p_quote uuid, p_test_recipient text, p_mode text) TO service_role;


--
-- Name: FUNCTION claim_quote_mail(p_quote uuid, p_test_recipient text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.claim_quote_mail(p_quote uuid, p_test_recipient text) FROM PUBLIC;


--
-- Name: FUNCTION close_month(p_unit uuid, p_month date); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.close_month(p_unit uuid, p_month date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.close_month(p_unit uuid, p_month date) TO authenticated;


--
-- Name: FUNCTION complete_job_production(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.complete_job_production(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_job_production(p_id uuid) TO authenticated;


--
-- Name: FUNCTION confirm_cancellation_refund(p_request uuid, p_method text, p_reference text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.confirm_cancellation_refund(p_request uuid, p_method text, p_reference text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_cancellation_refund(p_request uuid, p_method text, p_reference text) TO authenticated;


--
-- Name: FUNCTION confirm_completion_notified(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.confirm_completion_notified(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_completion_notified(p_id uuid) TO authenticated;


--
-- Name: FUNCTION confirm_payment_request(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.confirm_payment_request(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_payment_request(p_id uuid) TO authenticated;


--
-- Name: FUNCTION create_asset(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.create_asset(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_asset(p jsonb) TO authenticated;


--
-- Name: FUNCTION create_quote(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.create_quote(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_quote(p jsonb) TO authenticated;


--
-- Name: FUNCTION customer_mail_status(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.customer_mail_status() FROM PUBLIC;
GRANT ALL ON FUNCTION public.customer_mail_status() TO authenticated;


--
-- Name: FUNCTION customer_stats(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.customer_stats(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.customer_stats(p_id uuid) TO authenticated;


--
-- Name: FUNCTION dashboard_stats(p_unit uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.dashboard_stats(p_unit uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dashboard_stats(p_unit uuid) TO authenticated;


--
-- Name: FUNCTION finish_accepted_pdf(p_id uuid, p_claim uuid, p_pdf text, p_error text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.finish_accepted_pdf(p_id uuid, p_claim uuid, p_pdf text, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_accepted_pdf(p_id uuid, p_claim uuid, p_pdf text, p_error text) TO authenticated;
GRANT ALL ON FUNCTION public.finish_accepted_pdf(p_id uuid, p_claim uuid, p_pdf text, p_error text) TO service_role;


--
-- Name: FUNCTION finish_get_tagged_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.finish_get_tagged_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_get_tagged_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text) TO service_role;


--
-- Name: FUNCTION finish_quote_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.finish_quote_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_quote_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text) TO authenticated;
GRANT ALL ON FUNCTION public.finish_quote_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text) TO service_role;


--
-- Name: FUNCTION generate_job_receipt(p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.generate_job_receipt(p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.generate_job_receipt(p_job uuid) TO authenticated;
GRANT ALL ON FUNCTION public.generate_job_receipt(p_job uuid) TO service_role;


--
-- Name: FUNCTION get_get_tagged_request(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_get_tagged_request(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_get_tagged_request(p_id uuid) TO authenticated;


--
-- Name: FUNCTION get_tagged_attention(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_tagged_attention() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_tagged_attention() TO authenticated;


--
-- Name: FUNCTION get_tagged_pending_count(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_tagged_pending_count() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_tagged_pending_count() TO authenticated;


--
-- Name: FUNCTION job_customer_status(p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.job_customer_status(p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.job_customer_status(p_job uuid) TO authenticated;


--
-- Name: FUNCTION job_lifecycle(p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.job_lifecycle(p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.job_lifecycle(p_job uuid) TO authenticated;


--
-- Name: FUNCTION pending_accepted_documents(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.pending_accepted_documents() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pending_accepted_documents() TO service_role;


--
-- Name: FUNCTION prepare_existing_accepted_document(p_quote uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prepare_existing_accepted_document(p_quote uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prepare_existing_accepted_document(p_quote uuid) TO authenticated;


--
-- Name: FUNCTION public_cancel_quote(p_token text, p_quote uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_cancel_quote(p_token text, p_quote uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_cancel_quote(p_token text, p_quote uuid) TO anon;
GRANT ALL ON FUNCTION public.public_cancel_quote(p_token text, p_quote uuid) TO authenticated;


--
-- Name: FUNCTION public_cancellation_assessment(p_token text, p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_cancellation_assessment(p_token text, p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_cancellation_assessment(p_token text, p_job uuid) TO anon;
GRANT ALL ON FUNCTION public.public_cancellation_assessment(p_token text, p_job uuid) TO authenticated;


--
-- Name: FUNCTION public_completion(p_token text, p_decision text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_completion(p_token text, p_decision text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_completion(p_token text, p_decision text) TO anon;
GRANT ALL ON FUNCTION public.public_completion(p_token text, p_decision text) TO authenticated;


--
-- Name: FUNCTION public_confirm_job_cancellation(p_token text, p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_confirm_job_cancellation(p_token text, p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_confirm_job_cancellation(p_token text, p_job uuid) TO anon;
GRANT ALL ON FUNCTION public.public_confirm_job_cancellation(p_token text, p_job uuid) TO authenticated;


--
-- Name: FUNCTION public_extension(p_token text, p_accept boolean, p_name text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_extension(p_token text, p_accept boolean, p_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_extension(p_token text, p_accept boolean, p_name text) TO anon;
GRANT ALL ON FUNCTION public.public_extension(p_token text, p_accept boolean, p_name text) TO authenticated;


--
-- Name: FUNCTION public_job_document(p_token text, p_document uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_job_document(p_token text, p_document uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_job_document(p_token text, p_document uuid) TO anon;
GRANT ALL ON FUNCTION public.public_job_document(p_token text, p_document uuid) TO authenticated;


--
-- Name: FUNCTION public_job_documents(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_job_documents(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_job_documents(p_token text) TO anon;
GRANT ALL ON FUNCTION public.public_job_documents(p_token text) TO authenticated;


--
-- Name: FUNCTION public_job_status(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_job_status(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_job_status(p_token text) TO anon;
GRANT ALL ON FUNCTION public.public_job_status(p_token text) TO authenticated;


--
-- Name: FUNCTION public_pickup_fee(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_pickup_fee(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_pickup_fee(p_token text) TO anon;
GRANT ALL ON FUNCTION public.public_pickup_fee(p_token text) TO authenticated;


--
-- Name: FUNCTION public_quote(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_quote(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_quote(p_token text) TO anon;
GRANT ALL ON FUNCTION public.public_quote(p_token text) TO authenticated;


--
-- Name: FUNCTION public_request_status(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_request_status(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_request_status(p_token text) TO anon;
GRANT ALL ON FUNCTION public.public_request_status(p_token text) TO authenticated;


--
-- Name: FUNCTION public_status_cancellation_assessment(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_status_cancellation_assessment(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_status_cancellation_assessment(p_token text) TO anon;
GRANT ALL ON FUNCTION public.public_status_cancellation_assessment(p_token text) TO authenticated;


--
-- Name: FUNCTION public_status_cancellation_finance(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_status_cancellation_finance(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_status_cancellation_finance(p_token text) TO anon;
GRANT ALL ON FUNCTION public.public_status_cancellation_finance(p_token text) TO authenticated;


--
-- Name: FUNCTION public_status_confirm_cancellation(p_token text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_status_confirm_cancellation(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_status_confirm_cancellation(p_token text) TO anon;
GRANT ALL ON FUNCTION public.public_status_confirm_cancellation(p_token text) TO authenticated;


--
-- Name: FUNCTION public_status_submit_cancellation_payment(p_token text, p_request uuid, p_method text, p_proof_path text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_status_submit_cancellation_payment(p_token text, p_request uuid, p_method text, p_proof_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_status_submit_cancellation_payment(p_token text, p_request uuid, p_method text, p_proof_path text) TO anon;
GRANT ALL ON FUNCTION public.public_status_submit_cancellation_payment(p_token text, p_request uuid, p_method text, p_proof_path text) TO authenticated;


--
-- Name: FUNCTION public_submit_payment_request(p_token text, p_request uuid, p_method text, p_proof_path text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_submit_payment_request(p_token text, p_request uuid, p_method text, p_proof_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_submit_payment_request(p_token text, p_request uuid, p_method text, p_proof_path text) TO anon;
GRANT ALL ON FUNCTION public.public_submit_payment_request(p_token text, p_request uuid, p_method text, p_proof_path text) TO authenticated;


--
-- Name: FUNCTION public_submit_pickup_fee_payment(p_token text, p_request uuid, p_method text, p_proof_path text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_submit_pickup_fee_payment(p_token text, p_request uuid, p_method text, p_proof_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_submit_pickup_fee_payment(p_token text, p_request uuid, p_method text, p_proof_path text) TO anon;
GRANT ALL ON FUNCTION public.public_submit_pickup_fee_payment(p_token text, p_request uuid, p_method text, p_proof_path text) TO authenticated;


--
-- Name: FUNCTION public_work_review(p_token text, p_response text, p_request text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.public_work_review(p_token text, p_response text, p_request text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_work_review(p_token text, p_response text, p_request text) TO anon;
GRANT ALL ON FUNCTION public.public_work_review(p_token text, p_response text, p_request text) TO authenticated;


--
-- Name: FUNCTION publish_policy(p_unit uuid, p_title text, p_content text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.publish_policy(p_unit uuid, p_title text, p_content text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_policy(p_unit uuid, p_title text, p_content text) TO authenticated;


--
-- Name: FUNCTION quote_delivery(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.quote_delivery(p_id uuid) TO authenticated;


--
-- Name: FUNCTION record_mileage(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.record_mileage(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_mileage(p jsonb) TO authenticated;


--
-- Name: FUNCTION record_movement(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.record_movement(p jsonb) TO authenticated;


--
-- Name: FUNCTION regenerate_quote_link(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.regenerate_quote_link(p_id uuid) TO authenticated;


--
-- Name: FUNCTION register_document_metadata(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.register_document_metadata(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.register_document_metadata(p jsonb) TO authenticated;


--
-- Name: FUNCTION reject_get_tagged(p_id uuid, p_reason text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reject_get_tagged(p_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reject_get_tagged(p_id uuid, p_reason text) TO authenticated;


--
-- Name: FUNCTION request_cancellation_access(p_network text, p_name text, p_email text, p_phone text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.request_cancellation_access(p_network text, p_name text, p_email text, p_phone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.request_cancellation_access(p_network text, p_name text, p_email text, p_phone text) TO service_role;


--
-- Name: FUNCTION request_job_cancellation(p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.request_job_cancellation(p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.request_job_cancellation(p_job uuid) TO authenticated;


--
-- Name: FUNCTION request_job_extension(p_job uuid, p_request text, p_key uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.request_job_extension(p_job uuid, p_request text, p_key uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.request_job_extension(p_job uuid, p_request text, p_key uuid) TO authenticated;


--
-- Name: FUNCTION resend_quote(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.resend_quote(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resend_quote(p_id uuid) TO authenticated;


--
-- Name: FUNCTION resolve_get_tagged(p_id uuid, p_customer uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.resolve_get_tagged(p_id uuid, p_customer uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_get_tagged(p_id uuid, p_customer uuid) TO authenticated;


--
-- Name: FUNCTION retry_accepted_document(p_id uuid, p_part text, p_reconciled boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.retry_accepted_document(p_id uuid, p_part text, p_reconciled boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.retry_accepted_document(p_id uuid, p_part text, p_reconciled boolean) TO authenticated;
GRANT ALL ON FUNCTION public.retry_accepted_document(p_id uuid, p_part text, p_reconciled boolean) TO service_role;


--
-- Name: FUNCTION retry_customer_notification(p_id uuid, p_reconciled boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.retry_customer_notification(p_id uuid, p_reconciled boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.retry_customer_notification(p_id uuid, p_reconciled boolean) TO authenticated;


--
-- Name: FUNCTION review_get_tagged_quote(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.review_get_tagged_quote(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.review_get_tagged_quote(p jsonb) TO authenticated;


--
-- Name: FUNCTION rls_auto_enable(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC;


--
-- Name: FUNCTION run_scheduled_tasks(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.run_scheduled_tasks() FROM PUBLIC;
GRANT ALL ON FUNCTION public.run_scheduled_tasks() TO service_role;


--
-- Name: FUNCTION save_category(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.save_category(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_category(p jsonb) TO authenticated;


--
-- Name: FUNCTION save_customer(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.save_customer(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_customer(p jsonb) TO authenticated;


--
-- Name: FUNCTION save_job_extension(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.save_job_extension(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_job_extension(p jsonb) TO authenticated;


--
-- Name: FUNCTION save_settings(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.save_settings(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_settings(p jsonb) TO authenticated;


--
-- Name: FUNCTION schedule_pick_return(p_job uuid, p_leg text, p_window_start timestamp with time zone, p_window_end timestamp with time zone, p_eta timestamp with time zone); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.schedule_pick_return(p_job uuid, p_leg text, p_window_start timestamp with time zone, p_window_end timestamp with time zone, p_eta timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.schedule_pick_return(p_job uuid, p_leg text, p_window_start timestamp with time zone, p_window_end timestamp with time zone, p_eta timestamp with time zone) TO authenticated;


--
-- Name: FUNCTION search_records(p_unit uuid, p_query text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_records(p_unit uuid, p_query text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_records(p_unit uuid, p_query text) TO authenticated;


--
-- Name: FUNCTION send_job_extension(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.send_job_extension(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.send_job_extension(p_id uuid) TO authenticated;


--
-- Name: FUNCTION send_quote(p_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.send_quote(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.send_quote(p_id uuid) TO authenticated;


--
-- Name: FUNCTION send_quote_to(p_id uuid, p_recipient text, p_regenerate boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.send_quote_to(p_id uuid, p_recipient text, p_regenerate boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.send_quote_to(p_id uuid, p_recipient text, p_regenerate boolean) TO authenticated;


--
-- Name: FUNCTION set_job_customer_stage(p_job uuid, p_stage text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_job_customer_stage(p_job uuid, p_stage text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_job_customer_stage(p_job uuid, p_stage text) TO authenticated;


--
-- Name: FUNCTION submit_get_tagged(p_key uuid, p_network text, p_payload jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.submit_get_tagged(p_key uuid, p_network text, p_payload jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_get_tagged(p_key uuid, p_network text, p_payload jsonb) TO service_role;


--
-- Name: FUNCTION submit_get_tagged_v2(p_key uuid, p_network text, p_payload jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.submit_get_tagged_v2(p_key uuid, p_network text, p_payload jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_get_tagged_v2(p_key uuid, p_network text, p_payload jsonb) TO service_role;


--
-- Name: FUNCTION update_document_evidence_metadata(p_document uuid, p_metadata jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.update_document_evidence_metadata(p_document uuid, p_metadata jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_document_evidence_metadata(p_document uuid, p_metadata jsonb) TO authenticated;


--
-- Name: FUNCTION update_transaction(p jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.update_transaction(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_transaction(p jsonb) TO authenticated;


--
-- Name: FUNCTION vehicle_report(p_unit uuid, p_year integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.vehicle_report(p_unit uuid, p_year integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.vehicle_report(p_unit uuid, p_year integer) TO authenticated;


--
-- Name: TABLE accepted_document_status; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.accepted_document_status TO service_role;
GRANT SELECT ON TABLE public.accepted_document_status TO authenticated;


--
-- Name: TABLE accepted_documents; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.accepted_documents TO service_role;
GRANT SELECT ON TABLE public.accepted_documents TO authenticated;


--
-- Name: TABLE accounts; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.accounts TO service_role;
GRANT SELECT ON TABLE public.accounts TO authenticated;


--
-- Name: TABLE agreements; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.agreements TO service_role;
GRANT SELECT ON TABLE public.agreements TO authenticated;


--
-- Name: TABLE assets; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.assets TO service_role;
GRANT SELECT ON TABLE public.assets TO authenticated;


--
-- Name: TABLE transactions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.transactions TO service_role;
GRANT SELECT ON TABLE public.transactions TO authenticated;


--
-- Name: TABLE asset_details; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.asset_details TO service_role;
GRANT SELECT ON TABLE public.asset_details TO authenticated;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.audit_log TO service_role;
GRANT SELECT ON TABLE public.audit_log TO authenticated;


--
-- Name: TABLE business_units; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.business_units TO service_role;
GRANT SELECT ON TABLE public.business_units TO authenticated;


--
-- Name: TABLE cancellation_requests; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.cancellation_requests TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.cancellation_requests TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.cancellation_requests TO service_role;


--
-- Name: TABLE categories; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.categories TO service_role;
GRANT SELECT ON TABLE public.categories TO authenticated;


--
-- Name: TABLE collections; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.collections TO service_role;
GRANT SELECT ON TABLE public.collections TO authenticated;


--
-- Name: TABLE commercial_flows; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.commercial_flows TO service_role;
GRANT SELECT ON TABLE public.commercial_flows TO authenticated;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.customers TO service_role;
GRANT SELECT ON TABLE public.customers TO authenticated;


--
-- Name: TABLE delivery_acknowledgments; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.delivery_acknowledgments TO service_role;
GRANT SELECT ON TABLE public.delivery_acknowledgments TO authenticated;


--
-- Name: TABLE document_relations; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.document_relations TO service_role;
GRANT SELECT ON TABLE public.document_relations TO authenticated;


--
-- Name: TABLE documents; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.documents TO service_role;
GRANT SELECT ON TABLE public.documents TO authenticated;


--
-- Name: TABLE expenses; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.expenses TO service_role;
GRANT SELECT ON TABLE public.expenses TO authenticated;


--
-- Name: TABLE refunds; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.refunds TO service_role;
GRANT SELECT ON TABLE public.refunds TO authenticated;


--
-- Name: TABLE reimbursements; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.reimbursements TO service_role;
GRANT SELECT ON TABLE public.reimbursements TO authenticated;


--
-- Name: TABLE expense_details; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.expense_details TO service_role;
GRANT SELECT ON TABLE public.expense_details TO authenticated;


--
-- Name: TABLE inter_unit_transfers; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.inter_unit_transfers TO service_role;
GRANT SELECT ON TABLE public.inter_unit_transfers TO authenticated;


--
-- Name: TABLE financial_effects; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.financial_effects TO service_role;
GRANT SELECT ON TABLE public.financial_effects TO authenticated;


--
-- Name: TABLE finance_summary; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.finance_summary TO service_role;
GRANT SELECT ON TABLE public.finance_summary TO authenticated;


--
-- Name: TABLE job_extensions; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_extensions TO service_role;
GRANT SELECT ON TABLE public.job_extensions TO authenticated;


--
-- Name: TABLE jobs; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.jobs TO service_role;
GRANT SELECT ON TABLE public.jobs TO authenticated;


--
-- Name: TABLE sales; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sales TO service_role;
GRANT SELECT ON TABLE public.sales TO authenticated;


--
-- Name: TABLE sale_balances; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sale_balances TO service_role;
GRANT SELECT ON TABLE public.sale_balances TO authenticated;


--
-- Name: TABLE job_commercial_totals; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_commercial_totals TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_commercial_totals TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_commercial_totals TO service_role;


--
-- Name: TABLE job_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_items TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_items TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_items TO service_role;


--
-- Name: TABLE job_receipts; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_receipts TO service_role;
GRANT SELECT ON TABLE public.job_receipts TO authenticated;


--
-- Name: TABLE memberships; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.memberships TO service_role;
GRANT SELECT ON TABLE public.memberships TO authenticated;


--
-- Name: TABLE mileage; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.mileage TO service_role;
GRANT SELECT ON TABLE public.mileage TO authenticated;


--
-- Name: TABLE monthly_closes; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.monthly_closes TO service_role;
GRANT SELECT ON TABLE public.monthly_closes TO authenticated;


--
-- Name: TABLE owner_transactions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.owner_transactions TO service_role;
GRANT SELECT ON TABLE public.owner_transactions TO authenticated;


--
-- Name: TABLE payment_requests; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.payment_requests TO service_role;
GRANT SELECT ON TABLE public.payment_requests TO authenticated;


--
-- Name: TABLE physical_accounts; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.physical_accounts TO service_role;
GRANT SELECT ON TABLE public.physical_accounts TO authenticated;


--
-- Name: TABLE pick_return_orders; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_orders TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_orders TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_orders TO service_role;


--
-- Name: TABLE pick_return_routes; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_routes TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_routes TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_routes TO service_role;


--
-- Name: TABLE pick_return_stops; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_stops TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_stops TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pick_return_stops TO service_role;


--
-- Name: TABLE policies; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.policies TO service_role;
GRANT SELECT ON TABLE public.policies TO authenticated;


--
-- Name: TABLE quote_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.quote_items TO service_role;
GRANT SELECT ON TABLE public.quote_items TO authenticated;


--
-- Name: TABLE quotes; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.quotes TO service_role;
GRANT SELECT ON TABLE public.quotes TO authenticated;


--
-- Name: TABLE recent_activity; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.recent_activity TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.recent_activity TO service_role;


--
-- Name: TABLE review_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.review_items TO service_role;
GRANT SELECT ON TABLE public.review_items TO authenticated;


--
-- Name: TABLE sale_versions; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.sale_versions TO service_role;
GRANT SELECT ON TABLE public.sale_versions TO authenticated;


--
-- Name: TABLE storage_folders; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.storage_folders TO service_role;
GRANT SELECT ON TABLE public.storage_folders TO authenticated;


--
-- Name: TABLE unit_settings; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.unit_settings TO service_role;
GRANT SELECT ON TABLE public.unit_settings TO authenticated;


--
-- Name: TABLE vendors; Type: ACL; Schema: public; Owner: postgres
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.vendors TO service_role;
GRANT SELECT ON TABLE public.vendors TO authenticated;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--


--
-- Name: objects payment_proofs_admin_read; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY payment_proofs_admin_read ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'payment-proofs'::text) AND ((storage.foldername(name))[1] = '10000000-0000-0000-0000-000000000002'::text) AND (EXISTS ( SELECT 1
   FROM public.memberships
  WHERE ((memberships.user_id = auth.uid()) AND (memberships.unit_id = '10000000-0000-0000-0000-000000000002'::uuid) AND (memberships.role = 'admin'::text))))));


--
-- PostgreSQL database dump
--


-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11 (Postgres.app)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: business_units; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.business_units (id, code, name) FROM stdin;
10000000-0000-0000-0000-000000000001	BOFT	Bandits of the Framing
10000000-0000-0000-0000-000000000002	TOOLTAG	ToolTag
\.


--
-- Data for Name: physical_accounts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.physical_accounts (id, name, currency, reconciled_balance, reconciled_at, created_at) FROM stdin;
20000000-0000-0000-0000-000000000001	BOFT Business Checking	USD	\N	\N	2026-10-03 03:12:56.35233+00
\.


--
-- Data for Name: accounts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.accounts (id, unit_id, physical_account_id, name, active) FROM stdin;
514d86cd-51b9-4705-aa84-0f0ec9c7a238	10000000-0000-0000-0000-000000000001	20000000-0000-0000-0000-000000000001	BOFT Operating Account	t
e40d0194-b133-4613-8961-95c78ef46522	10000000-0000-0000-0000-000000000002	20000000-0000-0000-0000-000000000001	ToolTag Operating Account	t
\.


--
-- Data for Name: categories; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.categories (id, unit_id, name, kind, active, is_equipment, is_fuel, is_mileage) FROM stdin;
3dc69ea9-f614-40f9-93b8-4d21ae2e431a	10000000-0000-0000-0000-000000000002	Engraving Services	income	t	f	f	f
36b34f1a-2e64-4488-bbfe-c25ae90af53d	10000000-0000-0000-0000-000000000002	Custom Parts Sales	income	t	f	f	f
2a608f20-16c8-462b-9e4b-37ff99f1ba02	10000000-0000-0000-0000-000000000002	On-Site / Travel Fee	income	t	f	f	f
8e216867-cf47-4bd3-8a40-64f638233eea	10000000-0000-0000-0000-000000000002	Other Revenue	income	t	f	f	f
8999a4c1-88fd-4149-8c6a-29726fc9e8f7	10000000-0000-0000-0000-000000000002	Materials & Supplies	expense	t	f	f	f
70c22659-c09d-473c-b70f-026ff2633f2f	10000000-0000-0000-0000-000000000002	Packaging & Shipping	expense	t	f	f	f
89a1c751-05c8-4585-aa5e-be974f66a453	10000000-0000-0000-0000-000000000002	Fuel	expense	t	f	t	f
16d344a3-b9ff-48ac-8c21-5600562451db	10000000-0000-0000-0000-000000000002	Travel / Mileage	expense	t	f	f	t
49dd6e2e-f47a-43a5-92fc-a0d4864cf9c1	10000000-0000-0000-0000-000000000002	Marketing & Advertising	expense	t	f	f	f
27bc496f-b344-4134-87fd-ff58aeda6a5d	10000000-0000-0000-0000-000000000002	Software & Subscriptions	expense	t	f	f	f
e55c2dd5-0241-4a9b-aa0f-050c8f94ed91	10000000-0000-0000-0000-000000000002	Payment Processing Fees	expense	t	f	f	f
686185d9-9536-4dfe-9929-d02706667365	10000000-0000-0000-0000-000000000002	Office / Admin	expense	t	f	f	f
435db9bd-dd5c-4c93-b891-11551dd4cbc4	10000000-0000-0000-0000-000000000002	Repairs & Maintenance	expense	t	f	f	f
331d969e-f23e-471b-bdc4-c7a5647a41e6	10000000-0000-0000-0000-000000000002	Equipment / Asset Purchase	expense	t	t	f	f
26c45060-c196-43e8-85c5-8c17489c4943	10000000-0000-0000-0000-000000000002	Other Expense	expense	t	f	f	f
6060a2e7-0afe-477c-b840-f978f09600f7	10000000-0000-0000-0000-000000000002	Laser Equipment	asset	t	f	f	f
04df19f9-2df7-419c-b60c-9f66913c92e3	10000000-0000-0000-0000-000000000002	Laser Accessories	asset	t	f	f	f
5deb2a43-c92c-4083-ab72-673ba823e943	10000000-0000-0000-0000-000000000002	Computer / Electronics	asset	t	f	f	f
efbe1b9c-2a34-4d81-b37d-2552017794e2	10000000-0000-0000-0000-000000000002	Tools & Shop Equipment	asset	t	f	f	f
544a3dc6-1a50-4499-823c-df1edfac5126	10000000-0000-0000-0000-000000000002	Furniture / Workspace	asset	t	f	f	f
ffb64e23-74d5-4600-8eee-68c9358df31d	10000000-0000-0000-0000-000000000002	Other Equipment	asset	t	f	f	f
\.


--
-- Data for Name: policies; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.policies (id, unit_id, version, title, content, published_at, created_at) FROM stdin;
b6a02e2d-7d06-48da-b5a4-a471b2fe1cc4	10000000-0000-0000-0000-000000000002	1	ToolTag Customer Agreement & Custom Engraving Terms v1.0	ToolTag Customer Agreement & Custom Engraving Terms\r\nBy accepting this Agreement, the customer confirms that they have reviewed and approved the related ToolTag quote, including the items, quantities, engraving content, logos or artwork, engraving locations, dimensions, orientation, colors, paint-fill instructions, pricing, and other specifications shown in the accepted quote.\r\nThe accepted quote and this Agreement together define the approved scope of work.\r\n1. Customer Approval of Quote and Engraving Details\r\nBefore accepting, the customer is responsible for reviewing all names, spelling, wording, numbers, logos, artwork, placement, engraving locations, dimensions, orientation, quantities, colors, paint-fill selections, and other instructions shown in the quote.\r\nToolTag is not responsible for errors that were submitted, supplied, or approved by the customer.\r\nOnce work begins, changes to the approved scope may require a revised quote, additional charges, and new approval.\r\n2. Custom Work and Refundability\r\nEngraved, personalized, modified, or otherwise customized items are generally non-refundable once work has begun.\r\nBecause custom work is produced specifically for the customer, a change of mind after engraving or customization has started does not create an automatic right to a refund.\r\nThis does not limit remedies for an error or qualifying damage directly caused by ToolTag.\r\n3. ToolTag Errors or Workmanship Issues\r\nIf ToolTag makes an error that does not match the approved quote or directly causes a qualifying workmanship issue, ToolTag may, depending on the circumstances:\r\n- Rework or correct the item\r\n- Replace the affected item\r\n- Issue a partial refund\r\n- Issue a full refund for the affected item or service\r\nThe appropriate remedy will depend on the nature of the issue, the item involved, availability of replacement parts or products, and whether correction is reasonably possible.\r\n4. Issue and Refund Request Window\r\nCustomers should notify ToolTag of engraving-related errors, workmanship issues, or qualifying damage as soon as reasonably possible and normally within 14 calendar days after pickup, delivery, or completion notice.\r\nRequests received after 14 calendar days may be reviewed at ToolTag’s discretion unless applicable law requires otherwise.\r\n5. Three-Day Completion Review\r\nAfter ToolTag sends notice that the work has been completed or delivered, the customer has 3 calendar days to review the completed work and report any immediately apparent issue related to the approved scope.\r\nIf the customer does not respond during that period, ToolTag may administratively close the Job as:\r\nCompleted – Deemed Accepted per Agreement\r\nThis administrative closure does not represent a false record of express customer acceptance and does not eliminate rights or remedies that cannot legally be waived.\r\nIt also does not automatically eliminate an otherwise eligible claim submitted within the applicable 14-day review period.\r\n6. Customer-Supplied Items\r\nWhen the customer provides an item for engraving or customization, the customer is responsible for determining whether the item is suitable for the requested work.\r\nMaterials, coatings, plastics, finishes, paints, adhesives, electronics, and manufacturing methods can respond differently to engraving processes.\r\nToolTag does not guarantee replacement of a customer-supplied item unless available evidence reasonably indicates that ToolTag directly caused substantial damage beyond the intended engraving or customization process.\r\n7. Electronic and Electrical Tools, Batteries, and Chargers\r\nToolTag may engrave or customize tools, batteries, chargers, and other items containing electronic or electrical components.\r\nUnless specifically agreed otherwise, ToolTag is not required to perform functional testing before or after engraving.\r\nAcceptance of an item by ToolTag does not certify that the item was functioning before service, and return or delivery of the item does not certify that it is functioning afterward.\r\nToolTag is not responsible for a later electrical, battery, charging, motor, control-board, internal-component, or similar failure unless available evidence reasonably shows that ToolTag directly intervened with or damaged the relevant component.\r\n8. Damage Beyond Intended Engraving\r\nIf ToolTag’s process penetrates, burns, cuts, melts, or otherwise damages an item substantially beyond the intended engraving surface or depth, and the damage is reasonably determined to have been directly caused by ToolTag, ToolTag may provide an appropriate remedy, including replacement when warranted.\r\n9. Replacement Items\r\nWhen replacement is determined to be the appropriate remedy, estimated replacement time may be approximately 45–60 days, depending on manufacturer, model, vendor, inventory, shipping, and availability.\r\nA replacement may be a reasonably equivalent item or component and is not required to be an upgrade, a higher-value product, or a brand-new item when an equivalent replacement is otherwise reasonable.\r\n10. Paint Fill, Color, and Cosmetic Finishes\r\nEngraving and applied color are separate components of the finished work.\r\nToolTag does not guarantee that paint fill, ink, coating, or applied color will remain permanent for the life of the item.\r\nColor may fade, scratch, chip, wear, discolor, or deteriorate from normal use, friction, impacts, heat, sunlight or UV exposure, oils, grease, chemicals, cleaners, alcohol, solvents, moisture, or other environmental conditions.\r\nNormal wear of applied color does not automatically constitute defective engraving or create an automatic right to a refund.\r\nToolTag may offer touch-up or refinishing when appropriate.\r\n11. Natural Material and Finish Variations\r\nDifferences in plastic composition, coating thickness, anodizing, paint, texture, surface condition, prior wear, manufacturing batches, and similar material characteristics may cause variations in engraving color, depth, contrast, texture, or appearance.\r\nReasonable variations that do not materially depart from the approved design are not considered defects.\r\n12. Photographic Documentation\r\nToolTag may photograph items before work begins and after work is completed.\r\nThese photographs may be used to document the physical condition of the item, engraving location, approved work, completed result, and any later issue or claim.\r\nReceiving and completion photographs are intended as business records and evidence of exterior condition; they do not constitute functional testing of electronic or mechanical components.\r\n13. Travel, On-Site Service, Delivery, Shipping, and Other Fees\r\nTravel, on-site service, shipping, delivery, rush, handling, or similar fees that have already been incurred or performed may be non-refundable, even when another portion of a Job qualifies for correction or refund.\r\n14. Refund Limit\r\nUnless applicable law requires otherwise, any refund associated with an affected item or service will not exceed the amount actually paid to ToolTag for that affected item or service.\r\n15. Changes After Acceptance\r\nAn accepted Quote will not be silently edited.\r\nAny material change involving price, scope, items, engraving content, quantities, locations, or other commercial terms may require a revised Quote or new version.\r\nThe previous accepted version will remain preserved in ToolTag’s records.\r\n16. Agreement Version and Record of Acceptance\r\nToolTag may update its standard terms for future Jobs.\r\nThe version accepted for a Job is preserved as part of that Job’s record and will not be retroactively replaced by a later version.\r\nToolTag may retain the date and time of acceptance, customer information, Quote version, Agreement version, acceptance folio, and related system records as evidence of the transaction.\r\n17. Electronic Acceptance\r\nBy selecting both approval checkboxes and clicking “Accept Quote & Agreement,” the customer confirms that:\r\nI have reviewed and approve the Quote details.\r\nI have read and agree to the ToolTag Customer Agreement & Custom Engraving Terms.\r\nElectronic acceptance is intended to have the same business effect as signing the approved Quote and Agreement electronically.\r\n18. Entire Approved Scope\r\nThe accepted Quote, this Agreement, and any formally approved revision constitute the agreed scope for the Job.\r\nInformal conversations, messages, drafts, mockups, or preliminary estimates that are not included in the accepted Quote or an approved revision do not replace the final accepted scope.\r\n19. Applicable Rights\r\nNothing in this Agreement is intended to waive any right or remedy that cannot legally be waived under applicable law.\r\nToolTag\r\nA DBA of Bandits of the Framing LLC\r\nUtah, USA	2026-10-03 22:56:34.300943+00	2026-10-03 22:56:34.300943+00
5eeb9272-647b-4aa6-9455-4c177d84de0b	10000000-0000-0000-0000-000000000002	2	ToolTag Customer Agreement & Custom Engraving Terms v2.0	# ToolTag Customer Agreement & Custom Engraving Terms\r\n\r\n**Revision 2.0**  \r\n**Effective Date: October 4, 2026**\r\n\r\nToolTag  \r\nA DBA of Bandits of the Framing LLC  \r\nUtah, USA\r\n\r\n---\r\n\r\nBy accepting this Agreement, the customer confirms that they have reviewed and approved the related ToolTag Quote, including the items, quantities, engraving content, logos or artwork, engraving locations, dimensions, orientation, colors, paint-fill instructions, pricing, service method, applicable Pickup or Return terms, and other specifications shown in the accepted Quote.\r\n\r\nThe accepted Quote, this Agreement, any applicable Pickup & Return Service Terms, and any formally approved revision together define the approved scope of work.\r\n\r\n---\r\n\r\n## 1. Customer Approval of Quote and Engraving Details\r\n\r\nBefore accepting, the customer is responsible for reviewing all names, spelling, wording, numbers, logos, artwork, placement, engraving locations, dimensions, orientation, quantities, colors, paint-fill selections, service method, and other instructions shown in the Quote.\r\n\r\nToolTag is not responsible for errors that were submitted, supplied, or approved by the customer.\r\n\r\nOnce work begins, changes to the approved scope may require a revised Quote, additional charges, and new approval.\r\n\r\n---\r\n\r\n## 2. Custom Work, Cancellation, and Refundability\r\n\r\nToolTag provides customized and personalized services that may permanently alter customer-owned items.\r\n\r\nBecause of the nature of customized work, cancellation and refund eligibility depend on the stage of the Job at the time the cancellation request is confirmed.\r\n\r\nA customer’s change of mind after preparation, engraving, or customization has started does not create an automatic right to a full refund.\r\n\r\nCancellation charges described in this Agreement are based on the accepted engraving or service amount shown in the applicable Quote.\r\n\r\nSeparately identified Pickup, Return, delivery, shipping, rush, handling, travel, or similar fees may be governed by separate terms and are not automatically included in refundable amounts.\r\n\r\nNothing in this Agreement limits remedies for an error or qualifying damage directly caused by ToolTag.\r\n\r\n---\r\n\r\n## 3. Cancellation Before Pickup or Work Begins\r\n\r\nIf the Job has not yet entered preparation, engraving, or another production stage, the customer may request cancellation.\r\n\r\nRefund eligibility will depend on:\r\n\r\n- Payments actually received by ToolTag\r\n- Any applicable Pickup Service Fee\r\n- Whether Pickup, travel, delivery, shipping, or other service-related costs have already been incurred\r\n- The applicable cancellation deadline\r\n- The service method selected by the customer\r\n\r\nIf Pickup service was selected, the Pickup cancellation rules contained in this Agreement also apply.\r\n\r\n---\r\n\r\n## 4. Cancellation During Preparation\r\n\r\nOnce ToolTag has received the customer’s items and the Job has entered the preparation stage, but engraving has **not yet started**, the Job may still be cancelled.\r\n\r\nAt this stage:\r\n\r\n- Any applicable Pickup Service Fee is non-refundable\r\n- **40% of the accepted engraving/service amount becomes due and non-refundable**\r\n- The remaining **60% of eligible engraving/service payments may be refunded**\r\n- Refunds are limited to amounts actually paid to ToolTag\r\n- If the customer has not yet paid enough to cover the applicable cancellation amount, the remaining cancellation balance may still be due\r\n\r\nThe 40% retained amount may cover preparation, handling, scheduling, setup, documentation, administration, and production resources already committed to the Job.\r\n\r\n---\r\n\r\n## 5. Cancellation After Engraving Has Started\r\n\r\nBecause engraving permanently modifies customer-owned items, cancellation terms become more restrictive once engraving has started.\r\n\r\n### 5.1 Engraving 50% or Less Complete\r\n\r\nIf engraving has started and **50% or less of the approved engraving work has been completed or materially started**, the customer may still request cancellation.\r\n\r\nAt this stage:\r\n\r\n- **60% of the accepted engraving/service amount becomes due and non-refundable**\r\n- Up to **40% of eligible engraving/service payments may be refundable**\r\n- Any applicable Pickup Service Fee remains subject to the Pickup Service Fee rules and may be non-refundable\r\n- If the amount already paid is less than the amount due under this cancellation policy, the remaining balance may still be owed\r\n\r\nThis rule applies even if only one engraving has been started when that engraving represents 50% or less of the approved engraving scope.\r\n\r\n---\r\n\r\n### 5.2 Engraving More Than 50% Complete\r\n\r\nIf **more than 50% of the approved engraving work has been completed or materially started**, the **full accepted engraving/service amount becomes due and non-refundable**.\r\n\r\nNo partial cancellation refund is available at this stage unless ToolTag determines otherwise or applicable law requires otherwise.\r\n\r\nThe customer remains responsible for any unpaid balance associated with the accepted Quote.\r\n\r\n---\r\n\r\n### 5.3 Engraving Completed\r\n\r\nOnce the approved engraving work has been completed, the Job **can no longer be cancelled for convenience**.\r\n\r\nThe full accepted amount becomes due.\r\n\r\nThe Job will continue through the normal completion, Return or delivery, customer acceptance, and payment process.\r\n\r\n---\r\n\r\n## 6. Determining Engraving Completion Percentage\r\n\r\nFor purposes of cancellation, ToolTag may determine engraving completion percentage using the approved engraving scope shown in the accepted Quote.\r\n\r\nThe calculation may consider individual:\r\n\r\n- Items\r\n- Engraving marks\r\n- Engraving locations\r\n- Text engravings\r\n- Logos\r\n- Artwork\r\n- Names\r\n- Identification marks\r\n- QR codes\r\n- Other separately approved engraving units\r\n\r\nCompletion percentage is based on the approved engraving scope and is not necessarily based only on the number of physical items.\r\n\r\nFor example, if a Job contains four approved engraving units:\r\n\r\n- 1 of 4 completed or materially started = 25%\r\n- 2 of 4 completed or materially started = 50%\r\n- 3 of 4 completed or materially started = 75%\r\n- 4 of 4 completed = 100%\r\n\r\nToolTag may use production records, photographs, timestamps, Job records, engraving records, or other available documentation to determine the stage of completion.\r\n\r\n---\r\n\r\n## 7. Outstanding Balance After Cancellation\r\n\r\nCancellation does not eliminate amounts already earned or due under the accepted Quote and Agreement.\r\n\r\nIf cancellation results in an outstanding balance for preparation, engraving, Pickup, Return, delivery, or other services already performed or committed, the customer remains responsible for that balance.\r\n\r\nTo the extent permitted by applicable law, customer-owned items may remain in ToolTag’s possession until applicable amounts due for the Job have been paid.\r\n\r\nOnce the applicable balance has been satisfied, ToolTag will coordinate the return or release of the customer’s items.\r\n\r\n---\r\n\r\n# Pickup & Return Service Terms\r\n\r\n## 8. Pickup Service Fee\r\n\r\nWhen Pickup service is selected, a **$10.00 Pickup Service Fee** applies unless ToolTag expressly states otherwise in the Quote.\r\n\r\nThe Pickup Service Fee must be **paid and confirmed before Pickup scheduling or Pickup service begins**.\r\n\r\nSubmission of payment by the customer does not by itself constitute confirmed payment.\r\n\r\nPayment must be received and confirmed by ToolTag before the Pickup & Return process becomes active.\r\n\r\nThe Pickup Service Fee is separate from the engraving/service amount unless expressly shown otherwise in the accepted Quote.\r\n\r\n---\r\n\r\n## 9. Pickup Schedule\r\n\r\nToolTag Pickup service is normally performed on **Saturdays between 8:00 AM and 12:00 PM**.\r\n\r\nAvailable Pickup dates and time windows depend on:\r\n\r\n- Route capacity\r\n- Current workload\r\n- Production capacity\r\n- Service area\r\n- Existing scheduled Pickups\r\n- Other operational conditions\r\n\r\nToolTag may provide the customer with available Pickup dates through its scheduling system.\r\n\r\nA requested date is not considered confirmed until the ToolTag system or ToolTag personnel confirm the scheduled Pickup.\r\n\r\n---\r\n\r\n## 10. Estimated Completion and Return Schedule\r\n\r\nItems picked up on Saturday are generally expected to be completed and returned on **Sunday between approximately 4:00 PM and 6:00 PM**, depending on workload and the approved scope of work.\r\n\r\nCompletion on the immediately following Sunday is an estimate and is not guaranteed.\r\n\r\nDepending on ToolTag’s workload, production requirements, engraving complexity, material behavior, corrections, equipment availability, or other operational conditions, the Return may be delayed.\r\n\r\nThe maximum normal processing period for a standard Pickup Job may extend until the **following Sunday after the originally expected Return date**.\r\n\r\nIf an unexpected delay, service issue, or schedule change affects the expected completion or Return date, ToolTag will notify the customer by email.\r\n\r\nWhen SMS notifications become available, ToolTag may also provide notifications by text message.\r\n\r\n---\r\n\r\n## 11. Special Pickup or Return Scheduling\r\n\r\nPickup or Return service outside the normal Saturday Pickup or Sunday Return schedule may be available.\r\n\r\nWeekday Pickup or Return service will generally be limited to **afternoon hours** and may include an additional service charge.\r\n\r\nCustomers who require a special day or schedule should describe the request in the applicable request form, including the **“Anything else we should know?”** section when available.\r\n\r\nToolTag will confirm availability and any additional charge before providing the special service.\r\n\r\n---\r\n\r\n## 12. Pickup Cancellation Deadline\r\n\r\nA scheduled Pickup may be changed or cancelled without forfeiting the Pickup Service Fee only if ToolTag receives the change or cancellation request **no later than Friday at 6:00 PM** before the scheduled Saturday Pickup.\r\n\r\nIf the Pickup is cancelled or changed after **Friday at 6:00 PM**, the **Pickup Service Fee is NON-REFUNDABLE**.\r\n\r\nThis deadline applies to the scheduled Pickup appointment associated with the Job.\r\n\r\n---\r\n\r\n## 13. Customer Unavailable at Scheduled Pickup\r\n\r\nIf ToolTag arrives at the scheduled Pickup location and:\r\n\r\n- The customer is not available\r\n- An authorized person is not available\r\n- The items are not available\r\n- ToolTag cannot reasonably obtain the items as scheduled\r\n\r\nthe **Pickup Service Fee remains due and is NON-REFUNDABLE**.\r\n\r\nA new Pickup appointment may require another Pickup Service Fee.\r\n\r\n---\r\n\r\n## 14. ToolTag-Initiated Pickup Cancellation\r\n\r\nIf ToolTag is unable to perform the scheduled Pickup for a reason attributable to ToolTag, ToolTag may:\r\n\r\n- Reschedule the Pickup without an additional Pickup Fee\r\n- Apply the existing Pickup Fee to a new appointment\r\n- Refund the Pickup Service Fee when appropriate\r\n\r\nThe customer will not be penalized for a Pickup cancellation caused solely by ToolTag.\r\n\r\n---\r\n\r\n## 15. Pickup Receiving Evidence\r\n\r\nWhen ToolTag receives or picks up customer items, ToolTag may photograph and document the condition of the items.\r\n\r\nPickup photographs may become the official **Receiving Evidence** for the associated Job.\r\n\r\nWhen sufficient Receiving Evidence has been captured during Pickup, the Job may automatically proceed into the preparation or production workflow without requiring the same receiving-evidence step to be repeated.\r\n\r\nPickup Receiving Evidence is separate from:\r\n\r\n- Completed Work Evidence\r\n- Return or Delivery Evidence\r\n\r\nEach type of evidence documents a different stage of the Job.\r\n\r\n---\r\n\r\n## 16. Completed Work Evidence\r\n\r\nAfter engraving or customization has been completed, ToolTag may create photographic or other evidence documenting the completed work.\r\n\r\nCompleted Work Evidence documents the finished engraving or customization.\r\n\r\nCompleted Work Evidence is not the same as Return or Delivery Evidence.\r\n\r\nFor Pickup & Return Jobs, completion of the work may move the Job into a **Delivery In Progress** or similar Return stage before final customer delivery.\r\n\r\n---\r\n\r\n## 17. Return Scheduling and Delivery In Progress\r\n\r\nAfter the approved work has been completed and documented, ToolTag may schedule the Return of the customer’s items.\r\n\r\nThe customer may receive notification that the Job has entered the **Delivery In Progress** process.\r\n\r\nThe notice may include:\r\n\r\n- Scheduled Return date\r\n- Delivery window\r\n- Estimated arrival time\r\n- Updated ETA\r\n- Delivery status\r\n- Other relevant Return information\r\n\r\nToolTag may update the estimated arrival time as the Return route progresses.\r\n\r\n---\r\n\r\n## 18. Customer Availability During Return\r\n\r\nOn the scheduled Return day, the customer should monitor the phone number and email address provided to ToolTag so delivery can be coordinated.\r\n\r\nToolTag may notify the customer when:\r\n\r\n- The Return is scheduled\r\n- The Job enters Delivery In Progress\r\n- ToolTag is preparing to begin the Return route\r\n- ToolTag is on the way\r\n- The estimated arrival time changes\r\n- ToolTag has arrived\r\n- Delivery has been completed\r\n\r\nSMS notifications may be added when that service becomes available.\r\n\r\n---\r\n\r\n## 19. Unattended Delivery\r\n\r\nToolTag will not leave customer items unattended at a door, porch, driveway, garage area, or other location unless the customer expressly authorizes unattended delivery.\r\n\r\nIf unattended delivery is authorized, ToolTag may photograph or otherwise document:\r\n\r\n- The location where the items were left\r\n- The condition of the items at delivery\r\n- The date and time of delivery\r\n- Other reasonable delivery evidence\r\n\r\nOnce the items have been delivered to the location expressly authorized by the customer and ToolTag has recorded delivery evidence, ToolTag is not responsible for subsequent theft, loss, disappearance, removal, weather exposure, or interference occurring after delivery, except where applicable law provides otherwise.\r\n\r\n---\r\n\r\n## 20. Pickup & Return Disclaimer\r\n\r\nThe Pickup & Return Service Terms may also be displayed separately as a disclaimer during the Get Tagged request, Pickup selection, scheduling, or Pickup & Return workflow.\r\n\r\nDisplaying these terms separately during the Pickup process does not replace this Agreement.\r\n\r\nWhen Pickup service is included in the accepted Quote, the applicable Pickup & Return terms become part of the customer’s accepted ToolTag Agreement.\r\n\r\nToolTag may preserve the exact version of the Pickup & Return terms associated with the Job.\r\n\r\nFuture changes to Pickup policies will not retroactively replace the version associated with an already accepted Job.\r\n\r\n---\r\n\r\n# Refunds, Issues, and Customer Remedies\r\n\r\n## 21. Refund Processing\r\n\r\nA cancellation request and a completed refund are separate events.\r\n\r\nIf a cancellation qualifies for a refund, ToolTag may first mark the refund as pending while the cancellation, payment records, Job status, and applicable Agreement terms are reviewed.\r\n\r\nAn approved refund is generally processed by ToolTag within **5–7 business days** after the refund is confirmed.\r\n\r\nAfter ToolTag issues the refund, the amount of time required for funds to appear in the customer’s account may depend on the payment method, bank, financial institution, or payment provider.\r\n\r\nA refund is considered completed by ToolTag when ToolTag has issued the applicable funds through the approved refund method.\r\n\r\nToolTag may provide the customer with an electronic refund confirmation or receipt showing:\r\n\r\n- Refund amount\r\n- Refund date\r\n- Refund method\r\n- Related Quote or Job\r\n- Applicable reference number\r\n\r\n---\r\n\r\n## 22. Refund Limit\r\n\r\nUnless applicable law requires otherwise, a cash refund associated with an affected item or service will not exceed the amount actually paid to ToolTag for the refundable portion of that item or service.\r\n\r\nThis limitation does not eliminate an outstanding balance that may remain due under an applicable cancellation charge.\r\n\r\nPickup Service Fees are evaluated separately according to the Pickup Service Terms.\r\n\r\n---\r\n\r\n## 23. ToolTag Errors or Workmanship Issues\r\n\r\nIf ToolTag makes an error that does not match the approved Quote or directly causes a qualifying workmanship issue, ToolTag may, depending on the circumstances:\r\n\r\n- Rework or correct the item\r\n- Replace the affected item\r\n- Issue a partial refund\r\n- Issue a full refund for the affected item or service\r\n\r\nThe appropriate remedy will depend on:\r\n\r\n- The nature of the issue\r\n- The item involved\r\n- The approved scope\r\n- Availability of replacement parts or products\r\n- Whether correction is reasonably possible\r\n- The extent of the affected work\r\n\r\nCancellation charges for customer-requested cancellations do not limit remedies for qualifying ToolTag errors or qualifying damage caused by ToolTag.\r\n\r\n---\r\n\r\n## 24. Issue and Refund Request Window\r\n\r\nCustomers should notify ToolTag of engraving-related errors, workmanship issues, or qualifying damage as soon as reasonably possible and normally within **14 calendar days** after Pickup, Return, delivery, or completion notice.\r\n\r\nRequests received after 14 calendar days may be reviewed at ToolTag’s discretion unless applicable law requires otherwise.\r\n\r\nThis 14-day issue window is separate from customer-requested cancellation rules.\r\n\r\n---\r\n\r\n## 25. Three-Day Completion Review\r\n\r\nAfter ToolTag sends notice that the work has been completed or delivered, the customer has **3 calendar days** to review the completed work and report any immediately apparent issue related to the approved scope.\r\n\r\nIf the customer does not respond during that period, ToolTag may administratively close the Job as:\r\n\r\n**Completed – Deemed Accepted per Agreement**\r\n\r\nThis administrative closure does not represent a false record of express customer acceptance and does not eliminate rights or remedies that cannot legally be waived.\r\n\r\nIt also does not automatically eliminate an otherwise eligible claim submitted within the applicable 14-day review period.\r\n\r\n---\r\n\r\n# Customer-Owned Items and Workmanship\r\n\r\n## 26. Customer-Supplied Items\r\n\r\nWhen the customer provides an item for engraving or customization, the customer is responsible for determining whether the item is suitable for the requested work.\r\n\r\nMaterials, coatings, plastics, finishes, paints, adhesives, electronics, and manufacturing methods can respond differently to engraving processes.\r\n\r\nToolTag does not guarantee replacement of a customer-supplied item unless available evidence reasonably indicates that ToolTag directly caused substantial damage beyond the intended engraving or customization process.\r\n\r\n---\r\n\r\n## 27. Electronic and Electrical Tools, Batteries, and Chargers\r\n\r\nToolTag may engrave or customize tools, batteries, chargers, and other items containing electronic or electrical components.\r\n\r\nUnless specifically agreed otherwise, ToolTag is not required to perform functional testing before or after engraving.\r\n\r\nAcceptance of an item by ToolTag does not certify that the item was functioning before service.\r\n\r\nReturn or delivery of the item does not certify that it is functioning afterward.\r\n\r\nToolTag is not responsible for a later electrical, battery, charging, motor, control-board, internal-component, or similar failure unless available evidence reasonably shows that ToolTag directly intervened with or damaged the relevant component.\r\n\r\n---\r\n\r\n## 28. Damage Beyond Intended Engraving\r\n\r\nIf ToolTag’s process penetrates, burns, cuts, melts, or otherwise damages an item substantially beyond the intended engraving surface or depth, and the damage is reasonably determined to have been directly caused by ToolTag, ToolTag may provide an appropriate remedy, including replacement when warranted.\r\n\r\n---\r\n\r\n## 29. Replacement Items\r\n\r\nWhen replacement is determined to be the appropriate remedy, estimated replacement time may be approximately **45–60 days**, depending on:\r\n\r\n- Manufacturer\r\n- Model\r\n- Vendor\r\n- Inventory\r\n- Shipping\r\n- Availability\r\n\r\nA replacement may be a reasonably equivalent item or component.\r\n\r\nA replacement is not required to be an upgrade, a higher-value product, or a brand-new item when an equivalent replacement is otherwise reasonable.\r\n\r\n---\r\n\r\n## 30. Paint Fill, Color, and Cosmetic Finishes\r\n\r\nEngraving and applied color are separate components of the finished work.\r\n\r\nToolTag does not guarantee that paint fill, ink, coating, or applied color will remain permanent for the life of the item.\r\n\r\nColor may fade, scratch, chip, wear, discolor, or deteriorate from:\r\n\r\n- Normal use\r\n- Friction\r\n- Impacts\r\n- Heat\r\n- Sunlight or UV exposure\r\n- Oils\r\n- Grease\r\n- Chemicals\r\n- Cleaners\r\n- Alcohol\r\n- Solvents\r\n- Moisture\r\n- Other environmental conditions\r\n\r\nNormal wear of applied color does not automatically constitute defective engraving or create an automatic right to a refund.\r\n\r\nToolTag may offer touch-up or refinishing when appropriate.\r\n\r\n---\r\n\r\n## 31. Natural Material and Finish Variations\r\n\r\nDifferences in plastic composition, coating thickness, anodizing, paint, texture, surface condition, prior wear, manufacturing batches, and similar material characteristics may cause variations in engraving:\r\n\r\n- Color\r\n- Depth\r\n- Contrast\r\n- Texture\r\n- Appearance\r\n\r\nReasonable variations that do not materially depart from the approved design are not considered defects.\r\n\r\n---\r\n\r\n## 32. Photographic Documentation\r\n\r\nToolTag may photograph customer items:\r\n\r\n- When they are picked up\r\n- When they are received\r\n- Before work begins\r\n- During relevant stages of production\r\n- After engraving or customization is completed\r\n- During Return\r\n- At final delivery\r\n\r\nThese photographs may be used to document:\r\n\r\n- Physical condition\r\n- Engraving location\r\n- Approved work\r\n- Completed result\r\n- Pickup\r\n- Return\r\n- Delivery\r\n- Damage claims\r\n- Later issues or disputes\r\n\r\nReceiving Evidence, Completed Work Evidence, and Delivery Evidence are separate business records documenting different stages of the Job.\r\n\r\nPhotographic evidence does not constitute functional testing of electronic or mechanical components.\r\n\r\n---\r\n\r\n## 33. Travel, Pickup, On-Site Service, Delivery, Shipping, and Other Fees\r\n\r\nTravel, Pickup, on-site service, shipping, delivery, rush, handling, or similar fees that have already been incurred, performed, or become non-refundable under the applicable service terms may remain non-refundable even when another portion of the Job qualifies for correction, cancellation adjustment, or refund.\r\n\r\n---\r\n\r\n# Quote, Agreement, and Records\r\n\r\n## 34. Changes After Acceptance\r\n\r\nAn accepted Quote will not be silently edited.\r\n\r\nAny material change involving:\r\n\r\n- Price\r\n- Scope\r\n- Items\r\n- Engraving content\r\n- Quantities\r\n- Engraving locations\r\n- Service method\r\n- Pickup or Return service\r\n- Other commercial terms\r\n\r\nmay require a revised Quote or new version.\r\n\r\nThe previous accepted version will remain preserved in ToolTag’s records.\r\n\r\n---\r\n\r\n## 35. Agreement Version and Record of Acceptance\r\n\r\nToolTag may update its standard terms for future Jobs.\r\n\r\nThe version accepted for a Job is preserved as part of that Job’s record and will not be retroactively replaced by a later version.\r\n\r\nToolTag may retain:\r\n\r\n- Date and time of acceptance\r\n- Customer information\r\n- Quote version\r\n- Agreement version\r\n- Pickup & Return Terms version\r\n- Acceptance folio\r\n- Job information\r\n- Payment records\r\n- Cancellation records\r\n- Refund records\r\n- Electronic acceptance records\r\n- Related system records\r\n\r\nas evidence of the transaction.\r\n\r\n---\r\n\r\n## 36. Electronic Acceptance\r\n\r\nBy selecting both approval checkboxes and clicking **“Accept Quote & Agreement,”** the customer confirms:\r\n\r\n**I have reviewed and approve the Quote details.**\r\n\r\n**I have read and agree to the ToolTag Customer Agreement & Custom Engraving Terms, including the cancellation provisions and any applicable Pickup & Return Service Terms associated with my selected service.**\r\n\r\nElectronic acceptance is intended to have the same business effect as signing the approved Quote and Agreement electronically.\r\n\r\n---\r\n\r\n## 37. Entire Approved Scope\r\n\r\nThe accepted Quote, this Agreement, any applicable Pickup & Return Service Terms, and any formally approved revision constitute the agreed scope for the Job.\r\n\r\nInformal conversations, messages, drafts, mockups, preliminary estimates, or other communications that are not included in the accepted Quote or an approved revision do not replace the final accepted scope.\r\n\r\n---\r\n\r\n## 38. Applicable Rights\r\n\r\nNothing in this Agreement is intended to waive any right or remedy that cannot legally be waived under applicable law.\r\n\r\nIf any provision of this Agreement is determined to be unenforceable, the remaining provisions will continue to apply to the extent permitted by law.\r\n\r\n---\r\n\r\n**ToolTag**  \r\nA DBA of Bandits of the Framing LLC  \r\nUtah, USA\r\n\r\n**Agreement Revision: 2.0**  \r\n**Effective Date: October 4, 2026**	2026-10-04 23:51:53.112256+00	2026-10-04 23:51:53.112256+00
\.


--
-- Data for Name: unit_settings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.unit_settings (unit_id, timezone, quote_valid_days, quote_reminder_days, completion_days, refund_days, drive_root_id, boft_url, annual_vehicle_method, mileage_rate, zelle_email, venmo_handle, payment_account_id) FROM stdin;
10000000-0000-0000-0000-000000000001	America/Denver	7	2	3	14	\N	\N	Fuel	\N	\N	\N	\N
10000000-0000-0000-0000-000000000002	America/Denver	7	2	3	14	\N	\N	Fuel	\N	payments@tooltag.martinlab.studio	\N	e40d0194-b133-4613-8961-95c78ef46522
\.


--
-- Data for Name: buckets; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

COPY storage.buckets (id, name, owner, created_at, updated_at, public, avif_autodetection, file_size_limit, allowed_mime_types, owner_id, type, versioning_status, lifecycle_configuration, lifecycle_configuration_generation) FROM stdin;
payment-proofs	payment-proofs	\N	2026-10-04 08:39:47.395439+00	2026-10-04 08:39:47.395439+00	f	f	5242880	{image/png,image/jpeg,image/webp}	\N	STANDARD	DISABLED	\N	\N
\.


--
-- PostgreSQL database dump complete
--


