-- Driver arrival, attended handover and provisional second-Return reservations.
alter table public.pick_return_stops add column return_wait_until timestamptz;
alter table public.pick_return_stops add column return_customer_coming_at timestamptz;
alter table public.pick_return_stops add column customer_present_at timestamptz;
create function public.return_driver_action(p_stop uuid,p_action text,p_present boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.pick_return_stops;r public.pick_return_routes;j public.jobs;pr public.pick_return_orders;result jsonb;
begin
 select * into s from public.pick_return_stops where id=p_stop for update;
 select * into r from public.pick_return_routes where id=s.route_id for update;
 select * into j from public.jobs where id=s.job_id for update;
 if j.id is null or r.leg<>'Return' then raise exception 'Return stop unavailable';end if;
 perform private.require_admin(j.unit_id);
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.service_method not in ('Pickup & Delivery','Drop-off + Delivery') or pr.production_ready_at is null then raise exception 'This Job is not ready for Return';end if;
 if j.status='Cancelled' or j.work_stage like '%Cancellation Requested%' or j.work_stage like '%Production Hold%' then raise exception 'Delivery blocked: Cancellation Requested / Production Hold';end if;
 if exists(select 1 from public.job_extensions where job_id=j.id and status in ('Requested','Draft','Sent')) or exists(select 1 from public.job_items where job_id=j.id and stage not in ('Finished','Cancelled')) then raise exception 'Delivery blocked: resolve pending additional work first';end if;
 if p_action='customer-coming' then
  if s.status<>'Arrived' then raise exception 'Arrive before recording the customer response';end if;
  update public.pick_return_stops set return_customer_coming_at=now(),return_wait_until=null where id=s.id;
  return jsonb_build_object('ok',true);
 end if;
 if p_action='not-home' then
  if s.status<>'Arrived' or s.return_customer_coming_at is not null or s.return_wait_until is null or now()<s.return_wait_until then raise exception 'Wait five minutes without a customer response before continuing';end if;
 elsif p_action='cash' then
  if s.status<>'Arrived' or not p_present then raise exception 'The customer must be present for the cash exchange';end if;
  if pr.delivery_payment_method<>'Cash' then raise exception 'This stop is not a cash delivery';end if;
  return public.collect_route_cash(s.id);
 elsif p_action='arrived' then
  if s.status<>'En Route' then raise exception 'Start the Return before arriving';end if;
 elsif p_action='delivered' then
  if s.status<>'Arrived' or not p_present then raise exception 'The customer must be present. Never leave items at the door';end if;
  update public.pick_return_stops set customer_present_at=now() where id=s.id;
 elsif p_action<>'en-route' then raise exception 'Unknown Return action';end if;
 result:=public.advance_pick_return_stop(p_stop,p_action);
 if coalesce((result->>'rescheduled')::boolean,false) then return result;end if;
 if p_action='arrived' then
  update public.pick_return_stops set return_wait_until=now()+interval '5 minutes',return_customer_coming_at=null where id=s.id;
  perform private.route_notice(j.id,'RETURN_ARRIVED','return-arrived:'||s.id,'ToolTag has arrived with your items. Please come out to receive them within five minutes. Nothing will be left unattended.');
 end if;
 return result;
end $$;
revoke all on function public.return_driver_action(uuid,text,boolean) from public;
grant execute on function public.return_driver_action(uuid,text,boolean) to authenticated;

create function private.return_delivery_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 if new.status='Completed' and old.status<>'Completed' and exists(select 1 from public.pick_return_routes where id=new.route_id and leg='Return') then
  select * into j from public.jobs where id=new.job_id;
  if j.work_stage like '%Cancellation Requested%' or j.work_stage like '%Production Hold%' then raise exception 'Delivery blocked: Cancellation Requested / Production Hold';end if;
  if exists(select 1 from public.job_extensions where job_id=j.id and status in ('Requested','Draft','Sent')) or exists(select 1 from public.job_items where job_id=j.id and stage not in ('Finished','Cancelled')) then raise exception 'Resolve additional work before delivery';end if;
  if new.customer_present_at is null then raise exception 'The customer must be present to receive the delivery';end if;
 end if;
 return new;
end $$;
create trigger return_delivery_guard before update on public.pick_return_stops for each row execute function private.return_delivery_guard();
revoke all on function private.return_delivery_guard() from public;

create function private.extension_route_cutoff() returns trigger language plpgsql security definer set search_path='' as $$
declare start_at timestamptz;
begin
 perform 1 from public.jobs where id=new.job_id for update;
 select min(s.window_start) into start_at from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=new.job_id and r.leg='Return' and s.status in ('Scheduled','En Route','Arrived');
 if start_at is not null and now()>=start_at-interval '1 hour' then raise exception 'Additional work cutoff: one hour before the Return window starts';end if;
 return new;
end $$;
create trigger extension_route_cutoff before insert on public.job_extensions for each row execute function private.extension_route_cutoff();
revoke all on function private.extension_route_cutoff() from public;

create function public.return_acknowledgment_link(p_stop uuid) returns text language plpgsql security definer set search_path='' as $$
declare s public.pick_return_stops;j public.jobs;token text;
begin
 select * into s from public.pick_return_stops where id=p_stop;
 select * into j from public.jobs where id=s.job_id;
 perform private.require_admin(j.unit_id);
 if s.status<>'Completed' or j.status<>'Delivered – Pending Customer Acceptance' or not exists(select 1 from public.pick_return_routes where id=s.route_id and leg='Return') then return null;end if;
 select l.token into token from private.job_mail_links l where l.job_id=j.id;
 return token;
end $$;
revoke all on function public.return_acknowledgment_link(uuid) from public;
grant execute on function public.return_acknowledgment_link(uuid) to authenticated;

alter table public.pick_return_orders add column return_reservation_stop_id uuid references public.pick_return_stops(id);
alter table public.pick_return_orders add column return_reservation_expires_at timestamptz;

create function private.reserve_return_retry(p_job uuid,p_missed uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare j public.jobs;pr public.pick_return_orders;miss public.pick_return_stops;r public.pick_return_routes;a jsonb;rid uuid;sid uuid;seq integer;chosen timestamptz;
begin
 select * into j from public.jobs where id=p_job for update;
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.delivery_attempts<>1 or pr.returned_at is not null or pr.delivery_payment_status='Shop Pickup' then return null;end if;
 if pr.return_reservation_stop_id is not null then return pr.return_reservation_stop_id;end if;
 perform pg_advisory_xact_lock(hashtextextended(j.unit_id::text||'Return',0));
 select * into miss from public.pick_return_stops where id=p_missed and job_id=j.id and status='Failed';
 select * into r from public.pick_return_routes where id=miss.route_id and leg='Return';
 if r.id is null then raise exception 'Missed Return unavailable';end if;
 a:=public.route_availability(j.id,'Return',greatest(r.route_date+1,(now() at time zone 'America/Denver')::date),private.ensure_job_status_link(j.id));
 select (slot->>'eta')::timestamptz into chosen from jsonb_array_elements(a->'slots') slot order by (select count(*) from public.pick_return_stops ss join public.pick_return_routes rr on rr.id=ss.route_id where rr.unit_id=j.unit_id and rr.leg='Return' and ss.eta=(slot->>'eta')::timestamptz and ss.status not in ('Cancelled','Failed')), (slot->>'eta')::timestamptz limit 1;
 insert into public.pick_return_routes(unit_id,route_date,leg) values(j.unit_id,(a->>'day')::date,'Return') on conflict(unit_id,route_date,leg) do update set route_date=excluded.route_date returning id into rid;
 perform 1 from public.pick_return_routes where id=rid for update;
 select coalesce(max(sequence),0)+1 into seq from public.pick_return_stops where route_id=rid;
 insert into public.pick_return_stops(unit_id,route_id,job_id,sequence,status,window_start,window_end,eta,address,customer_phone,customer_email)
 values(j.unit_id,rid,j.id,seq,'Requested',(a->>'window_start')::timestamptz,(a->>'window_end')::timestamptz,chosen,miss.address,miss.customer_phone,private.job_customer_recipient(j.id)) returning id into sid;
 update public.pick_return_orders set return_reservation_stop_id=sid,return_reservation_expires_at=now()+interval '15 days',return_window_start=(a->>'window_start')::timestamptz,return_window_end=(a->>'window_end')::timestamptz,return_eta=chosen,return_status='Scheduled',delivery_payment_status='Pending Delivery',updated_at=now() where job_id=j.id;
 return sid;
end $$;
revoke all on function private.reserve_return_retry(uuid,uuid) from public;

create function private.release_return_reservation(p_job uuid) returns void language plpgsql security definer set search_path='' as $$
declare pr public.pick_return_orders;
begin
 select * into pr from public.pick_return_orders where job_id=p_job for update;
 update public.pick_return_stops s set status='Cancelled' from public.pick_return_routes r where s.route_id=r.id and s.job_id=p_job and r.leg='Return' and s.status in ('Requested','Scheduled');
 update public.transactions t set status='Voided' from public.delivery_attempt_fees f join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=p_job and f.sale_id=t.id and b.collected=0;
 update public.pick_return_orders set delivery_payment_status='Shop Pickup',return_status='Delivery In Progress',return_window_start=null,return_window_end=null,return_eta=null,return_reservation_stop_id=null,return_reservation_expires_at=null,updated_at=now() where job_id=p_job;
 perform private.route_notice(p_job,'SHOP_PICKUP','reservation-expired:'||coalesce(pr.return_reservation_stop_id::text,p_job::text),'Your provisional second Return was not paid in time and the reserved place has been released. Your items stay at the shop for free pickup when instructed. The first delivery attempt remains nonrefundable.');
end $$;
revoke all on function private.release_return_reservation(uuid) from public;

create or replace function private.reconcile_delivery(p_job uuid) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; due numeric; start_at timestamptz; paid_at timestamptz; retry_paid boolean; retry_paid_at timestamptz; reservation public.pick_return_stops;
begin
 select * into j from public.jobs where id=p_job for update;
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.delivery_attempts>=2 or pr.production_ready_at is null or pr.returned_at is not null or pr.delivery_payment_status='Shop Pickup' or j.status in ('Cancelled','Completed') then return;end if;
 if pr.delivery_attempts=1 and pr.return_reservation_stop_id is not null then
  select * into reservation from public.pick_return_stops where id=pr.return_reservation_stop_id for update;
  select coalesce(bool_or((f.amount=0 or b.balance_due=0) and coalesce(b.transaction_status,'')<>'Voided'),false) into retry_paid from public.delivery_attempt_fees f left join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=j.id;
  if not retry_paid then
   if now()>=pr.return_reservation_expires_at or now()>=reservation.window_start-interval '1 hour' then perform private.release_return_reservation(j.id);end if;
   return;
  end if;
  select max(confirmed_at) into retry_paid_at from public.payment_requests where job_id=j.id and status='Confirmed';
  if retry_paid_at>reservation.window_start-interval '1 hour' or now()>=reservation.window_start then
   perform private.auto_return(j.id,(reservation.window_start at time zone 'America/Denver')::date+1);
  else
   perform private.assign_route(j.id,'Return',reservation.window_start,reservation.window_end,reservation.eta);
  end if;
  update public.pick_return_orders set return_reservation_stop_id=null,return_reservation_expires_at=null,updated_at=now() where job_id=j.id;
  select * into pr from public.pick_return_orders where job_id=j.id;
 end if;
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
      perform private.reserve_return_retry(j.id,s.id);
      select * into pr from public.pick_return_orders where job_id=j.id;
      perform private.route_notice(j.id,'RETURN_MISSED','return-missed:'||s.id,'Delivery pending. Nothing was left at the door. A provisional place is reserved for '||to_char(pr.return_window_start at time zone 'America/Denver','FMDay, FMMonth DD, YYYY')||'. Confirm the second attempt by paying $'||(select to_char(second_delivery_attempt_fee,'FM999999990.00') from public.unit_settings where unit_id=j.unit_id)||' before the route payment cutoff, or choose free shop pickup. Unpaid reservations are released at the cutoff or after 15 days, whichever comes first. The first attempt is nonrefundable. A second miss requires shop pickup; there is no third trip.');
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


create or replace function public.choose_shop_pickup(p_job uuid,p_token text) returns void language plpgsql security definer set search_path='' as $$
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
 update public.pick_return_orders set delivery_payment_status='Shop Pickup',return_reservation_stop_id=null,return_reservation_expires_at=null,return_window_start=null,return_window_end=null,return_eta=null,updated_at=now() where job_id=j.id;
 perform private.route_notice(j.id,'SHOP_PICKUP','shop-pickup:'||j.id,'Your items will be held at the shop. Wait for ToolTag pickup instructions. The first delivery attempt is not refundable.');
end $$;
revoke all on function public.choose_shop_pickup(uuid,text) from public;
grant execute on function public.choose_shop_pickup(uuid,text) to anon,authenticated;


create or replace function public.choose_second_return(p_job uuid,p_token text) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; fee numeric; cid uuid; sale uuid; stop uuid;
begin
 j:=private.route_actor(p_job,p_token);
 if not exists(select 1 from private.job_status_links where job_id=j.id and token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')) then raise exception 'Access denied';end if;
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.delivery_attempts<>1 or pr.returned_at is not null or pr.delivery_payment_status='Shop Pickup' then raise exception 'A second Return is unavailable';end if;
 if pr.return_reservation_expires_at is not null and (now()>=pr.return_reservation_expires_at or now()>=pr.return_window_start-interval '1 hour') then raise exception 'The provisional Return reservation has expired; arrange shop pickup';end if;
 if exists(select 1 from public.delivery_attempt_fees where job_id=j.id) then return;end if;
 select id into stop from public.pick_return_stops where job_id=j.id and status='Failed' order by completed_at desc limit 1;
 select second_delivery_attempt_fee into fee from public.unit_settings where unit_id=j.unit_id;
 select customer_id into cid from public.commercial_flows where id=j.flow_id;
 if fee>0 then
  insert into public.transactions(unit_id,type,amount,customer_id,description,reference) values(j.unit_id,'SALE',fee,cid,'Second Return attempt · '||j.code,'RETURN:'||stop) returning id into sale;
  insert into public.sales(transaction_id,unit_id,code,approved_items) values(sale,j.unit_id,j.code||'/RETURN2',jsonb_build_array(jsonb_build_object('article','Second Return attempt','quantity',1,'unit_price',fee)));
 end if;
 insert into public.delivery_attempt_fees(unit_id,job_id,stop_id,amount,sale_id) values(j.unit_id,j.id,stop,fee,sale);
 perform private.route_notice(j.id,'PAYMENT_DUE','return-retry-payment:'||j.id,'Your provisional second delivery is pending. Its reservation is confirmed only after the additional fee is paid and verified. A second missed attempt is nonrefundable and requires shop pickup.');
end $$;
revoke all on function public.choose_second_return(uuid,text) from public;
grant execute on function public.choose_second_return(uuid,text) to anon,authenticated;


create function private.route_delivery_contact() returns trigger language plpgsql security definer set search_path='' as $$
declare j public.jobs;c public.customers;address text;
begin
 select * into j from public.jobs where id=new.job_id;
 select x.* into c from public.customers x join public.commercial_flows f on f.customer_id=x.id where f.id=j.flow_id;
 select case when r.leg='Return' then l.delivery_address else l.pickup_address end into address from public.pick_return_routes r join public.quote_logistics l on l.quote_id=j.quote_id where r.id=new.route_id;
 new.address:=coalesce(nullif(new.address,''),address);
 new.customer_phone:=coalesce(nullif(new.customer_phone,''),nullif(c.phone,''));
 new.customer_email:=coalesce(nullif(new.customer_email,''),private.job_customer_recipient(j.id));
 return new;
end $$;
create trigger route_delivery_contact before insert on public.pick_return_stops for each row execute function private.route_delivery_contact();
revoke all on function private.route_delivery_contact() from public;

create function public.return_retry_context(p_job uuid,p_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs;pr public.pick_return_orders;
begin
 j:=private.route_actor(p_job,p_token);
 if not exists(select 1 from private.job_status_links l where l.job_id=j.id and l.token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex')) then raise exception 'Status link unavailable';end if;
 select * into pr from public.pick_return_orders where job_id=j.id;
 return jsonb_build_object('reserved',pr.return_reservation_stop_id is not null,'expires_at',pr.return_reservation_expires_at,'day',pr.return_window_start,'shop',pr.delivery_payment_status='Shop Pickup');
end $$;
revoke all on function public.return_retry_context(uuid,text) from public;
grant execute on function public.return_retry_context(uuid,text) to anon,authenticated;
