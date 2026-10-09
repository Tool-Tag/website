
create index if not exists job_items_unit_idx on public.job_items(unit_id);
create index if not exists job_items_quote_idx on public.job_items(quote_id);
create index if not exists job_items_quote_item_idx on public.job_items(quote_item_id);
create index if not exists documents_job_item_idx on public.documents(job_item_id) where job_item_id is not null;
create index if not exists pick_return_orders_unit_idx on public.pick_return_orders(unit_id);
create index if not exists pick_return_stops_unit_idx on public.pick_return_stops(unit_id);
create index if not exists cancellation_requests_unit_idx on public.cancellation_requests(unit_id);
create index if not exists cancellation_requests_job_idx on public.cancellation_requests(job_id,requested_at desc);
create index if not exists payment_requests_job_purpose_idx on public.payment_requests(job_id,purpose,status);

alter table public.documents
  add column pick_return_stop_id uuid references public.pick_return_stops(id) on delete set null;
create index documents_pick_return_stop_idx
  on public.documents(pick_return_stop_id)
  where pick_return_stop_id is not null;

create table private.pickup_payment_links (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  token text not null,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create or replace function private.job_customer_recipient(p_job uuid)
returns text
language sql
stable
security definer
set search_path=''
as $$
  select coalesce(
    (
      select d.customer_recipient_email
      from public.accepted_documents d
      where d.job_id=p_job
      order by d.accepted_at desc
      limit 1
    ),
    (
      select a.accepted_email
      from public.agreements a
      where a.job_id=p_job
      order by a.accepted_at desc
      limit 1
    )
  );
$$;

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
      'action_path','/pick-return/pay/'||token,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $$;

create or replace function public.public_pickup_fee(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  pr public.pick_return_orders;
  link private.pickup_payment_links;
  zelle text;
  venmo text;
begin
  select * into link
  from private.pickup_payment_links
  where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and expires_at>now();

  if link.job_id is null then raise exception 'Pickup payment link unavailable'; end if;

  select * into j from public.jobs where id=link.job_id;
  select * into pr from public.pick_return_orders where job_id=j.id;

  if pr.job_id is null then raise exception 'Pickup service is unavailable'; end if;

  select zelle_email,venmo_handle
  into zelle,venmo
  from public.unit_settings
  where unit_id=j.unit_id;

  return jsonb_build_object(
    'job_code',j.code,
    'amount',pr.fee_amount,
    'fee_status',pr.fee_status,
    'pickup_status',pr.pickup_status,
    'scheduler_enabled',pr.scheduler_enabled,
    'zelle_email',zelle,
    'venmo_handle',venmo,
    'terms_version',pr.terms_version
  );
end $$;

revoke all on function public.public_pickup_fee(text) from public;
grant execute on function public.public_pickup_fee(text) to anon,authenticated;

create or replace function public.public_submit_pickup_fee_payment(
  p_token text,
  p_request uuid,
  p_method text,
  p_proof_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  link private.pickup_payment_links;
  j public.jobs;
  pr public.pick_return_orders;
  existing public.payment_requests;
  rid uuid;
  zelle text;
  venmo text;
begin
  select * into link
  from private.pickup_payment_links
  where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and expires_at>now();

  if link.job_id is null then raise exception 'Pickup payment link unavailable'; end if;

  select * into j from public.jobs where id=link.job_id for update;
  select * into pr from public.pick_return_orders where job_id=j.id for update;

  if pr.job_id is null then raise exception 'Pickup service is unavailable'; end if;
  if j.status='Cancelled' then raise exception 'This Job is cancelled'; end if;

  if pr.fee_status='Confirmed' then
    return jsonb_build_object(
      'status','Confirmed',
      'amount',pr.fee_amount,
      'job_code',j.code
    );
  end if;

  select * into existing
  from public.payment_requests
  where request_key=p_request;

  if existing.id is not null then
    return jsonb_build_object(
      'id',existing.id,
      'status',existing.status,
      'method',existing.method,
      'amount',existing.amount
    );
  end if;

  if exists(
    select 1 from public.payment_requests
    where job_id=j.id
      and purpose='Pickup Fee'
      and status='Pending Verification'
  ) then
    raise exception 'Pickup fee payment is already awaiting verification';
  end if;

  if p_method not in ('Zelle','Venmo') then
    raise exception 'Choose Zelle or Venmo for the Pickup fee';
  end if;

  select zelle_email,venmo_handle
  into zelle,venmo
  from public.unit_settings
  where unit_id=j.unit_id;

  if p_method='Zelle' and nullif(trim(zelle),'') is null then
    raise exception 'Zelle is not configured yet';
  end if;
  if p_method='Venmo' and nullif(trim(venmo),'') is null then
    raise exception 'Venmo is not configured yet';
  end if;

  if nullif(trim(p_proof_path),'') is null then
    raise exception 'Upload payment proof';
  end if;

  if p_proof_path not like j.unit_id::text||'/%'
     or not exists(
       select 1 from storage.objects o
       where o.bucket_id='payment-proofs'
         and o.name=p_proof_path
     )
  then
    raise exception 'Payment proof was not found';
  end if;

  insert into public.payment_requests(
    request_key,unit_id,job_id,method,amount,proof_path,purpose
  )
  values(
    p_request,j.unit_id,j.id,p_method,pr.fee_amount,p_proof_path,'Pickup Fee'
  )
  returning id into rid;

  update public.pick_return_orders
  set fee_status='Pending Verification',
      updated_at=now()
  where job_id=j.id;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,
    'PICKUP_FEE_SUBMITTED',
    rid,
    'payments@tooltag.martinlab.studio',
    'pickup-fee-payment:'||rid,
    jsonb_build_object(
      'template','notification',
      'subject','Pickup fee payment submitted — '||j.code||' — '||p_method,
      'text',
        'Job: '||j.code||
        E'\nPickup fee: $'||to_char(pr.fee_amount,'FM999999990.00')||
        E'\nMethod: '||p_method||
        E'\nStatus: Pending Verification',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'id',rid,
    'status','Pending Verification',
    'amount',pr.fee_amount,
    'job_code',j.code
  );
end $$;

revoke all on function public.public_submit_pickup_fee_payment(text,uuid,text,text) from public;
grant execute on function public.public_submit_pickup_fee_payment(text,uuid,text,text) to anon,authenticated;

create or replace function public.confirm_payment_request(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  r public.payment_requests;
  j public.jobs;
  remaining numeric(14,2);
  due numeric(14,2);
  alloc numeric(14,2);
  paid numeric(14,2):=0;
  rec record;
  tid uuid;
  tids uuid[]:='{}';
  collection_account uuid;
  recipient text;
begin
  select * into r
  from public.payment_requests
  where id=p_id
  for update;

  if r.id is null then raise exception 'Payment request not found'; end if;
  perform private.require_admin(r.unit_id);

  if r.status='Confirmed' then
    return jsonb_build_object(
      'id',r.id,'status',r.status,
      'purpose',r.purpose,
      'confirmed_amount',r.confirmed_amount,
      'transaction_ids',r.transaction_ids
    );
  end if;

  if r.status<>'Pending Verification' then
    raise exception 'Payment request is not pending verification';
  end if;

  select payment_account_id into collection_account
  from public.unit_settings
  where unit_id=r.unit_id;

  if collection_account is null then
    raise exception 'Payment account is not configured';
  end if;

  select * into j
  from public.jobs
  where id=r.job_id
  for update;

  select balance_due into due
  from public.job_commercial_totals
  where id=j.id;

  if coalesce(due,0)<=0 then
    raise exception 'This job is already paid in full';
  end if;

  if r.purpose='Pickup Fee' then
    if not exists(
      select 1 from public.pick_return_orders pr
      where pr.job_id=j.id
        and pr.fee_status in ('Required','Pending Verification')
        and r.amount=pr.fee_amount
    ) then
      raise exception 'Pickup fee is not awaiting confirmation';
    end if;
  end if;

  remaining:=least(r.amount,due);

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
    ) q
    order by sort_order,transaction_id
  loop
    exit when remaining<=0;
    alloc:=least(remaining,rec.balance_due);

    insert into public.transactions(
      unit_id,account_id,type,transaction_date,amount,customer_id,
      description,payment_method,reference,created_by
    )
    values(
      r.unit_id,collection_account,'COLLECTION',
      (now() at time zone (
        select timezone from public.unit_settings where unit_id=r.unit_id
      ))::date,
      alloc,rec.customer_id,
      case when r.purpose='Pickup Fee'
        then 'Verified Pickup fee · '||j.code
        else 'Verified customer payment · '||j.code
      end,
      r.method,'PAYREQ:'||r.id,auth.uid()
    )
    returning id into tid;

    insert into public.collections(transaction_id,unit_id,sale_id)
    values(tid,r.unit_id,rec.transaction_id);

    tids:=array_append(tids,tid);
    paid:=paid+alloc;
    remaining:=remaining-alloc;
  end loop;

  if paid<=0 then raise exception 'No outstanding sale balance was available'; end if;

  update public.payment_requests
  set status='Confirmed',
      confirmed_at=now(),
      confirmed_by=auth.uid(),
      confirmed_amount=paid,
      transaction_ids=tids
  where id=r.id
  returning * into r;

  if r.purpose='Pickup Fee' then
    update public.pick_return_orders
    set fee_status='Confirmed',
        updated_at=now()
    where job_id=j.id;

    recipient:=private.job_customer_recipient(j.id);

    insert into public.notifications(
      unit_id,event,entity_id,recipient,dedupe_key,payload
    )
    values(
      j.unit_id,
      'PICKUP_FEE_CONFIRMED',
      j.id,
      recipient,
      'pickup-fee-confirmed:'||j.id,
      jsonb_build_object(
        'template','notification',
        'subject','Pickup fee confirmed — '||j.code,
        'text','Your $'||to_char(paid,'FM999999990.00')||
               ' Pickup & Return fee has been confirmed. Pickup scheduling will be available once ToolTag scheduling is enabled or ToolTag confirms your appointment.',
        'live_eligible',true
      )
    )
    on conflict do nothing;
  else
    perform public.generate_job_receipt(j.id);
  end if;

  return jsonb_build_object(
    'id',r.id,'status',r.status,'purpose',r.purpose,
    'confirmed_amount',r.confirmed_amount,'transaction_ids',r.transaction_ids
  );
end $$;

create or replace function public.schedule_pick_return(
  p_job uuid,
  p_leg text,
  p_window_start timestamptz,
  p_window_end timestamptz,
  p_eta timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  pr public.pick_return_orders;
  v_route_id uuid;
  stop_id uuid;
  route_day date;
  zone text;
  seq integer;
  deadline timestamptz;
  recipient text;
  status_token text;
  total_items integer;
  finished_items integer;
begin
  select * into j from public.jobs where id=p_job for update;
  if j.id is null then raise exception 'Job not found'; end if;
  perform private.require_admin(j.unit_id);

  select * into pr from public.pick_return_orders where job_id=j.id for update;
  if pr.job_id is null then raise exception 'This Job does not use Pickup & Return'; end if;
  if j.status='Cancelled' then raise exception 'This Job is cancelled'; end if;
  if p_leg not in ('Pickup','Return') then raise exception 'Choose Pickup or Return'; end if;
  if p_window_start is null or p_window_end is null or p_window_end<=p_window_start then
    raise exception 'Choose a valid delivery window';
  end if;

  select timezone into zone from public.unit_settings where unit_id=j.unit_id;
  route_day:=(p_window_start at time zone zone)::date;

  if p_leg='Pickup' then
    if pr.fee_status<>'Confirmed' then
      raise exception 'Confirm the $10 Pickup fee before scheduling Pickup';
    end if;
    if pr.pickup_status='Picked Up' then
      raise exception 'Items have already been picked up';
    end if;

    deadline:=case
      when extract(isodow from route_day)=6
      then ((route_day-1)+time '18:00') at time zone zone
      else null
    end;
  else
    if pr.hold_until_paid then
      raise exception 'Outstanding cancellation balance must be paid before Return';
    end if;

    select count(*),count(*) filter(where stage='Finished')
    into total_items,finished_items
    from public.job_items
    where job_id=j.id;

    if total_items=0 or total_items<>finished_items then
      raise exception 'Finish every item before scheduling Return';
    end if;

    if pr.return_status not in ('Delivery In Progress','Scheduled') then
      raise exception 'Return is not ready to schedule';
    end if;
  end if;

  update public.pick_return_stops s
  set status='Cancelled'
  from public.pick_return_routes r
  where s.route_id=r.id
    and s.job_id=j.id
    and r.leg=p_leg
    and s.status in ('Scheduled','En Route','Arrived');

  insert into public.pick_return_routes(unit_id,route_date,leg)
  values(j.unit_id,route_day,p_leg)
  on conflict(unit_id,route_date,leg)
  do update set route_date=excluded.route_date
  returning id into v_route_id;

  select coalesce(max(s.sequence),0)+1 into seq
  from public.pick_return_stops s
  where s.route_id=v_route_id;

  insert into public.pick_return_stops(
    unit_id,route_id,job_id,sequence,status,window_start,window_end,eta
  )
  values(
    j.unit_id,v_route_id,j.id,seq,'Scheduled',
    p_window_start,p_window_end,coalesce(p_eta,p_window_start)
  )
  returning id into stop_id;

  if p_leg='Pickup' then
    update public.pick_return_orders
    set pickup_status='Scheduled',
        pickup_window_start=p_window_start,
        pickup_window_end=p_window_end,
        pickup_eta=coalesce(p_eta,p_window_start),
        pickup_cancellation_deadline=deadline,
        updated_at=now()
    where job_id=j.id;
  else
    update public.pick_return_orders
    set return_status='Scheduled',
        return_window_start=p_window_start,
        return_window_end=p_window_end,
        return_eta=coalesce(p_eta,p_window_start),
        updated_at=now()
    where job_id=j.id;
  end if;

  recipient:=private.job_customer_recipient(j.id);
  select token into status_token from private.job_status_links where job_id=j.id;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,
    case when p_leg='Pickup' then 'PICKUP_SCHEDULED' else 'RETURN_SCHEDULED' end,
    stop_id,
    recipient,
    lower(p_leg)||'-scheduled:'||stop_id,
    jsonb_build_object(
      'template','notification',
      'subject',p_leg||' scheduled — '||j.code,
      'text',
        p_leg||' is scheduled for '||
        to_char(p_window_start at time zone zone,'FMDay, FMMonth DD, YYYY')||
        ' between '||
        to_char(p_window_start at time zone zone,'FMHH12:MI AM')||
        ' and '||
        to_char(p_window_end at time zone zone,'FMHH12:MI AM')||'.',
      'action_path',case when status_token is null then null else '/status/'||status_token end,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return stop_id;
end $$;

revoke all on function public.schedule_pick_return(uuid,text,timestamptz,timestamptz,timestamptz) from public,anon;
grant execute on function public.schedule_pick_return(uuid,text,timestamptz,timestamptz,timestamptz) to authenticated;
