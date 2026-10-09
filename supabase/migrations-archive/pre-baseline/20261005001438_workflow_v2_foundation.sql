
create table public.job_items (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.business_units(id),
  job_id uuid not null references public.jobs(id) on delete cascade,
  quote_id uuid not null references public.quotes(id),
  quote_item_id uuid not null references public.quote_items(id),
  unit_index integer not null check (unit_index > 0),
  sequence integer not null check (sequence > 0),
  article text not null,
  scope_snapshot jsonb not null default '{}'::jsonb,
  stage text not null default 'Preparation'
    check (stage in ('Preparation','Engraving','Finished Evidence','Finished','Cancelled')),
  engraving_started_at timestamptz,
  evidence_completed_at timestamptz,
  finished_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(job_id, quote_item_id, unit_index),
  unique(job_id, sequence)
);

create index job_items_job_stage_idx on public.job_items(job_id, stage, sequence);

alter table public.job_items enable row level security;
create policy job_items_read on public.job_items
  for select to authenticated
  using ((select private.can_access(unit_id)));
grant select on public.job_items to authenticated;

alter table public.documents
  add column job_item_id uuid references public.job_items(id) on delete set null;

alter table public.documents
  drop constraint if exists documents_type_check;
alter table public.documents
  add constraint documents_type_check
  check (type in (
    'Receipt','Quote','Agreement','Receiving Evidence','Completed Evidence',
    'Finished Evidence','Delivery Evidence','Payment Receipt','Issue / Review','Other'
  ));

alter table public.jobs
  drop constraint if exists jobs_work_stage_check;
alter table public.jobs
  add constraint jobs_work_stage_check
  check (work_stage in (
    'Not Started','Receiving Evidence','Preparing','Engraving',
    'Final Evidence','Final Details','Delivery In Progress',
    'Awaiting Delivery Acceptance','Issue Review','Payment',
    'Payment Verification','Closed'
  ));

create table public.pick_return_orders (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  unit_id uuid not null references public.business_units(id),
  service_method text not null default 'Pickup & Return'
    check (service_method='Pickup & Return'),
  fee_amount numeric(14,2) not null default 10.00 check (fee_amount >= 0),
  fee_status text not null default 'Required'
    check (fee_status in ('Required','Pending Verification','Confirmed','Refund Pending','Refunded','Forfeited')),
  scheduler_enabled boolean not null default false,
  pickup_status text not null default 'Not Scheduled'
    check (pickup_status in ('Not Scheduled','Scheduled','En Route','Arrived','Picked Up','Failed','Cancelled')),
  return_status text not null default 'Not Ready'
    check (return_status in ('Not Ready','Delivery In Progress','Scheduled','En Route','Arrived','Delivered','Cancelled')),
  pickup_window_start timestamptz,
  pickup_window_end timestamptz,
  pickup_eta timestamptz,
  pickup_cancellation_deadline timestamptz,
  picked_up_at timestamptz,
  return_window_start timestamptz,
  return_window_end timestamptz,
  return_eta timestamptz,
  returned_at timestamptz,
  unattended_delivery_authorized boolean not null default false,
  special_instructions text,
  terms_version text not null default '2.0',
  terms_snapshot text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.pick_return_orders enable row level security;
create policy pick_return_orders_read on public.pick_return_orders
  for select to authenticated
  using ((select private.can_access(unit_id)));
grant select on public.pick_return_orders to authenticated;

create table public.pick_return_routes (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.business_units(id),
  route_date date not null,
  leg text not null check (leg in ('Pickup','Return')),
  status text not null default 'Draft'
    check (status in ('Draft','Active','Completed','Cancelled')),
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(unit_id, route_date, leg)
);

alter table public.pick_return_routes enable row level security;
create policy pick_return_routes_read on public.pick_return_routes
  for select to authenticated
  using ((select private.can_access(unit_id)));
grant select on public.pick_return_routes to authenticated;

create table public.pick_return_stops (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.business_units(id),
  route_id uuid not null references public.pick_return_routes(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  sequence integer not null check (sequence > 0),
  status text not null default 'Scheduled'
    check (status in ('Scheduled','En Route','Arrived','Completed','Failed','Cancelled')),
  window_start timestamptz,
  window_end timestamptz,
  eta timestamptz,
  arrived_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(route_id, job_id),
  unique(route_id, sequence)
);

create index pick_return_stops_job_idx on public.pick_return_stops(job_id, status);

alter table public.pick_return_stops enable row level security;
create policy pick_return_stops_read on public.pick_return_stops
  for select to authenticated
  using ((select private.can_access(unit_id)));
grant select on public.pick_return_stops to authenticated;

create table public.cancellation_requests (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.business_units(id),
  job_id uuid not null references public.jobs(id) on delete cascade,
  quote_id uuid not null references public.quotes(id),
  customer_id uuid not null references public.customers(id),
  status text not null default 'Requested'
    check (status in ('Requested','Cancelled','Rejected')),
  refund_status text not null default 'None'
    check (refund_status in ('None','Pending','Completed')),
  requested_at timestamptz not null default now(),
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  stage_at_request text,
  items_total integer not null default 0,
  items_started integer not null default 0,
  items_finished integer not null default 0,
  service_amount numeric(14,2) not null default 0,
  pickup_fee_amount numeric(14,2) not null default 0,
  pickup_fee_refundable boolean not null default false,
  pickup_fee_refund_amount numeric(14,2) not null default 0,
  service_charge_percent numeric(5,2) not null default 0,
  service_charge_amount numeric(14,2) not null default 0,
  refund_eligible_amount numeric(14,2) not null default 0,
  amount_due numeric(14,2) not null default 0,
  agreement_version integer,
  assessment jsonb not null default '{}'::jsonb,
  refund_transaction_id uuid references public.transactions(id),
  created_at timestamptz not null default now()
);

create unique index cancellation_requests_one_open_idx
  on public.cancellation_requests(job_id)
  where status='Requested';

alter table public.cancellation_requests enable row level security;
create policy cancellation_requests_read on public.cancellation_requests
  for select to authenticated
  using ((select private.can_access(unit_id)));
grant select on public.cancellation_requests to authenticated;

alter table public.payment_requests
  add column purpose text not null default 'Final Balance';

alter table public.payment_requests
  add constraint payment_requests_purpose_check
  check (purpose in ('Final Balance','Pickup Fee','Cancellation Balance'));

alter table private.get_tagged_receipts
  add column request_status text not null default 'Pending',
  add column approved_at timestamptz,
  add column rejected_at timestamptz,
  add column reviewed_by uuid,
  add column rejection_reason text;

alter table private.get_tagged_receipts
  add constraint get_tagged_receipts_request_status_check
  check (request_status in ('Pending','Approved','Rejected','Converted'));

update private.get_tagged_receipts
set request_status='Converted'
where quote_id is not null;

create or replace function private.mark_get_tagged_converted()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.quote_id is not null
     and old.quote_id is null
     and new.request_status='Pending'
  then
    new.request_status:='Converted';
  end if;
  return new;
end $$;

create trigger get_tagged_mark_converted
before update of quote_id on private.get_tagged_receipts
for each row execute function private.mark_get_tagged_converted();

create or replace function private.sync_job_items(p_job uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
begin
  select * into j
  from public.jobs
  where id=p_job
  for update;

  if j.id is null then
    return;
  end if;

  if exists(
    select 1
    from public.job_items x
    where x.job_id=j.id
      and x.quote_id<>j.quote_id
  ) then
    if exists(
      select 1
      from public.job_items x
      where x.job_id=j.id
        and x.stage<>'Preparation'
    ) then
      raise exception 'Cannot replace Job items after production has started';
    end if;
    delete from public.job_items where job_id=j.id;
  end if;

  if exists(select 1 from public.job_items where job_id=j.id) then
    return;
  end if;

  insert into public.job_items(
    unit_id,job_id,quote_id,quote_item_id,unit_index,sequence,
    article,scope_snapshot,stage,engraving_started_at,
    evidence_completed_at,finished_at
  )
  select
    j.unit_id,
    j.id,
    j.quote_id,
    e.id,
    e.unit_index,
    e.sequence,
    e.article,
    e.scope_snapshot,
    case
      when j.work_stage in (
        'Awaiting Delivery Acceptance','Issue Review',
        'Payment','Payment Verification','Closed'
      ) then 'Finished'
      when j.work_stage in ('Final Evidence','Final Details') and e.sequence=1
        then 'Engraving'
      else 'Preparation'
    end,
    case
      when j.work_stage in ('Final Evidence','Final Details') and e.sequence=1
        then j.updated_at
      when j.work_stage in (
        'Awaiting Delivery Acceptance','Issue Review',
        'Payment','Payment Verification','Closed'
      ) then j.updated_at
      else null
    end,
    case
      when j.work_stage in (
        'Awaiting Delivery Acceptance','Issue Review',
        'Payment','Payment Verification','Closed'
      ) then j.updated_at
      else null
    end,
    case
      when j.work_stage in (
        'Awaiting Delivery Acceptance','Issue Review',
        'Payment','Payment Verification','Closed'
      ) then coalesce(j.delivered_at,j.updated_at)
      else null
    end
  from (
    select
      qi.id,
      qi.article,
      gs as unit_index,
      row_number() over(order by qi.sort_order,qi.id,gs)::integer as sequence,
      to_jsonb(qi)-'unit_id' as scope_snapshot
    from public.quote_items qi
    cross join lateral generate_series(1,qi.quantity) gs
    where qi.quote_id=j.quote_id
      and qi.engraving_type<>'Fee'
  ) e;
end $$;

create or replace function private.sync_job_items_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  perform private.sync_job_items(new.id);
  return new;
end $$;

create trigger jobs_sync_items
after insert or update of quote_id on public.jobs
for each row execute function private.sync_job_items_trigger();

select private.sync_job_items(id) from public.jobs;

create or replace function private.job_item_progress(p_job uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select jsonb_build_object(
    'total',count(*),
    'started',count(*) filter (
      where stage in ('Engraving','Finished Evidence','Finished')
    ),
    'finished',count(*) filter (where stage='Finished'),
    'cancelled',count(*) filter (where stage='Cancelled'),
    'current_item_id',(
      select x.id
      from public.job_items x
      where x.job_id=p_job
        and x.stage not in ('Finished','Cancelled')
      order by x.sequence
      limit 1
    ),
    'current_sequence',(
      select x.sequence
      from public.job_items x
      where x.job_id=p_job
        and x.stage not in ('Finished','Cancelled')
      order by x.sequence
      limit 1
    )
  )
  from public.job_items
  where job_id=p_job;
$$;
