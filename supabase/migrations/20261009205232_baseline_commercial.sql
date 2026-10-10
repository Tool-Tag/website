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
-- Name: active_customer_services(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.active_customer_services(p_customer uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select
    exists(
      select 1
      from public.commercial_flows f
      join public.quotes q on q.flow_id=f.id
      where f.customer_id=p_customer
        and q.status in ('Sent','Viewed','Agreement Pending')
        and q.expires_at>now()
    )
    or exists(
      select 1
      from public.commercial_flows f
      join public.jobs j on j.flow_id=f.id
      where f.customer_id=p_customer
        and j.status not in ('Completed','Cancelled')
    );
$$;


ALTER FUNCTION private.active_customer_services(p_customer uuid) OWNER TO postgres;

--
-- Name: cancellation_link_customer(text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.cancellation_link_customer(p_token text) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select l.customer_id
  from private.cancellation_access_links l
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and l.expires_at>now()
  order by l.created_at desc
  limit 1;
$$;


ALTER FUNCTION private.cancellation_link_customer(p_token text) OWNER TO postgres;

--
-- Name: commercial_immutable(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.commercial_immutable() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 raise exception 'Historical commercial record is immutable; create a revision';
end $$;


ALTER FUNCTION private.commercial_immutable() OWNER TO postgres;

--
-- Name: create_pick_return_order_from_agreement(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.create_pick_return_order_from_agreement() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
      'action_path','/pickup/'||token||'/payment',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $_$;


ALTER FUNCTION private.create_pick_return_order_from_agreement() OWNER TO postgres;

--
-- Name: freeze_accepted_document(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.freeze_accepted_document(p_quote uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare a public.agreements; q public.quotes; j public.jobs; c public.customers; sale uuid; snap jsonb; folio text; y integer; seq bigint; doc uuid; recipient text; company jsonb; phase text;
begin
 select * into q from public.quotes where id=p_quote for update;
 if q.unit_id<>'10000000-0000-0000-0000-000000000002' then return; end if;
 if exists(select 1 from public.accepted_documents where quote_id=p_quote) then return; end if;
 select * into a from public.agreements where quote_id=p_quote;
 if a.id is null then raise exception 'Completed acceptance required'; end if;
 select * into j from public.jobs where id=a.job_id;
 select * into c from public.customers where id=a.customer_id;
 select transaction_id into sale from public.sales where job_id=j.id;
 select coalesce(d.recipient,a.commercial_snapshot->>'customer_email') into recipient from private.quote_delivery d where d.quote_id=p_quote;
 recipient:=coalesce(recipient,a.commercial_snapshot->>'customer_email',a.accepted_email);
 company:=coalesce(a.commercial_snapshot->'company','{}'::jsonb);
 y:=extract(year from a.accepted_at at time zone (select timezone from public.unit_settings where unit_id=q.unit_id));
 insert into private.agreement_sequences(year,value) values(y,1) on conflict(year) do update set value=private.agreement_sequences.value+1 returning value into seq;
 folio:='TT-AGR-'||y||'-'||case when seq<100000 then lpad(seq::text,5,'0') else seq::text end;
 snap:=a.commercial_snapshot||jsonb_build_object(
 'schema_version',1,'acceptance_folio',folio,'customer_name',a.accepted_name,'company',company,
 'customer_email',recipient,'quote_recipient_selection',jsonb_build_object('email',recipient,'kind',case when lower(recipient)=lower(coalesce(company->>'email','')) then 'company' else 'personal' end),
 'accepted_contact_email',a.accepted_email,'customer_phone',a.accepted_phone,
 'quote_id',q.id,'quote_code',q.code,'quote_revision',q.revision,'job_id',j.id,'job_code',j.code,'sale_id',sale,
 'sale_code',(select code from public.sales where transaction_id=sale),
 'quote_accepted_at',q.accepted_at,'agreement_accepted_at',a.accepted_at,
 'agreement',jsonb_build_object('id',a.policy_id,'title',a.commercial_snapshot->'policy'->>'title','version',a.commercial_snapshot->'policy'->'version','text',a.content_snapshot),
 'confirmations',jsonb_build_object('quote',true,'agreement',true),
 'identity',jsonb_build_object('brand','ToolTag','legal','ToolTag is a registered DBA of Bandits of the Framing LLC.'),
 'previous_document_id',(select d.id from public.accepted_documents d join public.quotes oldq on oldq.id=d.quote_id where oldq.flow_id=q.flow_id order by d.accepted_at desc limit 1));
 insert into public.accepted_documents(unit_id,agreement_id,customer_id,quote_id,job_id,sale_id,acceptance_folio,agreement_version,accepted_at,customer_recipient_email,file_name,snapshot,canonical_snapshot,acceptance_snapshot_sha256)
 values(q.unit_id,a.id,a.customer_id,q.id,j.id,sale,folio,(snap->'agreement'->>'version')::integer,a.accepted_at,recipient,folio||'_'||q.code||'_Agreement.pdf',snap,snap::text,encode(sha256(convert_to(snap::text,'UTF8')),'hex')) returning id into doc;
 phase:=case when exists(select 1 from private.customer_mail_activation where unit_id=q.unit_id) then 'production' else 'test' end;
 insert into public.accepted_document_status(document_id,unit_id,mail_phase) values(doc,q.unit_id,phase);
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(q.unit_id,'Accepted Agreement Customer Copy',q.id,case when phase='production' then recipient else 'quotes@tooltag.martinlab.studio' end,'accepted-'||phase||':'||doc||':customer',jsonb_build_object('template','accepted_pdf','document_id',doc,'copy','customer','test',phase='test')),
       (q.unit_id,'Accepted Agreement ToolTag Copy',q.id,'quotes@tooltag.martinlab.studio','accepted-'||phase||':'||doc||':internal',jsonb_build_object('template','accepted_pdf','document_id',doc,'copy','internal','test',phase='test'));
end $$;


ALTER FUNCTION private.freeze_accepted_document(p_quote uuid) OWNER TO postgres;

--
-- Name: job_customer_recipient(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.job_customer_recipient(p_job uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


ALTER FUNCTION private.job_customer_recipient(p_job uuid) OWNER TO postgres;

--
-- Name: notify_customer_stage_change(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.notify_customer_stage_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  token_value text;
  recipient_value text;
  subject_value text;
  text_value text;
begin
  if old.customer_stage is not distinct from new.customer_stage then
    return new;
  end if;

  -- In Process gets the original Job Status email.
  -- Completed gets the dedicated Accept Delivery email.
  if new.customer_stage not in ('Engraving','Final Details') then
    return new;
  end if;

  token_value:=private.ensure_job_status_link(new.id);

  select coalesce(
    d.customer_recipient_email,
    a.accepted_email,
    a.commercial_snapshot->>'customer_email'
  )
  into recipient_value
  from public.agreements a
  left join public.accepted_documents d on d.agreement_id=a.id
  where a.job_id=new.id
  order by a.accepted_at desc
  limit 1;

  if nullif(trim(recipient_value),'') is null then
    return new;
  end if;

  if new.customer_stage='Engraving' then
    subject_value:='ToolTag Job Update — Engraving — '||new.code;
    text_value:='Your ToolTag Job has moved to the engraving stage. Use your private Job Status link to follow the progress.';
  else
    subject_value:='ToolTag Job Update — Final Details — '||new.code;
    text_value:='Your ToolTag Job is in final details and quality review. Use your private Job Status link to follow the progress.';
  end if;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    new.unit_id,
    'JOB_STATUS_UPDATE',
    new.id,
    recipient_value,
    'job-status-stage:'||new.id||':'||lower(replace(new.customer_stage,' ','-')),
    jsonb_build_object(
      'template','notification',
      'subject',subject_value,
      'text',text_value,
      'action_path','/status/'||token_value,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $$;


ALTER FUNCTION private.notify_customer_stage_change() OWNER TO postgres;

--
-- Name: priced_scope(jsonb); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.priced_scope(p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  result jsonb:='[]';
  item_json jsonb;
  mark_json jsonb;
  qty integer;
  cnt integer;
  extra numeric;
  paint numeric;
  base numeric;
  idx integer:=0;
  logos integer;
begin
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Add at least one item';
  end if;

  for item_json in select value from jsonb_array_elements(p_items) loop
    qty:=(item_json->>'quantity')::integer;
    base:=(item_json->>'unit_price')::numeric;

    if qty is null or qty<1 or qty>10000 or base is null or base<0 or base<>round(base,2)
       or nullif(trim(item_json->>'article'),'') is null then
      raise exception 'Invalid quantity, article or base price';
    end if;

    if coalesce(item_json->>'engraving_type','') not in ('Fee','Text','Image / Logo') then
      raise exception 'Invalid engraving type';
    end if;

    cnt:=case
      when item_json->>'engraving_type'='Fee' then 0
      else jsonb_array_length(coalesce(item_json->'marks','[]'))
    end;

    if item_json->>'engraving_type'<>'Fee' and cnt<1 then
      raise exception 'Add engraving details';
    end if;

    paint:=0;

    for mark_json in
      select value from jsonb_array_elements(coalesce(item_json->'marks','[]'))
    loop
      if item_json->>'engraving_type'='Fee' then exit; end if;

      if nullif(trim(mark_json->>'location'),'') is null
         or coalesce(mark_json->>'type','') not in ('Text','Image / Logo') then
        raise exception 'Engraving location and type required';
      end if;

      if mark_json->>'type'='Text' and nullif(trim(mark_json->>'text'),'') is null then
        raise exception 'Engraving text required';
      end if;

      if mark_json->>'type'='Image / Logo' and coalesce(mark_json->>'url','') !~ '^https?://' then
        raise exception 'Image link required';
      end if;

      if coalesce((mark_json->>'paint_fill')::boolean,false) then
        if coalesce(mark_json->'paint_details'->>'mode','') not in ('single','multiple')
           or (mark_json->'paint_details'->>'mode'='single'
               and nullif(trim(mark_json->'paint_details'->>'color'),'') is null)
           or (mark_json->'paint_details'->>'mode'='multiple'
               and nullif(trim(mark_json->'paint_details'->>'instructions'),'') is null) then
          raise exception 'Paint instructions required';
        end if;
        paint:=2;
      end if;
    end loop;

    extra:=greatest(cnt-1,0)*5;

    result:=result||jsonb_build_array(
      item_json||jsonb_build_object(
        'unit_price',base,
        'sort_order',idx,
        'adaptation_fee',false,
        'paint_fee',false,
        'additional_engraving_fee',false,
        'pricing',jsonb_build_object(
          'version',1,
          'engraving_count',cnt,
          'base_unit_price',base,
          'additional_engraving_unit_charge',extra,
          'additional_engraving_charge',extra*qty,
          'paint_unit_charge',paint,
          'paint_charge',paint*qty,
          'line_total',qty*(base+extra+paint)
        )
      )
    );
    idx:=idx+1;

    if extra>0 then
      result:=result||jsonb_build_array(
        jsonb_build_object(
          'article','Additional engravings · '||(item_json->>'article'),
          'quantity',qty*greatest(cnt-1,0),
          'unit_price',5,
          'engraving_type','Fee',
          'notes','First engraving included; $5 per additional engraving per item.',
          'sort_order',idx,
          'additional_engraving_fee',true
        )
      );
      idx:=idx+1;
    end if;

    if paint>0 then
      result:=result||jsonb_build_array(
        jsonb_build_object(
          'article','Paint fill · '||(item_json->>'article'),
          'quantity',qty,
          'unit_price',2,
          'engraving_type','Fee',
          'notes','$2 per painted item, regardless of the number of paint-filled engravings.',
          'sort_order',idx,
          'paint_fee',true
        )
      );
      idx:=idx+1;
    end if;
  end loop;

  select count(distinct trim(mark_elem->>'url'))
  into logos
  from jsonb_array_elements(p_items) as item_elem
  cross join lateral jsonb_array_elements(coalesce(item_elem->'marks','[]')) as mark_elem
  where item_elem->>'engraving_type'<>'Fee'
    and mark_elem->>'type'='Image / Logo';

  if logos>0 then
    result:=result||jsonb_build_array(
      jsonb_build_object(
        'article','Falcon image / logo adaptation',
        'quantity',logos,
        'unit_price',3,
        'engraving_type','Fee',
        'notes','$3 per unique design.',
        'adaptation_fee',true,
        'sort_order',idx
      )
    );
  end if;

  return result;
end
$_$;


ALTER FUNCTION private.priced_scope(p_items jsonb) OWNER TO postgres;

--
-- Name: protect_extension(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.protect_extension() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if TG_OP='DELETE' then raise exception 'Extension history cannot be deleted'; end if;
 if (NEW.id,NEW.job_id,NEW.unit_id,NEW.sequence,NEW.code,NEW.request_key,NEW.requested_at,NEW.customer_request) is distinct from (OLD.id,OLD.job_id,OLD.unit_id,OLD.sequence,OLD.code,OLD.request_key,OLD.requested_at,OLD.customer_request) then raise exception 'Extension identity is immutable'; end if;
 if OLD.status in ('Sent','Approved','Completed') and (NEW.scope,NEW.items,NEW.total) is distinct from (OLD.scope,OLD.items,OLD.total) then raise exception 'Sent extension scope is immutable; cancel an unaccepted proposal and create another extension'; end if;
 if OLD.accepted_at is not null and (NEW.accepted_at,NEW.accepted_snapshot,NEW.snapshot_sha256,NEW.sale_id) is distinct from (OLD.accepted_at,OLD.accepted_snapshot,OLD.snapshot_sha256,OLD.sale_id) then raise exception 'Accepted extension is immutable'; end if;
 if OLD.accepted_at is not null and NEW.status not in ('Approved','Completed') then raise exception 'Accepted extension cannot be cancelled'; end if;
 NEW.updated_at:=now(); return NEW;
end $$;


ALTER FUNCTION private.protect_extension() OWNER TO postgres;

--
-- Name: protect_quote_scope(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.protect_quote_scope() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare qid uuid;
begin
 if TG_TABLE_NAME='quotes' then
 if OLD.sent_at is not null and (NEW.flow_id,NEW.revision,NEW.code,NEW.notes,NEW.policy_id,NEW.sent_at,NEW.expires_at) is distinct from
 (OLD.flow_id,OLD.revision,OLD.code,OLD.notes,OLD.policy_id,OLD.sent_at,OLD.expires_at) then raise exception 'Sent quote scope is frozen; create a revision'; end if;
 if OLD.review_snapshot is not null and NEW.review_snapshot is distinct from OLD.review_snapshot then raise exception 'Quote snapshot is immutable'; end if;
 return NEW;
 end if;
 if TG_OP<>'INSERT' then
 if exists(select 1 from public.quotes where id=OLD.quote_id and sent_at is not null) then raise exception 'Sent quote items are immutable'; end if;
 end if;
 if TG_OP<>'DELETE' then
 qid:=NEW.quote_id;
 if exists(select 1 from public.quotes where id=qid and sent_at is not null) then raise exception 'Sent quote items are immutable'; end if;
 return NEW;
 end if;
 return OLD;
end $$;


ALTER FUNCTION private.protect_quote_scope() OWNER TO postgres;

--
-- Name: queue_commercial_events(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.queue_commercial_events() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if TG_TABLE_NAME='quotes' then
 if NEW.status='Sent' and NEW.revision>1 and OLD.status<>NEW.status then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(NEW.unit_id,'Revision requires acceptance',NEW.id,'revision:'||NEW.id) on conflict do nothing;
 end if;
 elsif TG_TABLE_NAME='jobs' and NEW.status in ('Completed','Issue / Review') and OLD.status<>NEW.status then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
 values(NEW.unit_id,case when NEW.status='Completed' then 'Final completion' else 'Customer reported issue' end,NEW.id,'job-final:'||NEW.id||':'||NEW.status,jsonb_build_object('reason',NEW.completion_reason)) on conflict do nothing;
 end if;
 return NEW;
end $$;


ALTER FUNCTION private.queue_commercial_events() OWNER TO postgres;

--
-- Name: quote_snapshot(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.quote_snapshot(p_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select jsonb_build_object('id',q.id,'code',q.code,'revision',q.revision,'notes',q.notes,'customer_id',c.id,
 'company',jsonb_build_object('name',c.company_name,'email',c.company_email,'phone',c.company_phone,'address',c.company_address),'customer_name',c.name,'customer_email',c.email,'customer_phone',c.phone,'expires_at',q.expires_at,
 'items',(select jsonb_agg(to_jsonb(i)-'unit_id' order by i.sort_order,i.id) from public.quote_items i where quote_id=q.id),
 'total',(select sum(quantity*unit_price) from public.quote_items where quote_id=q.id),
 'policy',jsonb_build_object('id',p.id,'title',p.title,'version',p.version,'content',p.content))
 from public.quotes q join public.commercial_flows f on f.id=q.flow_id join public.customers c on c.id=f.customer_id
 left join public.policies p on p.id=q.policy_id where q.id=p_id;
$$;


ALTER FUNCTION private.quote_snapshot(p_id uuid) OWNER TO postgres;

--
-- Name: sync_accepted_document_metadata(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.sync_accepted_document_metadata() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  insert into public.documents(
    unit_id,type,file_name,original_file_name,mime_type,sha256,
    visibility,status,storage_provider,storage_status,folder_kind,
    customer_id,quote_id,job_id,agreement_id,accepted_document_id,
    content_snapshot,logical_key
  )
  values(
    new.unit_id,'Accepted Agreement',new.file_name,new.file_name,
    'application/pdf',new.acceptance_snapshot_sha256,
    'customer','Available','pending_drive','Pending Drive Upload','commercial',
    new.customer_id,new.quote_id,new.job_id,new.agreement_id,new.id,
    new.snapshot,'accepted-agreement:'||new.id::text
  )
  on conflict(unit_id,logical_key) do nothing;

  return new;
end
$$;


ALTER FUNCTION private.sync_accepted_document_metadata() OWNER TO postgres;

--
-- Name: sync_customer_stage(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.sync_customer_stage() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.status in ('Ready for Delivery','Delivered – Pending Customer Acceptance','Completed')
     and old.status is distinct from new.status then
    new.customer_stage:='Completed';
  end if;
  return new;
end $$;


ALTER FUNCTION private.sync_customer_stage() OWNER TO postgres;

--
-- Name: accept_agreement(text, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.accept_agreement(p_token text, p_name text, p_email text, p_phone text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare q public.quotes; f public.commercial_flows; jid uuid; sid uuid; total numeric(14,2); items jsonb; pol public.policies;
begin
 select x.* into q from public.quotes x join private.public_links l on l.quote_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if q.id is null then raise exception 'Invalid or expired link'; end if;
 select job_id into jid from public.agreements where quote_id=q.id;
 if jid is not null then return jid; end if; -- retry-safe atomic creation
 if q.status<>'Agreement Pending' then raise exception 'Accept the quote first'; end if;
 if nullif(trim(p_name),'') is null or nullif(trim(p_email),'') is null or nullif(trim(p_phone),'') is null then raise exception 'Your name, email and phone are required'; end if;
 select * into f from public.commercial_flows where id=q.flow_id for update;
 if exists(select 1 from public.quotes where flow_id=f.id and revision>q.revision and status in ('Agreement Pending','Accepted')) then raise exception 'A newer revision has been accepted'; end if;
 select * into pol from public.policies where id=q.policy_id;
 select sum(quantity*unit_price),jsonb_agg(to_jsonb(i)) into total,items from public.quote_items i where quote_id=q.id;
 select id into jid from public.jobs where flow_id=f.id;
 if jid is null then
 insert into public.jobs(unit_id,flow_id,quote_id,code) values(q.unit_id,f.id,q.id,'TT-J-'||f.year||'-'||lpad(f.sequence::text,5,'0')) returning id into jid;
 insert into public.transactions(unit_id,type,transaction_date,amount,customer_id,description,category_id)
 values(q.unit_id,'SALE',(now() at time zone (select timezone from public.unit_settings where unit_id=q.unit_id))::date,total,f.customer_id,'Accepted quote '||q.code,(select id from public.categories where unit_id=q.unit_id and name='Engraving Services')) returning id into sid;
 insert into public.sales(transaction_id,unit_id,job_id,quote_id,code,approved_items,revision) values(sid,q.unit_id,jid,q.id,'TT-S-'||f.year||'-'||lpad(f.sequence::text,5,'0'),items,q.revision);
 else
 select transaction_id into sid from public.sales where job_id=jid for update;
 if (select collected from public.sale_balances where transaction_id=sid)>total then raise exception 'Revision is below collected amount; admin must resolve refund first'; end if;
 -- Preserve original transaction date. Closed period requires an admin-managed correction first.
 update public.transactions set amount=total where id=sid;
 update public.sales set quote_id=q.id,approved_items=items,revision=q.revision where transaction_id=sid;
 update public.jobs set quote_id=q.id where id=jid;
 end if;
 insert into public.sale_versions(unit_id,sale_id,quote_id,revision,amount,approved_items) values(q.unit_id,sid,q.id,q.revision,total,items);
 insert into public.agreements(unit_id,quote_id,policy_id,customer_id,job_id,content_snapshot,accepted_name,accepted_email,accepted_phone)
 values(q.unit_id,q.id,pol.id,f.customer_id,jid,pol.content,trim(p_name),trim(p_email),trim(p_phone));
 update public.quotes set status='Revised' where flow_id=f.id and id<>q.id and status='Accepted';
 update public.quotes set status='Accepted' where id=q.id;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key) values(q.unit_id,'Agreement accepted copy',q.id,p_email,'agreement:'||q.id) on conflict do nothing;
 return jid;
end $$;


ALTER FUNCTION public.accept_agreement(p_token text, p_name text, p_email text, p_phone text) OWNER TO postgres;

--
-- Name: accept_quote(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.accept_quote(p_token text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare q public.quotes;
begin
 select x.* into q from public.quotes x join private.public_links l on l.quote_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if q.id is null or q.status not in ('Sent','Viewed','Agreement Pending','Accepted') then raise exception 'Quote is not available for acceptance'; end if;
 update public.quotes set status='Agreement Pending',accepted_at=coalesce(accepted_at,now()) where id=q.id and status in ('Sent','Viewed');
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(q.unit_id,'Quote Accepted',q.id,'quote-accepted:'||q.id) on conflict do nothing;
end $$;


ALTER FUNCTION public.accept_quote(p_token text) OWNER TO postgres;

--
-- Name: accepted_pdf_file(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.accepted_pdf_file(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d public.accepted_documents;
begin
 select * into d from public.accepted_documents where id=p_id;
 if d.id is null then raise exception 'Document not found'; end if;
 if coalesce(auth.role(),'')<>'service_role' and not private.can_access(d.unit_id) then raise exception 'Access denied'; end if;
 return (select jsonb_build_object('file_name',d.file_name,'pdf',encode(a.pdf,'base64'),'sha256',a.pdf_sha256) from private.accepted_pdf_artifacts a where a.document_id=p_id);
end $$;


ALTER FUNCTION public.accepted_pdf_file(p_id uuid) OWNER TO postgres;

--
-- Name: cancel_job_extension(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cancel_job_extension(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare x public.job_extensions; j public.jobs; token text; review_id uuid; recipient text;
begin
 select * into x from public.job_extensions where id=p_id;
 select * into j from public.jobs where id=x.job_id for update;
 select * into x from public.job_extensions where id=p_id for update; perform private.require_admin(x.unit_id);
 if x.accepted_at is not null then raise exception 'Accepted extensions cannot be cancelled'; end if;
 if x.status='Cancelled' then return; end if;
 update public.job_extensions set status='Cancelled' where id=p_id;
 if j.status='Ready for Delivery' and not exists(select 1 from public.job_extensions where job_id=j.id and status in ('Requested','Draft','Sent','Approved')) then
   token:=gen_random_uuid()::text||gen_random_uuid()::text;
   insert into private.job_review_links(job_id,token,token_hash,expires_at) values(j.id,token,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '30 days') returning id into review_id;
   select coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email') into recipient from public.agreements a left join public.accepted_documents d on d.agreement_id=a.id where a.quote_id=j.quote_id;
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload) values(j.unit_id,'JOB_READY',j.id,'job-ready:'||review_id,recipient,jsonb_build_object('template','work_review','review_id',review_id,'live_eligible',true));
 end if;
end $$;


ALTER FUNCTION public.cancel_job_extension(p_id uuid) OWNER TO postgres;

--
-- Name: claim_accepted_copy(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.claim_accepted_copy(p_id uuid, p_copy text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d public.accepted_documents; n public.notifications;
begin
 select * into d from public.accepted_documents where id=p_id;
 perform private.require_admin(d.unit_id);
 if p_copy not in ('customer','internal') then raise exception 'Invalid copy'; end if;
 if not exists(select 1 from private.accepted_pdf_artifacts where document_id=p_id) then return null; end if;
 select * into n from public.notifications where dedupe_key='accepted-pdf:'||p_id||':'||p_copy and status='Pending Integration' for update skip locked;
 if n.id is null then return null; end if;
 update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now() where id=n.id returning * into n;
 return to_jsonb(n);
end $$;


ALTER FUNCTION public.claim_accepted_copy(p_id uuid, p_copy text) OWNER TO postgres;

--
-- Name: claim_accepted_pdf(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.claim_accepted_pdf(p_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d public.accepted_documents; claim uuid;
begin
 if coalesce(auth.role(),'')<>'service_role' then
   if p_id is null then raise exception 'Worker required'; end if;
   perform private.require_admin((select unit_id from public.accepted_documents where id=p_id));
 end if;
 select x.* into d from public.accepted_documents x join public.accepted_document_status s on s.document_id=x.id
 where (p_id is null or x.id=p_id) and s.pdf_status='Pending' order by x.created_at for update of s skip locked limit 1;
 if d.id is null then return null; end if;
 claim:=gen_random_uuid();
 update public.accepted_document_status set pdf_status='Generating',pdf_claim=claim,pdf_started_at=now(),updated_at=now() where document_id=d.id;
 return to_jsonb(d)||jsonb_build_object('claim',claim);
end $$;


ALTER FUNCTION public.claim_accepted_pdf(p_id uuid) OWNER TO postgres;

--
-- Name: create_quote(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_quote(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid; fid uuid; qid uuid; y integer; seq integer; item jsonb; rev integer:=1; oldq public.quotes; mark jsonb;
begin
 perform private.require_admin(u);
 if jsonb_array_length(p->'items')=0 or p->'items' is null then raise exception 'Add at least one item'; end if;
 if nullif(p->>'revises_id','') is not null then
 select * into oldq from public.quotes where id=(p->>'revises_id')::uuid and unit_id=u for update;
 if oldq.id is null then raise exception 'Quote not found'; end if;
 fid:=oldq.flow_id;
 perform 1 from public.commercial_flows where id=fid for update;
 select coalesce(max(revision),0)+1 into rev from public.quotes where flow_id=fid;
 select year,sequence into y,seq from public.commercial_flows where id=fid;
 else
 y:=extract(year from now() at time zone (select timezone from public.unit_settings where unit_id=u));
 insert into private.annual_sequences(year,value) values(y,1) on conflict(year) do update set value=private.annual_sequences.value+1 returning value into seq;
 insert into public.commercial_flows(unit_id,customer_id,year,sequence) values(u,(p->>'customer_id')::uuid,y,seq) returning id into fid;
 end if;
 insert into public.quotes(unit_id,flow_id,revision,code,notes) values(u,fid,rev,'TT-Q-'||y||'-'||lpad(seq::text,5,'0'),p->>'notes') returning id into qid;
 for item in select value from jsonb_array_elements(private.priced_scope(p->'items')) loop
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,engraving_text,width_mm,height_mm,paint_fill,colors,unit_price,notes,sort_order,marks,paint_details,adaptation_fee,paint_fee,additional_engraving_fee,pricing)
 values(u,qid,item->>'article',(item->>'quantity')::integer,item->>'engraving_type',item->>'engraving_text',nullif(item->>'width_mm','')::numeric,nullif(item->>'height_mm','')::numeric,false,0,(item->>'unit_price')::numeric,item->>'notes',(item->>'sort_order')::integer,coalesce(item->'marks','[]'),coalesce(item->'paint_details','{}'),coalesce((item->>'adaptation_fee')::boolean,false),coalesce((item->>'paint_fee')::boolean,false),coalesce((item->>'additional_engraving_fee')::boolean,false),coalesce(item->'pricing','{}'));
 end loop;
 if (select sum(quantity*unit_price) from public.quote_items where quote_id=qid)<=0 then raise exception 'Quote total must be positive'; end if;
 return qid;
end $$;


ALTER FUNCTION public.create_quote(p jsonb) OWNER TO postgres;

--
-- Name: customer_stats(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.customer_stats(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid;
begin
 select unit_id into u from public.customers where id=p_id;
 if not private.can_access(u) then raise exception 'Access denied'; end if;
 return jsonb_build_object('lifetime_sales',coalesce((select sum(amount) from public.sale_balances where customer_id=p_id and transaction_status<>'Voided'),0),
 'outstanding',coalesce((select sum(balance_due) from public.sale_balances where customer_id=p_id and transaction_status<>'Voided'),0));
end $$;


ALTER FUNCTION public.customer_stats(p_id uuid) OWNER TO postgres;

--
-- Name: finish_accepted_pdf(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.finish_accepted_pdf(p_id uuid, p_claim uuid, p_pdf text DEFAULT NULL::text, p_error text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare s public.accepted_document_status; bytes bytea; hash text;
begin
 select * into s from public.accepted_document_status where document_id=p_id for update;
 perform private.require_admin(s.unit_id);
 if s.pdf_status<>'Generating' or s.pdf_claim is distinct from p_claim then return false; end if;
 if p_pdf is null then
   update public.accepted_document_status set pdf_status='PDF Generation Failed',pdf_error='PDF_GENERATION_FAILED',updated_at=now() where document_id=p_id;
 else
   bytes:=decode(p_pdf,'base64');
   if octet_length(bytes)>4000000 or substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF artifact'; end if;
   hash:=encode(sha256(bytes),'hex');
   insert into private.accepted_pdf_artifacts(document_id,pdf,pdf_sha256) values(p_id,bytes,hash);
   update public.accepted_document_status set pdf_status='Ready',pdf_sha256=hash,pdf_error=null,updated_at=now() where document_id=p_id;
 end if;
 return true;
end $$;


ALTER FUNCTION public.finish_accepted_pdf(p_id uuid, p_claim uuid, p_pdf text, p_error text) OWNER TO postgres;

--
-- Name: job_customer_status(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.job_customer_status(p_job uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  token_value text;
begin
  select * into j from public.jobs where id=p_job;
  if j.id is null then raise exception 'Job not found'; end if;

  perform private.require_admin(j.unit_id);
  token_value:=private.ensure_job_status_link(j.id);

  return jsonb_build_object(
    'stage',j.customer_stage,
    'path','/status/'||token_value
  );
end $$;


ALTER FUNCTION public.job_customer_status(p_job uuid) OWNER TO postgres;

--
-- Name: pending_accepted_documents(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.pending_accepted_documents() RETURNS TABLE(document_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker required'; end if;
 return query select s.document_id from public.accepted_document_status s
 where s.pdf_status='Pending' or (s.pdf_status='Ready' and s.mail_phase in ('production','test') and exists(select 1 from public.notifications n where n.payload->>'document_id'=s.document_id::text and n.payload->>'template'='accepted_pdf' and n.delivery_phase=s.mail_phase and n.status='Pending Integration'))
 order by case when s.pdf_status='Pending' then 0 else 1 end,s.updated_at limit 3;
end $$;


ALTER FUNCTION public.pending_accepted_documents() OWNER TO postgres;

--
-- Name: prepare_existing_accepted_document(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prepare_existing_accepted_document(p_quote uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare a public.agreements; d uuid;
begin
 select * into a from public.agreements where quote_id=p_quote;
 perform private.require_admin(a.unit_id);
 if a.id is null or a.commercial_snapshot is null or a.commercial_snapshot->'items' is null then raise exception 'No complete immutable acceptance snapshot; manual review required'; end if;
 perform 1 from public.quotes where id=p_quote for update;
 select id into d from public.accepted_documents where quote_id=p_quote;
 if d is not null then return d; end if;
 perform private.freeze_accepted_document(p_quote);
 select id into d from public.accepted_documents where quote_id=p_quote;
 -- Recovery creates no new acceptance and does not authorize any historical email.
 update public.accepted_document_status set mail_phase='legacy' where document_id=d;
 update public.notifications set delivery_phase='legacy' where payload->>'document_id'=d::text;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values(a.unit_id,auth.uid(),'accepted_documents',d,'recovered_from_acceptance',to_jsonb(a.id));
 return d;
end $$;


ALTER FUNCTION public.prepare_existing_accepted_document(p_quote uuid) OWNER TO postgres;

--
-- Name: public_cancel_quote(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_cancel_quote(p_token text, p_quote uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  cid uuid;
  q public.quotes;
begin
  cid:=private.cancellation_link_customer(p_token);
  if cid is null then raise exception 'Cancellation link unavailable'; end if;

  select qx.* into q
  from public.quotes qx
  join public.commercial_flows f on f.id=qx.flow_id
  where qx.id=p_quote and f.customer_id=cid
  for update of qx;

  if q.id is null then raise exception 'Quote not found'; end if;
  if q.status not in ('Sent','Viewed','Agreement Pending') then
    raise exception 'This Quote can no longer be cancelled from this page';
  end if;

  update public.quotes set status='Declined' where id=q.id;

  insert into public.notifications(
    unit_id,event,entity_id,dedupe_key,payload
  )
  values(
    q.unit_id,'QUOTE_CANCELLED_BY_CUSTOMER',q.id,'quote-cancelled:'||q.id,
    jsonb_build_object(
      'template','notification',
      'subject','Quote cancelled — '||q.code,
      'text','The customer cancelled '||q.code||' using the secure cancellation page.',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object('cancelled',true,'code',q.code);
end $$;


ALTER FUNCTION public.public_cancel_quote(p_token text, p_quote uuid) OWNER TO postgres;

--
-- Name: public_extension(text, boolean, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_extension(p_token text, p_accept boolean DEFAULT false, p_name text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare x public.job_extensions; j public.jobs; sid uuid; snap jsonb; customer uuid; current_total numeric;
begin
 select e.* into x from public.job_extensions e join private.extension_links l on l.extension_id=e.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and (l.expires_at>now() or e.accepted_at is not null);
 if x.id is null or x.status='Cancelled' then raise exception 'Extension link unavailable'; end if;
 select * into j from public.jobs where id=x.job_id for update;
 select * into x from public.job_extensions where id=x.id for update;
 if p_accept and x.accepted_at is null then
   if x.status<>'Sent' or j.status not in ('In Process','Ready for Delivery','Authorized','Receiving Documentation') or nullif(trim(p_name),'') is null then raise exception 'Extension is not available for acceptance'; end if;
   select grand_total into current_total from public.job_commercial_totals where id=j.id;
   select customer_id into customer from public.commercial_flows where id=j.flow_id;
   insert into public.transactions(unit_id,type,transaction_date,amount,customer_id,description,category_id)
   values(j.unit_id,'SALE',(now() at time zone (select timezone from public.unit_settings where unit_id=j.unit_id))::date,x.total,customer,'Approved job extension '||x.code,(select id from public.categories where unit_id=j.unit_id and name='Engraving Services')) returning id into sid;
   insert into public.sales(transaction_id,unit_id,code,approved_items) values(sid,j.unit_id,replace(x.code,'TT-J-','TT-S-'),x.items);
   snap:=jsonb_build_object('extension_id',x.id,'code',x.code,'job_id',j.id,'job_code',j.code,'scope',x.scope,'items',x.items,'total',x.total,'accepted_name',trim(p_name),'accepted_at',now(),'original_agreement_id',(select id from public.agreements where quote_id=j.quote_id),'job_total_after',current_total+x.total,'approved',true);
   update public.job_extensions set status='Approved',sale_id=sid,accepted_at=now(),accepted_snapshot=snap,snapshot_sha256=encode(sha256(convert_to(snap::text,'UTF8')),'hex') where id=x.id returning * into x;
   update public.jobs set status='In Process' where id=j.id;
 end if;
 select grand_total into current_total from public.job_commercial_totals where id=j.id;
 return jsonb_build_object('code',x.code,'job_code',j.code,'scope',x.scope,'items',x.items,'total',x.total,'status',x.status,'accepted_at',x.accepted_at,'grand_total',current_total+case when x.accepted_at is null then x.total else 0 end);
end $$;


ALTER FUNCTION public.public_extension(p_token text, p_accept boolean, p_name text) OWNER TO postgres;

--
-- Name: public_quote(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.public_quote(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare l private.public_links; q public.quotes; a public.agreements; snap jsonb; job_code text;
begin
 select * into l from private.public_links where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and quote_id is not null;
 if not found then raise exception 'This link is invalid or expired'; end if;
 select * into q from public.quotes where id=l.quote_id;
 select * into a from public.agreements where quote_id=q.id;
 if a.id is null and (l.expires_at<=now() or q.expires_at<=now() or q.status not in ('Sent','Viewed','Agreement Pending')) then raise exception 'Quote is unavailable or expired'; end if;
 update public.quotes set status='Viewed' where id=q.id and status='Sent';
 select code into job_code from public.jobs where id=a.job_id;
 snap:=coalesce(a.commercial_snapshot,q.review_snapshot,private.quote_snapshot(q.id));
 if a.id is not null then
 if a.commercial_snapshot is null then
 -- Legacy acceptances use their original signer and sale version, never today's Customer profile.
 snap:=snap||jsonb_build_object('customer_name',a.accepted_name,'customer_email',a.accepted_email,'customer_phone',a.accepted_phone,
 'total',(select amount from public.sale_versions where quote_id=q.id limit 1),
 'items',(select approved_items from public.sale_versions where quote_id=q.id limit 1));
 end if;
 snap:=snap||jsonb_build_object('policy',(snap->'policy')||jsonb_build_object('content',a.content_snapshot));
 end if;
 return snap||jsonb_build_object('status',case when q.status='Sent' then 'Viewed' else q.status end,
 'accepted',a.id is not null,'accepted_at',a.accepted_at,'snapshot_hash',a.snapshot_hash,'job_code',job_code);
end $$;


ALTER FUNCTION public.public_quote(p_token text) OWNER TO postgres;

--
-- Name: regenerate_quote_link(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.regenerate_quote_link(p_id uuid) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select private.send_review(p_id,true);
$$;


ALTER FUNCTION public.regenerate_quote_link(p_id uuid) OWNER TO postgres;

--
-- Name: retry_accepted_document(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.retry_accepted_document(p_id uuid, p_part text, p_reconciled boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare d public.accepted_documents; s public.accepted_document_status; n public.notifications;
begin
 select * into d from public.accepted_documents where id=p_id;
 perform private.require_admin(d.unit_id);
 if p_part='pdf' then
   select * into s from public.accepted_document_status where document_id=p_id for update;
   if s.pdf_status='Generating' and s.pdf_started_at>now()-interval '10 minutes' then raise exception 'PDF generation is still in progress'; end if;
   if s.pdf_status in ('PDF Generation Failed','Generating') then
     update public.accepted_document_status set pdf_status='Pending',pdf_claim=null,pdf_error=null,updated_at=now() where document_id=p_id;
   end if;
 elsif p_part in ('customer','internal') then
   select * into n from public.notifications where dedupe_key='accepted-'||(select mail_phase from public.accepted_document_status where document_id=p_id)||':'||p_id||':'||p_part for update;
   if n.status='Queued' and n.mail_attempted_at>now()-interval '10 minutes' then raise exception 'Mail delivery is still in progress'; end if;
   if (n.status='Queued' or n.mail_error='GMAIL_DELIVERY_UNKNOWN') and not p_reconciled then raise exception 'Confirm Gmail Sent mail was reviewed and this copy was not delivered'; end if;
   if n.status in ('Failed','Queued') then
     update public.notifications set status='Pending Integration',mail_claim=null,mail_error=null where id=n.id;
   end if;
 else raise exception 'Invalid retry target'; end if;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value)
 values(d.unit_id,auth.uid(),'accepted_documents',p_id,'retry_requested',jsonb_build_object('part',p_part,'reconciled',p_reconciled));
end $$;


ALTER FUNCTION public.retry_accepted_document(p_id uuid, p_part text, p_reconciled boolean) OWNER TO postgres;

--
-- Name: save_customer(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.save_customer(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid; cid uuid:=nullif(p->>'id','')::uuid;
begin
 perform private.require_admin(u);
 if exists(select 1 from public.customers where unit_id=u and id is distinct from cid and
 ((nullif(trim(p->>'email'),'') is not null and lower(email)=lower(trim(p->>'email'))) or
 (nullif(regexp_replace(p->>'phone','\D','','g'),'') is not null and regexp_replace(phone,'\D','','g')=regexp_replace(p->>'phone','\D','','g')))) then raise exception 'A customer with this email or phone exists. Open their profile before creating another.'; end if;
 if cid is null then
 insert into public.customers(unit_id,name,phone,email,address,company_name,company_phone,company_email,company_address)
 values(u,trim(p->>'name'),trim(p->>'phone'),lower(trim(p->>'email')),p->>'address',p->>'company_name',p->>'company_phone',p->>'company_email',p->>'company_address') returning id into cid;
 else update public.customers set name=p->>'name',phone=p->>'phone',email=lower(p->>'email'),address=p->>'address',company_name=p->>'company_name',company_phone=p->>'company_phone',company_email=p->>'company_email',company_address=p->>'company_address',updated_at=now() where id=cid and unit_id=u;
 if not found then raise exception 'Customer not found'; end if;
 end if;
 return cid;
end $$;


ALTER FUNCTION public.save_customer(p jsonb) OWNER TO postgres;

--
-- Name: save_job_extension(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.save_job_extension(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare x public.job_extensions; priced jsonb; total numeric;
begin
 select * into x from public.job_extensions where id=(p->>'id')::uuid for update;
 perform private.require_admin(x.unit_id);
 if x.status not in ('Requested','Draft') then raise exception 'Only a draft extension can be edited'; end if;
 priced:=private.priced_scope(p->'items');
 select sum((i->>'quantity')::numeric*(i->>'unit_price')::numeric) into total from jsonb_array_elements(priced) i;
 if total<=0 then raise exception 'Extension total must be positive'; end if;
 update public.job_extensions set scope=coalesce(p->>'notes',''),items=priced,total=total,status='Draft' where id=x.id;
 return x.id;
end $$;


ALTER FUNCTION public.save_job_extension(p jsonb) OWNER TO postgres;

--
-- Name: send_job_extension(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.send_job_extension(p_id uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare x public.job_extensions; j public.jobs; token text; recipient text;
begin
 select * into x from public.job_extensions where id=p_id; select * into j from public.jobs where id=x.job_id for update;
 select * into x from public.job_extensions where id=p_id for update; perform private.require_admin(x.unit_id);
 if x.status not in ('Draft','Sent') or x.total<=0 then raise exception 'Prepare the extension scope first'; end if;
 if j.status not in ('In Process','Ready for Delivery','Authorized','Receiving Documentation') then raise exception 'Job is not active'; end if;
 select l.token into token from private.extension_links l where l.extension_id=x.id;
 if token is null then
   token:=gen_random_uuid()::text||gen_random_uuid()::text;
   insert into private.extension_links values(x.id,token,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '7 days');
 end if;
 select coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email') into recipient from public.agreements a left join public.accepted_documents d on d.agreement_id=a.id where a.quote_id=j.quote_id;
 update public.job_extensions set status='Sent' where id=x.id;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload) values(x.unit_id,'QUOTE_REVISION',x.id,'extension:'||x.id,recipient,jsonb_build_object('template','extension_approval','extension_id',x.id)) on conflict do nothing;
 return token;
end $$;


ALTER FUNCTION public.send_job_extension(p_id uuid) OWNER TO postgres;

--
-- Name: set_job_customer_stage(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_job_customer_stage(p_job uuid, p_stage text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  stage_order integer;
  current_order integer;
begin
  select * into j
  from public.jobs
  where id=p_job
  for update;

  if j.id is null then raise exception 'Job not found'; end if;
  perform private.require_admin(j.unit_id);

  stage_order:=case p_stage
    when 'In Process' then 1
    when 'Engraving' then 2
    when 'Final Details' then 3
    when 'Completed' then 4
    else null
  end;

  current_order:=case j.customer_stage
    when 'In Process' then 1
    when 'Engraving' then 2
    when 'Final Details' then 3
    when 'Completed' then 4
    else 0
  end;

  if stage_order is null then
    raise exception 'Invalid customer stage';
  end if;

  if stage_order<current_order then
    raise exception 'Customer stage cannot move backward';
  end if;

  update public.jobs
  set customer_stage=p_stage,
      updated_at=now()
  where id=j.id;

  return p_stage;
end $$;


ALTER FUNCTION public.set_job_customer_stage(p_job uuid, p_stage text) OWNER TO postgres;

--
-- Name: accepted_pdf_artifacts; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.accepted_pdf_artifacts (
    document_id uuid NOT NULL,
    pdf bytea NOT NULL,
    pdf_sha256 text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE private.accepted_pdf_artifacts OWNER TO postgres;

--
-- Name: delivery_scopes; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.delivery_scopes (
    job_id uuid NOT NULL,
    snapshot jsonb NOT NULL
);


ALTER TABLE private.delivery_scopes OWNER TO postgres;

--
-- Name: extension_links; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.extension_links (
    extension_id uuid NOT NULL,
    token text NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


ALTER TABLE private.extension_links OWNER TO postgres;

--
-- Name: job_review_links; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.job_review_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id uuid NOT NULL,
    token text NOT NULL,
    token_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    notified_at timestamp with time zone,
    viewed_at timestamp with time zone,
    response_at timestamp with time zone,
    response text,
    customer_request text
);


ALTER TABLE private.job_review_links OWNER TO postgres;

--
-- Name: public_links; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.public_links (
    token_hash text NOT NULL,
    unit_id uuid NOT NULL,
    quote_id uuid,
    job_id uuid,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT public_links_check CHECK (((quote_id IS NULL) <> (job_id IS NULL)))
);


ALTER TABLE private.public_links OWNER TO postgres;

--
-- Name: accepted_document_status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.accepted_document_status (
    document_id uuid NOT NULL,
    unit_id uuid NOT NULL,
    pdf_status text DEFAULT 'Pending'::text NOT NULL,
    pdf_error text,
    pdf_claim uuid,
    pdf_started_at timestamp with time zone,
    pdf_sha256 text,
    storage_status text DEFAULT 'Pending Drive Upload'::text NOT NULL,
    drive_file_id text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    mail_phase text DEFAULT 'legacy'::text NOT NULL,
    CONSTRAINT accepted_document_status_pdf_status_check CHECK ((pdf_status = ANY (ARRAY['Pending'::text, 'Generating'::text, 'Ready'::text, 'PDF Generation Failed'::text])))
);


ALTER TABLE public.accepted_document_status OWNER TO postgres;

--
-- Name: accepted_documents; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.accepted_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    document_type text DEFAULT 'Accepted Agreement'::text NOT NULL,
    agreement_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    job_id uuid NOT NULL,
    sale_id uuid,
    acceptance_folio text NOT NULL,
    agreement_version integer NOT NULL,
    accepted_at timestamp with time zone NOT NULL,
    customer_recipient_email text NOT NULL,
    file_name text NOT NULL,
    snapshot jsonb NOT NULL,
    canonical_snapshot text NOT NULL,
    acceptance_snapshot_sha256 text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.accepted_documents OWNER TO postgres;

--
-- Name: agreements; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.agreements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    policy_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    job_id uuid,
    content_snapshot text NOT NULL,
    accepted_name text NOT NULL,
    accepted_email text NOT NULL,
    accepted_phone text NOT NULL,
    accepted_at timestamp with time zone DEFAULT now() NOT NULL,
    commercial_snapshot jsonb,
    snapshot_hash text,
    acceptance_type text DEFAULT 'Quote + Agreement'::text NOT NULL
);


ALTER TABLE public.agreements OWNER TO postgres;

--
-- Name: customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    code text DEFAULT ('TT-C-'::text || upper(substr(replace((gen_random_uuid())::text, '-'::text, ''::text), 1, 12))) NOT NULL,
    name text NOT NULL,
    phone text NOT NULL,
    email text NOT NULL,
    address text NOT NULL,
    company_name text,
    company_phone text,
    company_email text,
    company_address text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT customers_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);


ALTER TABLE public.customers OWNER TO postgres;

--
-- Name: job_extensions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.job_extensions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    job_id uuid NOT NULL,
    sequence integer NOT NULL,
    code text NOT NULL,
    request_key uuid DEFAULT gen_random_uuid() NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    customer_request text NOT NULL,
    scope text DEFAULT ''::text NOT NULL,
    items jsonb DEFAULT '[]'::jsonb NOT NULL,
    total numeric(14,2) DEFAULT 0 NOT NULL,
    status text DEFAULT 'Requested'::text NOT NULL,
    accepted_at timestamp with time zone,
    accepted_snapshot jsonb,
    snapshot_sha256 text,
    sale_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT job_extensions_status_check CHECK ((status = ANY (ARRAY['Requested'::text, 'Draft'::text, 'Sent'::text, 'Approved'::text, 'Completed'::text, 'Cancelled'::text])))
);


ALTER TABLE public.job_extensions OWNER TO postgres;

--
-- Name: jobs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    flow_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    code text NOT NULL,
    status text DEFAULT 'Authorized'::text NOT NULL,
    delivered_at timestamp with time zone,
    completion_email_sent_at timestamp with time zone,
    completion_link_viewed_at timestamp with time zone,
    acceptance_deadline timestamp with time zone,
    customer_accepted_at timestamp with time zone,
    auto_closed_at timestamp with time zone,
    completion_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    customer_stage text DEFAULT 'In Process'::text NOT NULL,
    work_stage text DEFAULT 'Not Started'::text NOT NULL,
    CONSTRAINT jobs_customer_stage_check CHECK ((customer_stage = ANY (ARRAY['In Process'::text, 'Engraving'::text, 'Final Details'::text, 'Completed'::text]))),
    CONSTRAINT jobs_status_check CHECK ((status = ANY (ARRAY['Pending Agreement'::text, 'Authorized'::text, 'Receiving Documentation'::text, 'In Process'::text, 'Ready for Delivery'::text, 'Delivered – Pending Customer Acceptance'::text, 'Completed'::text, 'Cancelled'::text, 'Issue / Review'::text]))),
    CONSTRAINT jobs_work_stage_check CHECK ((work_stage = ANY (ARRAY['Not Started'::text, 'Receiving Evidence'::text, 'Preparing'::text, 'Engraving'::text, 'Final Evidence'::text, 'Final Details'::text, 'Delivery In Progress'::text, 'Awaiting Delivery Acceptance'::text, 'Issue Review'::text, 'Payment'::text, 'Payment Verification'::text, 'Closed'::text, 'Cancellation Requested / Production Hold'::text])))
);


ALTER TABLE public.jobs OWNER TO postgres;

--
-- Name: policies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    version integer NOT NULL,
    title text NOT NULL,
    content text NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT policies_content_check CHECK ((length(TRIM(BOTH FROM content)) > 20))
);


ALTER TABLE public.policies OWNER TO postgres;

--
-- Name: quote_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.quote_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    article text NOT NULL,
    quantity integer NOT NULL,
    engraving_type text NOT NULL,
    engraving_text text,
    character_count integer GENERATED ALWAYS AS (char_length(COALESCE(engraving_text, ''::text))) STORED,
    width_mm numeric(10,2),
    height_mm numeric(10,2),
    paint_fill boolean DEFAULT false NOT NULL,
    colors integer DEFAULT 0 NOT NULL,
    unit_price numeric(14,2) NOT NULL,
    notes text,
    sort_order integer DEFAULT 0 NOT NULL,
    marks jsonb DEFAULT '[]'::jsonb NOT NULL,
    adaptation_fee boolean DEFAULT false NOT NULL,
    paint_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    paint_fee boolean DEFAULT false NOT NULL,
    additional_engraving_fee boolean DEFAULT false NOT NULL,
    pricing jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT quote_items_check CHECK (((engraving_type <> 'Text'::text) OR (length(TRIM(BOTH FROM engraving_text)) > 0))),
    CONSTRAINT quote_items_colors_check CHECK ((colors >= 0)),
    CONSTRAINT quote_items_engraving_type_check CHECK ((engraving_type = ANY (ARRAY['Text'::text, 'Image / Logo'::text, 'Fee'::text]))),
    CONSTRAINT quote_items_height_mm_check CHECK ((height_mm > (0)::numeric)),
    CONSTRAINT quote_items_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT quote_items_unit_price_check CHECK ((unit_price >= (0)::numeric)),
    CONSTRAINT quote_items_width_mm_check CHECK ((width_mm > (0)::numeric))
);


ALTER TABLE public.quote_items OWNER TO postgres;

--
-- Name: quotes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.quotes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    flow_id uuid NOT NULL,
    revision integer DEFAULT 1 NOT NULL,
    code text NOT NULL,
    status text DEFAULT 'Draft'::text NOT NULL,
    notes text,
    sent_at timestamp with time zone,
    expires_at timestamp with time zone,
    accepted_at timestamp with time zone,
    policy_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    review_snapshot jsonb,
    source text DEFAULT 'internal'::text NOT NULL,
    intake_details jsonb,
    intake_reviewed_at timestamp with time zone,
    CONSTRAINT quotes_status_check CHECK ((status = ANY (ARRAY['Draft'::text, 'Sent'::text, 'Viewed'::text, 'Accepted'::text, 'Agreement Pending'::text, 'Declined'::text, 'Expired'::text, 'Revised'::text])))
);


ALTER TABLE public.quotes OWNER TO postgres;

