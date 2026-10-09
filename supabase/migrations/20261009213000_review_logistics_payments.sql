-- Review & Accept logistics selection and pre-work payment gate.
-- Forward-only migration. Do not edit the six applied baseline migrations.

alter table public.unit_settings
  add column max_pickup_stops_per_saturday integer not null default 10;

alter table public.unit_settings
  add constraint unit_settings_max_pickup_stops_per_saturday_check
  check (max_pickup_stops_per_saturday between 1 and 100);

create table public.quote_logistics (
  quote_id uuid primary key references public.quotes(id) on delete cascade,
  unit_id uuid not null references public.business_units(id),
  job_id uuid references public.jobs(id) on delete set null,
  option_code text not null,
  fee_amount numeric(14,2) not null,
  pickup_address text,
  delivery_address text,
  saturday_date date,
  pickup_stop_id uuid references public.pick_return_stops(id) on delete set null,
  payment_scope text,
  payment_status text not null,
  payment_method text,
  provider text,
  provider_reference text,
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quote_logistics_option_check check (
    option_code in ('pickup_only','pickup_delivery','dropoff_pickup','dropoff_delivery')
  ),
  constraint quote_logistics_fee_check check (fee_amount in (0.00,9.99,19.99)),
  constraint quote_logistics_payment_scope_check check (
    payment_scope is null or payment_scope in ('full','fee_only')
  ),
  constraint quote_logistics_payment_status_check check (
    payment_status in ('not_applicable','pending','pending_verification','paid_confirmed')
  ),
  constraint quote_logistics_payment_method_check check (
    payment_method is null or payment_method in ('Card','Zelle','Venmo')
  ),
  constraint quote_logistics_provider_check check (
    provider is null or provider in ('stripe','manual')
  )
);

create index quote_logistics_job_idx on public.quote_logistics(job_id);
create index quote_logistics_payment_idx on public.quote_logistics(unit_id,payment_status);

alter table public.quote_logistics enable row level security;
create policy quote_logistics_read on public.quote_logistics
for select to authenticated
using ((select private.can_access(quote_logistics.unit_id)));

grant select, references, trigger, truncate, maintain on public.quote_logistics to service_role;
grant select on public.quote_logistics to authenticated;

create table public.logistics_payment_attempts (
  id uuid primary key,
  unit_id uuid not null references public.business_units(id),
  quote_id uuid not null references public.quotes(id),
  job_id uuid not null references public.jobs(id),
  provider text not null,
  method text not null,
  payment_scope text not null,
  amount numeric(14,2) not null check (amount > 0),
  status text not null default 'pending',
  provider_reference text,
  payment_request_id uuid references public.payment_requests(id) on delete set null,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  constraint logistics_payment_attempts_provider_check check (provider in ('stripe','manual')),
  constraint logistics_payment_attempts_method_check check (method in ('Card','Zelle','Venmo')),
  constraint logistics_payment_attempts_scope_check check (payment_scope in ('full','fee_only')),
  constraint logistics_payment_attempts_status_check check (
    status in ('pending','pending_verification','paid_confirmed','failed','cancelled')
  )
);

create unique index logistics_payment_attempts_provider_reference_key
on public.logistics_payment_attempts(provider,provider_reference)
where provider_reference is not null;

create index logistics_payment_attempts_job_idx
on public.logistics_payment_attempts(job_id,created_at desc);

alter table public.logistics_payment_attempts enable row level security;
create policy logistics_payment_attempts_read on public.logistics_payment_attempts
for select to authenticated
using ((select private.can_access(logistics_payment_attempts.unit_id)));

grant select, references, trigger, truncate, maintain on public.logistics_payment_attempts to service_role;
grant select on public.logistics_payment_attempts to authenticated;

alter table public.pick_return_stops
  add column address text,
  add column customer_phone text,
  add column customer_email text,
  add column requested_at timestamptz;

alter table public.pick_return_stops
  drop constraint pick_return_stops_status_check;
alter table public.pick_return_stops
  add constraint pick_return_stops_status_check check (
    status in ('Requested','Scheduled','En Route','Arrived','Completed','Failed','Cancelled')
  );

alter table public.pick_return_orders
  drop constraint pick_return_orders_service_method_check,
  drop constraint pick_return_orders_pickup_status_check,
  drop constraint pick_return_orders_return_status_check;

alter table public.pick_return_orders
  add constraint pick_return_orders_service_method_check check (
    service_method in ('Pickup Only','Pickup & Delivery','Drop-off + Delivery','Pickup & Return')
  ),
  add constraint pick_return_orders_pickup_status_check check (
    pickup_status in ('Not Applicable','Not Scheduled','Scheduled','En Route','Arrived','Picked Up','Failed','Cancelled')
  ),
  add constraint pick_return_orders_return_status_check check (
    return_status in ('Not Applicable','Not Ready','Delivery In Progress','Scheduled','En Route','Arrived','Delivered','Cancelled')
  );

alter table public.payment_requests
  add column provider text,
  add column provider_reference text,
  add column payment_scope text;

alter table public.payment_requests
  drop constraint payment_requests_method_check,
  drop constraint payment_requests_purpose_check;

alter table public.payment_requests
  add constraint payment_requests_method_check check (
    method in ('Cash','Zelle','Venmo','Card')
  ),
  add constraint payment_requests_purpose_check check (
    purpose in ('Final Balance','Pickup Fee','Cancellation Balance','Logistics Fee','Logistics Full Prepayment')
  ),
  add constraint payment_requests_provider_check check (
    provider is null or provider in ('stripe','manual')
  ),
  add constraint payment_requests_payment_scope_check check (
    payment_scope is null or payment_scope in ('full','fee_only')
  );

create or replace function private.logistics_option(p_code text)
returns jsonb
language sql
immutable
set search_path=''
as $$
  select case p_code
    when 'pickup_only' then jsonb_build_object(
      'code','pickup_only',
      'name','Pickup Only',
      'fee',9.99,
      'pickup',true,
      'delivery',false,
      'description','We pick up your items from your address. You pick up the finished work at our shop.'
    )
    when 'pickup_delivery' then jsonb_build_object(
      'code','pickup_delivery',
      'name','Pickup & Delivery',
      'fee',19.99,
      'pickup',true,
      'delivery',true,
      'description','We pick up your items and deliver the finished work back to you.'
    )
    when 'dropoff_pickup' then jsonb_build_object(
      'code','dropoff_pickup',
      'name','Drop-off & Pickup',
      'fee',0.00,
      'pickup',false,
      'delivery',false,
      'description','You drop off your items at our shop and pick up the finished work there.'
    )
    when 'dropoff_delivery' then jsonb_build_object(
      'code','dropoff_delivery',
      'name','Drop-off + Delivery',
      'fee',9.99,
      'pickup',false,
      'delivery',true,
      'description','You drop off your items at our shop. We deliver the finished work back to you.'
    )
    else null
  end;
$$;

revoke all on function private.logistics_option(text) from public;

create or replace function private.logistics_predefined(p_quote uuid)
returns text
language sql
stable
security definer
set search_path=''
as $$
  select coalesce(
    (select l.option_code from public.quote_logistics l where l.quote_id=p_quote),
    (
      select case
        when q.source='public_get_tagged'
         and private.get_tagged_is_pickup(coalesce(q.intake_details,'{}'::jsonb))
        then 'pickup_delivery'
        else null
      end
      from public.quotes q
      where q.id=p_quote
    )
  );
$$;

revoke all on function private.logistics_predefined(uuid) from public;

create or replace function private.quote_logistics_context(p_quote uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  q public.quotes;
  c public.customers;
  l public.quote_logistics;
  predefined text;
  selected text;
  option_data jsonb;
  available jsonb:='[]'::jsonb;
  zone text;
  max_stops integer;
begin
  select * into q from public.quotes where id=p_quote;
  if q.id is null then return null; end if;

  select c0.* into c
  from public.commercial_flows f
  join public.customers c0 on c0.id=f.customer_id
  where f.id=q.flow_id;

  select * into l from public.quote_logistics where quote_id=q.id;
  predefined:=private.logistics_predefined(q.id);
  selected:=coalesce(l.option_code,predefined);
  option_data:=private.logistics_option(selected);

  select timezone,max_pickup_stops_per_saturday
  into zone,max_stops
  from public.unit_settings
  where unit_id=q.unit_id;

  if l.locked_at is null then
    select coalesce(jsonb_agg(x.obj order by x.route_date),'[]'::jsonb)
    into available
    from (
      select d.route_date,
             jsonb_build_object(
               'date',d.route_date,
               'remaining',greatest(max_stops-coalesce(used.used_stops,0),0),
               'window','8:00 AM–12:00 PM'
             ) obj
      from (
        select gs::date route_date
        from generate_series(
          ((now() at time zone zone)::date + 1)::timestamp,
          ((now() at time zone zone)::date + 70)::timestamp,
          interval '1 day'
        ) gs
        where extract(isodow from gs)=6
      ) d
      left join lateral (
        select count(*)::integer used_stops
        from public.pick_return_routes r
        join public.pick_return_stops s on s.route_id=r.id
        where r.unit_id=q.unit_id
          and r.route_date=d.route_date
          and r.leg='Pickup'
          and s.status not in ('Cancelled','Failed')
      ) used on true
      where coalesce(used.used_stops,0)<max_stops
      order by d.route_date
      limit 8
    ) x;
  end if;

  return jsonb_build_object(
    'requires_selection',l.quote_id is null and predefined is null,
    'predefined',l.quote_id is null and predefined is not null,
    'selected_option',selected,
    'option',option_data,
    'options',jsonb_build_array(
      private.logistics_option('pickup_only'),
      private.logistics_option('pickup_delivery'),
      private.logistics_option('dropoff_pickup'),
      private.logistics_option('dropoff_delivery')
    ),
    'personal_address',nullif(trim(c.address),''),
    'company_address',nullif(trim(c.company_address),''),
    'pickup_address',l.pickup_address,
    'delivery_address',l.delivery_address,
    'saturday_date',l.saturday_date,
    'available_saturdays',available,
    'payment_status',l.payment_status,
    'payment_scope',l.payment_scope,
    'payment_method',l.payment_method,
    'locked',l.locked_at is not null
  );
end $$;

revoke all on function private.quote_logistics_context(uuid) from public;

create or replace function private.quote_snapshot(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  q public.quotes;
  f public.commercial_flows;
  c public.customers;
  p public.policies;
  l public.quote_logistics;
  base_items jsonb;
  all_items jsonb;
  base_total numeric(14,2);
  total_value numeric(14,2);
  opt jsonb;
begin
  select * into q from public.quotes where id=p_id;
  select * into f from public.commercial_flows where id=q.flow_id;
  select * into c from public.customers where id=f.customer_id;
  select * into p from public.policies where id=q.policy_id;
  select * into l from public.quote_logistics where quote_id=q.id;

  select
    coalesce(jsonb_agg(to_jsonb(i)-'unit_id' order by i.sort_order,i.id),'[]'::jsonb),
    coalesce(sum(i.quantity*i.unit_price),0)
  into base_items,base_total
  from public.quote_items i
  where i.quote_id=q.id
    and coalesce(i.pricing->>'kind','')<>'pickup_service_fee';

  all_items:=base_items;
  total_value:=base_total;

  if l.quote_id is not null then
    opt:=private.logistics_option(l.option_code);
    all_items:=all_items||jsonb_build_array(
      jsonb_build_object(
        'article','Logistics — '||(opt->>'name'),
        'quantity',1,
        'engraving_type','Fee',
        'engraving_text','',
        'unit_price',l.fee_amount,
        'paint_fill',false,
        'colors',0,
        'marks','[]'::jsonb,
        'notes',opt->>'description',
        'pricing',jsonb_build_object(
          'kind','logistics_service',
          'option_code',l.option_code
        )
      )
    );
    total_value:=total_value+l.fee_amount;
  end if;

  return jsonb_build_object(
    'id',q.id,
    'code',q.code,
    'revision',q.revision,
    'notes',q.notes,
    'customer_id',c.id,
    'company',jsonb_build_object(
      'name',c.company_name,
      'email',c.company_email,
      'phone',c.company_phone,
      'address',c.company_address
    ),
    'customer_name',c.name,
    'customer_email',c.email,
    'customer_phone',c.phone,
    'customer_address',c.address,
    'expires_at',q.expires_at,
    'items',all_items,
    'total',total_value,
    'policy',jsonb_build_object(
      'id',p.id,
      'title',p.title,
      'version',p.version,
      'content',p.content
    ),
    'logistics',case
      when l.quote_id is null then null
      else jsonb_build_object(
        'option_code',l.option_code,
        'option_name',opt->>'name',
        'fee_amount',l.fee_amount,
        'pickup_address',l.pickup_address,
        'delivery_address',l.delivery_address,
        'saturday_date',l.saturday_date,
        'payment_status',l.payment_status
      )
    end
  );
end $$;

revoke all on function private.quote_snapshot(uuid) from public;

create or replace function public.public_quote(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  lnk private.public_links;
  q public.quotes;
  a public.agreements;
  snap jsonb;
  job_code text;
  base_items jsonb;
  base_total numeric(14,2);
begin
  select * into lnk
  from private.public_links
  where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and quote_id is not null;

  if not found then raise exception 'This link is invalid or expired'; end if;

  select * into q from public.quotes where id=lnk.quote_id;
  select * into a from public.agreements where quote_id=q.id;

  if a.id is null and (
    lnk.expires_at<=now()
    or q.expires_at<=now()
    or q.status not in ('Sent','Viewed','Agreement Pending')
  ) then
    raise exception 'Quote is unavailable or expired';
  end if;

  update public.quotes set status='Viewed'
  where id=q.id and status='Sent';

  select code into job_code from public.jobs where id=a.job_id;
  snap:=coalesce(a.commercial_snapshot,q.review_snapshot,private.quote_snapshot(q.id));

  if a.id is null then
    select
      coalesce(jsonb_agg(to_jsonb(i)-'unit_id' order by i.sort_order,i.id),'[]'::jsonb),
      coalesce(sum(i.quantity*i.unit_price),0)
    into base_items,base_total
    from public.quote_items i
    where i.quote_id=q.id
      and coalesce(i.pricing->>'kind','')<>'pickup_service_fee';

    snap:=snap||jsonb_build_object(
      'items',base_items,
      'total',base_total,
      'logistics',private.quote_logistics_context(q.id)
    );
  else
    if a.commercial_snapshot is null then
      snap:=snap||jsonb_build_object(
        'customer_name',a.accepted_name,
        'customer_email',a.accepted_email,
        'customer_phone',a.accepted_phone,
        'total',(select amount from public.sale_versions where quote_id=q.id limit 1),
        'items',(select approved_items from public.sale_versions where quote_id=q.id limit 1)
      );
    end if;
    snap:=snap||jsonb_build_object(
      'policy',(snap->'policy')||jsonb_build_object('content',a.content_snapshot),
      'logistics',private.quote_logistics_context(q.id)
    );
  end if;

  return snap||jsonb_build_object(
    'status',case when q.status='Sent' then 'Viewed' else q.status end,
    'accepted',a.id is not null,
    'accepted_at',a.accepted_at,
    'snapshot_hash',a.snapshot_hash,
    'job_code',job_code
  );
end $$;

revoke all on function public.public_quote(text) from public;
grant execute on function public.public_quote(text) to anon,authenticated;

create or replace function private.freeze_acceptance()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  q public.quotes;
  snap jsonb;
begin
  select * into q from public.quotes where id=new.quote_id;
  if exists(select 1 from public.quote_logistics where quote_id=q.id) then
    snap:=private.quote_snapshot(q.id);
  else
    snap:=coalesce(q.review_snapshot,private.quote_snapshot(q.id));
  end if;

  new.commercial_snapshot:=snap||jsonb_build_object(
    'accepted_at',new.accepted_at,
    'acceptance_type','Quote + Agreement',
    'accepted_name',new.accepted_name,
    'accepted_email',new.accepted_email,
    'accepted_phone',new.accepted_phone
  );
  new.snapshot_hash:=encode(
    sha256(convert_to(new.commercial_snapshot::text,'UTF8')),
    'hex'
  );
  return new;
end $$;

revoke all on function private.freeze_acceptance() from public;

create or replace function public.accept_agreement(
  p_token text,
  p_name text,
  p_email text,
  p_phone text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  q public.quotes;
  f public.commercial_flows;
  jid uuid;
  sid uuid;
  total numeric(14,2);
  items jsonb;
  pol public.policies;
  l public.quote_logistics;
  opt jsonb;
begin
  select x.* into q
  from public.quotes x
  join private.public_links pl on pl.quote_id=x.id
  where pl.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and pl.expires_at>now()
  for update of x;

  if q.id is null then raise exception 'Invalid or expired link'; end if;

  select job_id into jid from public.agreements where quote_id=q.id;
  if jid is not null then return jid; end if;

  if q.status<>'Agreement Pending' then raise exception 'Accept the quote first'; end if;
  if nullif(trim(p_name),'') is null
     or nullif(trim(p_email),'') is null
     or nullif(trim(p_phone),'') is null
  then
    raise exception 'Your name, email and phone are required';
  end if;

  select * into f from public.commercial_flows where id=q.flow_id for update;
  if exists(
    select 1 from public.quotes
    where flow_id=f.id
      and revision>q.revision
      and status in ('Agreement Pending','Accepted')
  ) then
    raise exception 'A newer revision has been accepted';
  end if;

  select * into pol from public.policies where id=q.policy_id;
  select * into l from public.quote_logistics where quote_id=q.id;

  select
    coalesce(sum(i.quantity*i.unit_price),0),
    coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order,i.id),'[]'::jsonb)
  into total,items
  from public.quote_items i
  where i.quote_id=q.id
    and coalesce(i.pricing->>'kind','')<>'pickup_service_fee';

  if l.quote_id is not null then
    opt:=private.logistics_option(l.option_code);
    total:=total+l.fee_amount;
    items:=items||jsonb_build_array(
      jsonb_build_object(
        'article','Logistics — '||(opt->>'name'),
        'quantity',1,
        'engraving_type','Fee',
        'engraving_text','',
        'unit_price',l.fee_amount,
        'paint_fill',false,
        'colors',0,
        'marks','[]'::jsonb,
        'notes',opt->>'description',
        'pricing',jsonb_build_object(
          'kind','logistics_service',
          'option_code',l.option_code
        )
      )
    );
  end if;

  select id into jid from public.jobs where flow_id=f.id;
  if jid is null then
    insert into public.jobs(unit_id,flow_id,quote_id,code)
    values(
      q.unit_id,f.id,q.id,
      'TT-J-'||f.year||'-'||lpad(f.sequence::text,5,'0')
    )
    returning id into jid;

    insert into public.transactions(
      unit_id,type,transaction_date,amount,customer_id,description,category_id
    )
    values(
      q.unit_id,
      'SALE',
      (now() at time zone (
        select timezone from public.unit_settings where unit_id=q.unit_id
      ))::date,
      total,
      f.customer_id,
      'Accepted quote '||q.code,
      (select id from public.categories
       where unit_id=q.unit_id and name='Engraving Services')
    )
    returning id into sid;

    insert into public.sales(
      transaction_id,unit_id,job_id,quote_id,code,approved_items,revision
    )
    values(
      sid,q.unit_id,jid,q.id,
      'TT-S-'||f.year||'-'||lpad(f.sequence::text,5,'0'),
      items,q.revision
    );
  else
    select transaction_id into sid
    from public.sales
    where job_id=jid
    for update;

    if (select collected from public.sale_balances where transaction_id=sid)>total then
      raise exception 'Revision is below collected amount; admin must resolve refund first';
    end if;

    update public.transactions set amount=total where id=sid;
    update public.sales
    set quote_id=q.id,approved_items=items,revision=q.revision
    where transaction_id=sid;
    update public.jobs set quote_id=q.id where id=jid;
  end if;

  insert into public.sale_versions(
    unit_id,sale_id,quote_id,revision,amount,approved_items
  )
  values(q.unit_id,sid,q.id,q.revision,total,items);

  insert into public.agreements(
    unit_id,quote_id,policy_id,customer_id,job_id,
    content_snapshot,accepted_name,accepted_email,accepted_phone
  )
  values(
    q.unit_id,q.id,pol.id,f.customer_id,jid,
    pol.content,trim(p_name),trim(p_email),trim(p_phone)
  );

  update public.quotes
  set status='Revised'
  where flow_id=f.id and id<>q.id and status='Accepted';

  update public.quotes set status='Accepted' where id=q.id;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key
  )
  values(q.unit_id,'Agreement accepted copy',q.id,p_email,'agreement:'||q.id)
  on conflict do nothing;

  return jid;
end $$;

revoke all on function public.accept_agreement(text,text,text,text) from public;

create or replace function private.lock_quote_logistics()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if tg_op='DELETE' then
    if old.locked_at is not null then
      raise exception 'Accepted logistics are locked; create a revised Quote';
    end if;
    return old;
  end if;

  if old.locked_at is not null and (
    new.option_code is distinct from old.option_code
    or new.fee_amount is distinct from old.fee_amount
    or new.pickup_address is distinct from old.pickup_address
    or new.delivery_address is distinct from old.delivery_address
    or new.saturday_date is distinct from old.saturday_date
  ) then
    raise exception 'Accepted logistics are locked; create a revised Quote';
  end if;

  new.updated_at:=now();
  return new;
end $$;

revoke all on function private.lock_quote_logistics() from public;

create trigger quote_logistics_lock
before update or delete on public.quote_logistics
for each row execute function private.lock_quote_logistics();

create or replace function private.enforce_logistics_payment_gate()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if (
    old.work_stage is distinct from new.work_stage
    or old.status is distinct from new.status
  ) and (
    new.status='In Process'
    or new.work_stage in (
      'Receiving Evidence','Preparing','Engraving','Final Evidence',
      'Final Details','Delivery In Progress'
    )
  ) and exists(
    select 1
    from public.quote_logistics l
    where l.quote_id=new.quote_id
      and l.locked_at is not null
      and l.payment_status not in ('paid_confirmed','not_applicable')
  ) then
    raise exception 'Logistics fee must be confirmed before work can start';
  end if;
  return new;
end $$;

revoke all on function private.enforce_logistics_payment_gate() from public;

create trigger jobs_logistics_payment_gate
before update on public.jobs
for each row execute function private.enforce_logistics_payment_gate();

create or replace function private.enforce_logistics_route_leg()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  leg text;
  code text;
begin
  select r.leg into leg from public.pick_return_routes r where r.id=new.route_id;
  select l.option_code into code
  from public.jobs j
  join public.quote_logistics l on l.quote_id=j.quote_id
  where j.id=new.job_id;

  if code is null then return new; end if;

  if leg='Pickup' and code not in ('pickup_only','pickup_delivery') then
    raise exception 'This logistics option does not include ToolTag Pickup';
  end if;
  if leg='Return' and code not in ('pickup_delivery','dropoff_delivery') then
    raise exception 'This logistics option does not include ToolTag Delivery';
  end if;

  return new;
end $$;

revoke all on function private.enforce_logistics_route_leg() from public;

create trigger pick_return_stop_logistics_leg
before insert or update of route_id,job_id on public.pick_return_stops
for each row execute function private.enforce_logistics_route_leg();

create or replace function private.create_pick_return_order_from_agreement()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  fee numeric(14,2);
  token text;
  recipient text;
begin
  -- New logistics are finalized by accept_review_with_logistics.
  if exists(select 1 from public.quote_logistics where quote_id=new.quote_id) then
    return new;
  end if;

  select sum(quantity*unit_price)
  into fee
  from public.quote_items
  where quote_id=new.quote_id
    and pricing->>'kind'='pickup_service_fee';

  if coalesce(fee,0)<=0 then return new; end if;

  insert into public.pick_return_orders(
    job_id,unit_id,fee_amount,fee_status,scheduler_enabled,
    terms_version,terms_snapshot
  )
  values(
    new.job_id,new.unit_id,fee,'Required',false,
    coalesce(new.commercial_snapshot->'policy'->>'version','2.0'),
    new.content_snapshot
  )
  on conflict(job_id) do nothing;

  select l.token into token
  from private.pickup_payment_links l
  where l.job_id=new.job_id and l.expires_at>now();

  if token is null then
    token:=gen_random_uuid()::text||gen_random_uuid()::text;
    insert into private.pickup_payment_links(job_id,token,token_hash,expires_at)
    values(
      new.job_id,
      token,
      encode(sha256(convert_to(token,'UTF8')),'hex'),
      now()+interval '90 days'
    )
    on conflict(job_id) do update
      set token=excluded.token,
          token_hash=excluded.token_hash,
          expires_at=excluded.expires_at,
          created_at=now();
  end if;

  recipient:=coalesce(new.accepted_email,private.job_customer_recipient(new.job_id));

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    new.unit_id,
    'PICKUP_FEE_REQUIRED',
    new.job_id,
    recipient,
    'pickup-fee-required:'||new.job_id,
    jsonb_build_object(
      'template','notification',
      'subject','Pickup fee required — '||(
        select code from public.jobs where id=new.job_id
      ),
      'text','Your $'||to_char(fee,'FM999999990.00')||
             ' Pickup & Return fee must be paid and confirmed before Pickup can be scheduled.',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $$;

revoke all on function private.create_pick_return_order_from_agreement() from public;

create or replace function public.accept_review_with_logistics(
  p_token text,
  p_quote_confirmed boolean,
  p_agreement_confirmed boolean,
  p_logistics jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  jid uuid;
  q public.quotes;
  f public.commercial_flows;
  c public.customers;
  destination text;
  accepted_name text;
  accepted_email text;
  accepted_phone text;
  existing public.quote_logistics;
  predefined text;
  code text;
  opt jsonb;
  fee numeric(14,2);
  pickup_required boolean;
  delivery_required boolean;
  pickup_address text;
  delivery_address text;
  saturday date;
  zone text;
  max_stops integer;
  v_route_id uuid;
  stop_id uuid;
  used_stops integer;
  seq integer;
  window_start timestamptz;
  window_end timestamptz;
  agreement_version text;
begin
  if p_quote_confirmed is distinct from true
     or p_agreement_confirmed is distinct from true
  then
    raise exception 'Both quote and Agreement acknowledgments are required';
  end if;

  select x.* into q
  from public.quotes x
  join private.public_links l on l.quote_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
  for update of x;

  if q.id is null then raise exception 'Quote is unavailable or expired'; end if;

  select * into existing from public.quote_logistics where quote_id=q.id;
  select a.job_id into jid from public.agreements a where a.quote_id=q.id;

  if jid is not null and existing.locked_at is not null then
    return jsonb_build_object(
      'job_id',jid,
      'payment_required',existing.fee_amount>0
        and existing.payment_status<>'paid_confirmed',
      'payment_status',existing.payment_status,
      'payment_path',case
        when existing.fee_amount>0
             and existing.payment_status<>'paid_confirmed'
        then '/review/'||p_token||'/payment'
        else null
      end
    );
  end if;

  if q.expires_at<=now()
     or q.status not in ('Sent','Viewed','Agreement Pending')
  then
    raise exception 'Quote is unavailable or expired';
  end if;

  select * into f from public.commercial_flows where id=q.flow_id;
  select * into c from public.customers where id=f.customer_id and unit_id=q.unit_id;
  select d.recipient into destination
  from private.quote_delivery d where d.quote_id=q.id;

  accepted_name:=coalesce(
    nullif(trim(q.review_snapshot->>'customer_name'),''),
    nullif(trim(c.name),'')
  );
  accepted_email:=coalesce(
    nullif(trim(destination),''),
    nullif(trim(q.review_snapshot->>'customer_email'),''),
    nullif(trim(c.email),'')
  );
  accepted_phone:=case
    when lower(coalesce(accepted_email,''))=
         lower(coalesce(q.review_snapshot->'company'->>'email',c.company_email,''))
    then coalesce(
      nullif(trim(q.review_snapshot->'company'->>'phone'),''),
      nullif(trim(c.company_phone),''),
      nullif(trim(q.review_snapshot->>'customer_phone'),''),
      nullif(trim(c.phone),'')
    )
    else coalesce(
      nullif(trim(q.review_snapshot->>'customer_phone'),''),
      nullif(trim(c.phone),''),
      nullif(trim(q.review_snapshot->'company'->>'phone'),''),
      nullif(trim(c.company_phone),'')
    )
  end;

  if accepted_name is null
     or accepted_email is null
     or accepted_email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     or accepted_phone is null
  then
    raise exception 'Customer contact information is incomplete; update the customer before accepting';
  end if;

  predefined:=private.logistics_predefined(q.id);
  code:=nullif(trim(coalesce(p_logistics->>'option_code','')),'');

  if predefined is not null then
    if code is not null and code<>predefined then
      raise exception 'The logistics method on this Quote is already defined';
    end if;
    code:=predefined;
  end if;

  opt:=private.logistics_option(code);
  if opt is null then raise exception 'Choose a logistics option'; end if;

  fee:=(opt->>'fee')::numeric;
  pickup_required:=(opt->>'pickup')::boolean;
  delivery_required:=(opt->>'delivery')::boolean;

  pickup_address:=nullif(trim(coalesce(p_logistics->>'pickup_address','')),'');
  delivery_address:=nullif(trim(coalesce(p_logistics->>'delivery_address','')),'');

  if pickup_required and pickup_address is null then
    pickup_address:=nullif(trim(coalesce(q.intake_details->'service'->>'address','')),'');
  end if;
  if code='pickup_delivery' and delivery_address is null then
    delivery_address:=pickup_address;
  end if;

  if pickup_required and pickup_address is null then
    raise exception 'Enter a Pickup address';
  end if;
  if delivery_required and delivery_address is null then
    raise exception 'Enter a delivery address';
  end if;

  if pickup_required then
    begin
      saturday:=nullif(p_logistics->>'saturday_date','')::date;
    exception when others then
      raise exception 'Choose an available Saturday';
    end;

    select timezone,max_pickup_stops_per_saturday
    into zone,max_stops
    from public.unit_settings where unit_id=q.unit_id;

    if saturday is null
       or extract(isodow from saturday)<>6
       or saturday<=((now() at time zone zone)::date)
    then
      raise exception 'Choose an available Saturday';
    end if;
  else
    saturday:=null;
    select timezone,max_pickup_stops_per_saturday
    into zone,max_stops
    from public.unit_settings where unit_id=q.unit_id;
  end if;

  insert into public.quote_logistics(
    quote_id,unit_id,option_code,fee_amount,
    pickup_address,delivery_address,saturday_date,payment_status
  )
  values(
    q.id,q.unit_id,code,fee,
    pickup_address,delivery_address,saturday,
    case when fee=0 then 'not_applicable' else 'pending' end
  );

  perform public.accept_quote(p_token);
  jid:=public.accept_agreement(
    p_token,accepted_name,accepted_email,accepted_phone
  );

  update public.quote_logistics
  set job_id=jid,locked_at=now()
  where quote_id=q.id;

  if fee>0 then
    select p.version::text into agreement_version
    from public.policies p where p.id=q.policy_id;

    insert into public.pick_return_orders(
      job_id,unit_id,service_method,fee_amount,fee_status,scheduler_enabled,
      pickup_status,return_status,terms_version,terms_snapshot
    )
    values(
      jid,q.unit_id,opt->>'name',fee,'Required',false,
      case when pickup_required then 'Not Scheduled' else 'Not Applicable' end,
      case when delivery_required then 'Not Ready' else 'Not Applicable' end,
      coalesce(agreement_version,'current'),
      (select content_snapshot from public.agreements where quote_id=q.id)
    )
    on conflict(job_id) do update set
      service_method=excluded.service_method,
      fee_amount=excluded.fee_amount,
      fee_status=case
        when public.pick_return_orders.fee_status='Confirmed' then 'Confirmed'
        else excluded.fee_status
      end,
      pickup_status=excluded.pickup_status,
      return_status=excluded.return_status,
      terms_version=excluded.terms_version,
      terms_snapshot=excluded.terms_snapshot,
      updated_at=now();
  end if;

  if pickup_required then
    insert into public.pick_return_routes(unit_id,route_date,leg)
    values(q.unit_id,saturday,'Pickup')
    on conflict(unit_id,route_date,leg)
    do update set route_date=excluded.route_date
    returning id into v_route_id;

    perform 1
    from public.pick_return_routes r
    where r.id=v_route_id
    for update;

    select count(*)::integer into used_stops
    from public.pick_return_stops s
    where s.route_id=v_route_id
      and s.status not in ('Cancelled','Failed');

    if used_stops>=max_stops then
      raise exception 'That Saturday is at capacity; choose another Saturday';
    end if;

    select coalesce(max(s.sequence),0)+1 into seq
    from public.pick_return_stops s
    where s.route_id=v_route_id;

    window_start:=(saturday+time '08:00') at time zone zone;
    window_end:=(saturday+time '12:00') at time zone zone;

    insert into public.pick_return_stops(
      unit_id,route_id,job_id,sequence,status,
      window_start,window_end,eta,address,customer_phone,customer_email,requested_at
    )
    values(
      q.unit_id,v_route_id,jid,seq,'Requested',
      window_start,window_end,null,pickup_address,
      accepted_phone,accepted_email,now()
    )
    returning id into stop_id;

    update public.quote_logistics
    set pickup_stop_id=stop_id
    where quote_id=q.id;
  end if;

  insert into public.notifications(
    unit_id,event,entity_id,dedupe_key,payload
  )
  select
    q.unit_id,
    'Drive commercial archive pending',
    q.id,
    'drive-commercial:'||q.id,
    jsonb_build_object(
      'job_id',jid,
      'quote_id',q.id,
      'agreement_id',a.id,
      'snapshot_hash',a.snapshot_hash,
      'folders',jsonb_build_array('Quote','Agreement')
    )
  from public.agreements a
  where a.quote_id=q.id
  on conflict do nothing;

  update public.notifications n
  set payload=jsonb_build_object(
    'template','confirmation',
    'template_version',1,
    'snapshot',a.commercial_snapshot,
    'job_code',j.code,
    'delivery','Pending Integration'
  )
  from public.agreements a
  join public.jobs j on j.id=a.job_id
  where n.dedupe_key='agreement:'||q.id
    and a.quote_id=q.id
    and n.payload='{}'::jsonb;

  if q.status<>'Accepted' then
    perform private.freeze_accepted_document(q.id);
  end if;

  return jsonb_build_object(
    'job_id',jid,
    'payment_required',fee>0,
    'payment_status',case when fee=0 then 'not_applicable' else 'pending' end,
    'payment_path',case when fee>0 then '/review/'||p_token||'/payment' else null end
  );
end $$;

revoke all on function public.accept_review_with_logistics(text,boolean,boolean,jsonb) from public;
grant execute on function public.accept_review_with_logistics(text,boolean,boolean,jsonb)
to anon,authenticated;

create or replace function public.accept_review(
  p_token text,
  p_quote_confirmed boolean,
  p_agreement_confirmed boolean,
  p_name text,
  p_email text,
  p_phone text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  result jsonb;
begin
  result:=public.accept_review_with_logistics(
    p_token,p_quote_confirmed,p_agreement_confirmed,null
  );
  return (result->>'job_id')::uuid;
end $$;

revoke all on function public.accept_review(text,boolean,boolean,text,text,text) from public;
grant execute on function public.accept_review(text,boolean,boolean,text,text,text)
to anon,authenticated;

create or replace function public.public_logistics_payment(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  q public.quotes;
  a public.agreements;
  j public.jobs;
  l public.quote_logistics;
  settings public.unit_settings;
  due numeric(14,2);
begin
  select x.* into q
  from public.quotes x
  join private.public_links pl on pl.quote_id=x.id
  where pl.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if q.id is null then raise exception 'Payment link unavailable'; end if;

  select * into a from public.agreements where quote_id=q.id;
  if a.id is null then raise exception 'Accept the Quote and Agreement first'; end if;

  select * into j from public.jobs where id=a.job_id;
  select * into l from public.quote_logistics where quote_id=q.id;
  if l.quote_id is null or l.locked_at is null then
    raise exception 'Logistics selection is unavailable';
  end if;

  select * into settings from public.unit_settings where unit_id=q.unit_id;
  select balance_due into due from public.job_commercial_totals where id=j.id;

  return jsonb_build_object(
    'job_id',j.id,
    'job_code',j.code,
    'customer_name',a.accepted_name,
    'fee_amount',l.fee_amount,
    'payment_status',l.payment_status,
    'payment_scope',l.payment_scope,
    'payment_method',l.payment_method,
    'balance_due',coalesce(due,0),
    'memo',j.code||' '||a.accepted_name,
    'methods',jsonb_build_object(
      'zelle',settings.zelle_email,
      'venmo',settings.venmo_handle
    )
  );
end $$;

revoke all on function public.public_logistics_payment(text) from public;
grant execute on function public.public_logistics_payment(text) to anon,authenticated;

create or replace function public.prepare_logistics_payment(
  p_token text,
  p_scope text,
  p_method text,
  p_attempt uuid
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  q public.quotes;
  a public.agreements;
  j public.jobs;
  l public.quote_logistics;
  s public.unit_settings;
  amount_due numeric(14,2);
  provider_name text;
begin
  if p_scope not in ('full','fee_only') then raise exception 'Choose a payment option'; end if;
  if p_method not in ('Card','Zelle','Venmo') then raise exception 'Choose Card, Zelle, or Venmo'; end if;

  select x.* into q
  from public.quotes x
  join private.public_links pl on pl.quote_id=x.id
  where pl.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if q.id is null then raise exception 'Payment link unavailable'; end if;
  select * into a from public.agreements where quote_id=q.id;
  if a.id is null then raise exception 'Accept the Quote and Agreement first'; end if;
  select * into j from public.jobs where id=a.job_id for update;
  select * into l from public.quote_logistics where quote_id=q.id for update;
  select * into s from public.unit_settings where unit_id=q.unit_id;

  if l.fee_amount<=0 or l.payment_status='not_applicable' then
    raise exception 'No logistics payment is required';
  end if;
  if l.payment_status='paid_confirmed' then
    raise exception 'Logistics payment is already confirmed';
  end if;

  if p_method='Zelle' and nullif(trim(s.zelle_email),'') is null then
    raise exception 'Zelle is not configured yet';
  end if;
  if p_method='Venmo' and nullif(trim(s.venmo_handle),'') is null then
    raise exception 'Venmo is not configured yet';
  end if;

  if p_scope='fee_only' then
    amount_due:=l.fee_amount;
  else
    select balance_due into amount_due
    from public.job_commercial_totals where id=j.id;
  end if;

  if coalesce(amount_due,0)<=0 then raise exception 'There is no balance due'; end if;

  provider_name:=case when p_method='Card' then 'stripe' else 'manual' end;

  insert into public.logistics_payment_attempts(
    id,unit_id,quote_id,job_id,provider,method,payment_scope,amount,status
  )
  values(
    p_attempt,q.unit_id,q.id,j.id,provider_name,p_method,p_scope,amount_due,'pending'
  );

  return jsonb_build_object(
    'attempt_id',p_attempt,
    'quote_id',q.id,
    'job_id',j.id,
    'job_code',j.code,
    'customer_name',a.accepted_name,
    'customer_email',a.accepted_email,
    'amount',amount_due,
    'fee_amount',l.fee_amount,
    'scope',p_scope,
    'method',p_method,
    'memo',j.code||' '||a.accepted_name,
    'zelle',s.zelle_email,
    'venmo',s.venmo_handle
  );
end $$;

revoke all on function public.prepare_logistics_payment(text,text,text,uuid) from public;
grant execute on function public.prepare_logistics_payment(text,text,text,uuid)
to anon,authenticated;

create or replace function public.mark_logistics_manual_submitted(
  p_token text,
  p_attempt uuid
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  q public.quotes;
  a public.agreements;
  attempt public.logistics_payment_attempts;
  request_id uuid;
  purpose_value text;
begin
  select x.* into q
  from public.quotes x
  join private.public_links pl on pl.quote_id=x.id
  where pl.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if q.id is null then raise exception 'Payment link unavailable'; end if;
  select * into a from public.agreements where quote_id=q.id;
  if a.id is null then raise exception 'Accept the Quote and Agreement first'; end if;

  select * into attempt
  from public.logistics_payment_attempts
  where id=p_attempt and quote_id=q.id
  for update;

  if attempt.id is null or attempt.provider<>'manual' then
    raise exception 'Payment attempt unavailable';
  end if;

  if attempt.status='pending_verification' then
    return jsonb_build_object(
      'status','pending_verification',
      'attempt_id',attempt.id,
      'amount',attempt.amount
    );
  end if;

  if attempt.status<>'pending' then raise exception 'Payment attempt is no longer active'; end if;

  if exists(
    select 1 from public.payment_requests
    where job_id=attempt.job_id
      and purpose in ('Logistics Fee','Logistics Full Prepayment')
      and status='Pending Verification'
  ) then
    raise exception 'A logistics payment is already awaiting verification';
  end if;

  purpose_value:=case
    when attempt.payment_scope='full' then 'Logistics Full Prepayment'
    else 'Logistics Fee'
  end;

  insert into public.payment_requests(
    request_key,unit_id,job_id,method,amount,status,purpose,
    provider,provider_reference,payment_scope
  )
  values(
    attempt.id,attempt.unit_id,attempt.job_id,attempt.method,attempt.amount,
    'Pending Verification',purpose_value,'manual','manual:'||attempt.id,
    attempt.payment_scope
  )
  returning id into request_id;

  update public.logistics_payment_attempts
  set status='pending_verification',
      provider_reference='manual:'||id,
      payment_request_id=request_id
  where id=attempt.id;

  update public.quote_logistics
  set payment_scope=attempt.payment_scope,
      payment_status='pending_verification',
      payment_method=attempt.method,
      provider='manual',
      provider_reference='manual:'||attempt.id
  where quote_id=attempt.quote_id;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    attempt.unit_id,
    'LOGISTICS_PAYMENT_SUBMITTED',
    request_id,
    'payments@tooltag.martinlab.studio',
    'logistics-payment-submitted:'||request_id,
    jsonb_build_object(
      'template','notification',
      'subject','Logistics payment submitted — '||(
        select code from public.jobs where id=attempt.job_id
      ),
      'text',
        'Method: '||attempt.method||
        E'\nAmount: $'||to_char(attempt.amount,'FM999999990.00')||
        E'\nStatus: Pending Verification',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'status','pending_verification',
    'attempt_id',attempt.id,
    'payment_request_id',request_id,
    'amount',attempt.amount
  );
end $$;

revoke all on function public.mark_logistics_manual_submitted(text,uuid) from public;
grant execute on function public.mark_logistics_manual_submitted(text,uuid)
to anon,authenticated;

create or replace function public.attach_logistics_card_session(
  p_token text,
  p_attempt uuid,
  p_provider_reference text
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  qid uuid;
  attempt public.logistics_payment_attempts;
begin
  select x.id into qid
  from public.quotes x
  join private.public_links pl on pl.quote_id=x.id
  where pl.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  select * into attempt
  from public.logistics_payment_attempts
  where id=p_attempt and quote_id=qid
  for update;

  if attempt.id is null
     or attempt.provider<>'stripe'
     or attempt.method<>'Card'
     or attempt.status<>'pending'
  then
    raise exception 'Card payment attempt unavailable';
  end if;

  update public.logistics_payment_attempts
  set provider_reference=p_provider_reference
  where id=attempt.id;

  update public.quote_logistics
  set payment_scope=attempt.payment_scope,
      payment_status='pending',
      payment_method='Card',
      provider='stripe',
      provider_reference=p_provider_reference
  where quote_id=attempt.quote_id;
end $$;

revoke all on function public.attach_logistics_card_session(text,uuid,text) from public;
grant execute on function public.attach_logistics_card_session(text,uuid,text)
to anon,authenticated;

create or replace function private.sync_logistics_payment_confirmation()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  l public.quote_logistics;
  s public.pick_return_stops;
  recipient text;
begin
  if new.status<>'Confirmed'
     or old.status='Confirmed'
     or new.purpose not in ('Logistics Fee','Logistics Full Prepayment')
  then
    return new;
  end if;

  select * into j from public.jobs where id=new.job_id;
  select * into l from public.quote_logistics where quote_id=j.quote_id for update;

  if l.quote_id is null then return new; end if;

  update public.quote_logistics
  set payment_scope=coalesce(new.payment_scope,l.payment_scope),
      payment_status='paid_confirmed',
      payment_method=new.method,
      provider=coalesce(new.provider,l.provider),
      provider_reference=coalesce(new.provider_reference,l.provider_reference)
  where quote_id=l.quote_id;

  update public.logistics_payment_attempts
  set status='paid_confirmed',
      confirmed_at=coalesce(confirmed_at,now()),
      payment_request_id=new.id
  where id=new.request_key;

  if exists(select 1 from public.pick_return_orders where job_id=j.id) then
    update public.pick_return_orders
    set fee_status='Confirmed',
        scheduler_enabled=true,
        updated_at=now()
    where job_id=j.id;
  end if;

  if l.pickup_stop_id is not null then
    update public.pick_return_stops
    set status='Scheduled'
    where id=l.pickup_stop_id and status='Requested'
    returning * into s;

    if s.id is not null then
      update public.pick_return_orders
      set pickup_status='Scheduled',
          pickup_window_start=s.window_start,
          pickup_window_end=s.window_end,
          pickup_eta=null,
          updated_at=now()
      where job_id=j.id;
    end if;
  end if;

  recipient:=private.job_customer_recipient(j.id);

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,
    'LOGISTICS_PAYMENT_CONFIRMED',
    new.id,
    recipient,
    'logistics-payment-confirmed:'||new.id,
    jsonb_build_object(
      'template','notification',
      'subject','Logistics payment confirmed — '||j.code,
      'text',
        'ToolTag confirmed your logistics payment of $'||
        to_char(coalesce(new.confirmed_amount,new.amount),'FM999999990.00')||
        '. Your Job can now continue to the applicable logistics/work stage.',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $$;

revoke all on function private.sync_logistics_payment_confirmation() from public;

create trigger payment_requests_sync_logistics
after update of status on public.payment_requests
for each row execute function private.sync_logistics_payment_confirmation();

create or replace function public.confirm_logistics_card_payment(
  p_attempt uuid,
  p_provider_reference text,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  role_name text;
  attempt public.logistics_payment_attempts;
  j public.jobs;
  request_id uuid;
  purpose_value text;
  collection_account uuid;
  due numeric(14,2);
  remaining numeric(14,2);
  alloc numeric(14,2);
  paid numeric(14,2):=0;
  rec record;
  tid uuid;
  tids uuid[]:='{}';
begin
  role_name:=coalesce(
    nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',
    current_setting('request.jwt.claim.role',true),
    ''
  );
  if role_name<>'service_role' then
    raise exception 'Server credentials required' using errcode='42501';
  end if;

  select * into attempt
  from public.logistics_payment_attempts
  where id=p_attempt
  for update;

  if attempt.id is null or attempt.provider<>'stripe' then
    raise exception 'Card payment attempt unavailable';
  end if;

  if attempt.status='paid_confirmed' then
    return jsonb_build_object(
      'status','paid_confirmed',
      'attempt_id',attempt.id,
      'payment_request_id',attempt.payment_request_id
    );
  end if;

  if attempt.status<>'pending'
     or attempt.provider_reference is distinct from p_provider_reference
     or round(attempt.amount,2)<>round(p_amount,2)
  then
    raise exception 'Card payment confirmation does not match the pending attempt';
  end if;

  select * into j from public.jobs where id=attempt.job_id for update;
  select payment_account_id into collection_account
  from public.unit_settings where unit_id=attempt.unit_id;

  if collection_account is null then
    raise exception 'Payment account is not configured';
  end if;

  select balance_due into due
  from public.job_commercial_totals where id=j.id;

  if coalesce(due,0)<=0 then
    raise exception 'This Job is already paid in full';
  end if;

  purpose_value:=case
    when attempt.payment_scope='full' then 'Logistics Full Prepayment'
    else 'Logistics Fee'
  end;

  insert into public.payment_requests(
    request_key,unit_id,job_id,method,amount,status,purpose,
    provider,provider_reference,payment_scope
  )
  values(
    attempt.id,attempt.unit_id,attempt.job_id,'Card',attempt.amount,
    'Pending Verification',purpose_value,'stripe',p_provider_reference,
    attempt.payment_scope
  )
  returning id into request_id;

  remaining:=least(attempt.amount,due);

  for rec in
    select *
    from (
      select 0 as sort_order,s.transaction_id,s.balance_due,s.customer_id
      from public.sale_balances s
      where s.job_id=j.id
        and s.transaction_status<>'Voided'
        and s.balance_due>0
      union all
      select x.sequence as sort_order,s.transaction_id,s.balance_due,s.customer_id
      from public.job_extensions x
      join public.sale_balances s on s.transaction_id=x.sale_id
      where x.job_id=j.id
        and x.status in ('Approved','Completed')
        and s.transaction_status<>'Voided'
        and s.balance_due>0
    ) x
    order by sort_order,transaction_id
  loop
    exit when remaining<=0;
    alloc:=least(remaining,rec.balance_due);

    insert into public.transactions(
      unit_id,account_id,type,transaction_date,amount,customer_id,
      description,payment_method,reference,created_by
    )
    values(
      attempt.unit_id,
      collection_account,
      'COLLECTION',
      (now() at time zone (
        select timezone from public.unit_settings where unit_id=attempt.unit_id
      ))::date,
      alloc,
      rec.customer_id,
      case
        when attempt.payment_scope='full'
        then 'Verified full prepayment · '||j.code
        else 'Verified logistics fee · '||j.code
      end,
      'Card',
      'STRIPE:'||p_provider_reference,
      null
    )
    returning id into tid;

    insert into public.collections(transaction_id,unit_id,sale_id)
    values(tid,attempt.unit_id,rec.transaction_id);

    tids:=array_append(tids,tid);
    paid:=paid+alloc;
    remaining:=remaining-alloc;
  end loop;

  if paid<=0 then raise exception 'No outstanding sale balance was available'; end if;

  update public.payment_requests
  set status='Confirmed',
      confirmed_at=now(),
      confirmed_amount=paid,
      transaction_ids=tids
  where id=request_id;

  update public.logistics_payment_attempts
  set status='paid_confirmed',
      confirmed_at=now(),
      payment_request_id=request_id
  where id=attempt.id;

  return jsonb_build_object(
    'status','paid_confirmed',
    'attempt_id',attempt.id,
    'payment_request_id',request_id,
    'confirmed_amount',paid
  );
end $$;

revoke all on function public.confirm_logistics_card_payment(uuid,text,numeric) from public;
grant execute on function public.confirm_logistics_card_payment(uuid,text,numeric)
to service_role;

create or replace function public.save_settings(p jsonb)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  u uuid:=(p->>'unit_id')::uuid;
  max_stops integer;
begin
  perform private.require_admin(u);

  if p ? 'timezone'
     and not exists(select 1 from pg_timezone_names where name=p->>'timezone')
  then
    raise exception 'Invalid timezone';
  end if;

  if p ? 'boft_url'
     and nullif(p->>'boft_url','') is not null
     and p->>'boft_url' !~ '^https://'
  then
    raise exception 'BOFT URL must use HTTPS';
  end if;

  if p ? 'max_pickup_stops_per_saturday' then
    max_stops:=(p->>'max_pickup_stops_per_saturday')::integer;
    if max_stops not between 1 and 100 then
      raise exception 'Saturday Pickup capacity must be between 1 and 100';
    end if;
  end if;

  update public.unit_settings
  set timezone=case when p ? 'timezone' then p->>'timezone' else timezone end,
      drive_root_id=case when p ? 'drive_root_id' then nullif(trim(p->>'drive_root_id'),'') else drive_root_id end,
      boft_url=case when p ? 'boft_url' then nullif(trim(p->>'boft_url'),'') else boft_url end,
      annual_vehicle_method=case when p ? 'annual_vehicle_method' then p->>'annual_vehicle_method' else annual_vehicle_method end,
      mileage_rate=case when p ? 'mileage_rate' then nullif(p->>'mileage_rate','')::numeric else mileage_rate end,
      zelle_email=case when p ? 'zelle_email' then nullif(trim(p->>'zelle_email'),'') else zelle_email end,
      venmo_handle=case when p ? 'venmo_handle' then nullif(trim(p->>'venmo_handle'),'') else venmo_handle end,
      max_pickup_stops_per_saturday=coalesce(max_stops,max_pickup_stops_per_saturday)
  where unit_id=u;
end $$;

revoke all on function public.save_settings(jsonb) from public;
grant execute on function public.save_settings(jsonb) to authenticated;

create or replace function public.submit_get_tagged_v2(
  p_key uuid,
  p_network text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  r private.get_tagged_receipts;
  fingerprint text;
  candidates uuid[];
  count_requests integer;
  rate_bucket timestamptz:=
    date_trunc('hour',now())
    + floor(extract(minute from now())/15)*interval '15 minutes';
  contact jsonb:=p_payload->'contact';
  details jsonb:=p_payload;
  method text;
begin
  if coalesce(
    nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',
    current_setting('request.jwt.claim.role',true),
    ''
  )<>'service_role' then
    raise exception 'Server credentials required' using errcode='42501';
  end if;

  if p_payload is null
     or p_network is null
     or p_key is null
     or p_network !~ '^[a-f0-9]{64}$'
     or length(p_payload::text)>100000
     or nullif(trim(contact->>'name'),'') is null
     or coalesce(contact->>'email','') !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     or length(private.get_tagged_phone(contact->>'phone')) not between 7 and 15
     or jsonb_typeof(p_payload->'quote_items') is distinct from 'array'
     or jsonb_array_length(p_payload->'quote_items') not between 1 and 20
  then
    raise exception 'Invalid request';
  end if;

  method:=lower(trim(coalesce(p_payload->'service'->>'method','')));
  if method in ('on-site','on site','mobile / on-site','mobile','onsite') then
    raise exception 'On-site service is temporarily unavailable';
  end if;

  if private.get_tagged_is_pickup(p_payload) then
    details:=jsonb_set(
      details,
      '{service}',
      coalesce(details->'service','{}'::jsonb)
        || jsonb_build_object(
          'method','Pickup',
          'logistics_option','pickup_delivery',
          'logistics_fee',19.99
        ),
      true
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended('tooltag-get-tagged',0));
  fingerprint:=encode(sha256(convert_to(details::text,'UTF8')),'hex');

  select * into r from private.get_tagged_receipts where id=p_key;
  if found then
    if r.fingerprint<>fingerprint then raise exception 'Request already submitted'; end if;
    return jsonb_build_object('reference',r.reference,'status',r.request_status);
  end if;

  insert into private.get_tagged_rate values(p_network,rate_bucket,1)
  on conflict(network,bucket)
  do update set requests=private.get_tagged_rate.requests+1
  returning requests into count_requests;
  if count_requests>5 then raise exception 'Request rate limit'; end if;

  insert into private.get_tagged_rate values('global',rate_bucket,1)
  on conflict(network,bucket)
  do update set requests=private.get_tagged_rate.requests+1
  returning requests into count_requests;
  if count_requests>100 then raise exception 'Request rate limit'; end if;

  delete from private.get_tagged_rate where bucket<now()-interval '2 days';

  lock table public.customers in share row exclusive mode;

  select coalesce(array_agg(c.id),'{}')
  into candidates
  from public.customers c
  where c.unit_id=u
    and (
      lower(trim(c.email))=lower(trim(contact->>'email'))
      or private.get_tagged_phone(c.phone)=private.get_tagged_phone(contact->>'phone')
    );

  insert into private.get_tagged_receipts(
    id,fingerprint,details,matching,candidates,request_status
  )
  values(
    p_key,
    fingerprint,
    details,
    case
      when cardinality(candidates)=0 then 'new'
      when cardinality(candidates)=1 then 'reused'
      else 'review'
    end,
    candidates,
    'Pending'
  )
  returning * into r;

  return jsonb_build_object('reference',r.reference,'status',r.request_status);
end $$;

revoke all on function public.submit_get_tagged_v2(uuid,text,jsonb) from public;
grant execute on function public.submit_get_tagged_v2(uuid,text,jsonb) to service_role;

create or replace function private.create_get_tagged_draft(
  p_receipt uuid,
  p_customer uuid
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  y integer;
  seq integer;
  fid uuid;
  qid uuid;
  r private.get_tagged_receipts;
begin
  select * into r
  from private.get_tagged_receipts
  where id=p_receipt
  for update;

  if r.quote_id is not null then return r.quote_id; end if;

  if not exists(
    select 1 from public.customers where id=p_customer and unit_id=u
  ) then
    raise exception 'Customer not found';
  end if;

  y:=extract(year from now() at time zone (
    select timezone from public.unit_settings where unit_id=u
  ));

  insert into private.annual_sequences(year,value)
  values(y,1)
  on conflict(year) do update
    set value=private.annual_sequences.value+1
  returning value into seq;

  insert into public.commercial_flows(unit_id,customer_id,year,sequence)
  values(u,p_customer,y,seq)
  returning id into fid;

  insert into public.quotes(
    unit_id,flow_id,code,notes,source,intake_details
  )
  values(
    u,
    fid,
    'TT-Q-'||y||'-'||lpad(seq::text,5,'0'),
    r.details->>'notes',
    'public_get_tagged',
    r.details-'quote_items'
  )
  returning id into qid;

  perform private.store_get_tagged_items(
    qid,
    private.get_tagged_scope(r.details->'quote_items')
  );

  update private.get_tagged_receipts
  set quote_id=qid,customer_id=p_customer
  where id=r.id;

  return qid;
end $$;

revoke all on function private.create_get_tagged_draft(uuid,uuid) from public;

create or replace function public.advance_job_item(p_item uuid,p_action text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  wi public.job_items;
  j public.jobs;
  current_sequence integer;
  remaining integer;
  prog jsonb;
  delivery boolean;
  next_item uuid;
begin
  select * into wi from public.job_items where id=p_item for update;
  if wi.id is null then raise exception 'Job item not found'; end if;

  select * into j from public.jobs where id=wi.job_id for update;
  perform private.require_admin(j.unit_id);

  if exists(
    select 1 from public.cancellation_requests c
    where c.job_id=j.id and c.status='Requested'
  ) then
    update public.jobs
    set work_stage='Cancellation Requested / Production Hold',updated_at=now()
    where id=j.id and status<>'Cancelled';

    return jsonb_build_object(
      'blocked',true,'reason','Cancellation request detected',
      'progress',private.job_item_progress(j.id)
    );
  end if;

  if j.status='Cancelled' then raise exception 'This Job is cancelled'; end if;

  select min(sequence) into current_sequence
  from public.job_items
  where job_id=j.id and stage not in ('Finished','Cancelled');

  if current_sequence is distinct from wi.sequence then
    raise exception 'Finish the current item before moving to another item';
  end if;

  if j.work_stage='Cancellation Requested / Production Hold' then
    update public.jobs
    set work_stage=case when wi.stage='Preparation' then 'Preparing' else 'Engraving' end,
        updated_at=now()
    where id=j.id;
  end if;

  if p_action in ('next','preparation-done') and wi.stage='Preparation' then
    update public.job_items
    set stage='Engraving',
        preparation_started_at=coalesce(preparation_started_at,now()),
        engraving_started_at=coalesce(engraving_started_at,now()),
        updated_at=now()
    where id=wi.id;

    update public.jobs
    set status='In Process',work_stage='Engraving',
        customer_stage='Engraving',updated_at=now()
    where id=j.id;

  elsif p_action='finished' and wi.stage='Finished Evidence' then
    update public.job_items
    set stage='Finished',
        finished_at=coalesce(finished_at,now()),
        completed_at=coalesce(completed_at,now()),
        updated_at=now()
    where id=wi.id;

    select id into next_item
    from public.job_items
    where job_id=j.id and stage='Preparation'
    order by sequence limit 1;

    if next_item is not null then
      update public.job_items
      set preparation_started_at=coalesce(preparation_started_at,now()),
          updated_at=now()
      where id=next_item;
    end if;

    select count(*) into remaining
    from public.job_items
    where job_id=j.id and stage not in ('Finished','Cancelled');

    if remaining=0 then
      if exists(select 1 from public.quote_logistics where quote_id=j.quote_id) then
        select exists(
          select 1 from public.quote_logistics
          where quote_id=j.quote_id
            and option_code in ('pickup_delivery','dropoff_delivery')
        ) into delivery;
      else
        select exists(
          select 1 from public.pick_return_orders where job_id=j.id
        ) into delivery;
      end if;

      if delivery then
        update public.pick_return_orders
        set return_status='Delivery In Progress',updated_at=now()
        where job_id=j.id;

        update public.jobs
        set work_stage='Delivery In Progress',
            customer_stage='Final Details',updated_at=now()
        where id=j.id;

        insert into public.notifications(
          unit_id,event,entity_id,recipient,dedupe_key,payload
        )
        select
          j.unit_id,'DELIVERY_IN_PROGRESS',j.id,a.accepted_email,
          'delivery-in-progress:'||j.id,
          jsonb_build_object(
            'template','notification',
            'subject','Delivery in progress — '||j.code,
            'text','Your ToolTag Job is finished and has entered the delivery process.',
            'live_eligible',true
          )
        from public.agreements a
        where a.job_id=j.id
        order by a.accepted_at desc
        limit 1
        on conflict do nothing;
      else
        update public.jobs
        set work_stage='Final Details',
            customer_stage='Final Details',updated_at=now()
        where id=j.id;
      end if;
    else
      update public.jobs
      set work_stage='Engraving',customer_stage='Engraving',updated_at=now()
      where id=j.id;
    end if;
  else
    raise exception 'Invalid item transition';
  end if;

  prog:=private.job_item_progress(j.id);
  return jsonb_build_object(
    'blocked',false,'job_id',j.id,'item_id',wi.id,'progress',prog
  );
end $$;

revoke all on function public.advance_job_item(uuid,text) from public;
grant execute on function public.advance_job_item(uuid,text) to authenticated;

create or replace function public.complete_job_production(p_id uuid)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  token text:=gen_random_uuid()::text||gen_random_uuid()::text;
  total_items integer;
  finished_items integer;
  delivery boolean;
begin
  select * into j from public.jobs where id=p_id for update;
  if j.id is null then raise exception 'Job not found'; end if;

  perform private.require_admin(j.unit_id);

  if private.apply_pending_cancellation(j.id) then return null; end if;

  if exists(select 1 from public.quote_logistics where quote_id=j.quote_id) then
    select exists(
      select 1 from public.quote_logistics
      where quote_id=j.quote_id
        and option_code in ('pickup_delivery','dropoff_delivery')
    ) into delivery;
  else
    select exists(
      select 1 from public.pick_return_orders where job_id=j.id
    ) into delivery;
  end if;

  if delivery then
    raise exception 'This Job must complete the ToolTag delivery flow';
  end if;

  select count(*),count(*) filter(where stage='Finished')
  into total_items,finished_items
  from public.job_items where job_id=j.id;

  if total_items=0 or finished_items<>total_items then
    raise exception 'Finish every Job item before completing production';
  end if;

  if exists(
    select 1 from public.job_extensions
    where job_id=j.id and status in ('Requested','Draft','Sent')
  ) then
    raise exception 'Resolve pending extensions first';
  end if;

  update public.job_extensions
  set status='Completed'
  where job_id=j.id and status='Approved';

  insert into private.delivery_scopes(job_id,snapshot)
  values(j.id,private.job_portal_snapshot(j.id))
  on conflict(job_id) do nothing;

  update public.jobs
  set status='Delivered – Pending Customer Acceptance',
      work_stage='Awaiting Delivery Acceptance',
      customer_stage='Completed',
      delivered_at=coalesce(delivered_at,now()),
      updated_at=now()
  where id=j.id;

  insert into private.public_links(token_hash,unit_id,job_id,expires_at)
  values(
    encode(sha256(convert_to(token,'UTF8')),'hex'),
    j.unit_id,j.id,now()+interval '30 days'
  );

  insert into private.job_mail_links(job_id,token)
  values(j.id,token)
  on conflict(job_id) do update set token=excluded.token;

  insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
  values(
    j.unit_id,'Completion acknowledgment',j.id,'delivery:'||j.id,
    jsonb_build_object('live_eligible',true)
  )
  on conflict do nothing;

  return token;
end $$;

revoke all on function public.complete_job_production(uuid) from public;
grant execute on function public.complete_job_production(uuid) to authenticated;


-- Route-stop integration boundary: keep the existing tracking system untouched,
-- but make each stop self-contained with the contact/address data it needs.
create or replace function private.populate_logistics_route_stop()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  route_leg text;
  route_unit uuid;
  route_day date;
  max_stops integer;
  used_stops integer;
  qid uuid;
  logistics public.quote_logistics;
  agreement public.agreements;
begin
  select r.leg,r.unit_id,r.route_date
  into route_leg,route_unit,route_day
  from public.pick_return_routes r
  where r.id=new.route_id;

  if route_leg is null then return new; end if;

  if route_leg='Pickup' and new.status not in ('Cancelled','Failed') then
    select s.max_pickup_stops_per_saturday
    into max_stops
    from public.unit_settings s
    where s.unit_id=route_unit;

    select count(*)::integer
    into used_stops
    from public.pick_return_stops x
    where x.route_id=new.route_id
      and x.id is distinct from new.id
      and x.status not in ('Cancelled','Failed');

    if used_stops>=coalesce(max_stops,10) then
      raise exception 'That Saturday is at capacity; choose another Saturday';
    end if;
  end if;

  select j.quote_id into qid from public.jobs j where j.id=new.job_id;
  select * into logistics
  from public.quote_logistics l
  where l.quote_id=qid;

  select * into agreement
  from public.agreements a
  where a.job_id=new.job_id
  order by a.accepted_at desc
  limit 1;

  if logistics.quote_id is not null then
    new.address:=coalesce(
      nullif(trim(new.address),''),
      case
        when route_leg='Pickup' then logistics.pickup_address
        when route_leg='Return' then logistics.delivery_address
        else null
      end
    );
  end if;

  new.customer_phone:=coalesce(
    nullif(trim(new.customer_phone),''),
    nullif(trim(agreement.accepted_phone),'')
  );
  new.customer_email:=coalesce(
    nullif(trim(new.customer_email),''),
    nullif(trim(agreement.accepted_email),'')
  );
  new.requested_at:=coalesce(new.requested_at,now());

  return new;
end $$;

revoke all on function private.populate_logistics_route_stop() from public;

create trigger pick_return_stop_logistics_context
before insert or update of route_id,job_id,status,address,customer_phone,customer_email
on public.pick_return_stops
for each row execute function private.populate_logistics_route_stop();


-- Card is a valid collection method only after the payment provider has
-- confirmed it. Preserve all existing movement checks while extending the
-- collection-method allowlist for the Stripe confirmation path.
create or replace function private.movement_integrity()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.type='COLLECTION'
     and (
       new.payment_method is null
       or new.payment_method not in ('Cash','Zelle','Venmo','Card')
     )
  then
    raise exception 'Choose Cash, Zelle, Venmo, or Card';
  end if;

  if new.account_id is not null
     and not exists(
       select 1
       from public.accounts
       where id=new.account_id and active
     )
  then
    raise exception 'Account inactive';
  end if;

  return new;
end $$;

revoke all on function private.movement_integrity() from public;
