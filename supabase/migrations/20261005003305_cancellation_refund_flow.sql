
alter table public.cancellation_requests
  add column refund_transaction_ids uuid[] not null default '{}';

alter table public.documents
  drop constraint if exists documents_type_check;
alter table public.documents
  add constraint documents_type_check
  check (type in (
    'Receipt','Quote','Agreement','Receiving Evidence','Completed Evidence',
    'Finished Evidence','Delivery Evidence','Payment Receipt','Refund Receipt',
    'Issue / Review','Other'
  ));

create table private.cancellation_access_links (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  token text not null,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index cancellation_access_customer_idx
  on private.cancellation_access_links(customer_id,expires_at desc);

create or replace function private.active_customer_services(p_customer uuid)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select
    exists(
      select 1
      from public.commercial_flows f
      join public.quotes q on q.flow_id=f.id
      where f.customer_id=p_customer
        and q.status in ('Sent','Viewed','Agreement Pending')
        and q.expires_at>now()
    )
    or exists(
      select 1
      from public.commercial_flows f
      join public.jobs j on j.flow_id=f.id
      where f.customer_id=p_customer
        and j.status not in ('Completed','Cancelled')
    );
$$;

create or replace function public.request_cancellation_access(
  p_network text,
  p_name text,
  p_email text,
  p_phone text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  cid uuid;
  token text;
  link_id uuid;
  count_requests integer;
  rate_bucket timestamptz:=
    date_trunc('hour',now())
    + floor(extract(minute from now())/15)*interval '15 minutes';
begin
  if coalesce(
    nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',
    current_setting('request.jwt.claim.role',true),''
  )<>'service_role' then
    raise exception 'Server credentials required' using errcode='42501';
  end if;

  if p_network is null
     or p_network !~ '^[a-f0-9]{64}$'
     or nullif(trim(p_name),'') is null
     or coalesce(p_email,'') !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     or length(private.get_tagged_phone(p_phone)) not between 7 and 15
  then
    raise exception 'Invalid cancellation lookup';
  end if;

  insert into private.get_tagged_rate(network,bucket,requests)
  values('cancel:'||p_network,rate_bucket,1)
  on conflict(network,bucket)
  do update set requests=private.get_tagged_rate.requests+1
  returning requests into count_requests;

  if count_requests>5 then raise exception 'Request rate limit'; end if;

  select c.id into cid
  from public.customers c
  where c.unit_id=u
    and lower(trim(c.name))=lower(trim(p_name))
    and lower(trim(c.email))=lower(trim(p_email))
    and private.get_tagged_phone(c.phone)=private.get_tagged_phone(p_phone)
  order by c.created_at desc
  limit 1;

  if cid is null or not private.active_customer_services(cid) then
    return jsonb_build_object('matched',false);
  end if;

  token:=gen_random_uuid()::text||gen_random_uuid()::text;

  insert into private.cancellation_access_links(
    customer_id,token,token_hash,expires_at
  )
  values(
    cid,token,
    encode(sha256(convert_to(token,'UTF8')),'hex'),
    now()+interval '24 hours'
  )
  returning id into link_id;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    u,'CANCELLATION_ACCESS',link_id,lower(trim(p_email)),
    'cancellation-access:'||link_id,
    jsonb_build_object(
      'template','notification',
      'subject','ToolTag cancellation details',
      'text','Use the secure link below to review your active ToolTag services and cancellation options.',
      'action_path','/help/cancel/'||token,
      'live_eligible',true
    )
  );

  return jsonb_build_object('matched',true);
end $$;

revoke all on function public.request_cancellation_access(text,text,text,text) from public,anon,authenticated;
grant execute on function public.request_cancellation_access(text,text,text,text) to service_role;

create or replace function private.cancellation_link_customer(p_token text)
returns uuid
language sql
stable
security definer
set search_path=''
as $$
  select l.customer_id
  from private.cancellation_access_links l
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and l.expires_at>now()
  order by l.created_at desc
  limit 1;
$$;

create or replace function public.cancellation_access(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  cid uuid;
  cname text;
begin
  cid:=private.cancellation_link_customer(p_token);
  if cid is null then raise exception 'Cancellation link unavailable'; end if;

  select name into cname from public.customers where id=cid;

  return jsonb_build_object(
    'customer_name',cname,
    'services',
    coalesce((
      select jsonb_agg(x order by x->>'code')
      from (
        select jsonb_build_object(
          'kind','Quote','id',q.id,'code',q.code,'status',q.status,
          'amount',coalesce((
            select sum(i.quantity*i.unit_price)
            from public.quote_items i where i.quote_id=q.id
          ),0),
          'can_cancel',true,
          'service_method',q.intake_details->'service'->>'method'
        ) as x
        from public.commercial_flows f
        join public.quotes q on q.flow_id=f.id
        where f.customer_id=cid
          and q.status in ('Sent','Viewed','Agreement Pending')
          and q.expires_at>now()

        union all

        select jsonb_build_object(
          'kind','Job','id',j.id,'code',j.code,'status',j.status,
          'work_stage',j.work_stage,
          'assessment',private.cancellation_assessment(j.id),
          'progress',private.job_item_progress(j.id),
          'pickup_return',(
            select to_jsonb(pr)-'unit_id'-'terms_snapshot'
            from public.pick_return_orders pr where pr.job_id=j.id
          )
        ) as x
        from public.commercial_flows f
        join public.jobs j on j.flow_id=f.id
        where f.customer_id=cid
          and j.status not in ('Completed','Cancelled')
      ) s
    ),'[]'::jsonb)
  );
end $$;

revoke all on function public.cancellation_access(text) from public;
grant execute on function public.cancellation_access(text) to anon,authenticated;

create or replace function public.public_cancel_quote(p_token text,p_quote uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  cid uuid;
  q public.quotes;
begin
  cid:=private.cancellation_link_customer(p_token);
  if cid is null then raise exception 'Cancellation link unavailable'; end if;

  select qx.* into q
  from public.quotes qx
  join public.commercial_flows f on f.id=qx.flow_id
  where qx.id=p_quote and f.customer_id=cid
  for update of qx;

  if q.id is null then raise exception 'Quote not found'; end if;
  if q.status not in ('Sent','Viewed','Agreement Pending') then
    raise exception 'This Quote can no longer be cancelled from this page';
  end if;

  update public.quotes set status='Declined' where id=q.id;

  insert into public.notifications(
    unit_id,event,entity_id,dedupe_key,payload
  )
  values(
    q.unit_id,'QUOTE_CANCELLED_BY_CUSTOMER',q.id,'quote-cancelled:'||q.id,
    jsonb_build_object(
      'template','notification',
      'subject','Quote cancelled — '||q.code,
      'text','The customer cancelled '||q.code||' using the secure cancellation page.',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object('cancelled',true,'code',q.code);
end $$;

revoke all on function public.public_cancel_quote(text,uuid) from public;
grant execute on function public.public_cancel_quote(text,uuid) to anon,authenticated;

create or replace function private.insert_cancellation_request(p_job uuid)
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

  select id into rid
  from public.cancellation_requests
  where job_id=j.id and status='Requested'
  order by requested_at
  limit 1;

  if rid is not null then return rid; end if;

  a:=private.cancellation_assessment(j.id);
  if coalesce((a->>'allowed')::boolean,false) is not true then
    raise exception 'This Job can no longer be cancelled for convenience';
  end if;

  select customer_id into customer
  from public.commercial_flows where id=j.flow_id;

  insert into public.cancellation_requests(
    unit_id,job_id,quote_id,customer_id,
    stage_at_request,items_total,items_started,items_finished,
    service_amount,pickup_fee_amount,pickup_fee_refundable,
    pickup_fee_refund_amount,service_charge_percent,
    service_charge_amount,refund_eligible_amount,amount_due,
    agreement_version,assessment,refund_status
  )
  values(
    j.unit_id,j.id,j.quote_id,customer,a->>'rule',
    (a->>'items_total')::integer,(a->>'items_started')::integer,
    (a->>'items_finished')::integer,(a->>'service_amount')::numeric,
    (a->>'pickup_fee_amount')::numeric,(a->>'pickup_fee_refundable')::boolean,
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

create or replace function public.request_job_cancellation(p_job uuid)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  rid uuid;
begin
  select * into j from public.jobs where id=p_job;
  if j.id is null then raise exception 'Job not found'; end if;
  perform private.require_admin(j.unit_id);
  rid:=private.insert_cancellation_request(j.id);
  perform private.apply_pending_cancellation(j.id);
  return rid;
end $$;

create or replace function public.public_cancellation_assessment(p_token text,p_job uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  cid uuid;
  j public.jobs;
begin
  cid:=private.cancellation_link_customer(p_token);
  if cid is null then raise exception 'Cancellation link unavailable'; end if;

  select jx.* into j
  from public.jobs jx
  join public.commercial_flows f on f.id=jx.flow_id
  where jx.id=p_job and f.customer_id=cid;

  if j.id is null then raise exception 'Job not found'; end if;

  return jsonb_build_object(
    'job_code',j.code,'status',j.status,
    'progress',private.job_item_progress(j.id),
    'assessment',private.cancellation_assessment(j.id),
    'pickup_return',(
      select to_jsonb(pr)-'unit_id'-'terms_snapshot'
      from public.pick_return_orders pr where pr.job_id=j.id
    )
  );
end $$;

revoke all on function public.public_cancellation_assessment(text,uuid) from public;
grant execute on function public.public_cancellation_assessment(text,uuid) to anon,authenticated;

create or replace function public.public_confirm_job_cancellation(p_token text,p_job uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  cid uuid;
  j public.jobs;
  rid uuid;
  r public.cancellation_requests;
begin
  cid:=private.cancellation_link_customer(p_token);
  if cid is null then raise exception 'Cancellation link unavailable'; end if;

  select jx.* into j
  from public.jobs jx
  join public.commercial_flows f on f.id=jx.flow_id
  where jx.id=p_job and f.customer_id=cid
  for update of jx;

  if j.id is null then raise exception 'Job not found'; end if;
  if j.status in ('Completed','Cancelled') then
    raise exception 'This Job can no longer be cancelled';
  end if;

  rid:=private.insert_cancellation_request(j.id);
  perform private.apply_pending_cancellation(j.id);
  select * into r from public.cancellation_requests where id=rid;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,'JOB_CANCELLED_BY_CUSTOMER',r.id,
    private.job_customer_recipient(j.id),'job-cancelled:'||r.id,
    jsonb_build_object(
      'template','notification',
      'subject','Cancellation confirmed — '||j.code,
      'text',
        'Your cancellation for '||j.code||' has been confirmed.'||
        case when r.refund_eligible_amount>0
          then ' Eligible refund: $'||to_char(r.refund_eligible_amount,'FM999999990.00')||
               '. Approved refunds are generally processed within 5–7 business days.'
          else ''
        end||
        case when r.amount_due>0
          then ' Outstanding amount due: $'||to_char(r.amount_due,'FM999999990.00')||'.'
          else ''
        end,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'request_id',r.id,'cancelled',true,'refund_status',r.refund_status,
    'assessment',r.assessment,
    'refund_eligible_amount',r.refund_eligible_amount,'amount_due',r.amount_due
  );
end $$;

revoke all on function public.public_confirm_job_cancellation(text,uuid) from public;
grant execute on function public.public_confirm_job_cancellation(text,uuid) to anon,authenticated;

create or replace function public.confirm_cancellation_refund(
  p_request uuid,
  p_method text,
  p_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  r public.cancellation_requests;
  j public.jobs;
  remaining numeric(14,2);
  available numeric(14,2);
  alloc numeric(14,2);
  rec record;
  refund_id uuid;
  refund_ids uuid[]:='{}';
  first_refund uuid;
  recipient text;
  receipt_id uuid;
  snap jsonb;
begin
  select * into r
  from public.cancellation_requests
  where id=p_request
  for update;

  if r.id is null then raise exception 'Cancellation request not found'; end if;
  perform private.require_admin(r.unit_id);

  if r.status<>'Cancelled' then raise exception 'Cancellation is not confirmed'; end if;
  if r.refund_status='Completed' then
    return jsonb_build_object(
      'status','Completed','amount',r.refund_eligible_amount,
      'transaction_ids',r.refund_transaction_ids
    );
  end if;
  if r.refund_status<>'Pending' or r.refund_eligible_amount<=0 then
    raise exception 'No refund is pending for this cancellation';
  end if;
  if p_method not in ('Cash','Zelle','Venmo','Bank Transfer','Card','Other') then
    raise exception 'Choose a valid refund method';
  end if;

  select * into j from public.jobs where id=r.job_id for update;
  remaining:=r.refund_eligible_amount;

  for rec in
    select
      t.id as original_id,t.unit_id,t.account_id,t.customer_id,t.amount,t.created_at,
      greatest(
        t.amount-coalesce((
          select sum(rt.amount)
          from public.refunds rf
          join public.transactions rt on rt.id=rf.transaction_id
          where rf.original_id=t.id and rt.status<>'Voided'
        ),0),0
      ) as refundable
    from public.collections c
    join public.transactions t on t.id=c.transaction_id
    where t.status<>'Voided'
      and c.sale_id in (
        select transaction_id from public.sales where job_id=j.id
        union
        select sale_id from public.job_extensions
        where job_id=j.id and accepted_at is not null
      )
    order by t.created_at,t.id
  loop
    exit when remaining<=0;
    available:=rec.refundable;
    if available<=0 then continue; end if;
    alloc:=least(remaining,available);

    insert into public.transactions(
      unit_id,account_id,type,transaction_date,amount,customer_id,
      description,payment_method,reference,created_by
    )
    values(
      r.unit_id,rec.account_id,'REFUND',
      (now() at time zone (
        select timezone from public.unit_settings where unit_id=r.unit_id
      ))::date,
      alloc,rec.customer_id,'Cancellation refund · '||j.code,p_method,
      coalesce(nullif(trim(p_reference),''),'CANCELREF:'||r.id),auth.uid()
    )
    returning id into refund_id;

    insert into public.refunds(
      transaction_id,unit_id,original_id,subtype,override_reason
    )
    values(
      refund_id,r.unit_id,rec.original_id,'Customer Refund',
      'Cancellation request '||r.id
    );

    if first_refund is null then first_refund:=refund_id; end if;
    refund_ids:=array_append(refund_ids,refund_id);
    remaining:=remaining-alloc;
  end loop;

  if remaining>0 then
    raise exception 'Refund amount exceeds refundable customer collections';
  end if;

  update public.cancellation_requests
  set refund_status='Completed',
      refund_transaction_id=first_refund,
      refund_transaction_ids=refund_ids
  where id=r.id
  returning * into r;

  if r.pickup_fee_refund_amount>0 then
    update public.pick_return_orders
    set fee_status='Refunded',updated_at=now()
    where job_id=j.id and fee_status='Refund Pending';
  end if;

  snap:=jsonb_build_object(
    'type','Cancellation Refund','request_id',r.id,
    'job_id',j.id,'job_code',j.code,'amount',r.refund_eligible_amount,
    'method',p_method,'reference',nullif(trim(p_reference),''),
    'processed_at',now(),'transaction_ids',refund_ids
  );

  insert into public.documents(
    unit_id,type,file_name,customer_id,job_id,content_snapshot,status,uploaded_by
  )
  values(
    r.unit_id,'Refund Receipt','Refund_'||j.code||'.json',
    r.customer_id,j.id,snap,'Available',auth.uid()
  )
  returning id into receipt_id;

  recipient:=private.job_customer_recipient(j.id);

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    r.unit_id,'REFUND_COMPLETED',receipt_id,recipient,
    'refund-completed:'||r.id,
    jsonb_build_object(
      'template','notification',
      'subject','Refund processed — '||j.code,
      'text',
        'ToolTag processed your refund of $'||
        to_char(r.refund_eligible_amount,'FM999999990.00')||
        ' via '||p_method||
        case when nullif(trim(p_reference),'') is null
          then '.'
          else '. Reference: '||trim(p_reference)||'.'
        end||
        ' This email is your electronic refund confirmation.',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'status','Completed','amount',r.refund_eligible_amount,
    'transaction_ids',refund_ids,'receipt_id',receipt_id
  );
end $$;

revoke all on function public.confirm_cancellation_refund(uuid,text,text) from public,anon;
grant execute on function public.confirm_cancellation_refund(uuid,text,text) to authenticated;
