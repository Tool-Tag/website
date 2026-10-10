-- ISO weekdays 1=Monday .. 7=Sunday. Existing routes/snapshots stay unchanged.
alter table public.unit_settings
 add column pickup_route_iso_weekdays integer[] not null default array[6],
 add column return_route_iso_weekdays integer[] not null default array[7],
 add constraint pickup_route_days_valid check (cardinality(pickup_route_iso_weekdays) between 1 and 7 and pickup_route_iso_weekdays <@ array[1,2,3,4,5,6,7]),
 add constraint return_route_days_valid check (cardinality(return_route_iso_weekdays) between 1 and 7 and return_route_iso_weekdays <@ array[1,2,3,4,5,6,7]);
update public.unit_settings set return_route_iso_weekdays=array[delivery_route_iso_weekday];
comment on column public.unit_settings.pickup_route_iso_weekdays is 'Weekly Pickup days, default Saturday. Review Agreement when changing.';
comment on column public.unit_settings.return_route_iso_weekdays is 'Weekly Return days, default Sunday. Review Agreement when changing.';
create or replace function public.route_availability(p_job uuid,p_leg text,p_day date,p_token text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; d date; start_at timestamptz; cap integer; slots jsonb; n integer; fee_stamp timestamptz; route_days integer[];
begin
 j:=private.route_actor(p_job,p_token);
 select * into pr from public.pick_return_orders where job_id=j.id;
 if pr.job_id is null or p_leg not in ('Pickup','Return') then raise exception 'Route unavailable'; end if;
 if p_day is null or p_day < (now() at time zone 'America/Denver')::date then raise exception 'Choose a future date'; end if;
 d:=p_day;
 select case when p_leg='Pickup' then coalesce(max_pickup_stops_per_saturday,10) else max_delivery_stops_per_sunday end into cap from public.unit_settings where unit_id=j.unit_id;
 select case when p_leg='Pickup' then pickup_route_iso_weekdays else return_route_iso_weekdays end into route_days from public.unit_settings where unit_id=j.unit_id;
 select max(p.confirmed_at) into fee_stamp from public.payment_requests p where job_id=j.id and status='Confirmed' and purpose in ('Pickup Fee','Logistics Fee','Logistics Full Prepayment');
 for n in 0..104 loop
  if not (extract(isodow from d)::integer = any(route_days)) then d:=d+1;continue;end if;
  start_at:=(d+case when p_leg='Pickup' then time '08:00' else time '14:00' end) at time zone 'America/Denver';
  if start_at<=now()+(case when p_leg='Return' then interval '1 hour' when pr.fee_status<>'Confirmed' or coalesce(fee_stamp,pr.created_at)>start_at-interval '48 hours' then interval '48 hours' else interval '24 hours' end) then d:=d+1;continue;end if;
  select coalesce(jsonb_agg(jsonb_build_object('eta',eta,'label',to_char(eta at time zone 'America/Denver','FMHH12:MI AM')) order by eta),'[]') into slots
  from generate_series(start_at,start_at+interval '4 hours',interval '20 minutes') as slots_at(eta)
  where (select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.unit_id=j.unit_id and r.route_date=d and r.leg=p_leg and s.job_id<>j.id and s.status not in ('Cancelled','Failed'))<cap
  and (select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.unit_id=j.unit_id and r.route_date=d and r.leg=p_leg and s.eta=slots_at.eta and s.job_id<>j.id and s.status not in ('Cancelled','Failed')) < case when p_leg='Pickup' then 1 else cap end;
  if jsonb_array_length(slots)>0 then return jsonb_build_object('route_iso_weekdays',to_jsonb(route_days),'route_iso_weekday',extract(isodow from d)::integer,'day',d,'slots',slots,'window_start',start_at,'window_end',start_at+interval '4 hours','moved',d<>p_day);end if;
  d:=d+1;
 end loop;
 raise exception 'No route availability';
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
      raise exception 'Pickup route capacity must be between 1 and 100';
    end if;
  end if;

  if p ? 'pickup_route_iso_weekdays' and jsonb_typeof(p->'pickup_route_iso_weekdays')<>'array' then raise exception 'Choose Pickup route days';end if;
  if p ? 'return_route_iso_weekdays' and jsonb_typeof(p->'return_route_iso_weekdays')<>'array' then raise exception 'Choose Return route days';end if;
  update public.unit_settings
  set timezone=case when p ? 'timezone' then p->>'timezone' else timezone end,
      drive_root_id=case when p ? 'drive_root_id' then nullif(trim(p->>'drive_root_id'),'') else drive_root_id end,
      boft_url=case when p ? 'boft_url' then nullif(trim(p->>'boft_url'),'') else boft_url end,
      annual_vehicle_method=case when p ? 'annual_vehicle_method' then p->>'annual_vehicle_method' else annual_vehicle_method end,
      mileage_rate=case when p ? 'mileage_rate' then nullif(p->>'mileage_rate','')::numeric else mileage_rate end,
      zelle_email=case when p ? 'zelle_email' then nullif(trim(p->>'zelle_email'),'') else zelle_email end,
      venmo_handle=case when p ? 'venmo_handle' then nullif(trim(p->>'venmo_handle'),'') else venmo_handle end,
      pickup_route_iso_weekdays=case when p ? 'pickup_route_iso_weekdays' then array(select distinct x::integer from jsonb_array_elements_text(p->'pickup_route_iso_weekdays') x order by x::integer) else pickup_route_iso_weekdays end,
      return_route_iso_weekdays=case when p ? 'return_route_iso_weekdays' then array(select distinct x::integer from jsonb_array_elements_text(p->'return_route_iso_weekdays') x order by x::integer) when p ? 'delivery_route_iso_weekday' then array[(p->>'delivery_route_iso_weekday')::integer] else return_route_iso_weekdays end,
      delivery_route_iso_weekday=coalesce((p->>'delivery_route_iso_weekday')::integer,delivery_route_iso_weekday),
      max_delivery_stops_per_sunday=coalesce((p->>'max_delivery_stops_per_sunday')::integer,max_delivery_stops_per_sunday),
      second_delivery_attempt_fee=coalesce((p->>'second_delivery_attempt_fee')::numeric,second_delivery_attempt_fee),
      max_pickup_stops_per_saturday=coalesce(max_stops,max_pickup_stops_per_saturday)
  where unit_id=u;
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
        where extract(isodow from gs)::integer = any((select pickup_route_iso_weekdays from public.unit_settings where unit_id=q.unit_id)::integer[]) and ((gs::date+time '08:00') at time zone zone)>now()+interval '48 hours'
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
      raise exception 'Choose an available Pickup date';
    end;

    select timezone,max_pickup_stops_per_saturday
    into zone,max_stops
    from public.unit_settings where unit_id=q.unit_id;

    if saturday is null
       or not (extract(isodow from saturday)::integer = any((select pickup_route_iso_weekdays from public.unit_settings where unit_id=q.unit_id)::integer[]))
       or ((saturday+time '08:00') at time zone zone)<=now()+interval '48 hours'
    then
      raise exception 'Choose an available Pickup date';
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
      raise exception 'That Pickup date is at capacity; choose another date';
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
create or replace function private.assign_route(p_job uuid, p_leg text, p_window_start timestamp with time zone, p_window_end timestamp with time zone, p_eta timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS uuid
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
      when extract(isodow from route_day)::integer = any((select pickup_route_iso_weekdays from public.unit_settings where unit_id=j.unit_id)::integer[])
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
create or replace function private.reconcile_pickups() returns void language plpgsql security definer set search_path='' as $$
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
   a:=public.route_availability(pr.job_id,'Pickup',(pr.pickup_window_start at time zone 'America/Denver')::date+1,private.ensure_job_status_link(pr.job_id));
   update public.pick_return_orders set pickup_window_start=(a->>'window_start')::timestamptz,pickup_window_end=(a->>'window_end')::timestamptz,pickup_eta=null,pickup_status='Not Scheduled',updated_at=now() where job_id=pr.job_id;
   perform private.route_notice(pr.job_id,'PICKUP_RESCHEDULED','pickup-cutoff:'||pr.job_id||':'||pr.pickup_window_start,'Your previous Pickup slot was released because the payment or scheduling cutoff passed. Choose an available slot for the next eligible Pickup day in your status page.');
  end if;
 end loop;
end $$;
create or replace function public.pickup_driver_action(p_stop uuid,p_action text) returns jsonb
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
   perform private.route_notice(j.id,'PICKUP_MISSED','pickup-missed:'||s.id,'We could not collect your items. Choose a free reschedule to the next available Pickup day or cancel in your status page. Your Pickup fee is nonrefundable in either case.');
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
create or replace function public.pickup_miss_choice(p_job uuid,p_token text,p_choice text) returns jsonb
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
  perform private.route_notice(j.id,'PICKUP_RESCHEDULED','pickup-retry:'||s.id,'Your Pickup has been rescheduled to the next available Pickup day at no additional charge. Your original Pickup fee remains nonrefundable.');
  return a;
 end if;
 raise exception 'Choose reschedule or cancel';
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
  perform private.route_notice(s.job_id,'ROUTE_INTERRUPTED','route-incident:'||i.id||':'||s.job_id,'We are sorry: our driver is unable to continue right now. ToolTag will confirm within 15 minutes whether a replacement can continue or your service moves to the next available '||case when r.leg='Pickup' then 'Pickup route day' else 'delivery route day' end||'. If a replacement is available, you may wait approximately one hour with a $5 refund, or reschedule. If no driver is available, a $10 refund is due; '||case when r.leg='Pickup' then 'Pickup will be rescheduled free of charge. You do not need to bring your pieces to the shop.' else 'you may collect your items at the shop for free.' end||' Refunds go back to your original payment method when its provider supports automatic refunds; otherwise ToolTag must issue the payment. Follow your status page.');
 end loop;
 return i.id;
end $$;
