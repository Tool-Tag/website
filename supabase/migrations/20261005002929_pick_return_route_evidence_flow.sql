
create or replace function private.begin_delivery_acceptance(p_job uuid)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  token text;
begin
  select * into j from public.jobs where id=p_job for update;
  if j.id is null then raise exception 'Job not found'; end if;

  if j.status='Delivered – Pending Customer Acceptance' then
    select l.token into token from private.job_mail_links l where l.job_id=j.id;
    return token;
  end if;

  if j.status='Cancelled' then
    raise exception 'Cancelled Job cannot enter delivery acceptance';
  end if;

  token:=gen_random_uuid()::text||gen_random_uuid()::text;

  insert into private.delivery_scopes(job_id,snapshot)
  values(j.id,private.job_portal_snapshot(j.id))
  on conflict(job_id) do update set snapshot=excluded.snapshot;

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

create or replace function private.activate_next_route_stop(
  p_route uuid,
  p_after_sequence integer
)
returns void
language plpgsql
security definer
set search_path=''
as $$
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
        and s.status in ('Scheduled','En Route','Arrived')
    ) then
      update public.pick_return_routes
      set status='Completed',completed_at=coalesce(completed_at,now())
      where id=r.id;
    end if;
    return;
  end if;

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

  if private.apply_pending_cancellation(j.id) then
    return jsonb_build_object(
      'blocked',true,'reason','Cancellation request detected','job_id',j.id
    );
  end if;

  if j.status='Cancelled' then raise exception 'This Job is cancelled'; end if;

  select * into pr from public.pick_return_orders where job_id=j.id for update;

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
    select l.token into status_token from private.job_status_links l where l.job_id=j.id;
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
            else 'ToolTag is on the way with your completed items.'
          end||eta_text,
        'action_path',case when status_token is null then null else '/status/'||status_token end,
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

    completion_token:=private.begin_delivery_acceptance(j.id);
    perform private.activate_next_route_stop(r.id,s.sequence);

  else
    raise exception 'Invalid route action';
  end if;

  return jsonb_build_object(
    'blocked',false,'job_id',j.id,'stop_id',s.id,
    'leg',r.leg,'action',p_action,'completion_token',completion_token
  );
end $$;

revoke all on function public.advance_pick_return_stop(uuid,text) from public,anon;
grant execute on function public.advance_pick_return_stop(uuid,text) to authenticated;

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
  stop_id uuid:=nullif(p->>'pick_return_stop_id','')::uuid;
  item public.job_items;
  stop public.pick_return_stops;
  route_leg text;
begin
  perform private.require_admin(u);

  if nullif(trim(p->>'drive_file_id'),'') is null then
    raise exception 'A real Google Drive file ID is required; uploads are not connected yet';
  end if;

  if p->>'drive_file_id' !~ '^[a-zA-Z0-9_-]{10,}$' then
    raise exception 'Invalid Drive file ID';
  end if;

  if item_id is not null then
    select * into item from public.job_items where id=item_id;
    if item.id is null
       or item.unit_id<>u
       or (jid is not null and item.job_id<>jid)
    then
      raise exception 'Job item does not belong to this Job';
    end if;
    jid:=item.job_id;
  end if;

  if stop_id is not null then
    select * into stop from public.pick_return_stops where id=stop_id;
    if stop.id is null
       or stop.unit_id<>u
       or (jid is not null and stop.job_id<>jid)
    then
      raise exception 'Route stop does not belong to this Job';
    end if;
    jid:=stop.job_id;
    select r.leg into route_leg
    from public.pick_return_routes r
    where r.id=stop.route_id;
  end if;

  if p->>'type'='Finished Evidence' then
    if item_id is null then
      raise exception 'Finished Evidence must be attached to a Job item';
    end if;
    if exists(
      select 1 from public.cancellation_requests
      where job_id=jid and status='Requested'
    ) then
      raise exception 'Cancellation request detected; this Job cannot continue';
    end if;
  end if;

  if p->>'type'='Receiving Evidence'
     and stop_id is not null
     and route_leg<>'Pickup'
  then
    raise exception 'Receiving Evidence must belong to a Pickup stop';
  end if;

  if p->>'type'='Delivery Evidence' then
    if stop_id is null or route_leg<>'Return' then
      raise exception 'Delivery Evidence must belong to a Return stop';
    end if;
  end if;

  insert into public.documents(
    unit_id,type,drive_file_id,file_name,customer_id,job_id,job_item_id,
    pick_return_stop_id,transaction_id,status,uploaded_by
  )
  values(
    u,p->>'type',p->>'drive_file_id',p->>'file_name',
    nullif(p->>'customer_id','')::uuid,
    jid,item_id,stop_id,
    nullif(p->>'transaction_id','')::uuid,
    'Available',auth.uid()
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
