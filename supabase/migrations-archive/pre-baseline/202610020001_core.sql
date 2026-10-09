-- Shared financial core. UTC timestamps; calendar business dates remain DATE.
create schema if not exists private;
revoke all on schema private from public;
create table public.business_units (
 id uuid primary key default gen_random_uuid(), code text unique not null check(code in ('BOFT','TOOLTAG')), name text not null
);
create table public.memberships (
 unit_id uuid references public.business_units not null, user_id uuid references auth.users not null,
 role text not null check(role in ('admin','viewer')), primary key(unit_id,user_id)
);
create function private.can_access(u uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid());
$$;
create function private.require_admin(u uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid() and role='admin') then raise exception 'Administrative access required' using errcode='42501'; end if;
end $$;
create table public.physical_accounts (
 id uuid primary key default gen_random_uuid(), name text not null, currency text not null default 'USD' check(currency='USD'),
 reconciled_balance numeric(14,2), reconciled_at timestamptz, created_at timestamptz not null default now()
);
create table public.accounts (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 physical_account_id uuid references public.physical_accounts not null, name text not null, active boolean not null default true,
 unique(id,unit_id), unique(unit_id,name)
);
create table public.categories (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units,
 name text not null, kind text not null check(kind in ('income','expense','asset')), active boolean not null default true,
 is_equipment boolean not null default false, is_fuel boolean not null default false, is_mileage boolean not null default false,
 unique nulls not distinct(unit_id,name,kind)
);
create table public.customers (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 code text unique not null default ('TT-C-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
 name text not null check(length(trim(name))>0), phone text not null, email text not null, address text not null,
 company_name text, company_phone text, company_email text, company_address text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(id,unit_id)
);
create index customer_email_idx on public.customers(unit_id,lower(email));
create index customer_phone_idx on public.customers(unit_id,phone);
create table public.vendors (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null, name text not null,
 unique(unit_id,name)
);
create table private.annual_sequences (year integer primary key, value integer not null);
create table public.commercial_flows (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 customer_id uuid not null, year integer not null, sequence integer not null,
 foreign key(customer_id,unit_id) references public.customers(id,unit_id), unique(year,sequence), unique(id,unit_id)
);
create table public.policies (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 version integer not null, title text not null, content text not null check(length(trim(content))>20), published_at timestamptz,
 created_at timestamptz not null default now(), unique(unit_id,version), unique(id,unit_id)
);
create table public.quotes (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 flow_id uuid not null, revision integer not null default 1, code text not null,
 status text not null default 'Draft' check(status in ('Draft','Sent','Viewed','Accepted','Agreement Pending','Declined','Expired','Revised')),
 notes text, sent_at timestamptz, expires_at timestamptz, accepted_at timestamptz,
 policy_id uuid, created_at timestamptz not null default now(),
 foreign key(flow_id,unit_id) references public.commercial_flows(id,unit_id),
 foreign key(policy_id,unit_id) references public.policies(id,unit_id), unique(flow_id,revision), unique(id,unit_id)
);
create table public.quote_items (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null, quote_id uuid not null,
 article text not null, quantity integer not null check(quantity>0), engraving_type text not null check(engraving_type in ('Text','Image / Logo','Fee')),
 engraving_text text, character_count integer generated always as (char_length(coalesce(engraving_text,''))) stored,
 width_mm numeric(10,2) check(width_mm>0), height_mm numeric(10,2) check(height_mm>0),
 paint_fill boolean not null default false, colors integer not null default 0 check(colors>=0),
 unit_price numeric(14,2) not null check(unit_price>=0), notes text, sort_order integer not null default 0,
 foreign key(quote_id,unit_id) references public.quotes(id,unit_id), check(engraving_type<>'Text' or length(trim(engraving_text))>0)
);
create table public.jobs (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null, flow_id uuid not null unique,
 quote_id uuid not null, code text not null unique,
 status text not null default 'Authorized' check(status in ('Pending Agreement','Authorized','Receiving Documentation','In Process','Ready for Delivery','Delivered – Pending Customer Acceptance','Completed','Cancelled','Issue / Review')),
 delivered_at timestamptz, completion_email_sent_at timestamptz, completion_link_viewed_at timestamptz,
 acceptance_deadline timestamptz, customer_accepted_at timestamptz, auto_closed_at timestamptz, completion_reason text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(id,unit_id),
 foreign key(flow_id,unit_id) references public.commercial_flows(id,unit_id), foreign key(quote_id,unit_id) references public.quotes(id,unit_id)
);
create table public.agreements (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 quote_id uuid not null unique, policy_id uuid not null, customer_id uuid not null, job_id uuid,
 content_snapshot text not null, accepted_name text not null, accepted_email text not null, accepted_phone text not null,
 accepted_at timestamptz not null default now(),
 foreign key(quote_id,unit_id) references public.quotes(id,unit_id), foreign key(policy_id,unit_id) references public.policies(id,unit_id),
 foreign key(customer_id,unit_id) references public.customers(id,unit_id), foreign key(job_id,unit_id) references public.jobs(id,unit_id)
);
create table public.transactions (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 type text not null check(type in ('SALE','COLLECTION','EXPENSE','OWNER_INJECTION','OWNER_DRAW','INTER_UNIT_TRANSFER','REFUND')),
 transaction_date date not null default current_date, amount numeric(14,2) not null check(amount>0),
 account_id uuid, category_id uuid references public.categories, customer_id uuid, vendor text,
 description text not null check(length(trim(description))>0), payment_method text check(payment_method in ('Cash','Zelle','Venmo','Bank Transfer','Card','Other')),
 reference text, status text not null default 'Active' check(status in ('Active','Voided','Archived')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), created_by uuid references auth.users,
 foreign key(account_id,unit_id) references public.accounts(id,unit_id), foreign key(customer_id,unit_id) references public.customers(id,unit_id), unique(id,unit_id),
 check(type='SALE' or account_id is not null)
);
create index transactions_unit_date_idx on public.transactions(unit_id,transaction_date desc);
create index transactions_account_idx on public.transactions(account_id);
create table public.sales (
 transaction_id uuid primary key, unit_id uuid references public.business_units not null, job_id uuid unique, quote_id uuid,
 code text unique not null, approved_items jsonb not null default '[]', revision integer not null default 1,
 foreign key(transaction_id,unit_id) references public.transactions(id,unit_id), foreign key(job_id,unit_id) references public.jobs(id,unit_id),
 foreign key(quote_id,unit_id) references public.quotes(id,unit_id), unique(transaction_id,unit_id)
);
create table public.sale_versions (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 sale_id uuid not null, quote_id uuid not null, revision integer not null, amount numeric(14,2) not null, approved_items jsonb not null,
 created_at timestamptz not null default now(), foreign key(sale_id,unit_id) references public.sales(transaction_id,unit_id),
 foreign key(quote_id,unit_id) references public.quotes(id,unit_id), unique(sale_id,revision)
);
create table public.collections (
 transaction_id uuid primary key, unit_id uuid references public.business_units not null, sale_id uuid,
 foreign key(transaction_id,unit_id) references public.transactions(id,unit_id), foreign key(sale_id,unit_id) references public.sales(transaction_id,unit_id)
);
create table public.expenses (
 transaction_id uuid primary key, unit_id uuid references public.business_units not null,
 paid_by text not null check(paid_by in ('Business','Owner')), lodging boolean not null default false, linked_asset_id uuid unique,
 foreign key(transaction_id,unit_id) references public.transactions(id,unit_id), unique(transaction_id,unit_id)
);
create table public.owner_transactions (
 transaction_id uuid primary key, unit_id uuid references public.business_units not null,
 subtype text not null check(subtype in ('Injection','Personal Draw','Reimbursement')),
 foreign key(transaction_id,unit_id) references public.transactions(id,unit_id)
);
create table public.reimbursements (
 transaction_id uuid not null, expense_id uuid not null, unit_id uuid references public.business_units not null,
 amount numeric(14,2) not null check(amount>0), primary key(transaction_id,expense_id),
 foreign key(transaction_id,unit_id) references public.transactions(id,unit_id), foreign key(expense_id,unit_id) references public.expenses(transaction_id,unit_id)
);
create table public.inter_unit_transfers (
 transaction_id uuid primary key references public.transactions, unit_id uuid references public.business_units not null,
 destination_unit_id uuid references public.business_units not null, destination_account_id uuid not null,
 foreign key(destination_account_id,destination_unit_id) references public.accounts(id,unit_id), check(unit_id<>destination_unit_id)
);
create table public.refunds (
 transaction_id uuid primary key, unit_id uuid references public.business_units not null,
 original_id uuid not null, subtype text not null check(subtype in ('Customer Refund','Vendor Refund')),
 override_reason text, foreign key(transaction_id,unit_id) references public.transactions(id,unit_id),
 foreign key(original_id,unit_id) references public.transactions(id,unit_id)
);
create table public.assets (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null, source_expense_id uuid unique,
 origin text not null check(origin in ('Purchased','Donated')), name text not null, category_id uuid references public.categories,
 serial_number text, warranty_expiration date, status text not null default 'Active' check(status in ('Active','Repair','Retired')),
 notes text, estimated_value numeric(14,2) check(estimated_value>=0), donated_by text, received_date date,
 created_at timestamptz not null default now(), unique(id,unit_id),
 foreign key(source_expense_id,unit_id) references public.expenses(transaction_id,unit_id),
 check((origin='Purchased' and source_expense_id is not null and estimated_value is null) or
 (origin='Donated' and source_expense_id is null and estimated_value is not null and donated_by is not null and received_date is not null))
);
alter table public.expenses add foreign key(linked_asset_id,unit_id) references public.assets(id,unit_id);
create table public.documents (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 type text not null check(type in ('Receipt','Quote','Agreement','Receiving Evidence','Completed Evidence','Payment Receipt','Issue / Review','Other')),
 drive_file_id text unique, file_name text not null, customer_id uuid, job_id uuid, transaction_id uuid, agreement_id uuid references public.agreements,
 content_snapshot jsonb, status text not null default 'Pending' check(status in ('Pending','Available','Archived')),
 created_at timestamptz not null default now(), uploaded_by uuid references auth.users,
 foreign key(customer_id,unit_id) references public.customers(id,unit_id), foreign key(job_id,unit_id) references public.jobs(id,unit_id),
 foreign key(transaction_id,unit_id) references public.transactions(id,unit_id), unique(id,unit_id)
);
create table public.document_relations (
 document_id uuid not null, unit_id uuid references public.business_units not null,
 transaction_id uuid not null, primary key(document_id,transaction_id),
 foreign key(document_id,unit_id) references public.documents(id,unit_id), foreign key(transaction_id,unit_id) references public.transactions(id,unit_id)
);
create table public.mileage (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 date date not null, purpose text not null, origin text not null, destination text not null, miles numeric(10,2) not null check(miles>0), notes text
);
create table public.unit_settings (
 unit_id uuid primary key references public.business_units, timezone text not null default 'America/Denver',
 quote_valid_days integer not null default 7 check(quote_valid_days=7), quote_reminder_days integer not null default 2 check(quote_reminder_days=2),
 completion_days integer not null default 3 check(completion_days=3), refund_days integer not null default 14 check(refund_days=14),
 drive_root_id text, boft_url text, annual_vehicle_method text not null default 'Fuel' check(annual_vehicle_method in ('Fuel','Mileage')),
 mileage_rate numeric(10,4) check(mileage_rate>=0)
);
create table public.monthly_closes (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null, month date not null check(extract(day from month)=1),
 version integer not null, status text not null check(status in ('Current','Superseded','Reclose Required','Documentation Updated')),
 snapshot jsonb not null, warnings jsonb not null, created_at timestamptz not null default now(), created_by uuid references auth.users,
 unique(unit_id,month,version)
);
create table public.audit_log (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 actor_id uuid, entity text not null, entity_id uuid not null, field text not null,
 old_value jsonb, new_value jsonb, reason text, created_at timestamptz not null default now()
);
create index audit_unit_time_idx on public.audit_log(unit_id,created_at desc);
create table public.notifications (
 id uuid primary key default gen_random_uuid(), unit_id uuid references public.business_units not null,
 event text not null, entity_id uuid not null, recipient text, payload jsonb not null default '{}',
 status text not null default 'Pending Integration' check(status in ('Pending Integration','Queued','Sent','Failed')),
 dedupe_key text unique not null, due_at timestamptz not null default now(), sent_at timestamptz, created_at timestamptz not null default now()
);
create table private.public_links (
 token_hash text primary key, unit_id uuid references public.business_units not null,
 quote_id uuid references public.quotes, job_id uuid references public.jobs, expires_at timestamptz not null,
 check((quote_id is null)<>(job_id is null))
);
-- Tenant isolation on all tables. Authenticated clients receive SELECT only; RPCs own all writes.
do $$ declare t text; begin
 foreach t in array array['accounts','categories','customers','vendors','commercial_flows','policies','quotes','quote_items','jobs','agreements','transactions','sales','sale_versions','collections','expenses','owner_transactions','reimbursements','inter_unit_transfers','refunds','assets','documents','document_relations','mileage','unit_settings','monthly_closes','audit_log','notifications'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy unit_read on public.%I for select to authenticated using (private.can_access(unit_id))',t);
 execute format('grant select on public.%I to authenticated',t);
 end loop;
end $$;
create policy shared_category_read on public.categories for select to authenticated using(unit_id is null and exists(select 1 from public.memberships where user_id=auth.uid()));
alter table public.memberships enable row level security;
create policy own_memberships on public.memberships for select to authenticated using(user_id=auth.uid());
alter table public.business_units enable row level security;
create policy member_units on public.business_units for select to authenticated using(private.can_access(id));
alter table public.physical_accounts enable row level security;
create policy account_read on public.physical_accounts for select to authenticated using(not exists(select 1 from public.accounts a where a.physical_account_id=id and not private.can_access(a.unit_id)) and exists(select 1 from public.accounts a where a.physical_account_id=id and private.can_access(a.unit_id)));
grant select on public.memberships,public.business_units,public.physical_accounts to authenticated;
grant usage on schema private to authenticated;
grant execute on function private.can_access(uuid) to authenticated;
revoke all on function private.require_admin(uuid) from public;
-- Shared master has a single physical account and two allocations, no invented opening balance.
insert into public.business_units(id,code,name) values
 ('10000000-0000-0000-0000-000000000001','BOFT','Bandits of the Framing'),
 ('10000000-0000-0000-0000-000000000002','TOOLTAG','ToolTag');
insert into public.physical_accounts(id,name) values('20000000-0000-0000-0000-000000000001','BOFT Business Checking');
insert into public.accounts(unit_id,physical_account_id,name) select id,'20000000-0000-0000-0000-000000000001',case code when 'BOFT' then 'BOFT Operating Account' else 'ToolTag Operating Account' end from public.business_units;
insert into public.unit_settings(unit_id) select id from public.business_units;
insert into public.categories(unit_id,name,kind,is_equipment,is_fuel,is_mileage)
 select '10000000-0000-0000-0000-000000000002',n,k,n='Equipment / Asset Purchase',n='Fuel',n='Travel / Mileage' from (values
 ('Engraving Services','income'),('Custom Parts Sales','income'),('On-Site / Travel Fee','income'),('Other Revenue','income'),
 ('Materials & Supplies','expense'),('Packaging & Shipping','expense'),('Fuel','expense'),('Travel / Mileage','expense'),('Marketing & Advertising','expense'),('Software & Subscriptions','expense'),('Payment Processing Fees','expense'),('Office / Admin','expense'),('Repairs & Maintenance','expense'),('Equipment / Asset Purchase','expense'),('Other Expense','expense'),
 ('Laser Equipment','asset'),('Laser Accessories','asset'),('Computer / Electronics','asset'),('Tools & Shop Equipment','asset'),('Furniture / Workspace','asset'),('Other Equipment','asset')) x(n,k);
