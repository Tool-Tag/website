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
-- Name: job_payment_snapshot(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.job_payment_snapshot(p_job uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select jsonb_build_object(
    'grand_total',coalesce(t.grand_total,0),
    'collected',coalesce(t.collected,0),
    'balance_due',coalesce(t.balance_due,0),
    'paid_in_full',coalesce(t.balance_due,0)=0,
    'request',(
      select jsonb_build_object(
        'id',r.id,
        'method',r.method,
        'amount',r.amount,
        'status',r.status,
        'submitted_at',r.submitted_at,
        'confirmed_at',r.confirmed_at,
        'confirmed_amount',r.confirmed_amount
      )
      from public.payment_requests r
      where r.job_id=p_job
      order by r.submitted_at desc
      limit 1
    ),
    'methods',jsonb_build_object(
      'cash',true,
      'zelle_email',(select zelle_email from public.unit_settings where unit_id=j.unit_id),
      'venmo_handle',(select venmo_handle from public.unit_settings where unit_id=j.unit_id)
    )
  )
  from public.jobs j
  left join public.job_commercial_totals t on t.id=j.id
  where j.id=p_job;
$$;


ALTER FUNCTION private.job_payment_snapshot(p_job uuid) OWNER TO postgres;

--
-- Name: movement_integrity(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.movement_integrity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if NEW.type='COLLECTION' and (NEW.payment_method is null or NEW.payment_method not in ('Cash','Zelle','Venmo')) then raise exception 'Choose Cash, Zelle or Venmo'; end if;
 if NEW.account_id is not null and not exists(select 1 from public.accounts where id=NEW.account_id and active) then raise exception 'Account inactive'; end if;
 return NEW;
end $$;


ALTER FUNCTION private.movement_integrity() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: receipt_after_collection(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.receipt_after_collection() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  jid uuid;
  ref text;
begin
  select reference into ref from public.transactions where id=NEW.transaction_id;
  if ref like 'PAYREQ:%' then return NEW; end if;

  select coalesce(s.job_id,x.job_id) into jid
  from public.sales s
  left join public.job_extensions x on x.sale_id=s.transaction_id
  where s.transaction_id=NEW.sale_id;

  if exists(
    select 1
    from public.jobs
    where id=jid
      and unit_id='10000000-0000-0000-0000-000000000002'
      and status in ('Delivered – Pending Customer Acceptance','Completed','Issue / Review')
  ) then
    perform public.generate_job_receipt(jid);
  end if;

  return NEW;
end $$;


ALTER FUNCTION private.receipt_after_collection() OWNER TO postgres;

--
-- Name: record_movement(jsonb); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.record_movement(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid; typ text:=p->>'type'; tid uuid; amt numeric(14,2):=(p->>'amount')::numeric;
 a uuid:=(p->>'account_id')::uuid; cat public.categories; original public.transactions; due numeric; rec record; remaining numeric; alloc numeric; sale public.transactions;
begin
 perform private.require_admin(u);
 perform 1 from public.business_units where id=u for update; -- serialize unit financial mutations
 perform set_config('app.change_reason',coalesce(p->>'reason',''),true);
 if typ not in ('COLLECTION','EXPENSE','OWNER_INJECTION','OWNER_DRAW','INTER_UNIT_TRANSFER','REFUND') then raise exception 'Unsupported movement'; end if;
 if amt is null or amt<=0 or (p->>'amount')::numeric<>amt then raise exception 'Positive amount with at most two decimal places required'; end if;
 if typ='EXPENSE' then
 select * into cat from public.categories where id=(p->>'category_id')::uuid and kind='expense' and active and (unit_id=u or unit_id is null);
 if cat.id is null or nullif(trim(p->>'vendor'),'') is null then raise exception 'Expense category and vendor required'; end if;
 end if;
 if typ='COLLECTION' and nullif(p->>'sale_id','') is not null then
 select t.* into sale from public.transactions t join public.sales s on s.transaction_id=t.id where t.id=(p->>'sale_id')::uuid and t.unit_id=u and t.status<>'Voided' for update of t;
 if sale.id is null then raise exception 'Sale not found'; end if;
 select balance_due into due from public.sale_balances where transaction_id=sale.id;
 if amt>due then raise exception 'Collection exceeds outstanding sale balance'; end if;
 if p->>'payment_method' not in ('Cash','Zelle','Venmo') or p->>'payment_method' is null then raise exception 'Choose Cash, Zelle or Venmo'; end if;
 end if;
 if typ='OWNER_DRAW' and p->>'subtype'='Reimbursement' then
 select coalesce(sum(reimbursement_due),0) into due from public.expense_details where unit_id=u and paid_by='Owner';
 if amt>due then raise exception 'Reimbursement exceeds outstanding amount'; end if;
 end if;
 if typ='REFUND' then
 select * into original from public.transactions where id=(p->>'original_id')::uuid and unit_id=u and status<>'Voided' for update;
 if original.id is null or original.type not in ('COLLECTION','EXPENSE') then raise exception 'Refund must link to a collection or expense'; end if;
 select original.amount-coalesce(sum(t.amount),0) into due from public.refunds r join public.transactions t on t.id=r.transaction_id where r.original_id=original.id and t.status<>'Voided';
 if original.type='EXPENSE' then
 if exists(select 1 from public.expenses where transaction_id=original.id and paid_by='Owner') then
 select reimbursement_due into due from public.expense_details where transaction_id=original.id;
 end if; end if;
 if amt>due then raise exception 'Refund exceeds eligible amount paid (or owner amount outstanding)'; end if;
 if original.type='COLLECTION' and coalesce((p->>'transaction_date')::date,current_date)>original.transaction_date+14 and nullif(trim(p->>'reason'),'') is null then raise exception 'Refund outside 14 days requires admin reason'; end if;
 end if;
 if typ='INTER_UNIT_TRANSFER' then
 perform private.require_admin((p->>'destination_unit_id')::uuid);
 if not exists(select 1 from public.accounts s join public.accounts d on d.physical_account_id=s.physical_account_id where s.id=a and s.unit_id=u and d.id=(p->>'destination_account_id')::uuid and d.unit_id=(p->>'destination_unit_id')::uuid and s.unit_id<>d.unit_id) then raise exception 'Allocation transfer requires two units sharing the same physical bank'; end if;
 end if;
 insert into public.transactions(unit_id,type,transaction_date,amount,account_id,category_id,customer_id,vendor,description,payment_method,reference,created_by)
 values(u,typ,coalesce((p->>'transaction_date')::date,current_date),amt,a,nullif(p->>'category_id','')::uuid,coalesce(sale.customer_id,nullif(p->>'customer_id','')::uuid),p->>'vendor',p->>'description',nullif(p->>'payment_method',''),p->>'reference',auth.uid()) returning id into tid;
 if typ='EXPENSE' then
 insert into public.expenses(transaction_id,unit_id,paid_by,lodging) values(tid,u,coalesce(p->>'paid_by','Business'),coalesce((p->>'lodging')::boolean,false));
 insert into public.vendors(unit_id,name) values(u,trim(p->>'vendor')) on conflict do nothing;
 elsif typ='COLLECTION' then
 insert into public.collections values(tid,u,nullif(p->>'sale_id','')::uuid);
 insert into public.documents(unit_id,type,file_name,transaction_id,customer_id,content_snapshot,uploaded_by)
 values(u,'Payment Receipt','Receipt-'||tid||'.json',tid,sale.customer_id,
 jsonb_build_object('amount',amt,'payment_method',p->>'payment_method','date',coalesce((p->>'transaction_date')::date,current_date),'sale_id',sale.id,
 'sale_total',sale.amount,'sale_code',(select code from public.sales where transaction_id=sale.id),'job_id',(select job_id from public.sales where transaction_id=sale.id),
 'paid_to_date',(select collected from public.sale_balances where transaction_id=sale.id),'balance_remaining',(select balance_due from public.sale_balances where transaction_id=sale.id)),auth.uid());
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values(u,'Payment receipt',tid,'payment:'||tid,jsonb_build_object('sale_id',sale.id));
 if exists(select 1 from public.sale_balances where transaction_id=sale.id and status='Paid') then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(u,'Final Paid receipt',sale.id,'paid:'||tid);
 end if;
 elsif typ in ('OWNER_INJECTION','OWNER_DRAW') then
 insert into public.owner_transactions values(tid,u,case when typ='OWNER_INJECTION' then 'Injection' else coalesce(p->>'subtype','Personal Draw') end);
 if p->>'subtype'='Reimbursement' then
 remaining:=amt;
 for rec in select * from public.expense_details where unit_id=u and paid_by='Owner' and reimbursement_due>0 order by transaction_date,transaction_id loop
 alloc:=least(remaining,rec.reimbursement_due);
 insert into public.reimbursements values(tid,rec.transaction_id,u,alloc); remaining:=remaining-alloc;
 exit when remaining=0;
 end loop;
 end if;
 elsif typ='INTER_UNIT_TRANSFER' then insert into public.inter_unit_transfers values(tid,u,(p->>'destination_unit_id')::uuid,(p->>'destination_account_id')::uuid);
 elsif typ='REFUND' then insert into public.refunds values(tid,u,original.id,case when original.type='COLLECTION' then 'Customer Refund' else 'Vendor Refund' end,p->>'reason');
 end if;
 return tid;
end $$;


ALTER FUNCTION private.record_movement(p jsonb) OWNER TO postgres;

--
-- Name: sync_job_receipt_metadata(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.sync_job_receipt_metadata() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  cid uuid;
begin
  select x.* into j
  from public.jobs x
  where x.id=new.job_id;

  select f.customer_id into cid
  from public.commercial_flows f
  where f.id=j.flow_id;

  insert into public.documents(
    unit_id,type,file_name,original_file_name,mime_type,sha256,
    visibility,status,storage_provider,storage_status,folder_kind,
    customer_id,quote_id,job_id,job_receipt_id,content_snapshot,logical_key
  )
  values(
    new.unit_id,'Final Receipt',j.code||'-Final-Receipt.pdf',
    j.code||'-Final-Receipt.pdf','application/pdf',new.snapshot_sha256,
    'customer','Available','pending_drive',
    coalesce(new.storage_status,'Pending Drive Upload'),'payments',
    cid,j.quote_id,j.id,new.id,new.snapshot,'final-receipt:'||new.id::text
  )
  on conflict(unit_id,logical_key) do nothing;

  return new;
end
$$;


ALTER FUNCTION private.sync_job_receipt_metadata() OWNER TO postgres;

--
-- Name: sync_payment_work_stage(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.sync_payment_work_stage() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare jid uuid;
begin
  if tg_table_name='payment_requests' then
    jid:=new.job_id;
    if new.status='Pending Verification' then
      update public.jobs set work_stage='Payment Verification',updated_at=now() where id=jid;
    elsif new.status='Confirmed' then
      if exists(select 1 from public.job_commercial_totals where id=jid and balance_due=0) then
        update public.jobs set work_stage='Closed',updated_at=now() where id=jid;
      else
        update public.jobs set work_stage='Payment',updated_at=now() where id=jid;
      end if;
    end if;
  end if;
  return new;
end $$;


ALTER FUNCTION private.sync_payment_work_stage() OWNER TO postgres;

--
-- Name: confirm_payment_request(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.confirm_payment_request(p_id uuid) RETURNS jsonb
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


ALTER FUNCTION public.confirm_payment_request(p_id uuid) OWNER TO postgres;

--
-- Name: create_asset(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_asset(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid; eid uuid:=nullif(p->>'source_expense_id','')::uuid; aid uuid;
begin
 perform private.require_admin(u);
 if p->>'origin'='Purchased' then
 perform 1 from public.expenses where transaction_id=eid and unit_id=u for update;
 if not exists(select 1 from public.expense_details where transaction_id=eid and unit_id=u and is_equipment and linked_asset_id is null) then raise exception 'Choose an unlinked equipment expense'; end if;
 end if;
 if not exists(select 1 from public.categories where id=(p->>'category_id')::uuid and kind='asset' and (unit_id=u or unit_id is null) and active) then raise exception 'Asset category required'; end if;
 insert into public.assets(unit_id,source_expense_id,origin,name,category_id,serial_number,warranty_expiration,notes,estimated_value,donated_by,received_date)
 values(u,eid,p->>'origin',p->>'name',(p->>'category_id')::uuid,p->>'serial_number',nullif(p->>'warranty_expiration','')::date,p->>'notes',nullif(p->>'estimated_value','')::numeric,nullif(p->>'donated_by',''),nullif(p->>'received_date','')::date) returning id into aid;
 if eid is not null then update public.expenses set linked_asset_id=aid where transaction_id=eid; end if;
 return aid;
end $$;


ALTER FUNCTION public.create_asset(p jsonb) OWNER TO postgres;

--
-- Name: generate_job_receipt(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_job_receipt(p_job uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  snap jsonb;
  rid uuid;
  fingerprint text;
  recipient text;
begin
  select * into j from public.jobs where id=p_job for update;
  perform private.require_admin(j.unit_id);

  snap:=private.job_portal_snapshot(j.id)-'evidence'-'status';

  snap:=snap||jsonb_build_object(
    'payments',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',p.payment_key,
          'date',p.transaction_date,
          'amount',p.amount,
          'method',p.payment_method,
          'reference',p.customer_reference
        )
        order by p.transaction_date,p.first_created_at
      )
      from (
        select
          case
            when coalesce(t.reference,'') like 'PAYREQ:%' then t.reference
            else t.id::text
          end as payment_key,
          min(t.transaction_date) as transaction_date,
          min(t.created_at) as first_created_at,
          sum(t.amount) as amount,
          max(t.payment_method) as payment_method,
          case
            when bool_or(coalesce(t.reference,'') like 'PAYREQ:%') then null
            else max(t.reference)
          end as customer_reference
        from public.collections c
        join public.transactions t on t.id=c.transaction_id
        where t.status<>'Voided'
          and c.sale_id in (
            select transaction_id from public.sales where job_id=j.id
            union
            select sale_id from public.job_extensions
            where job_id=j.id and accepted_at is not null
          )
        group by case
          when coalesce(t.reference,'') like 'PAYREQ:%' then t.reference
          else t.id::text
        end
      ) p
    ),'[]'::jsonb),
    'paid_in_full',
    coalesce(
      (snap->'totals'->>'balance_due')::numeric=0
      and (snap->'totals'->>'refunded')::numeric=0,
      false
    ),
    'paid_in_full_date',
    case
      when (snap->'totals'->>'balance_due')::numeric=0
       and (snap->'totals'->>'refunded')::numeric=0
      then (
        select max(t.transaction_date)
        from public.collections c
        join public.transactions t on t.id=c.transaction_id
        where t.status<>'Voided'
          and c.sale_id in (
            select transaction_id from public.sales where job_id=j.id
            union
            select sale_id from public.job_extensions
            where job_id=j.id and accepted_at is not null
          )
      )
    end
  );

  fingerprint:=encode(sha256(convert_to(snap::text,'UTF8')),'hex');

  insert into public.job_receipts(unit_id,job_id,snapshot,snapshot_sha256)
  values(j.unit_id,j.id,snap,fingerprint)
  on conflict(job_id,snapshot_sha256) do nothing
  returning id into rid;

  if rid is null then
    select id into rid
    from public.job_receipts
    where job_id=j.id and snapshot_sha256=fingerprint;
    return rid;
  end if;

  select coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email')
  into recipient
  from public.agreements a
  left join public.accepted_documents d on d.agreement_id=a.id
  where a.quote_id=j.quote_id;

  insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
  values(
    j.unit_id,
    'FINAL_PAID_RECEIPT',
    rid,
    recipient,
    'job-receipt:'||rid,
    jsonb_build_object('template','job_receipt','receipt_id',rid)
  );

  return rid;
end $$;


ALTER FUNCTION public.generate_job_receipt(p_job uuid) OWNER TO postgres;

--
-- Name: public_submit_payment_request(text, uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_submit_payment_request(p_token text, p_request uuid, p_method text, p_proof_path text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  j public.jobs;
  due numeric(14,2);
  existing public.payment_requests;
  rid uuid;
  zelle text;
  venmo text;
begin
  select x.* into j
  from public.jobs x
  join private.public_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and l.expires_at>now()
  for update of x;

  if j.id is null then raise exception 'Invalid or expired link'; end if;

  if not exists(select 1 from public.delivery_acknowledgments where job_id=j.id) then
    raise exception 'Confirm delivery before choosing payment';
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
    select 1
    from public.payment_requests
    where job_id=j.id and status='Pending Verification'
  ) then
    raise exception 'A payment is already awaiting verification';
  end if;

  select balance_due into due
  from public.job_commercial_totals
  where id=j.id;

  if coalesce(due,0)<=0 then
    raise exception 'This job is already paid in full';
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
         select 1
         from storage.objects o
         where o.bucket_id='payment-proofs'
           and o.name=p_proof_path
       )
    then
      raise exception 'Payment proof was not found';
    end if;
  end if;

  insert into public.payment_requests(
    request_key,unit_id,job_id,method,amount,proof_path
  )
  values(p_request,j.unit_id,j.id,p_method,due,p_proof_path)
  returning id into rid;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,
    'PAYMENT_SUBMITTED',
    rid,
    'payments@tooltag.martinlab.studio',
    'payment-request:'||rid,
    jsonb_build_object(
      'template','notification',
      'subject','Payment Submitted — '||j.code||' — '||p_method,
      'text',
        'Job: '||j.code
        ||E'\nAmount: $'||to_char(due,'FM999999990.00')
        ||E'\nPayment method: '||p_method
        ||E'\nStatus: Pending Verification'
        ||case
            when p_method in ('Zelle','Venmo') then E'\nPayment proof: Uploaded'
            else ''
          end,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'id',rid,
    'status','Pending Verification',
    'method',p_method,
    'amount',due
  );
end $_$;


ALTER FUNCTION public.public_submit_payment_request(p_token text, p_request uuid, p_method text, p_proof_path text) OWNER TO postgres;

--
-- Name: record_mileage(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.record_mileage(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid; mid uuid;
begin
 perform private.require_admin(u);
 insert into public.mileage(unit_id,date,purpose,origin,destination,miles,notes) values(u,(p->>'date')::date,p->>'purpose',p->>'origin',p->>'destination',(p->>'miles')::numeric,p->>'notes') returning id into mid;
 return mid;
end $$;


ALTER FUNCTION public.record_mileage(p jsonb) OWNER TO postgres;

--
-- Name: record_movement(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.record_movement(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid; key uuid:=coalesce(nullif(p->>'request_id','')::uuid,gen_random_uuid());
 fingerprint text:=encode(sha256(convert_to((p-'request_id')::text,'UTF8')),'hex'); prior private.mutation_requests; tid uuid;
begin
 perform private.require_admin(u);
 perform 1 from public.business_units where id=u for update;
 select * into prior from private.mutation_requests where unit_id=u and request_id=key;
 if found then
 if prior.payload_hash<>fingerprint then raise exception 'This request identifier was already used for different information'; end if;
 return prior.transaction_id;
 end if;
 tid:=private.record_movement(p);
 insert into private.mutation_requests values(u,key,fingerprint,tid);
 return tid;
end $$;


ALTER FUNCTION public.record_movement(p jsonb) OWNER TO postgres;

--
-- Name: accounts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    physical_account_id uuid NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true NOT NULL
);


ALTER TABLE public.accounts OWNER TO postgres;

--
-- Name: assets; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.assets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    source_expense_id uuid,
    origin text NOT NULL,
    name text NOT NULL,
    category_id uuid,
    serial_number text,
    warranty_expiration date,
    status text DEFAULT 'Active'::text NOT NULL,
    notes text,
    estimated_value numeric(14,2),
    donated_by text,
    received_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT assets_check CHECK ((((origin = 'Purchased'::text) AND (source_expense_id IS NOT NULL) AND (estimated_value IS NULL)) OR ((origin = 'Donated'::text) AND (source_expense_id IS NULL) AND (estimated_value IS NOT NULL) AND (donated_by IS NOT NULL) AND (received_date IS NOT NULL)))),
    CONSTRAINT assets_estimated_value_check CHECK ((estimated_value >= (0)::numeric)),
    CONSTRAINT assets_origin_check CHECK ((origin = ANY (ARRAY['Purchased'::text, 'Donated'::text]))),
    CONSTRAINT assets_status_check CHECK ((status = ANY (ARRAY['Active'::text, 'Repair'::text, 'Retired'::text])))
);


ALTER TABLE public.assets OWNER TO postgres;

--
-- Name: transactions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    type text NOT NULL,
    transaction_date date DEFAULT CURRENT_DATE NOT NULL,
    amount numeric(14,2) NOT NULL,
    account_id uuid,
    category_id uuid,
    customer_id uuid,
    vendor text,
    description text NOT NULL,
    payment_method text,
    reference text,
    status text DEFAULT 'Active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT transactions_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT transactions_check CHECK (((type = 'SALE'::text) OR (account_id IS NOT NULL))),
    CONSTRAINT transactions_description_check CHECK ((length(TRIM(BOTH FROM description)) > 0)),
    CONSTRAINT transactions_payment_method_check CHECK ((payment_method = ANY (ARRAY['Cash'::text, 'Zelle'::text, 'Venmo'::text, 'Bank Transfer'::text, 'Card'::text, 'Other'::text]))),
    CONSTRAINT transactions_status_check CHECK ((status = ANY (ARRAY['Active'::text, 'Voided'::text, 'Archived'::text]))),
    CONSTRAINT transactions_type_check CHECK ((type = ANY (ARRAY['SALE'::text, 'COLLECTION'::text, 'EXPENSE'::text, 'OWNER_INJECTION'::text, 'OWNER_DRAW'::text, 'INTER_UNIT_TRANSFER'::text, 'REFUND'::text])))
);


ALTER TABLE public.transactions OWNER TO postgres;

--
-- Name: categories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid,
    name text NOT NULL,
    kind text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    is_equipment boolean DEFAULT false NOT NULL,
    is_fuel boolean DEFAULT false NOT NULL,
    is_mileage boolean DEFAULT false NOT NULL,
    CONSTRAINT categories_kind_check CHECK ((kind = ANY (ARRAY['income'::text, 'expense'::text, 'asset'::text])))
);


ALTER TABLE public.categories OWNER TO postgres;

--
-- Name: collections; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.collections (
    transaction_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    sale_id uuid
);


ALTER TABLE public.collections OWNER TO postgres;

--
-- Name: commercial_flows; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.commercial_flows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    year integer NOT NULL,
    sequence integer NOT NULL
);


ALTER TABLE public.commercial_flows OWNER TO postgres;

--
-- Name: expenses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.expenses (
    transaction_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    paid_by text NOT NULL,
    lodging boolean DEFAULT false NOT NULL,
    linked_asset_id uuid,
    CONSTRAINT expenses_paid_by_check CHECK ((paid_by = ANY (ARRAY['Business'::text, 'Owner'::text])))
);


ALTER TABLE public.expenses OWNER TO postgres;

--
-- Name: refunds; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.refunds (
    transaction_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    original_id uuid NOT NULL,
    subtype text NOT NULL,
    override_reason text,
    CONSTRAINT refunds_subtype_check CHECK ((subtype = ANY (ARRAY['Customer Refund'::text, 'Vendor Refund'::text])))
);


ALTER TABLE public.refunds OWNER TO postgres;

--
-- Name: reimbursements; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.reimbursements (
    transaction_id uuid NOT NULL,
    expense_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    amount numeric(14,2) NOT NULL,
    CONSTRAINT reimbursements_amount_check CHECK ((amount > (0)::numeric))
);


ALTER TABLE public.reimbursements OWNER TO postgres;

--
-- Name: inter_unit_transfers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inter_unit_transfers (
    transaction_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    destination_unit_id uuid NOT NULL,
    destination_account_id uuid NOT NULL,
    CONSTRAINT inter_unit_transfers_check CHECK ((unit_id <> destination_unit_id))
);


ALTER TABLE public.inter_unit_transfers OWNER TO postgres;

--
-- Name: sales; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sales (
    transaction_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    job_id uuid,
    quote_id uuid,
    code text NOT NULL,
    approved_items jsonb DEFAULT '[]'::jsonb NOT NULL,
    revision integer DEFAULT 1 NOT NULL
);


ALTER TABLE public.sales OWNER TO postgres;

--
-- Name: job_receipts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.job_receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    job_id uuid NOT NULL,
    snapshot jsonb NOT NULL,
    snapshot_sha256 text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    storage_status text DEFAULT 'Pending Drive Upload'::text NOT NULL
);


ALTER TABLE public.job_receipts OWNER TO postgres;

--
-- Name: mileage; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.mileage (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    date date NOT NULL,
    purpose text NOT NULL,
    origin text NOT NULL,
    destination text NOT NULL,
    miles numeric(10,2) NOT NULL,
    notes text,
    CONSTRAINT mileage_miles_check CHECK ((miles > (0)::numeric))
);


ALTER TABLE public.mileage OWNER TO postgres;

--
-- Name: monthly_closes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.monthly_closes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    month date NOT NULL,
    version integer NOT NULL,
    status text NOT NULL,
    snapshot jsonb NOT NULL,
    warnings jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT monthly_closes_month_check CHECK ((EXTRACT(day FROM month) = (1)::numeric)),
    CONSTRAINT monthly_closes_status_check CHECK ((status = ANY (ARRAY['Current'::text, 'Superseded'::text, 'Reclose Required'::text, 'Documentation Updated'::text])))
);


ALTER TABLE public.monthly_closes OWNER TO postgres;

--
-- Name: owner_transactions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.owner_transactions (
    transaction_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    subtype text NOT NULL,
    CONSTRAINT owner_transactions_subtype_check CHECK ((subtype = ANY (ARRAY['Injection'::text, 'Personal Draw'::text, 'Reimbursement'::text])))
);


ALTER TABLE public.owner_transactions OWNER TO postgres;

--
-- Name: payment_requests; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_key uuid NOT NULL,
    unit_id uuid NOT NULL,
    job_id uuid NOT NULL,
    method text NOT NULL,
    amount numeric(14,2) NOT NULL,
    status text DEFAULT 'Pending Verification'::text NOT NULL,
    proof_path text,
    submitted_at timestamp with time zone DEFAULT now() NOT NULL,
    confirmed_at timestamp with time zone,
    confirmed_by uuid,
    confirmed_amount numeric(14,2),
    transaction_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    purpose text DEFAULT 'Final Balance'::text NOT NULL,
    CONSTRAINT payment_requests_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payment_requests_method_check CHECK ((method = ANY (ARRAY['Cash'::text, 'Zelle'::text, 'Venmo'::text]))),
    CONSTRAINT payment_requests_purpose_check CHECK ((purpose = ANY (ARRAY['Final Balance'::text, 'Pickup Fee'::text, 'Cancellation Balance'::text]))),
    CONSTRAINT payment_requests_status_check CHECK ((status = ANY (ARRAY['Pending Verification'::text, 'Confirmed'::text, 'Rejected'::text, 'Cancelled'::text])))
);


ALTER TABLE public.payment_requests OWNER TO postgres;

--
-- Name: physical_accounts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.physical_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    currency text DEFAULT 'USD'::text NOT NULL,
    reconciled_balance numeric(14,2),
    reconciled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT physical_accounts_currency_check CHECK ((currency = 'USD'::text))
);


ALTER TABLE public.physical_accounts OWNER TO postgres;

--
-- Name: sale_versions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sale_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    sale_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    revision integer NOT NULL,
    amount numeric(14,2) NOT NULL,
    approved_items jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.sale_versions OWNER TO postgres;

--
-- Name: vendors; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.vendors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    name text NOT NULL
);


ALTER TABLE public.vendors OWNER TO postgres;

