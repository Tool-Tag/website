-- Weekly delivery route day: ISO 1=Monday ... 7=Sunday. No existing bookings are moved.
alter table public.unit_settings add column delivery_route_iso_weekday integer not null default 7
 check (delivery_route_iso_weekday between 1 and 7);
comment on column public.unit_settings.delivery_route_iso_weekday is 'Delivery route weekday (ISO 1-7), Sunday by default; affects new availability and rescheduling, not existing stops.';

create or replace function public.route_availability(p_job uuid,p_leg text,p_day date,p_token text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; d date; start_at timestamptz; cap integer; slots jsonb; n integer; fee_stamp timestamptz; delivery_day integer;
begin
 j:=private.route_actor(p_job,p_token);
 select * into pr from public.pick_return_orders where job_id=j.id;
 if pr.job_id is null or p_leg not in ('Pickup','Return') then raise exception 'Route unavailable'; end if;
 if p_day is null or p_day < (now() at time zone 'America/Denver')::date then raise exception 'Choose a future date'; end if;
 d:=p_day;
 select case when p_leg='Pickup' then coalesce(max_pickup_stops_per_saturday,10) else max_delivery_stops_per_sunday end into cap from public.unit_settings where unit_id=j.unit_id;
 select delivery_route_iso_weekday into delivery_day from public.unit_settings where unit_id=j.unit_id;
 select max(p.confirmed_at) into fee_stamp from public.payment_requests p where job_id=j.id and status='Confirmed' and purpose in ('Pickup Fee','Logistics Fee','Logistics Full Prepayment');
 for n in 0..104 loop
  if extract(isodow from d) <> (case when p_leg='Pickup' then 6 else coalesce(delivery_day,7) end) then d:=d+1;continue;end if;
  start_at:=(d+case when p_leg='Pickup' then time '08:00' else time '14:00' end) at time zone 'America/Denver';
  if start_at<=now()+(case when p_leg='Return' then interval '1 hour' when pr.fee_status<>'Confirmed' or coalesce(fee_stamp,pr.created_at)>start_at-interval '48 hours' then interval '48 hours' else interval '24 hours' end) then d:=d+7;continue;end if;
  select coalesce(jsonb_agg(jsonb_build_object('eta',eta,'label',to_char(eta at time zone 'America/Denver','FMHH12:MI AM')) order by eta),'[]') into slots
  from generate_series(start_at,start_at+interval '4 hours',interval '20 minutes') as slots_at(eta)
  where (select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.unit_id=j.unit_id and r.route_date=d and r.leg=p_leg and s.job_id<>j.id and s.status not in ('Cancelled','Failed'))<cap
  and (select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.unit_id=j.unit_id and r.route_date=d and r.leg=p_leg and s.eta=slots_at.eta and s.job_id<>j.id and s.status not in ('Cancelled','Failed')) < case when p_leg='Pickup' then 1 else cap end;
  if jsonb_array_length(slots)>0 then return jsonb_build_object('route_iso_weekday',case when p_leg='Pickup' then 6 else coalesce(delivery_day,7) end,'day',d,'slots',slots,'window_start',start_at,'window_end',start_at+interval '4 hours','moved',d<>p_day);end if;
  d:=d+7;
 end loop;
 raise exception 'No route availability';
end $$;

create or replace function public.report_driver_incident(p_route uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;i public.route_incidents;s public.pick_return_stops;
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.id is null or not exists(select 1 from public.business_units where id=r.unit_id and code='TOOLTAG') then raise exception 'Route unavailable';end if;perform private.require_admin(r.unit_id);
 select * into i from public.route_incidents where route_id=r.id;
 if i.id is not null then return i.id;end if;
 if r.status in ('Cancelled','Completed') or r.confirmed_at is not null then raise exception 'Route is closed';end if;
 if not exists(select 1 from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived')) then raise exception 'No remaining confirmed stops';end if;
 insert into public.route_incidents(unit_id,route_id) values(r.unit_id,r.id) returning * into i;
 for s in select * from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived') order by sequence loop
  insert into public.route_incident_jobs(incident_id,unit_id,job_id,stop_id) values(i.id,r.unit_id,s.job_id,s.id);
  perform private.route_notice(s.job_id,'ROUTE_INTERRUPTED','route-incident:'||i.id||':'||s.job_id,'We are sorry: our driver is unable to continue right now. ToolTag will confirm within 15 minutes whether a replacement can continue or your service moves to the next available '||case when r.leg='Pickup' then 'Saturday' else 'delivery route day' end||'. If a replacement is available, you may wait approximately one hour with a $5 refund, or reschedule. If no driver is available, a $10 refund is due; '||case when r.leg='Pickup' then 'Pickup will be rescheduled free of charge. You do not need to bring your pieces to the shop.' else 'you may collect your items at the shop for free.' end||' Refunds go back to your original payment method when its provider supports automatic refunds; otherwise ToolTag must issue the payment. Follow your status page.');
 end loop;
 return i.id;
end $$;

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
  perform private.route_notice(j.id,'RETURN_RESCHEDULED','return-cutoff:'||j.id||':'||start_at,'Your delivery has moved to the next available delivery route day because payment was not confirmed by the final cutoff. See your updated schedule.');
 end if;
 update public.pick_return_orders set delivery_payment_status=case when coalesce(due,0)=0 then 'Ready' else 'Pending Delivery' end,updated_at=now() where job_id=j.id;
 if coalesce(due,0)>0 and start_at is not null and now()>=start_at-interval '24 hours' then
  perform private.route_notice(j.id,'PAYMENT_DUE','return-24h:'||j.id||':'||start_at,'Your delivery payment is pending. Electronic payment must be verified, or select cash before the final cutoff one hour before the route. No payment, no handover.');
 end if;
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
      delivery_route_iso_weekday=coalesce((p->>'delivery_route_iso_weekday')::integer,delivery_route_iso_weekday),
      max_delivery_stops_per_sunday=coalesce((p->>'max_delivery_stops_per_sunday')::integer,max_delivery_stops_per_sunday),
      second_delivery_attempt_fee=coalesce((p->>'second_delivery_attempt_fee')::numeric,second_delivery_attempt_fee),
      max_pickup_stops_per_saturday=coalesce(max_stops,max_pickup_stops_per_saturday)
  where unit_id=u;
end $$;
