-- Additive driver arrival controls. No Agreement or fee changes.
alter table public.pick_return_stops add column pickup_wait_until timestamptz;
alter table public.pick_return_stops add column customer_coming_at timestamptz;
alter table public.pick_return_orders add column pickup_missed_stop_id uuid references public.pick_return_stops(id);

create function public.pickup_driver_action(p_stop uuid,p_action text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.pick_return_stops; r public.pick_return_routes; j public.jobs; pr public.pick_return_orders; result jsonb;
begin
 select * into s from public.pick_return_stops where id=p_stop for update;
 select * into r from public.pick_return_routes where id=s.route_id for update;
 select * into j from public.jobs where id=s.job_id for update;
 if j.id is null or r.leg<>'Pickup' then raise exception 'Pickup stop unavailable';end if;
 perform private.require_admin(j.unit_id);
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.service_method not in ('Pickup Only','Pickup & Delivery') or pr.fee_status<>'Confirmed' then raise exception 'A scheduled, paid Pickup is required';end if;
 if j.status='Cancelled' or j.work_stage like '%Cancellation Requested%' or j.work_stage like '%Production Hold%' then raise exception 'Pickup is blocked while this Job is on hold';end if;
 if p_action in ('customer-coming','wait-more','pickup-miss') then
  if s.status<>'Arrived' then raise exception 'Arrive before using wait controls';end if;
  if p_action='customer-coming' then
   update public.pick_return_stops set customer_coming_at=now(),pickup_wait_until=null where id=s.id;
  elsif p_action='wait-more' then
   if s.customer_coming_at is not null or s.pickup_wait_until is null or now()<s.pickup_wait_until then raise exception 'Wait more is available only after timeout without a customer response';end if;
   update public.pick_return_stops set customer_coming_at=null,pickup_wait_until=now()+interval '5 minutes' where id=s.id;
  else
   if s.customer_coming_at is not null or s.pickup_wait_until is null or now()<s.pickup_wait_until then raise exception 'Wait for the five-minute timer before continuing';end if;
   update public.pick_return_stops set status='Failed',completed_at=now() where id=s.id;
   update public.pick_return_orders set pickup_status='Failed',pickup_missed_stop_id=s.id,updated_at=now() where job_id=j.id;
   perform private.route_notice(j.id,'PICKUP_MISSED','pickup-missed:'||s.id,'We could not collect your items. Choose a free reschedule to the next available Saturday or cancel in your status page. Your Pickup fee is nonrefundable in either case.');
   perform private.activate_next_route_stop(r.id,s.sequence);
  end if;
  return jsonb_build_object('ok',true);
 end if;
 if p_action not in ('en-route','arrived','picked-up') then raise exception 'Unknown Pickup action';end if;
 if p_action='arrived' and s.status<>'En Route' then raise exception 'Start the stop before arriving';end if;
 if p_action='picked-up' and s.status<>'Arrived' then raise exception 'Mark Arrived before collecting items';end if;
 result:=public.advance_pick_return_stop(p_stop,p_action);
 if p_action='arrived' then
  update public.pick_return_stops set pickup_wait_until=now()+interval '5 minutes',customer_coming_at=null where id=s.id;
  perform private.route_notice(j.id,'PICKUP_ARRIVED','pickup-arrived:'||s.id,'ToolTag has arrived for your Pickup. Please come out with your items within five minutes.');
 end if;
 return result;
end $$;
revoke all on function public.pickup_driver_action(uuid,text) from public;
grant execute on function public.pickup_driver_action(uuid,text) to authenticated;

-- Enforce the hold and arrival gates even when an older UI invokes the original RPC.
create function private.pickup_stop_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare j public.jobs;pr public.pick_return_orders;
begin
 if new.status is distinct from old.status and new.status in ('En Route','Arrived','Completed') and exists(select 1 from public.pick_return_routes where id=new.route_id and leg='Pickup') then
  select * into j from public.jobs where id=new.job_id;
  select * into pr from public.pick_return_orders where job_id=j.id;
  if j.status='Cancelled' or j.work_stage like '%Cancellation Requested%' or j.work_stage like '%Production Hold%' then raise exception 'Pickup blocked: Cancellation Requested / Production Hold';end if;
  if pr.fee_status<>'Confirmed' or pr.service_method not in ('Pickup Only','Pickup & Delivery') then raise exception 'A confirmed Pickup service is required';end if;
  if new.status='Completed' and old.status<>'Arrived' then raise exception 'Mark Arrived before Picked Up';end if;
 end if;
 return new;
end $$;
create trigger pickup_stop_guard before update on public.pick_return_stops for each row execute function private.pickup_stop_guard();
revoke all on function private.pickup_stop_guard() from public;

create function public.pickup_miss_choice(p_job uuid,p_token text,p_choice text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; s public.pick_return_stops; r public.pick_return_routes; a jsonb;
begin
 j:=private.route_actor(p_job,p_token);
 if not exists(select 1 from private.job_status_links l where l.job_id=j.id and l.token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex')) then raise exception 'Status link unavailable';end if;
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.pickup_status<>'Failed' or pr.pickup_missed_stop_id is null then raise exception 'There is no missed Pickup to resolve';end if;
 select * into s from public.pick_return_stops where id=pr.pickup_missed_stop_id;
 select * into r from public.pick_return_routes where id=s.route_id;
 if p_choice='cancel' then
  return public.public_status_confirm_cancellation(p_token);
 elsif p_choice='reschedule' then
  a:=public.route_availability(j.id,'Pickup',r.route_date+1,p_token);
  perform private.assign_route(j.id,'Pickup',(a->>'window_start')::timestamptz,(a->>'window_end')::timestamptz,(a->'slots'->0->>'eta')::timestamptz);
  update public.pick_return_orders set pickup_missed_stop_id=null where job_id=j.id;
  perform private.route_notice(j.id,'PICKUP_RESCHEDULED','pickup-retry:'||s.id,'Your Pickup has been rescheduled to the next available Saturday at no additional charge. Your original Pickup fee remains nonrefundable.');
  return a;
 end if;
 raise exception 'Choose reschedule or cancel';
end $$;
revoke all on function public.pickup_miss_choice(uuid,text,text) from public;
grant execute on function public.pickup_miss_choice(uuid,text,text) to anon,authenticated;

create function public.pickup_miss_state(p_job uuid,p_token text) returns boolean language plpgsql security definer set search_path='' as $$
declare j public.jobs; result boolean;
begin
 j:=private.route_actor(p_job,p_token);
 select pickup_status='Failed' and pickup_missed_stop_id is not null into result from public.pick_return_orders where job_id=j.id;
 return coalesce(result,false) and j.status<>'Cancelled';
end $$;
revoke all on function public.pickup_miss_state(uuid,text) from public;
grant execute on function public.pickup_miss_state(uuid,text) to anon,authenticated;

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
    and (r.leg<>'Pickup' or exists(select 1 from public.jobs gate_job join public.pick_return_orders pr on pr.job_id=gate_job.id where gate_job.id=s.job_id and gate_job.status<>'Cancelled' and gate_job.work_stage not like '%Cancellation Requested%' and gate_job.work_stage not like '%Production Hold%' and pr.fee_status='Confirmed' and pr.service_method in ('Pickup Only','Pickup & Delivery')))
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

