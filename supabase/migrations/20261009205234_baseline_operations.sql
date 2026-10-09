--
-- PostgreSQL database dump
--


-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11 (Postgres.app)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: activate_next_route_stop(uuid, integer); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.activate_next_route_stop(p_route uuid, p_after_sequence integer) RETURNS void
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


ALTER FUNCTION private.activate_next_route_stop(p_route uuid, p_after_sequence integer) OWNER TO postgres;

--
-- Name: apply_pending_cancellation(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.apply_pending_cancellation(p_job uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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

  update public.payment_requests
  set status='Cancelled'
  where job_id=p_job
    and status='Pending Verification';

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
            when fee_status in ('Required','Pending Verification') then 'Cancelled'
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


ALTER FUNCTION private.apply_pending_cancellation(p_job uuid) OWNER TO postgres;

--
-- Name: begin_delivery_acceptance(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.begin_delivery_acceptance(p_job uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION private.begin_delivery_acceptance(p_job uuid) OWNER TO postgres;

--
-- Name: cancellation_assessment(uuid, timestamp with time zone); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.cancellation_assessment(p_job uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION private.cancellation_assessment(p_job uuid, p_at timestamp with time zone) OWNER TO postgres;

--
-- Name: create_get_tagged_draft(uuid, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.create_get_tagged_draft(p_receipt uuid, p_customer uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  y integer;
  seq integer;
  fid uuid;
  qid uuid;
  r private.get_tagged_receipts;
  policy uuid;
  requested_version integer;
begin
  select * into r
  from private.get_tagged_receipts
  where id=p_receipt
  for update;

  if r.quote_id is not null then
    return r.quote_id;
  end if;

  if not exists(
    select 1 from public.customers
    where id=p_customer and unit_id=u
  ) then
    raise exception 'Customer not found';
  end if;

  if private.get_tagged_is_pickup(r.details) then
    requested_version:=nullif(
      r.details->'service'->>'agreement_version',''
    )::integer;

    if requested_version is null then
      raise exception 'Pickup Agreement version is missing';
    end if;

    select p.id into policy
    from public.policies p
    where p.unit_id=u
      and p.version=requested_version
      and p.published_at is not null
    limit 1;

    if policy is null then
      raise exception 'Pickup Agreement version is unavailable';
    end if;
  end if;

  y:=extract(year from now() at time zone (
    select timezone from public.unit_settings where unit_id=u
  ));

  insert into private.annual_sequences(year,value)
  values(y,1)
  on conflict(year) do update
    set value=private.annual_sequences.value+1
  returning value into seq;

  insert into public.commercial_flows(unit_id,customer_id,year,sequence)
  values(u,p_customer,y,seq)
  returning id into fid;

  insert into public.quotes(
    unit_id,flow_id,code,notes,source,intake_details,policy_id
  )
  values(
    u,
    fid,
    'TT-Q-'||y||'-'||lpad(seq::text,5,'0'),
    r.details->>'notes',
    'public_get_tagged',
    r.details-'quote_items',
    policy
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


ALTER FUNCTION private.create_get_tagged_draft(p_receipt uuid, p_customer uuid) OWNER TO postgres;

--
-- Name: create_job_status_portal(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.create_job_status_portal() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  token_value text;
  recipient_value text;
  job_code text;
begin
  token_value:=private.ensure_job_status_link(new.job_id);

  select j.code into job_code
  from public.jobs j
  where j.id=new.job_id;

  select coalesce(d.recipient,new.accepted_email)
  into recipient_value
  from public.quotes q
  left join private.quote_delivery d on d.quote_id=q.id
  where q.id=new.quote_id;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    new.unit_id,
    'JOB_STATUS_LINK',
    new.job_id,
    recipient_value,
    'job-status:'||new.job_id,
    jsonb_build_object(
      'template','notification',
      'subject','Track your ToolTag Job — '||job_code,
      'text','Your ToolTag Job is now active. Use this private link anytime to check its progress.',
      'action_path','/status/'||token_value,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $$;


ALTER FUNCTION private.create_job_status_portal() OWNER TO postgres;

--
-- Name: document_folder_kind(text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.document_folder_kind(p_type text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case
    when p_type in ('Accepted Quote','Accepted Agreement','Quote','Agreement','Job Extension')
      then 'commercial'
    when p_type='Receiving Evidence'
      then 'receiving'
    when p_type in ('Production Evidence','Finished Evidence','Completed Evidence')
      then 'production'
    when p_type in ('Delivery Evidence','Delivery Acknowledgment')
      then 'delivery'
    when p_type in ('Receipt','Payment Receipt','Final Receipt','Refund Receipt')
      then 'payments'
    when p_type in (
      'Issue / Review','Issue / Review Evidence','Cancellation Evidence',
      'Refund Review Evidence','Customer Claim'
    )
      then 'issue_review'
    else 'other'
  end
$$;


ALTER FUNCTION private.document_folder_kind(p_type text) OWNER TO postgres;

--
-- Name: document_metadata_defaults(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.document_metadata_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  cid uuid;
begin
  new.original_file_name:=coalesce(new.original_file_name,new.file_name);
  new.folder_kind:=coalesce(new.folder_kind,private.document_folder_kind(new.type));

  if new.mime_type is null and new.content_snapshot is not null then
    new.mime_type:='application/json';
  end if;

  if new.sha256 is null and new.content_snapshot is not null then
    new.sha256:=encode(
      sha256(convert_to(new.content_snapshot::text,'UTF8')),
      'hex'
    );
  end if;

  if new.drive_file_id is not null
     and new.storage_provider='pending_drive'
  then
    new.storage_provider:='legacy_drive';
    new.storage_status:='Uploaded';
    new.uploaded_at:=coalesce(new.uploaded_at,new.created_at,now());
  end if;

  if new.type in (
    'Accepted Quote','Accepted Agreement','Payment Receipt',
    'Final Receipt','Refund Receipt','Delivery Acknowledgment'
  ) and new.visibility='internal'
  then
    new.visibility:='customer';
  end if;

  if new.job_id is null
     and new.content_snapshot is not null
     and nullif(new.content_snapshot->>'job_id','') is not null
  then
    new.job_id:=(new.content_snapshot->>'job_id')::uuid;
  end if;

  if new.job_id is not null then
    select x.* into j
    from public.jobs x
    where x.id=new.job_id;

    if j.id is not null then
      new.quote_id:=coalesce(new.quote_id,j.quote_id);

      select f.customer_id into cid
      from public.commercial_flows f
      where f.id=j.flow_id;

      new.customer_id:=coalesce(new.customer_id,cid);
    end if;
  end if;

  if new.logical_key is null then
    if new.type='Payment Receipt' and new.transaction_id is not null then
      new.logical_key:='payment-receipt:'||new.transaction_id::text;
    elsif new.type='Refund Receipt'
       and new.content_snapshot is not null
       and nullif(new.content_snapshot->>'request_id','') is not null
    then
      new.logical_key:='refund-receipt:'||(new.content_snapshot->>'request_id');
    end if;
  end if;

  return new;
end
$$;


ALTER FUNCTION private.document_metadata_defaults() OWNER TO postgres;

--
-- Name: ensure_job_status_link(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.ensure_job_status_link(p_job uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  token_value text;
begin
  select token into token_value
  from private.job_status_links
  where job_id=p_job;

  if token_value is null then
    token_value:=gen_random_uuid()::text||gen_random_uuid()::text;
    insert into private.job_status_links(job_id,token,token_hash)
    values(
      p_job,
      token_value,
      encode(sha256(convert_to(token_value,'UTF8')),'hex')
    )
    on conflict(job_id) do update set job_id=excluded.job_id
    returning token into token_value;
  end if;

  return token_value;
end $$;


ALTER FUNCTION private.ensure_job_status_link(p_job uuid) OWNER TO postgres;

--
-- Name: ensure_pickup_fee_item(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.ensure_pickup_fee_item(p_quote uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION private.ensure_pickup_fee_item(p_quote uuid) OWNER TO postgres;

--
-- Name: freeze_acceptance(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.freeze_acceptance() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare q public.quotes; snap jsonb;
begin
 select * into q from public.quotes where id=NEW.quote_id;
 snap:=coalesce(q.review_snapshot,private.quote_snapshot(q.id));
 NEW.commercial_snapshot:=snap||jsonb_build_object('accepted_at',NEW.accepted_at,'acceptance_type','Quote + Agreement',
 'accepted_name',NEW.accepted_name,'accepted_email',NEW.accepted_email,'accepted_phone',NEW.accepted_phone);
 NEW.snapshot_hash:=encode(sha256(convert_to(NEW.commercial_snapshot::text,'UTF8')),'hex');
 return NEW;
end $$;


ALTER FUNCTION private.freeze_acceptance() OWNER TO postgres;

--
-- Name: get_tagged_is_pickup(jsonb); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.get_tagged_is_pickup(p_details jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select lower(trim(coalesce(p_details->'service'->>'method',''))) in (
    'pickup','pick up','pick-up','pickup & return','pick up & return','pick-up & return'
  );
$$;


ALTER FUNCTION private.get_tagged_is_pickup(p_details jsonb) OWNER TO postgres;

--
-- Name: get_tagged_phone(text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.get_tagged_phone(p text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
 select case when length(n)=11 and left(n,1)='1' then substr(n,2) else n end from (select regexp_replace(coalesce(p,''),'[^0-9]','','g') n)s;
$$;


ALTER FUNCTION private.get_tagged_phone(p text) OWNER TO postgres;

--
-- Name: get_tagged_scope(jsonb); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.get_tagged_scope(p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare i jsonb; m jsonb; normalized jsonb:='[]'; marks jsonb; result jsonb:='[]'; priced jsonb; pos integer:=0;
begin
 for i in select value from jsonb_array_elements(p_items) loop
  marks:='[]';
  for m in select value from jsonb_array_elements(i->'marks') loop
   if m->>'type'='Image / Logo' and coalesce(m->>'url','')='' then
    m:=m||jsonb_build_object('type','Text','text',m->>'description');
   end if;
   marks:=marks||jsonb_build_array(m);
  end loop;
  normalized:=normalized||jsonb_build_array(i||jsonb_build_object('marks',marks,'unit_price',0));
 end loop;
 priced:=private.priced_scope(normalized);
 for i in select value from jsonb_array_elements(priced) loop
  if i->>'engraving_type'<>'Fee' then
   i:=i||jsonb_build_object('marks',p_items->pos->'marks','engraving_type',p_items->pos->>'engraving_type');pos:=pos+1;
  elsif coalesce((i->>'additional_engraving_fee')::boolean,false) then
   i:=i||jsonb_build_object('article','Additional engravings','notes','First engraving included; $5 for each additional engraving per piece.');
  elsif coalesce((i->>'paint_fee')::boolean,false) then
   i:=i||jsonb_build_object('article','Paint fill','notes','$2 per painted physical piece, separate from additional engravings.');
  elsif coalesce((i->>'adaptation_fee')::boolean,false) then
   i:=i||jsonb_build_object('article','Falcon image / logo preparation','notes','$3 per distinct referenced design.');
  end if;
  result:=result||jsonb_build_array(i);
 end loop;return result;
end $_$;


ALTER FUNCTION private.get_tagged_scope(p_items jsonb) OWNER TO postgres;

--
-- Name: guard_get_tagged_review(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.guard_get_tagged_review() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if old.source='public_get_tagged' and old.intake_reviewed_at is null and new.status not in ('Draft','Declined','Expired') then raise exception 'Review and price this Get Tagged request before sending'; end if;
 return new;
end $$;


ALTER FUNCTION private.guard_get_tagged_review() OWNER TO postgres;

--
-- Name: insert_cancellation_request(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.insert_cancellation_request(p_job uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION private.insert_cancellation_request(p_job uuid) OWNER TO postgres;

--
-- Name: job_item_metadata_defaults(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.job_item_metadata_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if nullif(trim(new.display_label),'') is null then
    new.display_label:=
      'P'||lpad(new.sequence::text,3,'0')||' · '||new.article;
  end if;

  if new.preparation_started_at is null and new.sequence=1 then
    new.preparation_started_at:=now();
  end if;

  if new.completed_at is null and new.finished_at is not null then
    new.completed_at:=new.finished_at;
  end if;

  return new;
end
$$;


ALTER FUNCTION private.job_item_metadata_defaults() OWNER TO postgres;

--
-- Name: job_item_progress(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.job_item_progress(p_job uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select jsonb_build_object(
    'total',count(*),
    'started',count(*) filter (
      where stage in ('Engraving','Finished Evidence','Finished')
    ),
    'finished',count(*) filter (where stage='Finished'),
    'cancelled',count(*) filter (where stage='Cancelled'),
    'current_item_id',(
      select x.id
      from public.job_items x
      where x.job_id=p_job
        and x.stage not in ('Finished','Cancelled')
      order by x.sequence
      limit 1
    ),
    'current_sequence',(
      select x.sequence
      from public.job_items x
      where x.job_id=p_job
        and x.stage not in ('Finished','Cancelled')
      order by x.sequence
      limit 1
    )
  )
  from public.job_items
  where job_id=p_job;
$$;


ALTER FUNCTION private.job_item_progress(p_job uuid) OWNER TO postgres;

--
-- Name: job_portal_snapshot(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.job_portal_snapshot(p_job uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION private.job_portal_snapshot(p_job uuid) OWNER TO postgres;

--
-- Name: mark_get_tagged_converted(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.mark_get_tagged_converted() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.quote_id is not null
     and old.quote_id is null
     and new.request_status='Pending'
  then
    new.request_status:='Converted';
  end if;
  return new;
end $$;


ALTER FUNCTION private.mark_get_tagged_converted() OWNER TO postgres;

--
-- Name: mark_work_notified(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.mark_work_notified() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if NEW.status='Sent' and OLD.status<>'Sent' and NEW.payload->>'template'='work_review' then
 update private.job_review_links set notified_at=NEW.sent_at where id=(NEW.payload->>'review_id')::uuid;
 end if; return NEW;
end $$;


ALTER FUNCTION private.mark_work_notified() OWNER TO postgres;

--
-- Name: notify_get_tagged_request(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.notify_get_tagged_request() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare status_token text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
begin
 insert into private.request_status_links(request_id,token,token_hash) values(new.id,status_token,encode(sha256(convert_to(status_token,'UTF8')),'hex'));
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
 values('10000000-0000-0000-0000-000000000002','GET_TAGGED_REQUEST',new.id,'get-tagged-request:'||new.id,
 jsonb_build_object('template','get_tagged_request','live_eligible',true,'reference',new.reference,'contact',new.details->'contact','service',new.details->'service','items',new.details->'items','notes',new.details->>'notes'))
 on conflict(dedupe_key) do nothing;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values('10000000-0000-0000-0000-000000000002','GET_TAGGED_RECEIVED',new.id,new.details->'contact'->>'email','get-tagged-received:'||new.id,
 jsonb_build_object('template','get_tagged_received','live_eligible',true,'reference',new.reference,'name',new.details->'contact'->>'name')) on conflict(dedupe_key) do nothing;
 return new;
end $$;


ALTER FUNCTION private.notify_get_tagged_request() OWNER TO postgres;

--
-- Name: owner_integrity(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.owner_integrity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare typ text;
begin
 select type into typ from public.transactions where id=NEW.transaction_id;
 if (typ='OWNER_INJECTION' and NEW.subtype<>'Injection') or (typ='OWNER_DRAW' and NEW.subtype not in ('Personal Draw','Reimbursement')) then raise exception 'Invalid owner transaction subtype'; end if;
 return NEW;
end $$;


ALTER FUNCTION private.owner_integrity() OWNER TO postgres;

--
-- Name: protect_destination_close(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.protect_destination_close() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t public.transactions;
begin
 select * into t from public.transactions where id=NEW.transaction_id;
 if exists(select 1 from public.monthly_closes where unit_id=NEW.destination_unit_id and month=date_trunc('month',t.transaction_date)::date and status<>'Superseded') then
 if coalesce(current_setting('app.change_reason',true),'')='' then raise exception 'Destination period closed: reason required'; end if;
 update public.monthly_closes set status='Reclose Required' where unit_id=NEW.destination_unit_id and month=date_trunc('month',t.transaction_date)::date and status<>'Superseded';
 end if;
 return NEW;
end $$;


ALTER FUNCTION private.protect_destination_close() OWNER TO postgres;

--
-- Name: send_review(uuid, boolean); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.send_review(p_id uuid, p_regenerate boolean) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare q public.quotes; policy uuid; token text; snap jsonb; zone text;
begin
 select * into q from public.quotes where id=p_id for update;
 perform private.require_admin(q.unit_id);
 if q.status not in ('Draft','Sent','Viewed') then raise exception 'Create a revision for accepted or expired quotes'; end if;
 if q.expires_at<=now() then raise exception 'Quote expired; create a revision'; end if;
 select id into policy from public.policies where unit_id=q.unit_id and published_at is not null order by version desc limit 1;
 if policy is null then raise exception 'Publish the approved Agreement in Settings before sending a quote'; end if;
 if not exists(select 1 from public.quote_items where quote_id=p_id) or
 (select sum(quantity*unit_price) from public.quote_items where quote_id=p_id)<=0 then raise exception 'Add items with a positive quote total'; end if;
 if not exists(select 1 from public.commercial_flows f join public.customers c on c.id=f.customer_id
 where f.id=q.flow_id and (c.email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or c.company_email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')) then raise exception 'Customer needs a usable email address'; end if;
 select timezone into zone from public.unit_settings where unit_id=q.unit_id;
 update public.quotes set status=case when status='Draft' then 'Sent' else status end,
 policy_id=coalesce(policy_id,policy),sent_at=coalesce(sent_at,now()),
 expires_at=coalesce(expires_at,((now() at time zone zone)+interval '7 days') at time zone zone)
 where id=p_id returning * into q;
 select coalesce(q.review_snapshot,private.quote_snapshot(p_id)) into snap;
 update public.quotes set review_snapshot=snap where id=p_id and review_snapshot is null;
 select d.token into token from private.quote_delivery d where d.quote_id=p_id;
 if token is null or p_regenerate then
 token:=gen_random_uuid()::text||gen_random_uuid()::text;
 if p_regenerate then delete from private.public_links where quote_id=p_id; end if;
 insert into private.public_links values(encode(sha256(convert_to(token,'UTF8')),'hex'),q.unit_id,q.id,null,q.expires_at);
 insert into private.quote_delivery(quote_id,token) values(p_id,token) on conflict(quote_id) do update set token=excluded.token,created_at=now();
 end if;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload)
 values(q.unit_id,'Quote Sent',q.id,'quote:'||q.id,snap->>'customer_email',jsonb_build_object('template','quote','snapshot',snap,'delivery','Pending Integration'))
 on conflict(dedupe_key) do nothing;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,due_at,recipient,payload)
 values(q.unit_id,'Quote expiration reminder',q.id,'quote-reminder:'||q.id,
 ((q.expires_at at time zone zone)-interval '2 days') at time zone zone,snap->>'customer_email',jsonb_build_object('snapshot',snap,'due',false)) on conflict do nothing;
 if p_regenerate then
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value)
 values(q.unit_id,auth.uid(),'quotes',q.id,'link_regenerated',to_jsonb(now()));
 end if;
 return token;
end $_$;


ALTER FUNCTION private.send_review(p_id uuid, p_regenerate boolean) OWNER TO postgres;

--
-- Name: settle_cancelled_sales(uuid, numeric); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.settle_cancelled_sales(p_job uuid, p_target numeric) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION private.settle_cancelled_sales(p_job uuid, p_target numeric) OWNER TO postgres;

--
-- Name: store_get_tagged_items(uuid, jsonb); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.store_get_tagged_items(p_quote uuid, p_scope jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare i jsonb;
begin
 for i in select value from jsonb_array_elements(p_scope) loop
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,engraving_text,width_mm,height_mm,paint_fill,colors,unit_price,notes,sort_order,marks,paint_details,adaptation_fee,paint_fee,additional_engraving_fee,pricing)
 values('10000000-0000-0000-0000-000000000002',p_quote,i->>'article',(i->>'quantity')::integer,i->>'engraving_type',i->>'engraving_text',nullif(i->>'width_mm','')::numeric,nullif(i->>'height_mm','')::numeric,false,0,(i->>'unit_price')::numeric,i->>'notes',(i->>'sort_order')::integer,coalesce(i->'marks','[]'),coalesce(i->'paint_details','{}'),coalesce((i->>'adaptation_fee')::boolean,false),coalesce((i->>'paint_fee')::boolean,false),coalesce((i->>'additional_engraving_fee')::boolean,false),coalesce(i->'pricing','{}'));
 end loop;
end $$;


ALTER FUNCTION private.store_get_tagged_items(p_quote uuid, p_scope jsonb) OWNER TO postgres;

--
-- Name: sync_job_items(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.sync_job_items(p_job uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
begin
  select * into j
  from public.jobs
  where id=p_job
  for update;

  if j.id is null then
    return;
  end if;

  if exists(
    select 1
    from public.job_items x
    where x.job_id=j.id
      and x.quote_id<>j.quote_id
  ) then
    if exists(
      select 1
      from public.job_items x
      where x.job_id=j.id
        and x.stage<>'Preparation'
    ) then
      raise exception 'Cannot replace Job items after production has started';
    end if;
    delete from public.job_items where job_id=j.id;
  end if;

  if exists(select 1 from public.job_items where job_id=j.id) then
    return;
  end if;

  insert into public.job_items(
    unit_id,job_id,quote_id,quote_item_id,unit_index,sequence,
    article,scope_snapshot,stage,engraving_started_at,
    evidence_completed_at,finished_at
  )
  select
    j.unit_id,
    j.id,
    j.quote_id,
    e.id,
    e.unit_index,
    e.sequence,
    e.article,
    e.scope_snapshot,
    case
      when j.work_stage in (
        'Awaiting Delivery Acceptance','Issue Review',
        'Payment','Payment Verification','Closed'
      ) then 'Finished'
      when j.work_stage in ('Final Evidence','Final Details') and e.sequence=1
        then 'Engraving'
      else 'Preparation'
    end,
    case
      when j.work_stage in ('Final Evidence','Final Details') and e.sequence=1
        then j.updated_at
      when j.work_stage in (
        'Awaiting Delivery Acceptance','Issue Review',
        'Payment','Payment Verification','Closed'
      ) then j.updated_at
      else null
    end,
    case
      when j.work_stage in (
        'Awaiting Delivery Acceptance','Issue Review',
        'Payment','Payment Verification','Closed'
      ) then j.updated_at
      else null
    end,
    case
      when j.work_stage in (
        'Awaiting Delivery Acceptance','Issue Review',
        'Payment','Payment Verification','Closed'
      ) then coalesce(j.delivered_at,j.updated_at)
      else null
    end
  from (
    select
      qi.id,
      qi.article,
      gs as unit_index,
      row_number() over(order by qi.sort_order,qi.id,gs)::integer as sequence,
      to_jsonb(qi)-'unit_id' as scope_snapshot
    from public.quote_items qi
    cross join lateral generate_series(1,qi.quantity) gs
    where qi.quote_id=j.quote_id
      and qi.engraving_type<>'Fee'
  ) e;
end $$;


ALTER FUNCTION private.sync_job_items(p_job uuid) OWNER TO postgres;

--
-- Name: sync_job_items_trigger(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.sync_job_items_trigger() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  perform private.sync_job_items(new.id);
  return new;
end $$;


ALTER FUNCTION private.sync_job_items_trigger() OWNER TO postgres;

--
-- Name: transaction_guard(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.transaction_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare c public.categories; d date;
begin
 perform 1 from public.business_units where id=NEW.unit_id for update;
 if TG_OP='UPDATE' then
 if NEW.id<>OLD.id or NEW.unit_id<>OLD.unit_id or NEW.type<>OLD.type or NEW.created_at<>OLD.created_at then raise exception 'Identity, type and creation time are immutable'; end if;
 NEW.updated_at:=now();
 end if;
 if NEW.category_id is not null then
 select * into c from public.categories where id=NEW.category_id;
 if c.unit_id is not null and c.unit_id<>NEW.unit_id then raise exception 'Category belongs to another unit'; end if;
 end if;
 for d in select distinct x from unnest(array[NEW.transaction_date,case when TG_OP='UPDATE' then OLD.transaction_date else NEW.transaction_date end]) x loop
 if exists(select 1 from public.monthly_closes where unit_id=NEW.unit_id and month=date_trunc('month',d)::date and status<>'Superseded') then
 if coalesce(current_setting('app.change_reason',true),'')='' then raise exception 'Closed period: an admin reason is required'; end if;
 update public.monthly_closes set status='Reclose Required' where unit_id=NEW.unit_id and month=date_trunc('month',d)::date and status<>'Superseded';
 end if;
 end loop;
 return NEW;
end $$;


ALTER FUNCTION private.transaction_guard() OWNER TO postgres;

--
-- Name: transfer_correction_close(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.transfer_correction_close() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare dest uuid;
begin
 select destination_unit_id into dest from public.inter_unit_transfers where transaction_id=NEW.id;
 if dest is not null then
 if exists(select 1 from public.monthly_closes where unit_id=dest and month in (date_trunc('month',NEW.transaction_date)::date,date_trunc('month',OLD.transaction_date)::date) and status<>'Superseded') then
 if coalesce(current_setting('app.change_reason',true),'')='' then raise exception 'Destination period closed: reason required'; end if;
 update public.monthly_closes set status='Reclose Required' where unit_id=dest and month in (date_trunc('month',NEW.transaction_date)::date,date_trunc('month',OLD.transaction_date)::date) and status<>'Superseded';
 end if; end if;
 return NEW;
end $$;


ALTER FUNCTION private.transfer_correction_close() OWNER TO postgres;

--
-- Name: accept_review(text, boolean, boolean, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.accept_review(p_token text, p_quote_confirmed boolean, p_agreement_confirmed boolean, p_name text, p_email text, p_phone text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  jid uuid;
  q public.quotes;
  f public.commercial_flows;
  c public.customers;
  destination text;
  accepted_name text;
  accepted_email text;
  accepted_phone text;
begin
  if p_quote_confirmed is distinct from true or p_agreement_confirmed is distinct from true then
    raise exception 'Both quote and Agreement acknowledgments are required';
  end if;

  select x.* into q
  from public.quotes x
  join private.public_links l on l.quote_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and l.expires_at>now()
  for update of x;

  if q.id is null or q.expires_at<=now() or q.status not in ('Sent','Viewed','Agreement Pending','Accepted') then
    raise exception 'Quote is unavailable or expired';
  end if;

  select * into f from public.commercial_flows where id=q.flow_id;
  select * into c from public.customers where id=f.customer_id and unit_id=q.unit_id;
  select d.recipient into destination from private.quote_delivery d where d.quote_id=q.id;

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
    when lower(coalesce(accepted_email,''))=lower(coalesce(q.review_snapshot->'company'->>'email',c.company_email,''))
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
     or accepted_phone is null then
    raise exception 'Customer contact information is incomplete; update the customer before accepting';
  end if;

  perform public.accept_quote(p_token);
  jid:=public.accept_agreement(p_token,accepted_name,accepted_email,accepted_phone);

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

  insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
  select q.unit_id,'Drive commercial archive pending',q.id,'drive-commercial:'||q.id,
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

  if q.status<>'Accepted' then
    perform private.freeze_accepted_document(q.id);
  end if;

  return jid;
end $_$;


ALTER FUNCTION public.accept_review(p_token text, p_quote_confirmed boolean, p_agreement_confirmed boolean, p_name text, p_email text, p_phone text) OWNER TO postgres;

--
-- Name: add_document(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.add_document(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
end $_$;


ALTER FUNCTION public.add_document(p jsonb) OWNER TO postgres;

--
-- Name: advance_job(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.advance_job(p_id uuid, p_action text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  token text:=gen_random_uuid()::text||gen_random_uuid()::text;
begin
  select * into j from public.jobs where id=p_id for update;
  if j.id is null then raise exception 'Job not found'; end if;
  perform private.require_admin(j.unit_id);

  if p_action='start'
     and j.status='Authorized'
     and j.work_stage='Not Started'
  then
    update public.jobs
    set status='Receiving Documentation',
        work_stage='Receiving Evidence',
        customer_stage='In Process',
        updated_at=now()
    where id=j.id;
    return null;

  elsif p_action='receiving-done'
     and j.work_stage='Receiving Evidence'
  then
    if not exists(
      select 1 from public.documents
      where job_id=j.id and type='Receiving Evidence' and status='Available'
    ) then
      raise exception 'Add receiving evidence first';
    end if;

    update public.jobs
    set status='In Process',
        work_stage='Preparing',
        customer_stage='In Process',
        updated_at=now()
    where id=j.id;
    return null;

  elsif p_action='preparation-done'
     and j.work_stage='Preparing'
  then
    if exists(
      select 1 from public.job_extensions
      where job_id=j.id and status in ('Requested','Draft','Sent')
    ) then
      raise exception 'Resolve pending extensions first';
    end if;

    update public.jobs
    set status='In Process',
        work_stage='Final Evidence',
        customer_stage='Engraving',
        updated_at=now()
    where id=j.id;
    return null;

  elsif p_action in ('finished','ready')
     and j.status='In Process'
     and j.work_stage in ('Final Evidence','Final Details','Preparing')
  then
    if exists(
      select 1 from public.job_extensions
      where job_id=j.id and status in ('Requested','Draft','Sent')
    ) then
      raise exception 'Resolve pending extensions first';
    end if;

    if not exists(
      select 1
      from public.documents
      where job_id=j.id
        and type='Completed Evidence'
        and status='Available'
        and created_at>=coalesce(
          (select max(accepted_at) from public.job_extensions where job_id=j.id),
          j.created_at
        )
    ) then
      raise exception 'Add completed work evidence first';
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

  elsif p_action='deliver'
     and j.status='Ready for Delivery'
  then
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
  else
    raise exception 'Invalid job transition';
  end if;
end $$;


ALTER FUNCTION public.advance_job(p_id uuid, p_action text) OWNER TO postgres;

--
-- Name: advance_job_item(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.advance_job_item(p_item uuid, p_action text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  wi public.job_items;
  j public.jobs;
  current_sequence integer;
  remaining integer;
  prog jsonb;
  pickup boolean;
  next_item uuid;
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

  if exists(
    select 1
    from public.cancellation_requests c
    where c.job_id=j.id and c.status='Requested'
  ) then
    update public.jobs
    set work_stage='Cancellation Requested / Production Hold',
        updated_at=now()
    where id=j.id
      and status<>'Cancelled';

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

  if j.work_stage='Cancellation Requested / Production Hold' then
    update public.jobs
    set work_stage=case
      when wi.stage='Preparation' then 'Preparing'
      else 'Engraving'
    end,
    updated_at=now()
    where id=j.id;
  end if;

  if p_action in ('next','preparation-done') and wi.stage='Preparation' then
    update public.job_items
    set stage='Engraving',
        preparation_started_at=coalesce(preparation_started_at,now()),
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
        completed_at=coalesce(completed_at,now()),
        updated_at=now()
    where id=wi.id;

    select id into next_item
    from public.job_items
    where job_id=j.id
      and stage='Preparation'
    order by sequence
    limit 1;

    if next_item is not null then
      update public.job_items
      set preparation_started_at=coalesce(preparation_started_at,now()),
          updated_at=now()
      where id=next_item;
    end if;

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
end
$$;


ALTER FUNCTION public.advance_job_item(p_item uuid, p_action text) OWNER TO postgres;

--
-- Name: advance_pick_return_stop(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.advance_pick_return_stop(p_stop uuid, p_action text) RETURNS jsonb
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


ALTER FUNCTION public.advance_pick_return_stop(p_stop uuid, p_action text) OWNER TO postgres;

--
-- Name: approve_get_tagged(uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.approve_get_tagged(p_id uuid, p_customer uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.approve_get_tagged(p_id uuid, p_customer uuid) OWNER TO postgres;

--
-- Name: authorize_document_live_copies(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.authorize_document_live_copies(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d public.accepted_documents;
begin
 select * into d from public.accepted_documents where id=p_id; perform private.require_admin(d.unit_id);
 if not exists(select 1 from private.customer_mail_activation where unit_id=d.unit_id) then raise exception 'Activate production mail first'; end if;
 update public.accepted_document_status set mail_phase='production' where document_id=p_id;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(d.unit_id,'Accepted Agreement Customer Copy',d.quote_id,d.customer_recipient_email,'accepted-production:'||d.id||':customer',jsonb_build_object('template','accepted_pdf','document_id',d.id,'copy','customer','test',false,'live_eligible',true)),
 (d.unit_id,'Accepted Agreement ToolTag Copy',d.quote_id,'quotes@tooltag.martinlab.studio','accepted-production:'||d.id||':internal',jsonb_build_object('template','accepted_pdf','document_id',d.id,'copy','internal','test',false,'live_eligible',true)) on conflict do nothing;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values(d.unit_id,auth.uid(),'accepted_documents',d.id,'live_copies_authorized',to_jsonb(now()));
end $$;


ALTER FUNCTION public.authorize_document_live_copies(p_id uuid) OWNER TO postgres;

--
-- Name: cancellation_access(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cancellation_access(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.cancellation_access(p_token text) OWNER TO postgres;

--
-- Name: claim_document_copy(uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.claim_document_copy(p_id uuid, p_copy text, p_mode text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d public.accepted_documents; n public.notifications; phase text;
begin
 select * into d from public.accepted_documents where id=p_id; perform private.require_admin(d.unit_id);
 select mail_phase into phase from public.accepted_document_status where document_id=p_id;
 if not ((phase='production' and p_mode='live') or (phase='test' and p_mode='test-delivery')) then return null; end if;
 if p_copy not in ('customer','internal') or not exists(select 1 from private.accepted_pdf_artifacts where document_id=p_id) then return null; end if;
 select * into n from public.notifications where dedupe_key='accepted-'||phase||':'||p_id||':'||p_copy and status='Pending Integration' for update skip locked;
 if n.id is null then return null; end if;
 update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now() where id=n.id returning * into n;
 return to_jsonb(n);
end $$;


ALTER FUNCTION public.claim_document_copy(p_id uuid, p_copy text, p_mode text) OWNER TO postgres;

--
-- Name: close_month(uuid, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.close_month(p_unit uuid, p_month date) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare cid uuid; ver integer; snap jsonb; warnings jsonb;
begin
 perform private.require_admin(p_unit);
 perform 1 from public.business_units where id=p_unit for update;
 if p_month<>date_trunc('month',p_month)::date or p_month>=date_trunc('month',current_date)::date then raise exception 'Choose a completed calendar month'; end if;
 select coalesce(max(version),0)+1 into ver from public.monthly_closes where unit_id=p_unit and month=p_month;
 select jsonb_build_object('revenue',coalesce(sum(revenue),0),'expenses',coalesce(sum(expense),0),'equipment',coalesce(sum(equipment),0),'cash_change',coalesce(sum(cash),0),
 'transactions',coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where unit_id=p_unit and transaction_date>=p_month and transaction_date<p_month+interval '1 month'),'[]'::jsonb),
 'current_summary',(select to_jsonb(s) from public.finance_summary s where unit_id=p_unit)) into snap
 from public.financial_effects where unit_id=p_unit and transaction_date>=p_month and transaction_date<p_month+interval '1 month';
 select coalesce(jsonb_agg(to_jsonb(r)),'[]') into warnings from public.review_items r where unit_id=p_unit;
 update public.monthly_closes set status='Superseded' where unit_id=p_unit and month=p_month and status<>'Superseded';
 insert into public.monthly_closes(unit_id,month,version,status,snapshot,warnings,created_by) values(p_unit,p_month,ver,'Current',snap,warnings,auth.uid()) returning id into cid;
 return cid;
end $$;


ALTER FUNCTION public.close_month(p_unit uuid, p_month date) OWNER TO postgres;

--
-- Name: complete_job_production(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.complete_job_production(p_id uuid) RETURNS text
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


ALTER FUNCTION public.complete_job_production(p_id uuid) OWNER TO postgres;

--
-- Name: confirm_cancellation_refund(uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.confirm_cancellation_refund(p_request uuid, p_method text, p_reference text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
end $_$;


ALTER FUNCTION public.confirm_cancellation_refund(p_request uuid, p_method text, p_reference text) OWNER TO postgres;

--
-- Name: confirm_completion_notified(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.confirm_completion_notified(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare j public.jobs;
begin
 select * into j from public.jobs where id=p_id for update; perform private.require_admin(j.unit_id);
 if j.status<>'Delivered – Pending Customer Acceptance' then raise exception 'Deliver first'; end if;
 if j.acceptance_deadline is not null then return; end if;
 update public.jobs set acceptance_deadline=now()+interval '3 days',completion_reason='Completion link manually delivered by admin' where id=p_id;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,due_at) values(j.unit_id,'Completion reminder',j.id,'completion-reminder:'||j.id,now()+interval '2 days') on conflict do nothing;
end $$;


ALTER FUNCTION public.confirm_completion_notified(p_id uuid) OWNER TO postgres;

--
-- Name: dashboard_stats(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.dashboard_stats(p_unit uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare month_start date; next_month date; result jsonb;
begin
 if not private.can_access(p_unit) then raise exception 'Access denied'; end if;
 select date_trunc('month',now() at time zone timezone)::date into month_start from public.unit_settings where unit_id=p_unit;
 next_month:=(month_start+interval '1 month')::date;
 select jsonb_build_object(
 'sales_month',coalesce((select sum(amount) from public.transactions where unit_id=p_unit and type='SALE' and status<>'Voided' and transaction_date>=month_start and transaction_date<next_month),0),
 'collected_month',coalesce((select sum(amount) from public.transactions where unit_id=p_unit and type='COLLECTION' and status<>'Voided' and transaction_date>=month_start and transaction_date<next_month),0),
 'balance_due',coalesce((select sum(balance_due) from public.sale_balances where unit_id=p_unit and transaction_status<>'Voided'),0),
 'active_jobs',(select count(*) from public.jobs where unit_id=p_unit and status not in ('Completed','Cancelled')),
 'ready_jobs',(select count(*) from public.jobs where unit_id=p_unit and status='Ready for Delivery'),
 'issue_jobs',(select count(*) from public.jobs where unit_id=p_unit and status='Issue / Review'),
 'pending_quotes',(select count(*) from public.quotes where unit_id=p_unit and status in ('Sent','Viewed','Agreement Pending')),
 'accepted_quotes',(select count(*) from public.quotes where unit_id=p_unit and status='Accepted')) into result;
 return result;
end $$;


ALTER FUNCTION public.dashboard_stats(p_unit uuid) OWNER TO postgres;

--
-- Name: get_get_tagged_request(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_get_tagged_request(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  r private.get_tagged_receipts;
begin
  perform private.require_admin(u);

  select * into r
  from private.get_tagged_receipts
  where id=p_id;

  if r.id is null then
    raise exception 'Request not found';
  end if;

  return jsonb_build_object(
    'id',r.id,
    'reference',r.reference,
    'request_status',r.request_status,
    'matching',r.matching,
    'created_at',r.created_at,
    'approved_at',r.approved_at,
    'rejected_at',r.rejected_at,
    'rejection_reason',r.rejection_reason,
    'quote_id',r.quote_id,
    'customer_id',r.customer_id,
    'details',r.details,
    'candidates',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',c.id,
          'name',c.name,
          'email',c.email,
          'phone',c.phone
        )
        order by c.name,c.id
      )
      from public.customers c
      where c.id=any(r.candidates)
    ),'[]'::jsonb)
  );
end $$;


ALTER FUNCTION public.get_get_tagged_request(p_id uuid) OWNER TO postgres;

--
-- Name: get_tagged_attention(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_tagged_attention() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.get_tagged_attention() OWNER TO postgres;

--
-- Name: get_tagged_pending_count(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_tagged_pending_count() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 perform private.require_admin('10000000-0000-0000-0000-000000000002');
 return (select count(*)::integer from private.get_tagged_receipts r where r.request_status='Pending');
end $$;


ALTER FUNCTION public.get_tagged_pending_count() OWNER TO postgres;

--
-- Name: job_lifecycle(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.job_lifecycle(p_job uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare j public.jobs;
begin
 select * into j from public.jobs where id=p_job;
 if not private.can_access(j.unit_id) then raise exception 'Access denied'; end if;
 return jsonb_build_object('customer',(select jsonb_build_object('name',a.accepted_name,'email',coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email')) from public.agreements a left join public.accepted_documents d on d.agreement_id=a.id where a.quote_id=j.quote_id),'review',(select to_jsonb(l)-'token'-'token_hash' from private.job_review_links l where l.job_id=p_job order by l.created_at desc limit 1),'review_path',(select '/work/'||l.token from private.job_review_links l where l.job_id=p_job order by l.created_at desc limit 1));
end $$;


ALTER FUNCTION public.job_lifecycle(p_job uuid) OWNER TO postgres;

--
-- Name: public_cancellation_assessment(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_cancellation_assessment(p_token text, p_job uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.public_cancellation_assessment(p_token text, p_job uuid) OWNER TO postgres;

--
-- Name: public_completion(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_completion(p_token text, p_decision text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  scope jsonb;
  customer uuid;
  snap jsonb;
begin
  select x.* into j
  from public.jobs x
  join private.public_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and l.expires_at>now()
  for update of x;

  if j.id is null then raise exception 'Invalid or expired link'; end if;

  select snapshot into scope
  from private.delivery_scopes
  where job_id=j.id;

  scope:=coalesce(scope,private.job_portal_snapshot(j.id));

  if p_decision is not null then
    if p_decision='accept'
       and exists(select 1 from public.delivery_acknowledgments where job_id=j.id)
    then
      return scope||jsonb_build_object(
        'status',j.status,
        'reason',j.completion_reason,
        'acknowledgment',(
          select jsonb_build_object('id',a.id,'acknowledged_at',a.acknowledged_at)
          from public.delivery_acknowledgments a
          where a.job_id=j.id
        ),
        'payment',private.job_payment_snapshot(j.id)
      );
    end if;

    if j.status<>'Delivered – Pending Customer Acceptance' then
      raise exception 'This delivery acknowledgment has already been resolved';
    end if;

    if p_decision='accept' then
      select customer_id into customer
      from public.commercial_flows
      where id=j.flow_id;

      snap:=jsonb_build_object(
        'job_id',j.id,
        'job_code',j.code,
        'customer_id',customer,
        'scope',scope,
        'delivered_at',j.delivered_at,
        'acknowledged_at',now(),
        'confirmation','I confirm that I received the items/work associated with this ToolTag Job.',
        'method','Secure link / electronic confirmation'
      );

      insert into public.delivery_acknowledgments(
        unit_id,job_id,customer_id,delivered_at,snapshot,snapshot_sha256
      )
      values(
        j.unit_id,j.id,customer,j.delivered_at,snap,
        encode(sha256(convert_to(snap::text,'UTF8')),'hex')
      )
      on conflict(job_id) do nothing;

      update public.jobs
      set status='Completed',
          work_stage=case
            when exists(
              select 1 from public.job_commercial_totals
              where id=j.id and balance_due=0
            ) then 'Closed'
            else 'Payment'
          end,
          customer_accepted_at=now(),
          completion_reason='Completed – Customer Accepted',
          updated_at=now()
      where id=j.id;

    elsif p_decision='issue' then
      update public.jobs
      set status='Issue / Review',
          work_stage='Issue Review',
          completion_reason='Customer reported an issue',
          updated_at=now()
      where id=j.id;
    else
      raise exception 'Invalid decision';
    end if;
  end if;

  update public.jobs
  set completion_link_viewed_at=coalesce(completion_link_viewed_at,now())
  where id=j.id
  returning * into j;

  return scope||jsonb_build_object(
    'status',j.status,
    'reason',j.completion_reason,
    'acknowledgment',(
      select jsonb_build_object('id',a.id,'acknowledged_at',a.acknowledged_at)
      from public.delivery_acknowledgments a
      where a.job_id=j.id
    ),
    'payment',private.job_payment_snapshot(j.id)
  );
end $$;


ALTER FUNCTION public.public_completion(p_token text, p_decision text) OWNER TO postgres;

--
-- Name: public_confirm_job_cancellation(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_confirm_job_cancellation(p_token text, p_job uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
end $_$;


ALTER FUNCTION public.public_confirm_job_cancellation(p_token text, p_job uuid) OWNER TO postgres;

--
-- Name: public_job_document(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_job_document(p_token text, p_document uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  jid uuid;
  d public.documents;
begin
  select l.job_id into jid
  from private.job_status_links l
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if jid is null then
    raise exception 'Status link unavailable';
  end if;

  select * into d
  from public.documents x
  where x.id=p_document
    and x.job_id=jid
    and x.visibility='customer'
    and x.status<>'Archived';

  if d.id is null then
    raise exception 'Document unavailable';
  end if;

  return jsonb_build_object(
    'id',d.id,
    'type',d.type,
    'file_name',d.file_name,
    'original_file_name',d.original_file_name,
    'mime_type',d.mime_type,
    'file_size',d.file_size,
    'sha256',d.sha256,
    'status',d.status,
    'storage_status',d.storage_status,
    'folder_kind',d.folder_kind,
    'job_item_id',d.job_item_id,
    'created_at',d.created_at
  );
end
$$;


ALTER FUNCTION public.public_job_document(p_token text, p_document uuid) OWNER TO postgres;

--
-- Name: public_job_documents(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_job_documents(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  jid uuid;
begin
  select l.job_id into jid
  from private.job_status_links l
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if jid is null then
    raise exception 'Status link unavailable';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',d.id,
        'type',d.type,
        'file_name',d.file_name,
        'mime_type',d.mime_type,
        'file_size',d.file_size,
        'status',d.status,
        'storage_status',d.storage_status,
        'folder_kind',d.folder_kind,
        'job_item_id',d.job_item_id,
        'created_at',d.created_at
      )
      order by d.created_at,d.id
    )
    from public.documents d
    where d.job_id=jid
      and d.visibility='customer'
      and d.status<>'Archived'
  ),'[]'::jsonb);
end
$$;


ALTER FUNCTION public.public_job_documents(p_token text) OWNER TO postgres;

--
-- Name: public_job_status(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_job_status(p_token text) RETURNS jsonb
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
    'code',j.code,
    'customer_name',customer_name,
    'stage',j.customer_stage,
    'tracking_stage',tracking_stage,
    'job_status',j.status,
    'work_stage',j.work_stage,
    'updated_at',j.updated_at,
    'items_total',coalesce((prog->>'total')::integer,0),
    'items_completed',coalesce((prog->>'finished')::integer,0),
    'items_started',coalesce((prog->>'started')::integer,0),
    'item_progress',prog,
    'pickup_return',pr,
    'cancelled',j.status='Cancelled',
    'steps',tracking_steps
  );
end $$;


ALTER FUNCTION public.public_job_status(p_token text) OWNER TO postgres;

--
-- Name: public_pickup_fee(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_pickup_fee(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.public_pickup_fee(p_token text) OWNER TO postgres;

--
-- Name: public_request_status(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_request_status(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare r private.get_tagged_receipts; q public.quotes; j public.jobs; stage text; job_token text; stamp timestamptz; steps jsonb:=jsonb_build_array('Request received','In review','Preparing quote','Quote sent','In Process','Engraving','Final Details','Completed');
begin
 if p_token is null or p_token !~ '^[a-f0-9]{64}$' then return null; end if;
 select x.* into r from private.get_tagged_receipts x join private.request_status_links l on l.request_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if not found then return null; end if;
 select * into q from public.quotes where flow_id=(select flow_id from public.quotes where id=r.quote_id) order by revision desc limit 1;
 stage:='In review';stamp:=r.created_at;
 if q.id is not null then stage:='Preparing quote';stamp:=coalesce(q.intake_reviewed_at,q.created_at);end if;
 if q.sent_at is not null then stage:='Quote sent';stamp:=q.sent_at;end if;
 if r.request_status='Rejected' then stage:='Contact ToolTag';stamp:=coalesce(r.rejected_at,r.created_at);end if;
 if q.status in ('Declined','Expired') then stage:='Contact ToolTag';end if;
 select * into j from public.jobs where flow_id=q.flow_id;
 if j.id is not null then
  select token into job_token from private.job_status_links where job_id=j.id;
  stage:=case when j.status='Cancelled' then 'Contact ToolTag' when to_jsonb(j)->>'work_stage'='Closed' then 'Completed' else coalesce(to_jsonb(j)->>'customer_stage','In Process') end;stamp:=j.updated_at;
 end if;
 return jsonb_build_object('code',r.reference,'stage',stage,'steps',steps,'updated_at',stamp,'request_tracking',true,'job_status_token',job_token);
end $_$;


ALTER FUNCTION public.public_request_status(p_token text) OWNER TO postgres;

--
-- Name: public_status_cancellation_assessment(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_status_cancellation_assessment(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if j.id is null then raise exception 'Status link unavailable'; end if;

  return jsonb_build_object(
    'job_code',j.code,'status',j.status,'work_stage',j.work_stage,
    'progress',private.job_item_progress(j.id),
    'assessment',private.cancellation_assessment(j.id),
    'pickup_return',(
      select to_jsonb(pr)-'unit_id'-'terms_snapshot'
      from public.pick_return_orders pr where pr.job_id=j.id
    )
  );
end $$;


ALTER FUNCTION public.public_status_cancellation_assessment(p_token text) OWNER TO postgres;

--
-- Name: public_status_cancellation_finance(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_status_cancellation_finance(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.public_status_cancellation_finance(p_token text) OWNER TO postgres;

--
-- Name: public_status_confirm_cancellation(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_status_confirm_cancellation(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
end $_$;


ALTER FUNCTION public.public_status_confirm_cancellation(p_token text) OWNER TO postgres;

--
-- Name: public_status_submit_cancellation_payment(text, uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_status_submit_cancellation_payment(p_token text, p_request uuid, p_method text, p_proof_path text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
end $_$;


ALTER FUNCTION public.public_status_submit_cancellation_payment(p_token text, p_request uuid, p_method text, p_proof_path text) OWNER TO postgres;

--
-- Name: public_submit_pickup_fee_payment(text, uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_submit_pickup_fee_payment(p_token text, p_request uuid, p_method text, p_proof_path text DEFAULT NULL::text) RETURNS jsonb
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
end $_$;


ALTER FUNCTION public.public_submit_pickup_fee_payment(p_token text, p_request uuid, p_method text, p_proof_path text) OWNER TO postgres;

--
-- Name: public_work_review(text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_work_review(p_token text, p_response text DEFAULT NULL::text, p_request text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare l private.job_review_links; j public.jobs; seq integer;
begin
 select * into l from private.job_review_links where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and expires_at>now();
 if l.id is null then raise exception 'Link unavailable'; end if;
 select * into j from public.jobs where id=l.job_id for update;
 select * into l from private.job_review_links where id=l.id for update;
 if l.id<>(select id from private.job_review_links where job_id=j.id order by created_at desc limit 1) then raise exception 'A newer review is available'; end if;
 update private.job_review_links set viewed_at=coalesce(viewed_at,now()) where id=l.id;
 if p_response is not null and l.response_at is null then
   if j.status<>'Ready for Delivery' then raise exception 'Job is not ready for review'; end if;
   if p_response not in ('ready','additional') then raise exception 'Invalid response'; end if;
   if p_response='additional' then
     if nullif(trim(p_request),'') is null or length(p_request)>5000 then raise exception 'Describe your additional request'; end if;
     select coalesce(max(sequence),0)+1 into seq from public.job_extensions where job_id=j.id;
     insert into public.job_extensions(unit_id,job_id,sequence,code,customer_request,request_key) values(j.unit_id,j.id,seq,j.code||'/X'||seq,trim(p_request),l.id) on conflict(request_key) do nothing;
   end if;
   update private.job_review_links set response=p_response,response_at=now(),customer_request=case when p_response='additional' then trim(p_request) end where id=l.id returning * into l;
 end if;
 return private.job_portal_snapshot(j.id)||jsonb_build_object('response',l.response,'response_at',l.response_at);
end $$;


ALTER FUNCTION public.public_work_review(p_token text, p_response text, p_request text) OWNER TO postgres;

--
-- Name: publish_policy(uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.publish_policy(p_unit uuid, p_title text, p_content text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare pid uuid; v integer;
begin
 perform private.require_admin(p_unit);
 perform 1 from public.business_units where id=p_unit for update;
 select coalesce(max(version),0)+1 into v from public.policies where unit_id=p_unit;
 insert into public.policies(unit_id,version,title,content,published_at) values(p_unit,v,p_title,p_content,now()) returning id into pid;
 return pid;
end $$;


ALTER FUNCTION public.publish_policy(p_unit uuid, p_title text, p_content text) OWNER TO postgres;

--
-- Name: register_document_metadata(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.register_document_metadata(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  u uuid:=(p->>'unit_id')::uuid;
  did uuid;
  jid uuid:=nullif(p->>'job_id','')::uuid;
  item_id uuid:=nullif(p->>'job_item_id','')::uuid;
  stop_id uuid:=nullif(p->>'pick_return_stop_id','')::uuid;
  ext_id uuid:=nullif(p->>'job_extension_id','')::uuid;
  pay_id uuid:=nullif(p->>'payment_request_id','')::uuid;
  cancel_id uuid:=nullif(p->>'cancellation_request_id','')::uuid;
  item public.job_items;
  stop public.pick_return_stops;
  j public.jobs;
  qid uuid;
  cid uuid;
  route_leg text;
  doc_type text:=trim(coalesce(p->>'type',''));
  doc_visibility text:=coalesce(nullif(p->>'visibility',''),'internal');
  doc_sha text:=lower(nullif(p->>'sha256',''));
  doc_name text:=coalesce(nullif(trim(p->>'file_name'),''),nullif(trim(p->>'original_file_name'),''));
  original_name text:=coalesce(nullif(trim(p->>'original_file_name'),''),doc_name);
  logical text;
begin
  perform private.require_admin(u);

  if doc_type not in (
    'Receiving Evidence','Production Evidence','Delivery Evidence',
    'Issue / Review Evidence','Cancellation Evidence',
    'Refund Review Evidence','Customer Document','Other'
  ) then
    raise exception 'Unsupported document/evidence type';
  end if;

  if doc_visibility not in ('internal','customer') then
    raise exception 'Invalid document visibility';
  end if;

  if doc_name is null then
    raise exception 'File name is required';
  end if;

  if doc_sha is null or doc_sha !~ '^[0-9a-f]{64}$' then
    raise exception 'A SHA-256 fingerprint is required';
  end if;

  if coalesce((p->>'file_size')::bigint,-1)<0 then
    raise exception 'File size is required';
  end if;

  if nullif(p->>'drive_file_id','') is not null
     or nullif(p->>'drive_folder_id','') is not null
     or nullif(p->>'drive_web_view_link','') is not null
  then
    raise exception 'Google Drive integration is not enabled yet';
  end if;

  if item_id is not null then
    select * into item
    from public.job_items
    where id=item_id;

    if item.id is null or item.unit_id<>u then
      raise exception 'Job item not found';
    end if;

    if jid is not null and jid<>item.job_id then
      raise exception 'Job item does not belong to this Job';
    end if;

    jid:=item.job_id;
  end if;

  if stop_id is not null then
    select * into stop
    from public.pick_return_stops
    where id=stop_id;

    if stop.id is null or stop.unit_id<>u then
      raise exception 'Route stop not found';
    end if;

    if jid is not null and jid<>stop.job_id then
      raise exception 'Route stop does not belong to this Job';
    end if;

    jid:=stop.job_id;

    select r.leg into route_leg
    from public.pick_return_routes r
    where r.id=stop.route_id;
  end if;

  if jid is not null then
    select x.* into j
    from public.jobs x
    where x.id=jid;

    if j.id is null or j.unit_id<>u then
      raise exception 'Job not found';
    end if;

    select f.customer_id into cid
    from public.commercial_flows f
    where f.id=j.flow_id;

    qid:=j.quote_id;
  end if;

  if doc_type='Production Evidence' then
    if item_id is null then
      raise exception 'Production Evidence must belong to a physical Job Item';
    end if;

    if item.stage not in ('Engraving','Finished Evidence') then
      raise exception 'Production Evidence can only be added while this item is in Engraving';
    end if;

    if exists(
      select 1
      from public.cancellation_requests c
      where c.job_id=jid and c.status='Requested'
    ) then
      raise exception 'Cancellation request detected; production evidence cannot be added';
    end if;
  end if;

  if doc_type='Receiving Evidence'
     and stop_id is not null
     and route_leg<>'Pickup'
  then
    raise exception 'Receiving Evidence can only be linked to a Pickup stop';
  end if;

  if doc_type='Delivery Evidence'
     and stop_id is not null
     and route_leg<>'Return'
  then
    raise exception 'Delivery Evidence can only be linked to a Return stop';
  end if;

  if ext_id is not null and not exists(
    select 1 from public.job_extensions x
    where x.id=ext_id
      and x.unit_id=u
      and (jid is null or x.job_id=jid)
  ) then
    raise exception 'Job extension does not belong to this Job';
  end if;

  if pay_id is not null and not exists(
    select 1 from public.payment_requests x
    where x.id=pay_id
      and x.unit_id=u
      and (jid is null or x.job_id=jid)
  ) then
    raise exception 'Payment request does not belong to this Job';
  end if;

  if cancel_id is not null and not exists(
    select 1 from public.cancellation_requests x
    where x.id=cancel_id
      and x.unit_id=u
      and (jid is null or x.job_id=jid)
  ) then
    raise exception 'Cancellation request does not belong to this Job';
  end if;

  logical:=
    'evidence:'||
    coalesce(jid::text,'-')||':'||
    coalesce(item_id::text,'-')||':'||
    coalesce(stop_id::text,'-')||':'||
    doc_type||':'||doc_sha;

  insert into public.documents(
    unit_id,type,file_name,original_file_name,mime_type,file_size,sha256,
    visibility,status,storage_provider,storage_status,folder_kind,
    customer_id,quote_id,job_id,job_item_id,job_extension_id,
    pick_return_stop_id,payment_request_id,cancellation_request_id,
    notes,uploaded_by,logical_key
  )
  values(
    u,doc_type,doc_name,original_name,nullif(p->>'mime_type',''),
    (p->>'file_size')::bigint,doc_sha,
    doc_visibility,'Available','pending_drive','Pending Drive Upload',
    private.document_folder_kind(doc_type),
    coalesce(nullif(p->>'customer_id','')::uuid,cid),
    coalesce(nullif(p->>'quote_id','')::uuid,qid),
    jid,item_id,ext_id,stop_id,pay_id,cancel_id,
    nullif(p->>'notes',''),auth.uid(),logical
  )
  on conflict(unit_id,logical_key) do nothing
  returning id into did;

  if did is null then
    select d.id into did
    from public.documents d
    where d.unit_id=u and d.logical_key=logical;
  end if;

  if doc_type='Production Evidence' then
    update public.job_items
    set
      stage=case when stage='Engraving' then 'Finished Evidence' else stage end,
      evidence_completed_at=coalesce(evidence_completed_at,now()),
      updated_at=now()
    where id=item_id
      and stage in ('Engraving','Finished Evidence');
  end if;

  return did;
end
$_$;


ALTER FUNCTION public.register_document_metadata(p jsonb) OWNER TO postgres;

--
-- Name: reject_get_tagged(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reject_get_tagged(p_id uuid, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.reject_get_tagged(p_id uuid, p_reason text) OWNER TO postgres;

--
-- Name: request_cancellation_access(text, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.request_cancellation_access(p_network text, p_name text, p_email text, p_phone text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
end $_$;


ALTER FUNCTION public.request_cancellation_access(p_network text, p_name text, p_email text, p_phone text) OWNER TO postgres;

--
-- Name: request_job_cancellation(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.request_job_cancellation(p_job uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.request_job_cancellation(p_job uuid) OWNER TO postgres;

--
-- Name: request_job_extension(uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.request_job_extension(p_job uuid, p_request text, p_key uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare j public.jobs; seq integer; eid uuid;
begin
 select * into j from public.jobs where id=p_job for update; perform private.require_admin(j.unit_id);
 if j.status not in ('Authorized','Receiving Documentation','In Process','Ready for Delivery') then raise exception 'Job is not active'; end if;
 if nullif(trim(p_request),'') is null then raise exception 'Describe the requested work'; end if;
 select id into eid from public.job_extensions where request_key=p_key and job_id=p_job; if eid is not null then return eid; end if;
 select coalesce(max(sequence),0)+1 into seq from public.job_extensions where job_id=p_job;
 insert into public.job_extensions(unit_id,job_id,sequence,code,customer_request,request_key) values(j.unit_id,j.id,seq,j.code||'/X'||seq,trim(p_request),p_key) returning id into eid;
 return eid;
end $$;


ALTER FUNCTION public.request_job_extension(p_job uuid, p_request text, p_key uuid) OWNER TO postgres;

--
-- Name: resolve_get_tagged(uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.resolve_get_tagged(p_id uuid, p_customer uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare r private.get_tagged_receipts; qid uuid;
begin
 perform private.require_admin('10000000-0000-0000-0000-000000000002');
 select * into r from private.get_tagged_receipts where id=p_id for update;
 if r.id is null or not(p_customer=any(r.candidates)) then raise exception 'Select one of the matching customers'; end if;
 qid:=private.create_get_tagged_draft(p_id,p_customer);
 update private.get_tagged_receipts set matching='reused' where id=p_id;
 return qid;
end $$;


ALTER FUNCTION public.resolve_get_tagged(p_id uuid, p_customer uuid) OWNER TO postgres;

--
-- Name: review_get_tagged_quote(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.review_get_tagged_quote(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION public.review_get_tagged_quote(p jsonb) OWNER TO postgres;

--
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION public.rls_auto_enable() OWNER TO postgres;

--
-- Name: run_scheduled_tasks(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.run_scheduled_tasks() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u record; m date; j record;
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
 -- TT only in phase 1. BOFT production and its monthly automation are untouched.
 for u in select s.* from public.unit_settings s join public.business_units b on b.id=s.unit_id where b.code='TOOLTAG' loop
 m:=(date_trunc('month',now() at time zone u.timezone)-interval '1 month')::date;
 if not exists(select 1 from public.monthly_closes where unit_id=u.unit_id and month=m) then perform public.close_month(u.unit_id,m); end if;
 end loop;
end $$;


ALTER FUNCTION public.run_scheduled_tasks() OWNER TO postgres;

--
-- Name: save_category(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.save_category(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid; cid uuid;
begin
 perform private.require_admin(u);
 if nullif(p->>'id','') is not null then
 update public.categories set active=coalesce((p->>'active')::boolean,active) where id=(p->>'id')::uuid and unit_id=u returning id into cid;
 else insert into public.categories(unit_id,name,kind) values(u,p->>'name',p->>'kind') returning id into cid;
 end if;
 return cid;
end $$;


ALTER FUNCTION public.save_category(p jsonb) OWNER TO postgres;

--
-- Name: save_settings(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.save_settings(p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid;
begin
 perform private.require_admin(u);
 if p ? 'timezone' and not exists(select 1 from pg_timezone_names where name=p->>'timezone') then raise exception 'Invalid timezone'; end if;
 if p ? 'boft_url' and p->>'boft_url' !~ '^https://' then raise exception 'BOFT URL must use HTTPS'; end if;
 update public.unit_settings set timezone=coalesce(p->>'timezone',timezone),drive_root_id=coalesce(p->>'drive_root_id',drive_root_id),boft_url=coalesce(p->>'boft_url',boft_url),annual_vehicle_method=coalesce(p->>'annual_vehicle_method',annual_vehicle_method),mileage_rate=coalesce((p->>'mileage_rate')::numeric,mileage_rate) where unit_id=u;
end $$;


ALTER FUNCTION public.save_settings(p jsonb) OWNER TO postgres;

--
-- Name: schedule_pick_return(uuid, text, timestamp with time zone, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.schedule_pick_return(p_job uuid, p_leg text, p_window_start timestamp with time zone, p_window_end timestamp with time zone, p_eta timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS uuid
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
end $_$;


ALTER FUNCTION public.schedule_pick_return(p_job uuid, p_leg text, p_window_start timestamp with time zone, p_window_end timestamp with time zone, p_eta timestamp with time zone) OWNER TO postgres;

--
-- Name: search_records(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_records(p_unit uuid, p_query text) RETURNS TABLE(id uuid, kind text, label text, path text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if not private.can_access(p_unit) then raise exception 'Access denied'; end if;
 if length(trim(p_query))<2 then return; end if;
 return query
 select q.id,'Quote',q.code||' v'||q.revision,'/app/quotes/'||q.id from public.quotes q where q.unit_id=p_unit and q.code ilike '%'||p_query||'%'
 union all select j.id,'Job',j.code,'/app/jobs/'||j.id from public.jobs j where j.unit_id=p_unit and j.code ilike '%'||p_query||'%'
 union all select s.transaction_id,'Sale',s.code,'/app/finance/sales/'||s.transaction_id from public.sales s where s.unit_id=p_unit and s.code ilike '%'||p_query||'%'
 union all select d.id,'Document',d.file_name,case when d.job_id is not null then '/app/jobs/'||d.job_id when d.transaction_id is not null then '/app/finance/transactions/'||d.transaction_id when d.customer_id is not null then '/app/customers/'||d.customer_id else '/app/finance/review' end from public.documents d where d.unit_id=p_unit and (d.file_name ilike '%'||p_query||'%' or d.type ilike '%'||p_query||'%') limit 100;
end $$;


ALTER FUNCTION public.search_records(p_unit uuid, p_query text) OWNER TO postgres;

--
-- Name: submit_get_tagged(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.submit_get_tagged(p_key uuid, p_network text, p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  return public.submit_get_tagged_v2(p_key,p_network,p_payload);
end $$;


ALTER FUNCTION public.submit_get_tagged(p_key uuid, p_network text, p_payload jsonb) OWNER TO postgres;

--
-- Name: submit_get_tagged_v2(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.submit_get_tagged_v2(p_key uuid, p_network text, p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
end $_$;


ALTER FUNCTION public.submit_get_tagged_v2(p_key uuid, p_network text, p_payload jsonb) OWNER TO postgres;

--
-- Name: update_document_evidence_metadata(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_document_evidence_metadata(p_document uuid, p_metadata jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  d public.documents;
begin
  select * into d
  from public.documents
  where id=p_document
  for update;

  if d.id is null then
    raise exception 'Document not found';
  end if;

  perform private.require_admin(d.unit_id);

  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' then
    raise exception 'Document metadata must be a JSON object';
  end if;

  update public.documents
  set evidence_metadata=p_metadata
  where id=d.id;

  return d.id;
end
$$;


ALTER FUNCTION public.update_document_evidence_metadata(p_document uuid, p_metadata jsonb) OWNER TO postgres;

--
-- Name: update_transaction(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_transaction(p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t public.transactions;
begin
 select * into t from public.transactions where id=(p->>'id')::uuid for update;
 perform private.require_admin(t.unit_id);
 if nullif(trim(p->>'reason'),'') is null then raise exception 'Change reason required'; end if;
 perform set_config('app.change_reason',p->>'reason',true);
 -- Monetary corrections use reversals/refunds, preserving accepted sale and payment snapshots.
 if p->>'status'='Voided' and (t.type='SALE' or exists(select 1 from public.refunds where original_id=t.id) or exists(select 1 from public.reimbursements where expense_id=t.id) or exists(select 1 from public.assets where source_expense_id=t.id)) then raise exception 'Linked transaction cannot be voided; use a revision or refund'; end if;
 update public.transactions set transaction_date=coalesce((p->>'transaction_date')::date,transaction_date),description=coalesce(p->>'description',description),status=coalesce(p->>'status',status) where id=t.id;
end $$;


ALTER FUNCTION public.update_transaction(p jsonb) OWNER TO postgres;

--
-- Name: vehicle_report(uuid, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.vehicle_report(p_unit uuid, p_year integer) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare method text; rate numeric; miles numeric; fuel numeric;
begin
 if not private.can_access(p_unit) then raise exception 'Access denied'; end if;
 select annual_vehicle_method,mileage_rate into method,rate from public.unit_settings where unit_id=p_unit;
 select coalesce(sum(m.miles),0) into miles from public.mileage m where unit_id=p_unit and extract(year from date)=p_year;
 select coalesce(sum(t.amount),0) into fuel from public.transactions t join public.categories c on c.id=t.category_id where t.unit_id=p_unit and t.type='EXPENSE' and t.status<>'Voided' and c.is_fuel and extract(year from transaction_date)=p_year;
 return jsonb_build_object('year',p_year,'selected_method',method,'fuel_history',fuel,'miles_history',miles,'rate',rate,'selected_amount',case when method='Fuel' then fuel else miles*rate end,'note','One method only. Mileage rate must be supplied; no tax rate is assumed.');
end $$;


ALTER FUNCTION public.vehicle_report(p_unit uuid, p_year integer) OWNER TO postgres;

--
-- Name: cancellation_access_links; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.cancellation_access_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    token text NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE private.cancellation_access_links OWNER TO postgres;

--
-- Name: get_tagged_rate; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.get_tagged_rate (
    network text NOT NULL,
    bucket timestamp with time zone NOT NULL,
    requests integer NOT NULL
);


ALTER TABLE private.get_tagged_rate OWNER TO postgres;

--
-- Name: get_tagged_receipts; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.get_tagged_receipts (
    id uuid NOT NULL,
    fingerprint text NOT NULL,
    details jsonb NOT NULL,
    reference text DEFAULT ('TT-R-'::text || upper(substr(replace((gen_random_uuid())::text, '-'::text, ''::text), 1, 12))) NOT NULL,
    quote_id uuid,
    customer_id uuid,
    matching text NOT NULL,
    candidates uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    request_status text DEFAULT 'Pending'::text NOT NULL,
    approved_at timestamp with time zone,
    rejected_at timestamp with time zone,
    reviewed_by uuid,
    rejection_reason text,
    CONSTRAINT get_tagged_receipts_matching_check CHECK ((matching = ANY (ARRAY['new'::text, 'created'::text, 'reused'::text, 'review'::text]))),
    CONSTRAINT get_tagged_receipts_request_status_check CHECK ((request_status = ANY (ARRAY['Pending'::text, 'Approved'::text, 'Rejected'::text, 'Converted'::text])))
);


ALTER TABLE private.get_tagged_receipts OWNER TO postgres;

--
-- Name: job_status_links; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.job_status_links (
    job_id uuid NOT NULL,
    token text NOT NULL,
    token_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE private.job_status_links OWNER TO postgres;

--
-- Name: pickup_payment_links; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.pickup_payment_links (
    job_id uuid NOT NULL,
    token text NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE private.pickup_payment_links OWNER TO postgres;

--
-- Name: request_status_links; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.request_status_links (
    request_id uuid NOT NULL,
    token text NOT NULL,
    token_hash text NOT NULL
);


ALTER TABLE private.request_status_links OWNER TO postgres;

--
-- Name: cancellation_requests; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.cancellation_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    job_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    status text DEFAULT 'Requested'::text NOT NULL,
    refund_status text DEFAULT 'None'::text NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    confirmed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    stage_at_request text,
    items_total integer DEFAULT 0 NOT NULL,
    items_started integer DEFAULT 0 NOT NULL,
    items_finished integer DEFAULT 0 NOT NULL,
    service_amount numeric(14,2) DEFAULT 0 NOT NULL,
    pickup_fee_amount numeric(14,2) DEFAULT 0 NOT NULL,
    pickup_fee_refundable boolean DEFAULT false NOT NULL,
    pickup_fee_refund_amount numeric(14,2) DEFAULT 0 NOT NULL,
    service_charge_percent numeric(5,2) DEFAULT 0 NOT NULL,
    service_charge_amount numeric(14,2) DEFAULT 0 NOT NULL,
    refund_eligible_amount numeric(14,2) DEFAULT 0 NOT NULL,
    amount_due numeric(14,2) DEFAULT 0 NOT NULL,
    agreement_version integer,
    assessment jsonb DEFAULT '{}'::jsonb NOT NULL,
    refund_transaction_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    refund_transaction_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    CONSTRAINT cancellation_requests_refund_status_check CHECK ((refund_status = ANY (ARRAY['None'::text, 'Pending'::text, 'Completed'::text]))),
    CONSTRAINT cancellation_requests_status_check CHECK ((status = ANY (ARRAY['Requested'::text, 'Cancelled'::text, 'Rejected'::text])))
);


ALTER TABLE public.cancellation_requests OWNER TO postgres;

--
-- Name: delivery_acknowledgments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.delivery_acknowledgments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    job_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    delivered_at timestamp with time zone NOT NULL,
    acknowledged_at timestamp with time zone DEFAULT now() NOT NULL,
    acceptance_method text DEFAULT 'Secure link / electronic confirmation'::text NOT NULL,
    snapshot jsonb NOT NULL,
    snapshot_sha256 text NOT NULL
);


ALTER TABLE public.delivery_acknowledgments OWNER TO postgres;

--
-- Name: document_relations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.document_relations (
    document_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    transaction_id uuid NOT NULL
);


ALTER TABLE public.document_relations OWNER TO postgres;

--
-- Name: documents; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    type text NOT NULL,
    drive_file_id text,
    file_name text NOT NULL,
    customer_id uuid,
    job_id uuid,
    transaction_id uuid,
    agreement_id uuid,
    content_snapshot jsonb,
    status text DEFAULT 'Pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    uploaded_by uuid,
    job_item_id uuid,
    pick_return_stop_id uuid,
    quote_id uuid,
    job_extension_id uuid,
    payment_request_id uuid,
    cancellation_request_id uuid,
    accepted_document_id uuid,
    job_receipt_id uuid,
    original_file_name text,
    mime_type text,
    file_size bigint,
    sha256 text,
    visibility text DEFAULT 'internal'::text NOT NULL,
    uploaded_at timestamp with time zone,
    notes text,
    storage_provider text DEFAULT 'pending_drive'::text NOT NULL,
    storage_status text DEFAULT 'Pending Drive Upload'::text NOT NULL,
    drive_folder_id text,
    drive_web_view_link text,
    drive_download_metadata jsonb,
    folder_kind text,
    logical_key text,
    evidence_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT documents_evidence_metadata_object_check CHECK ((jsonb_typeof(evidence_metadata) = 'object'::text)),
    CONSTRAINT documents_file_size_nonnegative CHECK (((file_size IS NULL) OR (file_size >= 0))),
    CONSTRAINT documents_folder_kind_check CHECK (((folder_kind IS NULL) OR (folder_kind = ANY (ARRAY['commercial'::text, 'receiving'::text, 'production'::text, 'delivery'::text, 'payments'::text, 'issue_review'::text, 'other'::text])))),
    CONSTRAINT documents_sha256_format CHECK (((sha256 IS NULL) OR (sha256 ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT documents_status_check CHECK ((status = ANY (ARRAY['Pending'::text, 'Pending Upload'::text, 'Available'::text, 'Failed'::text, 'Archived'::text]))),
    CONSTRAINT documents_storage_provider_check CHECK ((storage_provider = ANY (ARRAY['pending_drive'::text, 'google_drive'::text, 'legacy_drive'::text, 'temporary'::text]))),
    CONSTRAINT documents_storage_status_check CHECK ((storage_status = ANY (ARRAY['Pending Upload'::text, 'Stored Locally/Temporary'::text, 'Pending Drive Upload'::text, 'Upload In Progress'::text, 'Uploaded'::text, 'Upload Failed'::text, 'Retry Required'::text, 'Failed'::text, 'Archived'::text]))),
    CONSTRAINT documents_type_check CHECK ((type = ANY (ARRAY['Receipt'::text, 'Quote'::text, 'Agreement'::text, 'Accepted Quote'::text, 'Accepted Agreement'::text, 'Receiving Evidence'::text, 'Completed Evidence'::text, 'Finished Evidence'::text, 'Production Evidence'::text, 'Delivery Evidence'::text, 'Delivery Acknowledgment'::text, 'Payment Receipt'::text, 'Final Receipt'::text, 'Refund Receipt'::text, 'Issue / Review'::text, 'Issue / Review Evidence'::text, 'Cancellation Evidence'::text, 'Refund Review Evidence'::text, 'Customer Document'::text, 'Customer Claim'::text, 'Job Extension'::text, 'Other'::text]))),
    CONSTRAINT documents_visibility_check CHECK ((visibility = ANY (ARRAY['internal'::text, 'customer'::text])))
);


ALTER TABLE public.documents OWNER TO postgres;

--
-- Name: job_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.job_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    job_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    quote_item_id uuid NOT NULL,
    unit_index integer NOT NULL,
    sequence integer NOT NULL,
    article text NOT NULL,
    scope_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    stage text DEFAULT 'Preparation'::text NOT NULL,
    engraving_started_at timestamp with time zone,
    evidence_completed_at timestamp with time zone,
    finished_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    display_label text NOT NULL,
    preparation_started_at timestamp with time zone,
    completed_at timestamp with time zone,
    CONSTRAINT job_items_sequence_check CHECK ((sequence > 0)),
    CONSTRAINT job_items_stage_check CHECK ((stage = ANY (ARRAY['Preparation'::text, 'Engraving'::text, 'Finished Evidence'::text, 'Finished'::text, 'Cancelled'::text]))),
    CONSTRAINT job_items_unit_index_check CHECK ((unit_index > 0))
);


ALTER TABLE public.job_items OWNER TO postgres;

--
-- Name: pick_return_orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pick_return_orders (
    job_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    service_method text DEFAULT 'Pickup & Return'::text NOT NULL,
    fee_amount numeric(14,2) DEFAULT 10.00 NOT NULL,
    fee_status text DEFAULT 'Required'::text NOT NULL,
    scheduler_enabled boolean DEFAULT false NOT NULL,
    pickup_status text DEFAULT 'Not Scheduled'::text NOT NULL,
    return_status text DEFAULT 'Not Ready'::text NOT NULL,
    pickup_window_start timestamp with time zone,
    pickup_window_end timestamp with time zone,
    pickup_eta timestamp with time zone,
    pickup_cancellation_deadline timestamp with time zone,
    picked_up_at timestamp with time zone,
    return_window_start timestamp with time zone,
    return_window_end timestamp with time zone,
    return_eta timestamp with time zone,
    returned_at timestamp with time zone,
    unattended_delivery_authorized boolean DEFAULT false NOT NULL,
    special_instructions text,
    terms_version text DEFAULT '2.0'::text NOT NULL,
    terms_snapshot text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    hold_until_paid boolean DEFAULT false NOT NULL,
    CONSTRAINT pick_return_orders_fee_amount_check CHECK ((fee_amount >= (0)::numeric)),
    CONSTRAINT pick_return_orders_fee_status_check CHECK ((fee_status = ANY (ARRAY['Required'::text, 'Pending Verification'::text, 'Confirmed'::text, 'Refund Pending'::text, 'Refunded'::text, 'Forfeited'::text, 'Cancelled'::text]))),
    CONSTRAINT pick_return_orders_pickup_status_check CHECK ((pickup_status = ANY (ARRAY['Not Scheduled'::text, 'Scheduled'::text, 'En Route'::text, 'Arrived'::text, 'Picked Up'::text, 'Failed'::text, 'Cancelled'::text]))),
    CONSTRAINT pick_return_orders_return_status_check CHECK ((return_status = ANY (ARRAY['Not Ready'::text, 'Delivery In Progress'::text, 'Scheduled'::text, 'En Route'::text, 'Arrived'::text, 'Delivered'::text, 'Cancelled'::text]))),
    CONSTRAINT pick_return_orders_service_method_check CHECK ((service_method = 'Pickup & Return'::text))
);


ALTER TABLE public.pick_return_orders OWNER TO postgres;

--
-- Name: pick_return_routes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pick_return_routes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    route_date date NOT NULL,
    leg text NOT NULL,
    status text DEFAULT 'Draft'::text NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pick_return_routes_leg_check CHECK ((leg = ANY (ARRAY['Pickup'::text, 'Return'::text]))),
    CONSTRAINT pick_return_routes_status_check CHECK ((status = ANY (ARRAY['Draft'::text, 'Active'::text, 'Completed'::text, 'Cancelled'::text])))
);


ALTER TABLE public.pick_return_routes OWNER TO postgres;

--
-- Name: pick_return_stops; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pick_return_stops (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    route_id uuid NOT NULL,
    job_id uuid NOT NULL,
    sequence integer NOT NULL,
    status text DEFAULT 'Scheduled'::text NOT NULL,
    window_start timestamp with time zone,
    window_end timestamp with time zone,
    eta timestamp with time zone,
    arrived_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pick_return_stops_sequence_check CHECK ((sequence > 0)),
    CONSTRAINT pick_return_stops_status_check CHECK ((status = ANY (ARRAY['Scheduled'::text, 'En Route'::text, 'Arrived'::text, 'Completed'::text, 'Failed'::text, 'Cancelled'::text])))
);


ALTER TABLE public.pick_return_stops OWNER TO postgres;

--
-- Name: storage_folders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.storage_folders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    job_id uuid,
    folder_kind text NOT NULL,
    storage_provider text DEFAULT 'pending_drive'::text NOT NULL,
    external_folder_id text,
    status text DEFAULT 'Pending Drive Creation'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT storage_folders_folder_kind_check CHECK ((folder_kind = ANY (ARRAY['commercial'::text, 'receiving'::text, 'production'::text, 'delivery'::text, 'payments'::text, 'issue_review'::text, 'other'::text]))),
    CONSTRAINT storage_folders_status_check CHECK ((status = ANY (ARRAY['Pending Drive Creation'::text, 'Creating'::text, 'Ready'::text, 'Create Failed'::text, 'Retry Required'::text, 'Archived'::text]))),
    CONSTRAINT storage_folders_storage_provider_check CHECK ((storage_provider = ANY (ARRAY['pending_drive'::text, 'google_drive'::text])))
);


ALTER TABLE public.storage_folders OWNER TO postgres;

