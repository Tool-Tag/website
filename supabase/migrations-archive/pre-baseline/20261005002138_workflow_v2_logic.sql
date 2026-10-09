
alter table public.pick_return_orders
  add column hold_until_paid boolean not null default false;

alter table private.get_tagged_receipts
  drop constraint if exists get_tagged_receipts_matching_check;
alter table private.get_tagged_receipts
  add constraint get_tagged_receipts_matching_check
  check (matching in ('new','created','reused','review'));

create or replace function private.get_tagged_is_pickup(p_details jsonb)
returns boolean
language sql
immutable
set search_path=''
as $$
  select lower(trim(coalesce(p_details->'service'->>'method',''))) in (
    'pickup','pick up','pick-up','pickup & return','pick up & return','pick-up & return'
  );
$$;

create or replace function private.ensure_pickup_fee_item(p_quote uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  q public.quotes;
  next_order integer;
begin
  select * into q from public.quotes where id=p_quote for update;
  if q.id is null or not private.get_tagged_is_pickup(q.intake_details) then
    return;
  end if;

  if exists(
    select 1 from public.quote_items
    where quote_id=q.id and pricing->>'kind'='pickup_service_fee'
  ) then
    return;
  end if;

  select coalesce(max(sort_order),-1)+1 into next_order
  from public.quote_items where quote_id=q.id;

  insert into public.quote_items(
    unit_id,quote_id,article,quantity,engraving_type,engraving_text,
    width_mm,height_mm,paint_fill,colors,unit_price,notes,sort_order,
    marks,paint_details,adaptation_fee,paint_fee,additional_engraving_fee,pricing
  )
  values(
    q.unit_id,q.id,'Pickup & Return Service Fee',1,'Fee',null,
    null,null,false,0,10.00,'Required before Pickup scheduling',next_order,
    '[]'::jsonb,'{}'::jsonb,false,false,false,
    jsonb_build_object('kind','pickup_service_fee','locked',true,'terms_version','2.0')
  );
end $$;

create or replace function private.create_get_tagged_draft(p_receipt uuid,p_customer uuid)
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
  select * into r from private.get_tagged_receipts where id=p_receipt for update;
  if r.quote_id is not null then return r.quote_id; end if;
  if not exists(select 1 from public.customers where id=p_customer and unit_id=u) then
    raise exception 'Customer not found';
  end if;

  y:=extract(year from now() at time zone (
    select timezone from public.unit_settings where unit_id=u
  ));

  insert into private.annual_sequences(year,value)
  values(y,1)
  on conflict(year) do update set value=private.annual_sequences.value+1
  returning value into seq;

  insert into public.commercial_flows(unit_id,customer_id,year,sequence)
  values(u,p_customer,y,seq)
  returning id into fid;

  insert into public.quotes(unit_id,flow_id,code,notes,source,intake_details)
  values(
    u,fid,'TT-Q-'||y||'-'||lpad(seq::text,5,'0'),
    r.details->>'notes','public_get_tagged',r.details-'quote_items'
  )
  returning id into qid;

  perform private.store_get_tagged_items(
    qid,
    private.get_tagged_scope(r.details->'quote_items')
  );

  perform private.ensure_pickup_fee_item(qid);

  update private.get_tagged_receipts
  set quote_id=qid,customer_id=p_customer
  where id=p_receipt;

  return qid;
end $$;

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
          'pickup_terms_version','2.0',
          'agreement_version',2,
          'pickup_fee',10.00
        ),
      true
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended('tooltag-get-tagged',0));
  fingerprint:=encode(sha256(convert_to(details::text,'UTF8')),'hex');

  select * into r from private.get_tagged_receipts where id=p_key;
  if found then
    if r.fingerprint<>fingerprint then
      raise exception 'Request already submitted';
    end if;
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

revoke all on function public.submit_get_tagged_v2(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.submit_get_tagged_v2(uuid,text,jsonb) to service_role;

create or replace function public.approve_get_tagged(
  p_id uuid,
  p_customer uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  r private.get_tagged_receipts;
  contact jsonb;
  cid uuid:=p_customer;
  qid uuid;
begin
  perform private.require_admin(u);

  select * into r
  from private.get_tagged_receipts
  where id=p_id
  for update;

  if r.id is null then raise exception 'Request not found'; end if;
  if r.request_status='Rejected' then raise exception 'Request was rejected'; end if;
  if r.quote_id is not null then return r.quote_id; end if;
  if r.request_status<>'Pending' then raise exception 'Request is not pending'; end if;

  contact:=r.details->'contact';

  if cid is not null then
    if not exists(select 1 from public.customers where id=cid and unit_id=u) then
      raise exception 'Customer not found';
    end if;
  elsif cardinality(r.candidates)=1 then
    cid:=r.candidates[1];
  elsif cardinality(r.candidates)>1 then
    raise exception 'Select one of the matching customers';
  else
    insert into public.customers(
      unit_id,name,email,phone,address,
      company_name,company_email,company_phone
    )
    values(
      u,
      trim(contact->>'name'),
      lower(trim(contact->>'email')),
      trim(contact->>'phone'),
      coalesce(r.details->'service'->>'address',''),
      nullif(contact->>'company_name',''),
      nullif(contact->>'company_email',''),
      nullif(contact->>'company_phone','')
    )
    returning id into cid;
  end if;

  qid:=private.create_get_tagged_draft(r.id,cid);

  update private.get_tagged_receipts
  set request_status='Approved',
      approved_at=now(),
      reviewed_by=auth.uid(),
      customer_id=cid,
      matching=case when cardinality(r.candidates)=0 then 'created' else 'reused' end
  where id=r.id;

  return qid;
end $$;

revoke all on function public.approve_get_tagged(uuid,uuid) from public,anon;
grant execute on function public.approve_get_tagged(uuid,uuid) to authenticated;

create or replace function public.reject_get_tagged(
  p_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  r private.get_tagged_receipts;
begin
  perform private.require_admin(u);

  select * into r
  from private.get_tagged_receipts
  where id=p_id
  for update;

  if r.id is null then raise exception 'Request not found'; end if;
  if r.quote_id is not null then
    raise exception 'A Quote already exists for this request';
  end if;
  if r.request_status<>'Pending' then
    raise exception 'Request is not pending';
  end if;

  update private.get_tagged_receipts
  set request_status='Rejected',
      rejected_at=now(),
      reviewed_by=auth.uid(),
      rejection_reason=nullif(trim(p_reason),'')
  where id=r.id;
end $$;

revoke all on function public.reject_get_tagged(uuid,text) from public,anon;
grant execute on function public.reject_get_tagged(uuid,text) to authenticated;

create or replace function public.get_tagged_attention()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  perform private.require_admin('10000000-0000-0000-0000-000000000002');

  return (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id',r.id,
          'reference',r.reference,
          'name',r.details->'contact'->>'name',
          'created_at',r.created_at,
          'quote_id',r.quote_id,
          'matching',r.matching,
          'request_status',r.request_status,
          'service_method',r.details->'service'->>'method',
          'candidates',(
            select jsonb_agg(
              jsonb_build_object(
                'id',c.id,'name',c.name,'email',c.email,'phone',c.phone
              )
            )
            from public.customers c
            where c.id=any(r.candidates)
          )
        )
        order by r.created_at
      ),
      '[]'::jsonb
    )
    from private.get_tagged_receipts r
    left join public.quotes q on q.id=r.quote_id
    where r.request_status='Pending'
       or (
         r.request_status='Converted'
         and q.status='Draft'
         and q.intake_reviewed_at is null
       )
  );
end $$;

create or replace function public.review_get_tagged_quote(p jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  q public.quotes;
  scope jsonb;
  i jsonb;
begin
  select * into q
  from public.quotes
  where id=(p->>'id')::uuid
  for update;

  perform private.require_admin(q.unit_id);

  if q.source<>'public_get_tagged'
     or q.status<>'Draft'
     or q.sent_at is not null
  then
    raise exception 'This request is no longer an editable Draft';
  end if;

  scope:=private.priced_scope(p->'items');

  for i in select value from jsonb_array_elements(scope) loop
    if i->>'engraving_type'<>'Fee'
       and (i->>'unit_price')::numeric<=0
    then
      raise exception 'Set the base service price for each item before completing review';
    end if;
  end loop;

  delete from public.quote_items where quote_id=q.id;
  perform private.store_get_tagged_items(q.id,scope);
  perform private.ensure_pickup_fee_item(q.id);

  update public.quotes
  set notes=p->>'notes',
      intake_reviewed_at=now()
  where id=q.id;

  return q.id;
end $$;

create or replace function private.create_pick_return_order_from_agreement()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  fee numeric(14,2);
begin
  select sum(quantity*unit_price)
  into fee
  from public.quote_items
  where quote_id=new.quote_id
    and pricing->>'kind'='pickup_service_fee';

  if coalesce(fee,0)<=0 then
    return new;
  end if;

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

  return new;
end $$;

create trigger agreements_create_pick_return_order
after insert on public.agreements
for each row execute function private.create_pick_return_order_from_agreement();

create or replace function private.cancellation_assessment(
  p_job uuid,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  j public.jobs;
  prog jsonb;
  pr public.pick_return_orders;
  total_items integer:=0;
  started_items integer:=0;
  finished_items integer:=0;
  service_amount numeric(14,2):=0;
  pickup_fee numeric(14,2):=0;
  collected numeric(14,2):=0;
  pickup_paid numeric(14,2):=0;
  service_paid numeric(14,2):=0;
  charge_pct numeric(5,2):=0;
  charge_amount numeric(14,2):=0;
  service_refund numeric(14,2):=0;
  fee_refundable boolean:=false;
  fee_refund numeric(14,2):=0;
  retained_fee numeric(14,2):=0;
  total_refund numeric(14,2):=0;
  amount_due numeric(14,2):=0;
  allowed boolean:=true;
  rule text:='Pre-Production';
  agreement_version integer;
begin
  select * into j from public.jobs where id=p_job;
  if j.id is null then raise exception 'Job not found'; end if;

  prog:=private.job_item_progress(j.id);
  total_items:=coalesce((prog->>'total')::integer,0);
  started_items:=coalesce((prog->>'started')::integer,0);
  finished_items:=coalesce((prog->>'finished')::integer,0);

  select coalesce(sum(quantity*unit_price),0)
  into service_amount
  from public.quote_items
  where quote_id=j.quote_id
    and engraving_type<>'Fee';

  select * into pr
  from public.pick_return_orders
  where job_id=j.id;

  pickup_fee:=coalesce(pr.fee_amount,0);

  select coalesce(t.collected,0)
  into collected
  from public.job_commercial_totals t
  where t.id=j.id;

  select coalesce(sum(confirmed_amount),0)
  into pickup_paid
  from public.payment_requests
  where job_id=j.id
    and purpose='Pickup Fee'
    and status='Confirmed';

  pickup_paid:=least(pickup_paid,pickup_fee);
  service_paid:=greatest(collected-pickup_paid,0);

  select (a.commercial_snapshot->'policy'->>'version')::integer
  into agreement_version
  from public.agreements a
  where a.job_id=j.id
  order by a.accepted_at desc
  limit 1;

  if total_items>0 and finished_items>=total_items then
    allowed:=false;
    rule:='Engraving Completed';
    charge_pct:=100;
  elsif started_items>0 then
    rule:='Engraving';
    if started_items*2<=greatest(total_items,1) then
      charge_pct:=60;
    else
      charge_pct:=100;
    end if;
  elsif j.work_stage in (
      'Preparing','Engraving','Final Evidence','Final Details','Delivery In Progress'
    )
    or pr.pickup_status='Picked Up'
  then
    rule:='Preparation';
    charge_pct:=40;
  else
    rule:='Pre-Production';
    charge_pct:=0;
  end if;

  charge_amount:=round(service_amount*charge_pct/100.0,2);

  if pickup_paid>0 then
    fee_refundable:=
      coalesce(pr.pickup_status,'Not Scheduled') not in ('Picked Up','Failed')
      and (
        pr.pickup_cancellation_deadline is null
        or p_at<=pr.pickup_cancellation_deadline
      );
  end if;

  fee_refund:=case when fee_refundable then pickup_paid else 0 end;
  retained_fee:=case when pickup_paid>0 and not fee_refundable then pickup_fee else 0 end;
  service_refund:=least(service_paid,greatest(service_amount-charge_amount,0));
  total_refund:=round(service_refund+fee_refund,2);

  amount_due:=greatest(
    round(charge_amount+retained_fee-(collected-total_refund),2),
    0
  );

  return jsonb_build_object(
    'allowed',allowed,
    'rule',rule,
    'job_status',j.status,
    'work_stage',j.work_stage,
    'items_total',total_items,
    'items_started',started_items,
    'items_finished',finished_items,
    'service_amount',service_amount,
    'service_charge_percent',charge_pct,
    'service_charge_amount',charge_amount,
    'pickup_fee_amount',pickup_fee,
    'pickup_fee_paid',pickup_paid,
    'pickup_fee_refundable',fee_refundable,
    'pickup_fee_refund_amount',fee_refund,
    'collected',collected,
    'service_paid',service_paid,
    'refund_eligible_amount',total_refund,
    'amount_due',amount_due,
    'agreement_version',agreement_version
  );
end $$;

create or replace function public.request_job_cancellation(p_job uuid)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  customer uuid;
  a jsonb;
  rid uuid;
begin
  select * into j from public.jobs where id=p_job for update;
  if j.id is null then raise exception 'Job not found'; end if;
  perform private.require_admin(j.unit_id);

  if exists(
    select 1 from public.cancellation_requests
    where job_id=j.id and status='Requested'
  ) then
    return (
      select id from public.cancellation_requests
      where job_id=j.id and status='Requested'
      limit 1
    );
  end if;

  a:=private.cancellation_assessment(j.id);

  if coalesce((a->>'allowed')::boolean,false) is not true then
    raise exception 'This Job can no longer be cancelled for convenience';
  end if;

  select customer_id into customer
  from public.commercial_flows
  where id=j.flow_id;

  insert into public.cancellation_requests(
    unit_id,job_id,quote_id,customer_id,
    stage_at_request,items_total,items_started,items_finished,
    service_amount,pickup_fee_amount,pickup_fee_refundable,
    pickup_fee_refund_amount,service_charge_percent,
    service_charge_amount,refund_eligible_amount,amount_due,
    agreement_version,assessment,refund_status
  )
  values(
    j.unit_id,j.id,j.quote_id,customer,
    a->>'rule',
    (a->>'items_total')::integer,
    (a->>'items_started')::integer,
    (a->>'items_finished')::integer,
    (a->>'service_amount')::numeric,
    (a->>'pickup_fee_amount')::numeric,
    (a->>'pickup_fee_refundable')::boolean,
    (a->>'pickup_fee_refund_amount')::numeric,
    (a->>'service_charge_percent')::numeric,
    (a->>'service_charge_amount')::numeric,
    (a->>'refund_eligible_amount')::numeric,
    (a->>'amount_due')::numeric,
    nullif(a->>'agreement_version','')::integer,
    a,
    case when (a->>'refund_eligible_amount')::numeric>0 then 'Pending' else 'None' end
  )
  returning id into rid;

  return rid;
end $$;

revoke all on function public.request_job_cancellation(uuid) from public,anon;
grant execute on function public.request_job_cancellation(uuid) to authenticated;

create or replace function private.apply_pending_cancellation(p_job uuid)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare
  r public.cancellation_requests;
  pr public.pick_return_orders;
begin
  select * into r
  from public.cancellation_requests
  where job_id=p_job and status='Requested'
  order by requested_at
  limit 1
  for update;

  if r.id is null then return false; end if;

  update public.jobs
  set status='Cancelled',
      completion_reason='Cancelled by customer request',
      updated_at=now()
  where id=p_job;

  update public.cancellation_requests
  set status='Cancelled',
      confirmed_at=now(),
      cancelled_at=now()
  where id=r.id;

  update public.job_items
  set cancelled_at=coalesce(cancelled_at,now()),
      updated_at=now()
  where job_id=p_job and stage<>'Finished';

  select * into pr
  from public.pick_return_orders
  where job_id=p_job
  for update;

  if pr.job_id is not null then
    if pr.pickup_status<>'Picked Up' then
      update public.pick_return_orders
      set pickup_status='Cancelled',
          return_status='Cancelled',
          fee_status=case
            when r.pickup_fee_refund_amount>0 then 'Refund Pending'
            when fee_status='Confirmed' then 'Forfeited'
            else fee_status
          end,
          updated_at=now()
      where job_id=p_job;

      update public.pick_return_stops
      set status='Cancelled'
      where job_id=p_job and status in ('Scheduled','En Route','Arrived');
    else
      update public.pick_return_orders
      set hold_until_paid=(r.amount_due>0),
          return_status=case
            when r.amount_due>0 then 'Not Ready'
            else 'Delivery In Progress'
          end,
          fee_status=case
            when r.pickup_fee_refund_amount>0 then 'Refund Pending'
            when fee_status='Confirmed' then 'Forfeited'
            else fee_status
          end,
          updated_at=now()
      where job_id=p_job;
    end if;
  end if;

  return true;
end $$;

create or replace function public.advance_job_item(
  p_item uuid,
  p_action text
)
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
  pickup boolean;
begin
  select * into wi
  from public.job_items
  where id=p_item
  for update;

  if wi.id is null then raise exception 'Job item not found'; end if;

  select * into j
  from public.jobs
  where id=wi.job_id
  for update;

  perform private.require_admin(j.unit_id);

  if private.apply_pending_cancellation(j.id) then
    return jsonb_build_object(
      'blocked',true,
      'reason','Cancellation request detected',
      'progress',private.job_item_progress(j.id)
    );
  end if;

  if j.status='Cancelled' then
    raise exception 'This Job is cancelled';
  end if;

  select min(sequence)
  into current_sequence
  from public.job_items
  where job_id=j.id
    and stage not in ('Finished','Cancelled');

  if current_sequence is distinct from wi.sequence then
    raise exception 'Finish the current item before moving to another item';
  end if;

  if p_action in ('next','preparation-done') and wi.stage='Preparation' then
    update public.job_items
    set stage='Engraving',
        engraving_started_at=coalesce(engraving_started_at,now()),
        updated_at=now()
    where id=wi.id;

    update public.jobs
    set status='In Process',
        work_stage='Engraving',
        customer_stage='Engraving',
        updated_at=now()
    where id=j.id;

  elsif p_action='finished' and wi.stage='Finished Evidence' then
    update public.job_items
    set stage='Finished',
        finished_at=coalesce(finished_at,now()),
        updated_at=now()
    where id=wi.id;

    select count(*) into remaining
    from public.job_items
    where job_id=j.id
      and stage not in ('Finished','Cancelled');

    if remaining=0 then
      select exists(
        select 1 from public.pick_return_orders where job_id=j.id
      ) into pickup;

      if pickup then
        update public.pick_return_orders
        set return_status='Delivery In Progress',
            updated_at=now()
        where job_id=j.id;

        update public.jobs
        set work_stage='Delivery In Progress',
            customer_stage='Final Details',
            updated_at=now()
        where id=j.id;

        insert into public.notifications(
          unit_id,event,entity_id,recipient,dedupe_key,payload
        )
        select
          j.unit_id,
          'DELIVERY_IN_PROGRESS',
          j.id,
          a.accepted_email,
          'delivery-in-progress:'||j.id,
          jsonb_build_object(
            'template','notification',
            'subject','Delivery in progress — '||j.code,
            'text','Your ToolTag Job is finished and has entered the Return delivery process.',
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
            customer_stage='Final Details',
            updated_at=now()
        where id=j.id;
      end if;
    else
      update public.jobs
      set work_stage='Engraving',
          customer_stage='Engraving',
          updated_at=now()
      where id=j.id;
    end if;

  else
    raise exception 'Invalid item transition';
  end if;

  prog:=private.job_item_progress(j.id);

  return jsonb_build_object(
    'blocked',false,
    'job_id',j.id,
    'item_id',wi.id,
    'progress',prog
  );
end $$;

revoke all on function public.advance_job_item(uuid,text) from public,anon;
grant execute on function public.advance_job_item(uuid,text) to authenticated;

create or replace function public.add_document(p jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  u uuid:=(p->>'unit_id')::uuid;
  did uuid;
  tx public.transactions;
  jid uuid:=nullif(p->>'job_id','')::uuid;
  item_id uuid:=nullif(p->>'job_item_id','')::uuid;
  item public.job_items;
begin
  perform private.require_admin(u);

  if nullif(trim(p->>'drive_file_id'),'') is null then
    raise exception 'A real Google Drive file ID is required; uploads are not connected yet';
  end if;

  if p->>'drive_file_id' !~ '^[a-zA-Z0-9_-]{10,}$' then
    raise exception 'Invalid Drive file ID';
  end if;

  if item_id is not null then
    select * into item
    from public.job_items
    where id=item_id;

    if item.id is null
       or item.unit_id<>u
       or (jid is not null and item.job_id<>jid)
    then
      raise exception 'Job item does not belong to this Job';
    end if;

    jid:=item.job_id;
  end if;

  if p->>'type'='Finished Evidence' and item_id is null then
    raise exception 'Finished Evidence must be attached to a Job item';
  end if;

  insert into public.documents(
    unit_id,type,drive_file_id,file_name,customer_id,job_id,job_item_id,
    transaction_id,status,uploaded_by
  )
  values(
    u,p->>'type',p->>'drive_file_id',p->>'file_name',
    nullif(p->>'customer_id','')::uuid,
    jid,item_id,
    nullif(p->>'transaction_id','')::uuid,
    'Available',
    auth.uid()
  )
  returning id into did;

  if p->>'type'='Finished Evidence' and item_id is not null then
    update public.job_items
    set stage=case when stage='Engraving' then 'Finished Evidence' else stage end,
        evidence_completed_at=coalesce(evidence_completed_at,now()),
        updated_at=now()
    where id=item_id
      and stage in ('Engraving','Finished Evidence');
  end if;

  if p->>'type'='Completed Evidence' and jid is not null then
    update public.jobs
    set customer_stage='Final Details',
        work_stage='Final Details',
        updated_at=now()
    where id=jid
      and unit_id=u
      and customer_stage='Engraving'
      and work_stage='Final Evidence';
  end if;

  select * into tx
  from public.transactions
  where id=nullif(p->>'transaction_id','')::uuid;

  update public.monthly_closes
  set status=case
    when status='Reclose Required' then status
    else 'Documentation Updated'
  end
  where unit_id=u
    and month=date_trunc('month',tx.transaction_date)::date
    and status<>'Superseded';

  return did;
end $$;

create or replace function private.job_portal_snapshot(p_job uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
 select jsonb_build_object(
   'id',j.id,
   'code',j.code,
   'status',j.status,
   'customer_name',a.accepted_name,
   'original_quote',a.commercial_snapshot,
   'extensions',coalesce((
     select jsonb_agg(
       jsonb_build_object(
         'code',x.code,'scope',x.scope,'items',x.items,
         'total',x.total,'status',x.status
       )
       order by x.sequence
     )
     from public.job_extensions x
     where x.job_id=j.id and x.accepted_at is not null
   ),'[]'::jsonb),
   'totals',(select to_jsonb(t) from public.job_commercial_totals t where t.id=j.id),
   'item_progress',private.job_item_progress(j.id),
   'evidence',coalesce((
     select jsonb_agg(
       jsonb_build_object(
         'id',d.id,'name',d.file_name,'type',d.type,'job_item_id',d.job_item_id
       )
       order by d.created_at,d.id
     )
     from public.documents d
     where d.job_id=j.id
       and d.type in ('Completed Evidence','Finished Evidence','Delivery Evidence')
       and d.status='Available'
   ),'[]'::jsonb)
 )
 from public.jobs j
 join public.agreements a on a.quote_id=j.quote_id
 where j.id=p_job;
$$;

create or replace function public.public_job_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  customer_name text;
  prog jsonb;
  pr jsonb;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if j.id is null then raise exception 'Status link unavailable'; end if;

  select c.name into customer_name
  from public.commercial_flows f
  join public.customers c on c.id=f.customer_id
  where f.id=j.flow_id;

  prog:=private.job_item_progress(j.id);

  select to_jsonb(x)-'unit_id'-'terms_snapshot'
  into pr
  from public.pick_return_orders x
  where x.job_id=j.id;

  return jsonb_build_object(
    'code',j.code,
    'customer_name',customer_name,
    'stage',j.customer_stage,
    'updated_at',j.updated_at,
    'items_total',coalesce((prog->>'total')::integer,0),
    'items_completed',coalesce((prog->>'finished')::integer,0),
    'items_started',coalesce((prog->>'started')::integer,0),
    'item_progress',prog,
    'pickup_return',pr,
    'cancelled',j.status='Cancelled',
    'steps',jsonb_build_array(
      'In Process',
      'Engraving',
      'Final Details',
      'Completed'
    )
  );
end $$;

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
begin
  select * into j from public.jobs where id=p_id for update;
  if j.id is null then raise exception 'Job not found'; end if;

  perform private.require_admin(j.unit_id);

  if private.apply_pending_cancellation(j.id) then
    return null;
  end if;

  if exists(select 1 from public.pick_return_orders where job_id=j.id) then
    raise exception 'Pickup & Return Jobs must complete the Return delivery flow';
  end if;

  select count(*),count(*) filter(where stage='Finished')
  into total_items,finished_items
  from public.job_items
  where job_id=j.id;

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
    j.unit_id,
    'Completion acknowledgment',
    j.id,
    'delivery:'||j.id,
    jsonb_build_object('live_eligible',true)
  )
  on conflict do nothing;

  return token;
end $$;

revoke all on function public.complete_job_production(uuid) from public,anon;
grant execute on function public.complete_job_production(uuid) to authenticated;
