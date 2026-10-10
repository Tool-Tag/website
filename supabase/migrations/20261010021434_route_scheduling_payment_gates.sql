-- Additive scheduling/payment gates. Existing Agreement text and accepted snapshots are untouched.
alter table public.unit_settings add column max_delivery_stops_per_sunday integer not null default 20 check (max_delivery_stops_per_sunday between 1 and 100);
alter table public.unit_settings add column second_delivery_attempt_fee numeric(14,2) not null default 10 check (second_delivery_attempt_fee >= 0);
alter table public.pick_return_orders add column delivery_payment_method text check (delivery_payment_method in ('Cash','Zelle','Venmo','Card'));
alter table public.pick_return_orders add column delivery_payment_status text not null default 'Not Ready' check (delivery_payment_status in ('Not Ready','Pending Delivery','Ready','Shop Pickup'));
alter table public.pick_return_orders add column delivery_attempts integer not null default 0;
alter table public.pick_return_orders add column production_ready_at timestamptz;
alter table public.pick_return_routes add column confirmed_at timestamptz;

create function public.attach_logistics_payment_proof(p_token text,p_attempt uuid,p_path text) returns void language plpgsql security definer set search_path='' as $$
declare a public.logistics_payment_attempts;
begin
 select x.* into a from public.logistics_payment_attempts x join private.public_links l on l.quote_id=x.quote_id
 where x.id=p_attempt and l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') for update of x;
 if a.id is null or a.provider<>'manual' or a.payment_request_id is null then raise exception 'Payment unavailable'; end if;
 if p_path <> a.unit_id::text||'/'||a.id::text||'.png' and p_path <> a.unit_id::text||'/'||a.id::text||'.jpg' and p_path <> a.unit_id::text||'/'||a.id::text||'.webp' then raise exception 'Invalid proof path'; end if;
 if not exists(select 1 from storage.objects where bucket_id='payment-proofs' and name=p_path) then raise exception 'Proof not stored'; end if;
 update public.payment_requests set proof_path=p_path where id=a.payment_request_id and proof_path is null;
end $$;
revoke all on function public.attach_logistics_payment_proof(text,uuid,text) from public;
grant execute on function public.attach_logistics_payment_proof(text,uuid,text) to anon,authenticated;

create function public.payment_proof_file(p_code text,p_payment uuid default null,p_token text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.payment_requests;
begin
 select * into j from public.jobs where code=p_code;
 if j.id is null then raise exception 'File unavailable'; end if;
 if not private.can_access(j.unit_id) and not exists(
 select 1 from private.job_status_links l where l.job_id=j.id and l.token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex')
 union all select 1 from private.public_links l where (l.job_id=j.id or l.quote_id=j.quote_id) and l.expires_at>now() and l.token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex')
 ) then raise exception 'File unavailable'; end if;
 select * into pr from public.payment_requests where job_id=j.id and proof_path is not null and (p_payment is null or id=p_payment) order by submitted_at desc limit 1;
 if pr.id is null or pr.proof_path not like j.unit_id::text||'/%' then raise exception 'File unavailable'; end if;
 return jsonb_build_object('path',pr.proof_path,'payment',pr.id);
end $$;
revoke all on function public.payment_proof_file(text,uuid,text) from public;
grant execute on function public.payment_proof_file(text,uuid,text) to anon,authenticated;

create function private.route_actor(p_job uuid,p_token text) returns public.jobs language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 select * into j from public.jobs where id=p_job;
 if j.id is null then raise exception 'Job unavailable'; end if;
 if not private.can_access(j.unit_id) and not exists(select 1 from private.job_status_links l where l.job_id=j.id and l.token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex')) then raise exception 'Access denied'; end if;
 return j;
end $$;
revoke all on function private.route_actor(uuid,text) from public;

create function public.route_availability(p_job uuid,p_leg text,p_day date,p_token text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; d date; start_at timestamptz; cap integer; slots jsonb; n integer; fee_stamp timestamptz;
begin
 j:=private.route_actor(p_job,p_token);
 select * into pr from public.pick_return_orders where job_id=j.id;
 if pr.job_id is null or p_leg not in ('Pickup','Return') then raise exception 'Route unavailable'; end if;
 if p_day is null or p_day < (now() at time zone 'America/Denver')::date then raise exception 'Choose a future date'; end if;
 d:=p_day;
 select case when p_leg='Pickup' then coalesce(max_pickup_stops_per_saturday,10) else max_delivery_stops_per_sunday end into cap from public.unit_settings where unit_id=j.unit_id;
 select max(p.confirmed_at) into fee_stamp from public.payment_requests p where job_id=j.id and status='Confirmed' and purpose in ('Pickup Fee','Logistics Fee','Logistics Full Prepayment');
 for n in 0..104 loop
  if extract(isodow from d) <> (case when p_leg='Pickup' then 6 else 7 end) then d:=d+1;continue;end if;
  start_at:=(d+case when p_leg='Pickup' then time '08:00' else time '14:00' end) at time zone 'America/Denver';
  if start_at<=now()+(case when p_leg='Return' then interval '1 hour' when pr.fee_status<>'Confirmed' or coalesce(fee_stamp,pr.created_at)>start_at-interval '48 hours' then interval '48 hours' else interval '24 hours' end) then d:=d+7;continue;end if;
  select coalesce(jsonb_agg(jsonb_build_object('eta',eta,'label',to_char(eta at time zone 'America/Denver','FMHH12:MI AM')) order by eta),'[]') into slots
  from generate_series(start_at,start_at+interval '4 hours',interval '20 minutes') as slots_at(eta)
  where (select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.unit_id=j.unit_id and r.route_date=d and r.leg=p_leg and s.job_id<>j.id and s.status not in ('Cancelled','Failed'))<cap
  and (select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.unit_id=j.unit_id and r.route_date=d and r.leg=p_leg and s.eta=slots_at.eta and s.job_id<>j.id and s.status not in ('Cancelled','Failed')) < case when p_leg='Pickup' then 1 else cap end;
  if jsonb_array_length(slots)>0 then return jsonb_build_object('day',d,'slots',slots,'window_start',start_at,'window_end',start_at+interval '4 hours','moved',d<>p_day);end if;
  d:=d+7;
 end loop;
 raise exception 'No route availability';
end $$;
revoke all on function public.route_availability(uuid,text,date,text) from public;
grant execute on function public.route_availability(uuid,text,date,text) to authenticated,anon;

CREATE FUNCTION private.assign_route(p_job uuid, p_leg text, p_window_start timestamp with time zone, p_window_end timestamp with time zone, p_eta timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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


  select * into pr from public.pick_return_orders where job_id=j.id for update;
  if pr.job_id is null then raise exception 'This Job does not use Pickup & Return'; end if;
  if p_leg not in ('Pickup','Return') then raise exception 'Choose Pickup or Return'; end if;
  if p_leg='Return' and pr.delivery_attempts>=2 then raise exception 'Shop pickup is required after two missed deliveries';end if;
  if p_leg='Return' and pr.delivery_payment_status='Shop Pickup' then raise exception 'Shop pickup selected';end if;
  if p_leg='Return' and pr.delivery_attempts=1 and not exists(select 1 from public.delivery_attempt_fees f join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=j.id and b.balance_due=0 and b.transaction_status<>'Voided') then raise exception 'Confirm the second Return payment before scheduling';end if;

  if j.status='Cancelled'
     and not (
       p_leg='Return'
       and pr.pickup_status='Picked Up'
     )
  then
    raise exception 'This cancelled Job is not eligible for a route';
  end if;

  if p_window_start is null or p_window_end is null or p_window_end<=p_window_start then
    raise exception 'Choose a valid delivery window';
  end if;

  select timezone into zone from public.unit_settings where unit_id=j.unit_id;
  route_day:=(p_window_start at time zone zone)::date;

  if p_leg='Pickup' then
    if pr.fee_status<>'Confirmed' then
      raise exception 'Confirm the logistics fee before scheduling Pickup';
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

    if j.status='Cancelled' then
      if pr.pickup_status<>'Picked Up' then
        raise exception 'There are no picked-up items to return';
      end if;
    else
      select count(*),count(*) filter(where stage='Finished')
      into total_items,finished_items
      from public.job_items
      where job_id=j.id;

      if total_items=0 or total_items<>finished_items then
        raise exception 'Finish every item before scheduling Return';
      end if;
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
    and s.status in ('Requested','Scheduled','En Route','Arrived');

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
  on conflict(route_id,job_id) do update set status='Scheduled',sequence=excluded.sequence,window_start=excluded.window_start,window_end=excluded.window_end,eta=excluded.eta
  where public.pick_return_stops.status='Cancelled' and public.pick_return_stops.completed_at is null
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
  status_token:=private.ensure_job_status_link(j.id);

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
      'action_path','/status/'||status_token,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return stop_id;
end $_$;
revoke all on function private.assign_route(uuid,text,timestamptz,timestamptz,timestamptz) from public;

create function public.route_schedule(p_job uuid,p_leg text,p_day date,p_eta timestamptz,p_token text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare j public.jobs; available jsonb; chosen timestamptz; previous timestamptz;
begin
 j:=private.route_actor(p_job,p_token);
 if p_token is null then perform private.require_admin(j.unit_id);
 elsif not exists(select 1 from private.job_status_links l where l.job_id=j.id and l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')) then raise exception 'Access denied';end if;
 perform pg_advisory_xact_lock(hashtextextended(j.unit_id::text||p_leg,0));
 select min(s.window_start) into previous from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=j.id and r.leg=p_leg and s.status in ('Requested','Scheduled','En Route','Arrived');
 if previous is not null and now()>=previous-(case when p_leg='Pickup' then interval '24 hours' else interval '1 hour' end) then raise exception 'Rescheduling cutoff has passed';end if;
 available:=public.route_availability(p_job,p_leg,p_day,p_token);
 if (available->>'moved')::boolean then chosen:=(available->'slots'->0->>'eta')::timestamptz;
 elsif exists(select 1 from jsonb_array_elements(available->'slots') x where (x->>'eta')::timestamptz=p_eta) then chosen:=p_eta;
 else raise exception 'That ETA is no longer available';end if;
 return private.assign_route(j.id,p_leg,(available->>'window_start')::timestamptz,(available->>'window_end')::timestamptz,chosen);
end $$;
revoke all on function public.route_schedule(uuid,text,date,timestamptz,text) from public;
grant execute on function public.route_schedule(uuid,text,date,timestamptz,text) to anon,authenticated;

create function public.confirm_pick_return_route(p_route uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 perform private.require_admin(r.unit_id);
 if r.confirmed_at is not null then return;end if;
 if not exists(select 1 from public.pick_return_stops where route_id=r.id and status in ('Completed','Failed')) or exists(select 1 from public.pick_return_stops where route_id=r.id and status not in ('Completed','Failed','Cancelled')) then raise exception 'Resolve every stop before confirming the route';end if;
 update public.pick_return_routes set status='Completed',completed_at=now(),confirmed_at=now() where id=r.id;
end $$;
revoke all on function public.confirm_pick_return_route(uuid) from public;
grant execute on function public.confirm_pick_return_route(uuid) to authenticated;

CREATE OR REPLACE FUNCTION private.activate_next_route_stop(p_route uuid, p_after_sequence integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  nxt public.pick_return_stops;
  r public.pick_return_routes;
  j public.jobs;
  recipient text;
  status_token text;
  zone text;
  eta_text text;
begin
  select * into r from public.pick_return_routes where id=p_route for update;
  if r.id is null then return; end if;

  select s.* into nxt
  from public.pick_return_stops s
  where s.route_id=r.id
    and s.sequence>p_after_sequence
    and s.status='Scheduled'
  order by s.sequence
  limit 1
  for update;

  if nxt.id is null then
    if not exists(
      select 1 from public.pick_return_stops s
      where s.route_id=r.id
        and s.status in ('Requested','Scheduled','En Route','Arrived')
    ) then
      update public.pick_return_routes set status='Active',completed_at=null where id=r.id;
    end if;
    return;
  end if;

  if r.leg='Return' and (exists(select 1 from public.delivery_attempt_fees df join public.sale_balances b on b.transaction_id=df.sale_id where df.job_id=nxt.job_id and b.balance_due>0) or exists(select 1 from public.job_commercial_totals t join public.pick_return_orders pr on pr.job_id=t.id where t.id=nxt.job_id and t.balance_due>0 and coalesce(pr.delivery_payment_method,'')<>'Cash')) then return;end if;
  update public.pick_return_stops set status='En Route' where id=nxt.id;
  update public.pick_return_routes
  set status='Active',started_at=coalesce(started_at,now())
  where id=r.id;

  if r.leg='Pickup' then
    update public.pick_return_orders
    set pickup_status='En Route',pickup_eta=nxt.eta,updated_at=now()
    where job_id=nxt.job_id;
  else
    update public.pick_return_orders
    set return_status='En Route',return_eta=nxt.eta,updated_at=now()
    where job_id=nxt.job_id;
  end if;

  select * into j from public.jobs where id=nxt.job_id;
  recipient:=private.job_customer_recipient(j.id);
  select l.token into status_token from private.job_status_links l where l.job_id=j.id;
  select timezone into zone from public.unit_settings where unit_id=j.unit_id;
  eta_text:=case
    when nxt.eta is null then ''
    else ' Estimated arrival: '||to_char(nxt.eta at time zone zone,'FMHH12:MI AM')||'.'
  end;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,
    case when r.leg='Pickup' then 'PICKUP_EN_ROUTE' else 'RETURN_EN_ROUTE' end,
    nxt.id,
    recipient,
    lower(r.leg)||'-en-route:'||nxt.id,
    jsonb_build_object(
      'template','notification',
      'subject','ToolTag is on the way — '||j.code,
      'text',
        case when r.leg='Pickup'
          then 'ToolTag has completed the previous stop and is now on the way for your Pickup.'
          else 'ToolTag has completed the previous stop and is now on the way with your completed items.'
        end||eta_text,
      'action_path',case when status_token is null then null else '/status/'||status_token end,
      'live_eligible',true
    )
  )
  on conflict do nothing;
end $$;

CREATE OR REPLACE FUNCTION public.public_job_status(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  customer_name text;
  prog jsonb;
  pr jsonb;
  tracking_stage text;
  tracking_steps jsonb;
  pickup_status text;
  return_status text;
  hold_until_paid boolean:=false;
  cancellation public.cancellation_requests;
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

  select
    to_jsonb(x)-'unit_id'-'terms_snapshot',
    x.pickup_status,
    x.return_status,
    x.hold_until_paid
  into pr,pickup_status,return_status,hold_until_paid
  from public.pick_return_orders x
  where x.job_id=j.id;

  if j.status='Cancelled' then
    select * into cancellation
    from public.cancellation_requests c
    where c.job_id=j.id and c.status='Cancelled'
    order by c.cancelled_at desc,c.created_at desc
    limit 1;

    if cancellation.id is not null then
      prog:=jsonb_build_object(
        'total',cancellation.items_total,
        'started',cancellation.items_started,
        'finished',cancellation.items_finished,
        'cancelled',greatest(cancellation.items_total-cancellation.items_finished,0),
        'current_item_id',null,
        'current_sequence',null
      );
    end if;

    if pr is not null and pickup_status='Picked Up' then
      tracking_steps:=jsonb_build_array(
        'Cancelled',
        'Cancellation Balance',
        'Delivery In Progress',
        'Return Scheduled',
        'Out for Delivery',
        'Delivered'
      );

      tracking_stage:=case
        when return_status='Delivered' then 'Delivered'
        when return_status in ('En Route','Arrived') then 'Out for Delivery'
        when return_status='Scheduled' then 'Return Scheduled'
        when hold_until_paid then 'Cancellation Balance'
        else 'Delivery In Progress'
      end;
    else
      tracking_steps:=jsonb_build_array('Cancelled');
      tracking_stage:='Cancelled';
    end if;

  elsif pr is not null then
    tracking_steps:=jsonb_build_array(
      'Pickup Fee','Pickup Scheduled','Pickup In Progress','Picked Up',
      'In Process','Engraving','Delivery In Progress','Return Scheduled',
      'Out for Delivery','Delivered','Completed'
    );

    tracking_stage:=case
      when j.status='Completed' or j.work_stage='Closed' then 'Completed'
      when return_status='Delivered' then 'Delivered'
      when return_status in ('En Route','Arrived') then 'Out for Delivery'
      when return_status='Scheduled' then 'Return Scheduled'
      when return_status='Delivery In Progress' then 'Delivery In Progress'
      when j.customer_stage='Engraving' then 'Engraving'
      when pickup_status='Picked Up' then 'In Process'
      when pickup_status in ('En Route','Arrived') then 'Pickup In Progress'
      when pickup_status='Scheduled' then 'Pickup Scheduled'
      when coalesce(pr->>'fee_status','Required')<>'Confirmed' then 'Pickup Fee'
      else 'Pickup Scheduled'
    end;
  else
    tracking_steps:=jsonb_build_array(
      'In Process','Engraving','Final Details','Completed'
    );
    tracking_stage:=j.customer_stage;
  end if;

  return jsonb_build_object(
    'id',j.id,
    'code',j.code,
    'customer_name',customer_name,
    'stage',j.customer_stage,
    'tracking_stage',case when pr->>'delivery_payment_status'='Pending Delivery' and j.status<>'Cancelled' then 'Pending Delivery' when pr->>'delivery_payment_status'='Shop Pickup' then 'Shop Pickup' else tracking_stage end,
    'job_status',j.status,
    'work_stage',j.work_stage,
    'updated_at',greatest(j.updated_at,(pr->>'updated_at')::timestamptz,(select max(coalesce(confirmed_at,submitted_at)) from public.payment_requests where job_id=j.id)),
    'items_total',coalesce((prog->>'total')::integer,0),
    'items_completed',coalesce((prog->>'finished')::integer,0),
    'items_started',coalesce((prog->>'started')::integer,0),
    'payment_proofs',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'submitted_at',submitted_at)),'[]') from public.payment_requests where job_id=j.id and proof_path is not null),
    'item_progress',prog,
    'payment',private.job_payment_snapshot(j.id),
    'pickup_return',pr,
    'second_return_fee',(select second_delivery_attempt_fee from public.unit_settings where unit_id=j.unit_id),
    'second_return_chosen',exists(select 1 from public.delivery_attempt_fees where job_id=j.id),
    'cancelled',j.status='Cancelled',
    'steps',tracking_steps
  );
end $$;

create function public.mark_logistics_manual_with_proof(p_token text,p_attempt uuid,p_path text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=public.mark_logistics_manual_submitted(p_token,p_attempt);
 if p_path is not null then perform public.attach_logistics_payment_proof(p_token,p_attempt,p_path);end if;
 return result;
end $$;
revoke all on function public.mark_logistics_manual_with_proof(text,uuid,text) from public;
grant execute on function public.mark_logistics_manual_with_proof(text,uuid,text) to anon,authenticated;

CREATE OR REPLACE FUNCTION public.public_submit_pickup_fee_payment(p_token text, p_request uuid, p_method text, p_proof_path text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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

  if p_proof_path is not null and (p_proof_path not like j.unit_id::text||'/%'
     or not exists(
       select 1 from storage.objects o
       where o.bucket_id='payment-proofs'
         and o.name=p_proof_path
     ))
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
end $_$;

create table public.delivery_attempt_fees (
 id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.business_units(id),
 job_id uuid not null references public.jobs(id), stop_id uuid not null unique references public.pick_return_stops(id),
 amount numeric(14,2) not null check (amount>=0), sale_id uuid references public.transactions(id), created_at timestamptz not null default now()
);
alter table public.delivery_attempt_fees enable row level security;
create policy delivery_attempt_fees_staff_read on public.delivery_attempt_fees for select to authenticated using (private.can_access(unit_id));
grant select on public.delivery_attempt_fees to authenticated;
revoke all on public.delivery_attempt_fees from anon;

create or replace view public.job_commercial_totals with (security_invoker=true) as
 select j.id,j.unit_id,coalesce(b.amount,0) as base_amount,
 coalesce(e.amount,0)+coalesce(f.amount,0) as extensions_amount,
 coalesce(b.amount,0)+coalesce(e.amount,0)+coalesce(f.amount,0) as grand_total,
 coalesce(b.collected,0)+coalesce(e.collected,0)+coalesce(f.collected,0) as collected,
 coalesce(b.refunded,0)+coalesce(e.refunded,0)+coalesce(f.refunded,0) as refunded,
 greatest(0,coalesce(b.amount,0)+coalesce(e.amount,0)+coalesce(f.amount,0)-coalesce(b.collected,0)-coalesce(e.collected,0)-coalesce(f.collected,0)) as balance_due
 from public.jobs j left join public.sale_balances b on b.job_id=j.id and b.transaction_status<>'Voided'
 left join lateral (select sum(s.amount) amount,sum(s.collected) collected,sum(s.refunded) refunded from public.job_extensions x join public.sale_balances s on s.transaction_id=x.sale_id where x.job_id=j.id and x.status in ('Approved','Completed') and s.transaction_status<>'Voided') e on true
 left join lateral (select sum(s.amount) amount,sum(s.collected) collected,sum(s.refunded) refunded from public.delivery_attempt_fees x join public.sale_balances s on s.transaction_id=x.sale_id where x.job_id=j.id and s.transaction_status<>'Voided') f on true;

create function private.payment_job(p_token text) returns public.jobs language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 select x.* into j from public.jobs x where exists(select 1 from private.job_status_links l where l.job_id=x.id and l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')) or exists(select 1 from private.public_links l where (l.job_id=x.id or l.quote_id=x.quote_id) and l.expires_at>now() and l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex'));
 if j.id is null or j.status in ('Cancelled','Completed') then raise exception 'Payment link unavailable';end if;
 return j;
end $$;
revoke all on function private.payment_job(text) from public;

create function public.prepare_route_payment(p_token text,p_method text,p_attempt uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; st public.unit_settings; due numeric; start_at timestamptz;
begin
 j:=private.payment_job(p_token);
 perform 1 from public.jobs where id=j.id for update;
 select * into st from public.unit_settings where unit_id=j.unit_id;
 select * into pr from public.pick_return_orders where job_id=j.id;
 select balance_due into due from public.job_commercial_totals where id=j.id;
 if p_method not in ('Cash','Zelle','Venmo','Card') or coalesce(due,0)<=0 then raise exception 'Payment unavailable';end if;
 if p_method='Zelle' and nullif(trim(st.zelle_email),'') is null or p_method='Venmo' and nullif(trim(st.venmo_handle),'') is null then raise exception 'Payment method is not configured';end if;
 start_at:=pr.return_window_start;
 if p_method='Cash' and start_at is not null and now()>=start_at-interval '1 hour' then raise exception 'Cash selection cutoff has passed';end if;
 if p_method='Cash' and exists(select 1 from public.delivery_attempt_fees f join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=j.id and b.balance_due>0) then raise exception 'Pay the second-attempt fee electronically or choose shop pickup';end if;
 update public.pick_return_orders set delivery_payment_method=p_method,updated_at=now() where job_id=j.id;
 if p_method='Card' then
 insert into public.logistics_payment_attempts(id,unit_id,quote_id,job_id,provider,method,payment_scope,amount,status) values(p_attempt,j.unit_id,j.quote_id,j.id,'stripe','Card','full',due,'pending');
 end if;
 return jsonb_build_object('job_id',j.id,'quote_id',j.quote_id,'job_code',j.code,'amount',due,'customer_email',private.job_customer_recipient(j.id),'zelle',st.zelle_email,'venmo',st.venmo_handle);
end $$;
revoke all on function public.prepare_route_payment(text,text,uuid) from public;
grant execute on function public.prepare_route_payment(text,text,uuid) to anon,authenticated;

create function public.attach_route_card_session(p_token text,p_attempt uuid,p_reference text) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 j:=private.payment_job(p_token);
 update public.logistics_payment_attempts set provider_reference=p_reference where id=p_attempt and job_id=j.id and provider='stripe' and status='pending' and provider_reference is null;
 if not found then raise exception 'Payment unavailable';end if;
end $$;
revoke all on function public.attach_route_card_session(text,uuid,text) from public;
grant execute on function public.attach_route_card_session(text,uuid,text) to anon,authenticated;

create function public.submit_route_payment(p_token text,p_method text,p_request uuid,p_path text) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; prepared jsonb; rid uuid;
begin
 j:=private.payment_job(p_token);
 select id into rid from public.payment_requests where request_key=p_request and job_id=j.id;
 if rid is not null then return jsonb_build_object('id',rid);end if;
 prepared:=public.prepare_route_payment(p_token,p_method,p_request);
 if p_method='Cash' then return jsonb_build_object('method','Cash','selected',true);end if;
 if p_method not in ('Zelle','Venmo') then raise exception 'Choose a manual payment method';end if;
 if p_path is null or p_path not like j.unit_id::text||'/%' or not exists(select 1 from storage.objects where bucket_id='payment-proofs' and name=p_path) then raise exception 'Upload payment proof';end if;
 if exists(select 1 from public.payment_requests where job_id=j.id and status='Pending Verification') then raise exception 'A payment is awaiting verification';end if;
 insert into public.payment_requests(request_key,unit_id,job_id,method,amount,proof_path,purpose) values(p_request,j.unit_id,j.id,p_method,(prepared->>'amount')::numeric,p_path,'Final Balance') returning id into rid;
 return jsonb_build_object('id',rid,'status','Pending Verification');
end $$;
revoke all on function public.submit_route_payment(text,text,uuid,text) from public;
grant execute on function public.submit_route_payment(text,text,uuid,text) to anon,authenticated;

CREATE OR REPLACE FUNCTION public.confirm_payment_request(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  r public.payment_requests;
  j public.jobs;
  cancellation public.cancellation_requests;
  remaining numeric(14,2);
  due numeric(14,2);
  remaining_due numeric(14,2);
  alloc numeric(14,2);
  paid numeric(14,2):=0;
  rec record;
  tid uuid;
  tids uuid[]:='{}';
  collection_account uuid;
  recipient text;
  status_token text;
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
  elsif r.purpose='Cancellation Balance' then
    select * into cancellation
    from public.cancellation_requests
    where job_id=j.id and status='Cancelled'
    order by cancelled_at desc,created_at desc
    limit 1;

    if cancellation.id is null
       or cancellation.amount_due<=0
       or r.amount>cancellation.amount_due+0.01
    then
      raise exception 'Cancellation balance is not awaiting confirmation';
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
      union all select 1000,s.transaction_id,s.balance_due,s.customer_id from public.delivery_attempt_fees df join public.sale_balances s on s.transaction_id=df.sale_id where df.job_id=j.id and s.transaction_status<>'Voided' and s.balance_due>0
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
      case
        when r.purpose='Pickup Fee' then 'Verified Pickup fee · '||j.code
        when r.purpose='Cancellation Balance' then 'Verified cancellation balance · '||j.code
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
    if r.purpose='Cancellation Balance' then
      select balance_due into remaining_due
      from public.job_commercial_totals
      where id=j.id;

      if coalesce(remaining_due,0)<=0.01 then
        update public.pick_return_orders
        set hold_until_paid=false,
            return_status=case
              when pickup_status='Picked Up'
                   and return_status='Not Ready'
              then 'Delivery In Progress'
              else return_status
            end,
            updated_at=now()
        where job_id=j.id;

        recipient:=private.job_customer_recipient(j.id);
        status_token:=private.ensure_job_status_link(j.id);

        insert into public.notifications(
          unit_id,event,entity_id,recipient,dedupe_key,payload
        )
        values(
          j.unit_id,
          'CANCELLATION_BALANCE_CONFIRMED',
          r.id,
          recipient,
          'cancellation-balance-confirmed:'||r.id,
          jsonb_build_object(
            'template','notification',
            'subject','Cancellation balance confirmed — '||j.code,
            'text','ToolTag confirmed your cancellation balance payment. If ToolTag already has your items, the Return process can now continue.',
            'action_path','/status/'||status_token,
            'live_eligible',true
          )
        )
        on conflict do nothing;
      end if;
    end if;

    perform public.generate_job_receipt(j.id);
  end if;

  return jsonb_build_object(
    'id',r.id,'status',r.status,'purpose',r.purpose,
    'confirmed_amount',r.confirmed_amount,'transaction_ids',r.transaction_ids
  );
end $_$;

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
      max_delivery_stops_per_sunday=coalesce((p->>'max_delivery_stops_per_sunday')::integer,max_delivery_stops_per_sunday),
      second_delivery_attempt_fee=coalesce((p->>'second_delivery_attempt_fee')::numeric,second_delivery_attempt_fee),
      max_pickup_stops_per_saturday=coalesce(max_stops,max_pickup_stops_per_saturday)
  where unit_id=u;
end $$;

create function private.route_notice(p_job uuid,p_event text,p_key text,p_text text) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs; token text;
begin
 select * into j from public.jobs where id=p_job;
 token:=private.ensure_job_status_link(j.id);
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(j.unit_id,p_event,j.id,private.job_customer_recipient(j.id),p_key,jsonb_build_object('template','notification','subject','ToolTag — '||j.code,'text',p_text,'action_path','/status/'||token,'live_eligible',true)) on conflict do nothing;
end $$;
revoke all on function private.route_notice(uuid,text,text,text) from public;

create function private.auto_return(p_job uuid,p_after date default null) returns uuid language plpgsql security definer set search_path='' as $$
declare j public.jobs; a jsonb; d date; sid uuid; chosen timestamptz;
begin
 select * into j from public.jobs where id=p_job for update;
 perform pg_advisory_xact_lock(hashtextextended(j.unit_id::text||'Return',0));
 d:=coalesce(p_after,(now() at time zone 'America/Denver')::date);
 a:=public.route_availability(j.id,'Return',d,private.ensure_job_status_link(j.id));
 select (slot->>'eta')::timestamptz into chosen from jsonb_array_elements(a->'slots') slot order by (select count(*) from public.pick_return_stops ss join public.pick_return_routes r on r.id=ss.route_id where r.unit_id=j.unit_id and r.leg='Return' and ss.eta=(slot->>'eta')::timestamptz and ss.status not in ('Cancelled','Failed')), (slot->>'eta')::timestamptz limit 1;
 sid:=private.assign_route(j.id,'Return',(a->>'window_start')::timestamptz,(a->>'window_end')::timestamptz,chosen);
 return sid;
end $$;
revoke all on function private.auto_return(uuid,date) from public;

create function private.reconcile_delivery(p_job uuid) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; due numeric; start_at timestamptz; paid_at timestamptz;
begin
 select * into j from public.jobs where id=p_job for update;
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.delivery_attempts>=2 or pr.production_ready_at is null or pr.returned_at is not null or pr.delivery_payment_status='Shop Pickup' or j.status in ('Cancelled','Completed') then return;end if;
 select balance_due into due from public.job_commercial_totals where id=j.id;
 select max(confirmed_at) into paid_at from public.payment_requests where job_id=j.id and status='Confirmed';
 start_at:=pr.return_window_start;
 if pr.delivery_attempts=1 and start_at is null then
  if exists(select 1 from public.delivery_attempt_fees f join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=j.id and b.balance_due=0 and b.transaction_status<>'Voided') then
   perform private.auto_return(j.id,(select max(r.route_date)+1 from public.pick_return_stops ss join public.pick_return_routes r on r.id=ss.route_id where ss.job_id=j.id and ss.status='Failed' and r.leg='Return'));
  end if;
  return;
 end if;
 if start_at is not null and now()>=start_at-interval '1 hour' and (coalesce(due,0)>0 and coalesce(pr.delivery_payment_method,'')<>'Cash' or coalesce(due,0)=0 and paid_at>start_at-interval '1 hour') then
  perform private.auto_return(j.id,(start_at at time zone 'America/Denver')::date+1);
  perform private.route_notice(j.id,'RETURN_RESCHEDULED','return-cutoff:'||j.id||':'||start_at,'Your delivery has moved to the next available Sunday because payment was not confirmed by the final cutoff. See your updated schedule.');
 end if;
 update public.pick_return_orders set delivery_payment_status=case when coalesce(due,0)=0 then 'Ready' else 'Pending Delivery' end,updated_at=now() where job_id=j.id;
 if coalesce(due,0)>0 and start_at is not null and now()>=start_at-interval '24 hours' then
  perform private.route_notice(j.id,'PAYMENT_DUE','return-24h:'||j.id||':'||start_at,'Your delivery payment is pending. Electronic payment must be verified, or select cash before the final cutoff one hour before the route. No payment, no handover.');
 end if;
end $$;
revoke all on function private.reconcile_delivery(uuid) from public;

create function private.production_route_ready() returns trigger language plpgsql security definer set search_path='' as $$
declare pr public.pick_return_orders; due numeric;
begin
 if new.status='Cancelled' or new.work_stage not in ('Delivery In Progress','Final Details') then return new;end if;
 select * into pr from public.pick_return_orders where job_id=new.id for update;
 if pr.job_id is null or pr.production_ready_at is not null or pr.return_status='Not Applicable' then return new;end if;
 if not exists(select 1 from public.job_items where job_id=new.id) or exists(select 1 from public.job_items where job_id=new.id and stage<>'Finished') then return new;end if;
 select balance_due into due from public.job_commercial_totals where id=new.id;
 update public.pick_return_orders set production_ready_at=now(),return_status='Delivery In Progress',delivery_payment_status=case when coalesce(due,0)=0 then 'Ready' else 'Pending Delivery' end where job_id=new.id;
 perform private.auto_return(new.id);
 if coalesce(due,0)>0 then perform private.route_notice(new.id,'PAYMENT_DUE','production-payment:'||new.id,'Your engraving is finished. Your Return route is assigned and is pending payment. Choose your payment method in your private status page.');end if;
 return new;
end $$;
revoke all on function private.production_route_ready() from public;
create trigger jobs_production_route_ready after update of work_stage on public.jobs for each row execute function private.production_route_ready();

create function public.collect_route_cash(p_stop uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.pick_return_stops; j public.jobs; pr public.pick_return_orders; due numeric; rid uuid;
begin
 select * into s from public.pick_return_stops where id=p_stop for update;
 select * into j from public.jobs where id=s.job_id for update;
 perform private.require_admin(j.unit_id);
 select * into pr from public.pick_return_orders where job_id=j.id;
 if pr.delivery_payment_method is distinct from 'Cash' or s.status<>'Arrived' or not exists(select 1 from public.pick_return_routes where id=s.route_id and leg='Return') then raise exception 'Cash collection is unavailable';end if;
 select balance_due into due from public.job_commercial_totals where id=j.id;
 if due<=0 then return jsonb_build_object('paid',true);end if;
 if exists(select 1 from public.payment_requests where job_id=j.id and status='Pending Verification') then raise exception 'Resolve pending payment verification first';end if;
 insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(s.id,j.unit_id,j.id,'Cash',due,'Final Balance') on conflict(request_key) do update set request_key=excluded.request_key returning id into rid;
 return public.confirm_payment_request(rid);
end $$;
revoke all on function public.collect_route_cash(uuid) from public;
grant execute on function public.collect_route_cash(uuid) to authenticated;

create function public.choose_shop_pickup(p_job uuid,p_token text) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders;
begin
 j:=private.route_actor(p_job,p_token);
 if not exists(select 1 from private.job_status_links where job_id=j.id and token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')) then raise exception 'Access denied';end if;
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.production_ready_at is null or pr.returned_at is not null then raise exception 'Shop pickup unavailable';end if;
 -- An unperformed second trip has no charge when free shop pickup is chosen.
 if pr.delivery_attempts=1 then
  if exists(select 1 from public.delivery_attempt_fees f join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=j.id and b.collected>0) then raise exception 'Contact ToolTag before changing a paid second delivery';end if;
  update public.transactions t set status='Voided' from public.delivery_attempt_fees f where f.job_id=j.id and f.sale_id=t.id;
 end if;
 update public.pick_return_stops s set status='Cancelled' from public.pick_return_routes r where s.route_id=r.id and s.job_id=j.id and r.leg='Return' and s.status in ('Requested','Scheduled','En Route','Arrived');
 update public.pick_return_orders set delivery_payment_status='Shop Pickup',updated_at=now() where job_id=j.id;
 perform private.route_notice(j.id,'SHOP_PICKUP','shop-pickup:'||j.id,'Your items will be held at the shop. Wait for ToolTag pickup instructions. The first delivery attempt is not refundable.');
end $$;
revoke all on function public.choose_shop_pickup(uuid,text) from public;
grant execute on function public.choose_shop_pickup(uuid,text) to anon,authenticated;

create or replace function public.schedule_pick_return(p_job uuid,p_leg text,p_window_start timestamptz,p_window_end timestamptz,p_eta timestamptz default null) returns uuid language plpgsql security definer set search_path='' as $$
begin
 return public.route_schedule(p_job,p_leg,(p_window_start at time zone 'America/Denver')::date,coalesce(p_eta,p_window_start),null);
end $$;

create or replace function private.sync_payment_work_stage()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  jid uuid;
begin
  if tg_table_name='payment_requests' then
    jid:=new.job_id;
    if exists(select 1 from public.pick_return_orders where job_id=jid and production_ready_at is not null and returned_at is null) then
      if new.status='Confirmed' then perform private.reconcile_delivery(jid);end if;
      return new;
    end if;

    if new.purpose in ('Logistics Fee','Logistics Full Prepayment') then
      return new;
    end if;

    if new.status='Pending Verification' then
      update public.jobs
      set work_stage='Payment Verification',updated_at=now()
      where id=jid;
    elsif new.status='Confirmed' then
      if exists(
        select 1
        from public.job_commercial_totals
        where id=jid and balance_due=0
      ) then
        update public.jobs
        set work_stage='Closed',updated_at=now()
        where id=jid;
      else
        update public.jobs
        set work_stage='Payment',updated_at=now()
        where id=jid;
      end if;
    end if;
  end if;

  return new;
end $$;

CREATE OR REPLACE FUNCTION public.advance_pick_return_stop(p_stop uuid, p_action text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  s public.pick_return_stops;
  r public.pick_return_routes;
  j public.jobs;
  pr public.pick_return_orders;
  recipient text;
  status_token text;
  zone text;
  eta_text text;
  completion_token text;
  due numeric; fee numeric; sale uuid; cid uuid;
begin
  select * into s from public.pick_return_stops where id=p_stop for update;
  if s.id is null then raise exception 'Route stop not found'; end if;

  select * into r from public.pick_return_routes where id=s.route_id for update;
  select * into j from public.jobs where id=s.job_id for update;
  perform private.require_admin(j.unit_id);

  perform private.apply_pending_cancellation(j.id);

  select * into j from public.jobs where id=s.job_id for update;
  select * into pr from public.pick_return_orders where job_id=j.id for update;

  if j.status='Cancelled'
     and not (
       r.leg='Return'
       and pr.pickup_status='Picked Up'
     )
  then
    raise exception 'This cancelled Job cannot continue this route';
  end if;

  if p_action='en-route' and exists(select 1 from public.pick_return_stops where route_id=r.id and sequence<s.sequence and status not in ('Completed','Cancelled','Failed')) then raise exception 'Resolve the previous stop first';end if;
  if r.leg='Return' then
    perform private.reconcile_delivery(j.id);
    select * into s from public.pick_return_stops where id=p_stop;
    if s.status='Cancelled' then return jsonb_build_object('rescheduled',true);end if;
    if exists(select 1 from public.delivery_attempt_fees df join public.sale_balances b on b.transaction_id=df.sale_id where df.job_id=j.id and b.balance_due>0) then raise exception 'Confirm the second-attempt fee before starting Return';end if;
    select balance_due into due from public.job_commercial_totals where id=j.id;
    if p_action='delivered' and coalesce(due,0)>0 then raise exception 'Collect and confirm payment before handing over items';end if;
  end if;

  if p_action='not-home' then
    if r.leg<>'Return' or s.status not in ('Arrived','En Route') then raise exception 'Arrive before marking Customer not home';end if;
    update public.pick_return_stops set status='Failed',completed_at=now() where id=s.id;
    update public.pick_return_orders set delivery_attempts=delivery_attempts+1,return_status='Delivery In Progress',updated_at=now() where job_id=j.id returning * into pr;
    if pr.delivery_attempts>=2 then
      update public.pick_return_orders set delivery_payment_status='Shop Pickup' where job_id=j.id;
      perform private.route_notice(j.id,'RETURN_MISSED','return-missed:'||s.id,'The second delivery attempt was unsuccessful. Your items are held at the shop. Wait for pickup instructions; nothing was left at the door.');
    else
      update public.pick_return_orders set return_window_start=null,return_window_end=null,return_eta=null,delivery_payment_status='Pending Delivery' where job_id=j.id;
      perform private.route_notice(j.id,'RETURN_MISSED','return-missed:'||s.id,'You were not home. Nothing was left at the door. Choose free shop pickup or pay for a second delivery attempt in your status page. The first delivery attempt is not refundable.');
    end if;
    perform private.activate_next_route_stop(r.id,s.sequence);
  elsif p_action='en-route' then
    if s.status<>'Scheduled' then raise exception 'Stop is not ready to start'; end if;
    if r.leg='Pickup' and pr.fee_status<>'Confirmed' then
      raise exception 'Pickup fee must be confirmed before starting the route';
    end if;
    if r.leg='Return' and pr.hold_until_paid then
      raise exception 'Outstanding balance must be paid before Return';
    end if;

    update public.pick_return_stops set status='En Route' where id=s.id;
    update public.pick_return_routes
    set status='Active',started_at=coalesce(started_at,now())
    where id=r.id;

    if r.leg='Pickup' then
      update public.pick_return_orders
      set pickup_status='En Route',pickup_eta=s.eta,updated_at=now()
      where job_id=j.id;
    else
      update public.pick_return_orders
      set return_status='En Route',return_eta=s.eta,updated_at=now()
      where job_id=j.id;
    end if;

    recipient:=private.job_customer_recipient(j.id);
    status_token:=private.ensure_job_status_link(j.id);
    select timezone into zone from public.unit_settings where unit_id=j.unit_id;
    eta_text:=case
      when s.eta is null then ''
      else ' Estimated arrival: '||to_char(s.eta at time zone zone,'FMHH12:MI AM')||'.'
    end;

    insert into public.notifications(
      unit_id,event,entity_id,recipient,dedupe_key,payload
    )
    values(
      j.unit_id,
      case when r.leg='Pickup' then 'PICKUP_EN_ROUTE' else 'RETURN_EN_ROUTE' end,
      s.id,
      recipient,
      lower(r.leg)||'-en-route:'||s.id,
      jsonb_build_object(
        'template','notification',
        'subject','ToolTag is on the way — '||j.code,
        'text',
          case when r.leg='Pickup'
            then 'ToolTag is on the way for your scheduled Pickup.'
            else 'ToolTag is on the way with your items.'
          end||eta_text,
        'action_path','/status/'||status_token,
        'live_eligible',true
      )
    )
    on conflict do nothing;

  elsif p_action='arrived' then
    if s.status not in ('Scheduled','En Route') then
      raise exception 'Stop cannot be marked Arrived';
    end if;

    update public.pick_return_stops
    set status='Arrived',arrived_at=coalesce(arrived_at,now())
    where id=s.id;

    if r.leg='Pickup' then
      update public.pick_return_orders
      set pickup_status='Arrived',updated_at=now()
      where job_id=j.id;
    else
      update public.pick_return_orders
      set return_status='Arrived',updated_at=now()
      where job_id=j.id;
    end if;

  elsif p_action='picked-up' then
    if r.leg<>'Pickup' then raise exception 'This is not a Pickup stop'; end if;
    if s.status not in ('Arrived','En Route') then
      raise exception 'Arrive at the Pickup stop first';
    end if;
    if pr.fee_status<>'Confirmed' then
      raise exception 'Pickup fee must be confirmed before collecting items';
    end if;
    if not exists(
      select 1 from public.documents d
      where d.pick_return_stop_id=s.id
        and d.job_id=j.id
        and d.type='Receiving Evidence'
        and d.status='Available'
    ) then
      raise exception 'Add receiving photos before marking Picked Up';
    end if;

    update public.pick_return_stops
    set status='Completed',completed_at=coalesce(completed_at,now())
    where id=s.id;

    update public.pick_return_orders
    set pickup_status='Picked Up',
        picked_up_at=coalesce(picked_up_at,now()),
        updated_at=now()
    where job_id=j.id;

    update public.jobs
    set status='In Process',
        work_stage='Preparing',
        customer_stage='In Process',
        updated_at=now()
    where id=j.id;

    perform private.activate_next_route_stop(r.id,s.sequence);

  elsif p_action='delivered' then
    if r.leg<>'Return' then raise exception 'This is not a Return stop'; end if;
    if s.status not in ('Arrived','En Route') then
      raise exception 'Arrive at the Return stop first';
    end if;
    if pr.hold_until_paid then
      raise exception 'Outstanding balance must be paid before delivery';
    end if;
    if not exists(
      select 1 from public.documents d
      where d.pick_return_stop_id=s.id
        and d.job_id=j.id
        and d.type='Delivery Evidence'
        and d.status='Available'
    ) then
      raise exception 'Add delivery photos before marking Delivered';
    end if;

    update public.pick_return_stops
    set status='Completed',completed_at=coalesce(completed_at,now())
    where id=s.id;

    update public.pick_return_orders
    set return_status='Delivered',
        returned_at=coalesce(returned_at,now()),
        updated_at=now()
    where job_id=j.id;

    if j.status='Cancelled' then
      recipient:=private.job_customer_recipient(j.id);
      status_token:=private.ensure_job_status_link(j.id);

      insert into public.notifications(
        unit_id,event,entity_id,recipient,dedupe_key,payload
      )
      values(
        j.unit_id,
        'CANCELLED_ITEMS_RETURNED',
        s.id,
        recipient,
        'cancelled-items-returned:'||j.id,
        jsonb_build_object(
          'template','notification',
          'subject','Items returned — '||j.code,
          'text','Your items from the cancelled ToolTag Job have been returned. Delivery evidence has been recorded.',
          'action_path','/status/'||status_token,
          'live_eligible',true
        )
      )
      on conflict do nothing;
    else
      completion_token:=private.begin_delivery_acceptance(j.id);
    end if;

    perform private.activate_next_route_stop(r.id,s.sequence);

  else
    raise exception 'Invalid route action';
  end if;

  return jsonb_build_object(
    'blocked',false,'job_id',j.id,'stop_id',s.id,
    'leg',r.leg,'action',p_action,'completion_token',completion_token
  );
end $$;

CREATE OR REPLACE FUNCTION public.complete_job_production(p_id uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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

  if exists(select 1 from public.pick_return_orders where job_id=j.id and return_status<>'Not Applicable') then
    raise exception 'Pickup & Return Jobs must complete the Return delivery flow';
  end if;

  select count(*),count(*) filter(where stage='Finished')
  into total_items,finished_items
  from public.job_items
  where job_id=j.id;

  if total_items=0 or finished_items<>total_items then
    raise exception 'Finish every Job item before completing production';
  end if;

  if j.status='Ready for Delivery' then return null;end if;
  if exists(
    select 1 from public.job_extensions
    where job_id=j.id and status in ('Requested','Draft','Sent')
  ) then
    raise exception 'Resolve pending extensions first';
  end if;

  update public.job_extensions
  set status='Completed'
  where job_id=j.id and status='Approved';

  update public.jobs set status='Ready for Delivery',work_stage='Final Details',customer_stage='Final Details',updated_at=now() where id=j.id;
  perform private.route_notice(j.id,'JOB_READY','shop-ready:'||j.id,'Your items are ready. Wait for ToolTag handover instructions. Delivery acceptance will be available after you receive your items.');
  return null;
end $$;

create function public.confirm_shop_handover(p_job uuid) returns text language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 select * into j from public.jobs where id=p_job for update;
 perform private.require_admin(j.unit_id);
 if j.delivered_at is not null then return null;end if;
 if j.status='Cancelled' or not exists(select 1 from public.job_items where job_id=j.id) or exists(select 1 from public.job_items where job_id=j.id and stage<>'Finished') then raise exception 'Items are not ready';end if;
 if exists(select 1 from public.pick_return_orders where job_id=j.id and return_status<>'Not Applicable' and delivery_payment_status<>'Shop Pickup') then raise exception 'Complete Return delivery instead';end if;
 if exists(select 1 from public.job_commercial_totals where id=j.id and balance_due>0) then raise exception 'Collect and confirm payment before handover';end if;
 update public.pick_return_orders set returned_at=now(),return_status='Delivered',updated_at=now() where job_id=j.id and delivery_payment_status='Shop Pickup';
 return private.begin_delivery_acceptance(j.id);
end $$;
revoke all on function public.confirm_shop_handover(uuid) from public;
grant execute on function public.confirm_shop_handover(uuid) to authenticated;

-- The retry is a customer choice, never a charge created automatically by a miss.
create function public.choose_second_return(p_job uuid,p_token text) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; fee numeric; cid uuid; sale uuid; stop uuid;
begin
 j:=private.route_actor(p_job,p_token);
 if not exists(select 1 from private.job_status_links where job_id=j.id and token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')) then raise exception 'Access denied';end if;
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.delivery_attempts<>1 or pr.returned_at is not null or pr.delivery_payment_status='Shop Pickup' then raise exception 'A second Return is unavailable';end if;
 if exists(select 1 from public.delivery_attempt_fees where job_id=j.id) then return;end if;
 select id into stop from public.pick_return_stops where job_id=j.id and status='Failed' order by completed_at desc limit 1;
 select second_delivery_attempt_fee into fee from public.unit_settings where unit_id=j.unit_id;
 select customer_id into cid from public.commercial_flows where id=j.flow_id;
 if fee>0 then
  insert into public.transactions(unit_id,type,amount,customer_id,description,reference) values(j.unit_id,'SALE',fee,cid,'Second Return attempt · '||j.code,'RETURN:'||stop) returning id into sale;
  insert into public.sales(transaction_id,unit_id,code,approved_items) values(sale,j.unit_id,j.code||'/RETURN2',jsonb_build_array(jsonb_build_object('article','Second Return attempt','quantity',1,'unit_price',fee)));
 end if;
 insert into public.delivery_attempt_fees(unit_id,job_id,stop_id,amount,sale_id) values(j.unit_id,j.id,stop,fee,sale);
 perform private.route_notice(j.id,'PAYMENT_DUE','return-retry-payment:'||j.id,'Your second delivery will be scheduled only after the additional fee is paid and confirmed. A second missed attempt is nonrefundable and requires shop pickup.');
end $$;
revoke all on function public.choose_second_return(uuid,text) from public;
grant execute on function public.choose_second_return(uuid,text) to anon,authenticated;

create function private.reconcile_pickups() returns void language plpgsql security definer set search_path='' as $$
declare pr public.pick_return_orders; a jsonb; paid_at timestamptz;
begin
 for pr in select p.* from public.pick_return_orders p join public.jobs j on j.id=p.job_id join public.business_units b on b.id=j.unit_id where b.code='TOOLTAG' and j.status not in ('Cancelled','Completed') and p.pickup_status in ('Not Scheduled','Scheduled') for update of p loop
  if pr.pickup_window_start is null then
   select s.window_start,s.window_end into pr.pickup_window_start,pr.pickup_window_end from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=pr.job_id and r.leg='Pickup' and s.status in ('Requested','Scheduled') order by s.window_start limit 1;
  end if;
  if pr.pickup_window_start is null then continue;end if;
  select max(confirmed_at) into paid_at from public.payment_requests where job_id=pr.job_id and status='Confirmed' and purpose in ('Pickup Fee','Logistics Fee','Logistics Full Prepayment');
  if (now()>=pr.pickup_window_start-interval '48 hours' and (pr.fee_status<>'Confirmed' or paid_at>pr.pickup_window_start-interval '48 hours')) or (pr.fee_status='Confirmed' and pr.pickup_eta is null and now()>=pr.pickup_window_start-interval '24 hours') then
   update public.pick_return_stops s set status='Cancelled' from public.pick_return_routes r where s.route_id=r.id and s.job_id=pr.job_id and r.leg='Pickup' and s.status in ('Requested','Scheduled');
   a:=public.route_availability(pr.job_id,'Pickup',(pr.pickup_window_start at time zone 'America/Denver')::date+7,private.ensure_job_status_link(pr.job_id));
   update public.pick_return_orders set pickup_window_start=(a->>'window_start')::timestamptz,pickup_window_end=(a->>'window_end')::timestamptz,pickup_eta=null,pickup_status='Not Scheduled',updated_at=now() where job_id=pr.job_id;
   perform private.route_notice(pr.job_id,'PICKUP_RESCHEDULED','pickup-cutoff:'||pr.job_id||':'||pr.pickup_window_start,'Your previous Saturday slot was released because the payment or scheduling cutoff passed. Choose an available slot for the next eligible Saturday in your status page.');
  end if;
 end loop;
end $$;
revoke all on function private.reconcile_pickups() from public;

CREATE OR REPLACE FUNCTION public.run_scheduled_tasks() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u record; m date; j record; route_job record;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required'; end if;
 update public.notifications n set payload=n.payload||jsonb_build_object('due',true,'detected_at',now())
 where n.event='Quote expiration reminder' and n.due_at<=now() and coalesce((n.payload->>'due')::boolean,false)=false
 and exists(select 1 from public.quotes q where q.id=n.entity_id and q.status in ('Sent','Viewed','Agreement Pending') and q.expires_at>now());
 update public.quotes set status='Expired'  where status in ('Sent','Viewed','Agreement Pending') and expires_at<now();
 for j in update public.jobs set status='Completed',auto_closed_at=now(),completion_reason='Completed – Deemed Accepted per Agreement'
 where status='Delivered – Pending Customer Acceptance' and acceptance_deadline<now() returning * loop
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(j.unit_id,'Administrative completion',j.id,'auto-complete:'||j.id) on conflict do nothing;
 end loop;
 perform private.reconcile_pickups();
 for route_job in select p.job_id from public.pick_return_orders p join public.jobs jj on jj.id=p.job_id join public.business_units b on b.id=jj.unit_id where b.code='TOOLTAG' and p.production_ready_at is not null and p.returned_at is null and jj.status not in ('Cancelled','Completed') loop
  perform private.reconcile_delivery(route_job.job_id);
 end loop;
 -- TT only in phase 1. BOFT production and its monthly automation are untouched.
 for u in select s.* from public.unit_settings s join public.business_units b on b.id=s.unit_id where b.code='TOOLTAG' loop
 m:=(date_trunc('month',now() at time zone u.timezone)-interval '1 month')::date;
 if not exists(select 1 from public.monthly_closes where unit_id=u.unit_id and month=m) then perform public.close_month(u.unit_id,m); end if;
 end loop;
end $$;

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
        where extract(isodow from gs)=6 and ((gs::date+time '08:00') at time zone zone)>now()+interval '48 hours'
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
       or ((saturday+time '08:00') at time zone zone)<=now()+interval '48 hours'
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
