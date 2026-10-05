
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
  accepted_total numeric(14,2):=0;
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
  settlement_amount numeric(14,2):=0;
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

  select * into pr
  from public.pick_return_orders
  where job_id=j.id;

  pickup_fee:=coalesce(pr.fee_amount,0);

  select
    coalesce(t.grand_total,0),
    coalesce(t.collected,0)
  into accepted_total,collected
  from public.job_commercial_totals t
  where t.id=j.id;

  service_amount:=greatest(accepted_total-pickup_fee,0);

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
  settlement_amount:=round(charge_amount+retained_fee,2);

  amount_due:=greatest(
    round(settlement_amount-(collected-total_refund),2),
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
    'accepted_total',accepted_total,
    'service_amount',service_amount,
    'service_charge_percent',charge_pct,
    'service_charge_amount',charge_amount,
    'pickup_fee_amount',pickup_fee,
    'pickup_fee_paid',pickup_paid,
    'pickup_fee_refundable',fee_refundable,
    'pickup_fee_refund_amount',fee_refund,
    'retained_pickup_fee',retained_fee,
    'settlement_amount',settlement_amount,
    'collected',collected,
    'service_paid',service_paid,
    'refund_eligible_amount',total_refund,
    'amount_due',amount_due,
    'agreement_version',agreement_version
  );
end $$;

create or replace function private.settle_cancelled_sales(
  p_job uuid,
  p_target numeric
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  remaining numeric(14,2):=round(greatest(coalesce(p_target,0),0),2);
  rec record;
  tx public.transactions;
  applied numeric(14,2);
begin
  perform set_config(
    'app.change_reason',
    'Customer cancellation settlement for Job '||p_job::text,
    true
  );

  for rec in
    select z.transaction_id,z.sort_order
    from (
      select s.transaction_id,0::integer as sort_order
      from public.sales s
      where s.job_id=p_job
      union all
      select x.sale_id,coalesce(x.sequence,1000)::integer
      from public.job_extensions x
      where x.job_id=p_job
        and x.sale_id is not null
        and x.accepted_at is not null
    ) z
    where z.transaction_id is not null
    order by z.sort_order,z.transaction_id
  loop
    select * into tx
    from public.transactions
    where id=rec.transaction_id
    for update;

    if tx.id is null or tx.status='Voided' then
      continue;
    end if;

    if remaining<=0 then
      update public.transactions
      set status='Voided'
      where id=tx.id;
      continue;
    end if;

    applied:=least(tx.amount,remaining);

    if applied<=0 then
      update public.transactions
      set status='Voided'
      where id=tx.id;
    elsif applied<tx.amount then
      update public.transactions
      set amount=applied,status='Active'
      where id=tx.id;
    end if;

    remaining:=round(remaining-applied,2);
  end loop;

  if remaining>0.01 then
    raise exception 'Cancellation settlement exceeds active Job sales';
  end if;
end $$;

create or replace function private.apply_pending_cancellation(p_job uuid)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare
  r public.cancellation_requests;
  pr public.pick_return_orders;
  settlement numeric(14,2);
begin
  select * into r
  from public.cancellation_requests
  where job_id=p_job and status='Requested'
  order by requested_at
  limit 1
  for update;

  if r.id is null then return false; end if;

  settlement:=coalesce(
    nullif(r.assessment->>'settlement_amount','')::numeric,
    r.service_charge_amount
      + case
          when coalesce((r.assessment->>'pickup_fee_paid')::numeric,0)>0
               and not r.pickup_fee_refundable
          then r.pickup_fee_amount
          else 0
        end
  );

  perform private.settle_cancelled_sales(p_job,settlement);

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
  set stage='Cancelled',
      cancelled_at=coalesce(cancelled_at,now()),
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

      update public.pick_return_stops s
      set status='Cancelled'
      from public.pick_return_routes rt
      where s.route_id=rt.id
        and s.job_id=p_job
        and rt.leg='Pickup'
        and s.status in ('Scheduled','En Route','Arrived');
    end if;
  end if;

  return true;
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
  if p_leg not in ('Pickup','Return') then raise exception 'Choose Pickup or Return'; end if;

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
end $$;

create or replace function public.advance_pick_return_stop(
  p_stop uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
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

  if p_action='en-route' then
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

create or replace function public.public_status_cancellation_finance(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  r public.cancellation_requests;
  pr public.payment_requests;
  zelle text;
  venmo text;
  remaining numeric(14,2):=0;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if j.id is null then raise exception 'Status link unavailable'; end if;

  select * into r
  from public.cancellation_requests
  where job_id=j.id and status='Cancelled'
  order by cancelled_at desc,created_at desc
  limit 1;

  if r.id is null then return null; end if;

  select coalesce(t.balance_due,0)
  into remaining
  from public.job_commercial_totals t
  where t.id=j.id;

  select * into pr
  from public.payment_requests
  where job_id=j.id
    and purpose='Cancellation Balance'
    and status in ('Pending Verification','Confirmed')
  order by submitted_at desc
  limit 1;

  select zelle_email,venmo_handle
  into zelle,venmo
  from public.unit_settings
  where unit_id=j.unit_id;

  return jsonb_build_object(
    'job_code',j.code,
    'request_id',r.id,
    'amount_due',r.amount_due,
    'balance_remaining',remaining,
    'refund_eligible_amount',r.refund_eligible_amount,
    'refund_status',r.refund_status,
    'payment',case
      when pr.id is null then null
      else jsonb_build_object(
        'id',pr.id,
        'status',pr.status,
        'method',pr.method,
        'amount',pr.amount,
        'submitted_at',pr.submitted_at,
        'confirmed_at',pr.confirmed_at
      )
    end,
    'zelle_email',zelle,
    'venmo_handle',venmo
  );
end $$;

revoke all on function public.public_status_cancellation_finance(text) from public;
grant execute on function public.public_status_cancellation_finance(text) to anon,authenticated;

create or replace function public.public_status_submit_cancellation_payment(
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
  j public.jobs;
  c public.cancellation_requests;
  existing public.payment_requests;
  rid uuid;
  due numeric(14,2);
  zelle text;
  venmo text;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
  for update of x;

  if j.id is null then raise exception 'Status link unavailable'; end if;

  select * into c
  from public.cancellation_requests
  where job_id=j.id and status='Cancelled'
  order by cancelled_at desc,created_at desc
  limit 1
  for update;

  if c.id is null or c.amount_due<=0 then
    raise exception 'No cancellation balance is due';
  end if;

  select balance_due into due
  from public.job_commercial_totals
  where id=j.id;

  if coalesce(due,0)<=0 then
    return jsonb_build_object(
      'status','Confirmed',
      'amount',c.amount_due,
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
      and purpose='Cancellation Balance'
      and status='Pending Verification'
  ) then
    raise exception 'Cancellation balance payment is already awaiting verification';
  end if;

  if p_method not in ('Cash','Zelle','Venmo') then
    raise exception 'Choose Cash, Zelle or Venmo';
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

  if p_method in ('Zelle','Venmo') then
    if nullif(trim(p_proof_path),'') is null then
      raise exception 'Upload payment proof for Zelle or Venmo';
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
  end if;

  insert into public.payment_requests(
    request_key,unit_id,job_id,method,amount,proof_path,purpose
  )
  values(
    p_request,j.unit_id,j.id,p_method,least(c.amount_due,due),
    p_proof_path,'Cancellation Balance'
  )
  returning id into rid;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,
    'CANCELLATION_PAYMENT_SUBMITTED',
    rid,
    'payments@tooltag.martinlab.studio',
    'cancellation-payment:'||rid,
    jsonb_build_object(
      'template','notification',
      'subject','Cancellation balance payment submitted — '||j.code||' — '||p_method,
      'text',
        'Job: '||j.code||
        E'\nAmount: $'||to_char(least(c.amount_due,due),'FM999999990.00')||
        E'\nPayment method: '||p_method||
        E'\nStatus: Pending Verification',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'id',rid,
    'status','Pending Verification',
    'amount',least(c.amount_due,due),
    'job_code',j.code
  );
end $$;

revoke all on function public.public_status_submit_cancellation_payment(text,uuid,text,text) from public;
grant execute on function public.public_status_submit_cancellation_payment(text,uuid,text,text) to anon,authenticated;

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
  status_token text;
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
  status_token:=private.ensure_job_status_link(j.id);

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
          then ' Outstanding amount due: $'||to_char(r.amount_due,'FM999999990.00')||
               '. Use your Job Status link to submit payment.'
          else ''
        end,
      'action_path','/status/'||status_token,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'request_id',r.id,'cancelled',true,'refund_status',r.refund_status,
    'assessment',r.assessment,
    'refund_eligible_amount',r.refund_eligible_amount,'amount_due',r.amount_due,
    'status_path','/status/'||status_token
  );
end $$;

create or replace function public.public_status_confirm_cancellation(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  rid uuid;
  r public.cancellation_requests;
  status_token text;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
  for update of x;

  if j.id is null then raise exception 'Status link unavailable'; end if;
  if j.status in ('Completed','Cancelled') then
    raise exception 'This Job can no longer be cancelled';
  end if;

  rid:=private.insert_cancellation_request(j.id);
  perform private.apply_pending_cancellation(j.id);
  select * into r from public.cancellation_requests where id=rid;
  status_token:=private.ensure_job_status_link(j.id);

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
          then ' Outstanding amount due: $'||to_char(r.amount_due,'FM999999990.00')||
               '. Use your Job Status link to submit payment.'
          else ''
        end,
      'action_path','/status/'||status_token,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'request_id',r.id,'cancelled',true,'refund_status',r.refund_status,
    'assessment',r.assessment,
    'refund_eligible_amount',r.refund_eligible_amount,'amount_due',r.amount_due,
    'status_path','/status/'||status_token
  );
end $$;

create or replace function public.confirm_payment_request(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
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
end $$;
