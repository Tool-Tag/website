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
-- Name: classify_mail(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.classify_mail() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare started timestamptz; eligible boolean;
begin
 select enabled_at into started from private.customer_mail_activation where unit_id=NEW.unit_id;
 if started is null or coalesce((NEW.payload->>'test')::boolean,false) then NEW.delivery_phase:='test'; return NEW; end if;
 eligible:=coalesce((NEW.payload->>'live_eligible')::boolean,false)
 or exists(select 1 from public.quotes q where q.id=NEW.entity_id and q.sent_at>=started)
 or exists(select 1 from public.jobs j where j.id=NEW.entity_id and (j.created_at>=started or j.completion_email_sent_at>=started))
 or exists(select 1 from public.transactions t where t.id=NEW.entity_id and t.created_at>=started)
 or exists(select 1 from public.transactions t where NEW.event='Final Paid receipt' and t.id::text=split_part(NEW.dedupe_key,':',2) and t.created_at>=started)
 or exists(select 1 from public.job_extensions x where x.id=NEW.entity_id and x.created_at>=started)
 or exists(select 1 from public.job_receipts r where r.id=NEW.entity_id and r.created_at>=started)
 or exists(select 1 from public.accepted_documents d where d.id::text=NEW.payload->>'document_id' and d.created_at>=started);
 NEW.delivery_phase:=case when NEW.created_at>=started and eligible then 'production' else 'legacy' end;
 return NEW;
end $$;


ALTER FUNCTION private.classify_mail() OWNER TO postgres;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    event text NOT NULL,
    entity_id uuid NOT NULL,
    recipient text,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'Pending Integration'::text NOT NULL,
    dedupe_key text NOT NULL,
    due_at timestamp with time zone DEFAULT now() NOT NULL,
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    mail_claim uuid,
    provider_id text,
    mail_error text,
    mail_attempted_at timestamp with time zone,
    delivery_phase text DEFAULT 'legacy'::text NOT NULL,
    CONSTRAINT notifications_status_check CHECK ((status = ANY (ARRAY['Pending Integration'::text, 'Queued'::text, 'Sent'::text, 'Failed'::text])))
);


ALTER TABLE public.notifications OWNER TO postgres;

--
-- Name: notification_mail(public.notifications); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.notification_mail(n public.notifications) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare l private.job_review_links; x public.job_extensions; token text; j public.jobs;
begin
 if n.payload->>'template'='work_review' then
   select * into l from private.job_review_links where id=(n.payload->>'review_id')::uuid and expires_at>now();
   select * into j from public.jobs where id=l.job_id;
   if l.id is null or l.response_at is not null or j.status<>'Ready for Delivery' or l.id<>(select id from private.job_review_links where job_id=j.id order by created_at desc limit 1) then return null; end if;
   return jsonb_build_object('recipient',n.recipient,'action_path','/work/'||l.token,'payload',jsonb_build_object('template','notification','subject','Your ToolTag work is completed — '||j.code,'text','Your engraving work is completed. Review the approved work and choose Ready for Delivery or request additional work.'));
 elsif n.payload->>'template'='extension_approval' then
   select * into x from public.job_extensions where id=n.entity_id;
   select t.token into token from private.extension_links t where t.extension_id=x.id and t.expires_at>now();
   if x.status<>'Sent' or token is null then return null; end if;
   return jsonb_build_object('recipient',n.recipient,'action_path','/extension/'||token,'payload',jsonb_build_object('template','notification','subject','ToolTag extension approval — '||x.code,'text','Review the additional work and pricing before we proceed. Additional total: $'||x.total));
 elsif n.payload->>'template'='job_receipt' then
   return jsonb_build_object('recipient',n.recipient,'payload',n.payload||(select jsonb_build_object('snapshot',r.snapshot) from public.job_receipts r where r.id=n.entity_id));
 end if;
 return private.notification_mail_base(n);
end $_$;


ALTER FUNCTION private.notification_mail(n public.notifications) OWNER TO postgres;

--
-- Name: notification_mail_base(public.notifications); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.notification_mail_base(n public.notifications) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  q public.quotes;
  j public.jobs;
  a public.agreements;
  t public.transactions;
  recipient text;
  token text;
  title text;
  body text;
  receipt jsonb;
begin
  if n.event='Agreement accepted copy'
     and exists(select 1 from public.accepted_documents where quote_id=n.entity_id)
  then return null; end if;

  if n.event in ('Quote Sent','Quote expiration reminder','Agreement accepted copy') then
    select * into q from public.quotes where id=n.entity_id and unit_id=n.unit_id;
    if q.id is null or not (n.payload ? 'snapshot') then return null; end if;
    if n.event<>'Agreement accepted copy'
       and (q.status not in ('Sent','Viewed','Agreement Pending') or q.expires_at<=now())
    then return null; end if;

    select d.token into token from private.quote_delivery d where d.quote_id=q.id;
    if token is null then return null; end if;
    return jsonb_build_object('recipient',n.recipient,'token',token,'payload',n.payload);

  elsif n.event in ('Payment receipt','Final Paid receipt') then
    select * into t
    from public.transactions
    where id=n.entity_id and unit_id=n.unit_id and status='Active';

    if t.id is null then return null; end if;

    select c.email into recipient
    from public.customers c
    where c.id=t.customer_id and c.unit_id=n.unit_id;

    select d.content_snapshot into receipt
    from public.documents d
    where d.unit_id=n.unit_id
      and d.type='Payment Receipt'
      and d.transaction_id=case
        when n.event='Payment receipt' then n.entity_id
        else substring(n.dedupe_key from 6)::uuid
      end
    order by d.created_at desc
    limit 1;

    if receipt is null then return null; end if;

    title:=case
      when n.event='Payment receipt' then 'ToolTag payment received'
      else 'ToolTag paid receipt'
    end;

    body:='Sale: '||coalesce(receipt->>'sale_code','')
      ||E'\nPayment received: $'||(receipt->>'amount')
      ||E'\nDate: '||(receipt->>'date')
      ||E'\nRemaining balance at payment: $'||coalesce(receipt->>'balance_remaining','0.00');

  elsif n.event in (
    'Job Ready for Delivery','Completion acknowledgment','Completion reminder',
    'Final completion','Administrative completion','Customer reported issue'
  ) then
    select * into j from public.jobs where id=n.entity_id and unit_id=n.unit_id;
    if j.id is null then return null; end if;

    select * into a
    from public.agreements
    where job_id=j.id
    order by accepted_at desc
    limit 1;

    recipient:=a.accepted_email;

    if n.event='Job Ready for Delivery' and j.status<>'Ready for Delivery'
    then return null; end if;

    if n.event in ('Completion acknowledgment','Completion reminder') then
      if j.status<>'Delivered – Pending Customer Acceptance' then return null; end if;

      select l.token into token
      from private.job_mail_links l
      join private.public_links p
        on p.token_hash=encode(sha256(convert_to(l.token,'UTF8')),'hex')
      where l.job_id=j.id and p.expires_at>now();

      if token is null then return null; end if;
    end if;

    if n.event='Final completion' and j.auto_closed_at is not null
    then return null; end if;

    title:=case n.event
      when 'Job Ready for Delivery' then 'Your ToolTag job is ready'
      when 'Completion acknowledgment' then 'Your ToolTag work is completed — '||j.code
      when 'Completion reminder' then 'Reminder: accept your ToolTag delivery'
      when 'Customer reported issue' then 'ToolTag received your issue report'
      else 'Your ToolTag job is completed'
    end;

    body:=case n.event
      when 'Completion acknowledgment' then
        'Your ToolTag work is finished. Please review the completed work and confirm delivery using the secure link below.'
      when 'Completion reminder' then
        'Please review your completed ToolTag work and confirm delivery using the secure link below.'
      when 'Customer reported issue' then
        'We received your issue report. Reply to this message to share more details.'
      when 'Job Ready for Delivery' then
        'Your work is ready for delivery.'
      else
        coalesce(j.completion_reason,'Completed')
    end;

  else
    if n.payload->>'template'='notification'
       and nullif(n.payload->>'subject','') is not null
       and nullif(n.payload->>'text','') is not null
    then
      return jsonb_build_object(
        'recipient',n.recipient,
        'action_path',nullif(n.payload->>'action_path',''),
        'payload',n.payload
      );
    end if;

    return null;
  end if;

  return jsonb_build_object(
    'recipient',recipient,
    'completion_token',token,
    'payload',jsonb_build_object(
      'template','notification',
      'subject',title,
      'text',body
    )
  );
end $_$;


ALTER FUNCTION private.notification_mail_base(n public.notifications) OWNER TO postgres;

--
-- Name: activate_customer_mail(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.activate_customer_mail() RETURNS timestamp with time zone
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:='10000000-0000-0000-0000-000000000002'; activated timestamptz;
begin
 perform private.require_admin(u);
 insert into private.customer_mail_activation(unit_id,enabled_at) values(u,now()) on conflict do nothing;
 select enabled_at into activated from private.customer_mail_activation where unit_id=u;
 return activated;
end $$;


ALTER FUNCTION public.activate_customer_mail() OWNER TO postgres;

--
-- Name: claim_get_tagged_mail(uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.claim_get_tagged_mail(p_id uuid, p_recipient text, p_mode text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare n public.notifications;
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_setting('request.jwt.claim.role',true),'')<>'service_role' then raise exception 'Worker credentials required' using errcode='42501'; end if;
 if p_mode not in ('live','test-delivery') or p_mode is null or p_recipient is null or p_recipient !~ '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+[.][^[:space:]<>@,;]+$' then raise exception 'Invalid mail configuration'; end if;
 select * into n from public.notifications x where x.event in ('GET_TAGGED_REQUEST','GET_TAGGED_RECEIVED') and x.unit_id='10000000-0000-0000-0000-000000000002'
 and (p_id is null or x.entity_id=p_id) and x.status='Pending Integration' and x.mail_claim is null
 and ((p_mode='live' and x.delivery_phase='production') or (p_mode='test-delivery' and x.delivery_phase='test'))
 and (p_mode='live' or x.event='GET_TAGGED_REQUEST' or lower(x.recipient)=lower(p_recipient))
 order by x.created_at,x.event desc for update skip locked limit 1;
 if not found then return null; end if;
 update public.notifications set status='Queued',recipient=case when event='GET_TAGGED_REQUEST' then p_recipient else recipient end,mail_claim=gen_random_uuid(),mail_attempted_at=now() where id=n.id returning * into n;
 return to_jsonb(n)||jsonb_build_object('status_token',(select token from private.request_status_links where request_id=n.entity_id));
end $_$;


ALTER FUNCTION public.claim_get_tagged_mail(p_id uuid, p_recipient text, p_mode text) OWNER TO postgres;

--
-- Name: claim_mail_for_mode(uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.claim_mail_for_mode(p_quote uuid, p_test_recipient text, p_mode text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare n public.notifications; content jsonb;
begin
 if coalesce(auth.role(),'') <> 'service_role' then
   if p_quote is null then raise exception 'Worker credentials required'; end if;
   perform private.require_admin((select unit_id from public.quotes where id=p_quote));
 end if;
 for n in select x.* from public.notifications x
 where x.unit_id='10000000-0000-0000-0000-000000000002' and (p_quote is null or x.entity_id=p_quote)
 and ((p_mode='live' and x.delivery_phase='production') or (p_mode='test-delivery' and x.delivery_phase='test')) and x.status='Pending Integration' and x.mail_claim is null and x.due_at<=now()
 order by x.created_at for update skip locked loop
   content:=private.notification_mail(n);
   if content is null or nullif(content->>'recipient','') is null then continue; end if;
   if p_test_recipient is not null and lower(content->>'recipient')<>lower(p_test_recipient) then continue; end if;
   update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now(),recipient=content->>'recipient' where id=n.id returning * into n;
   return to_jsonb(n)||content;
 end loop;
 return null;
end $$;


ALTER FUNCTION public.claim_mail_for_mode(p_quote uuid, p_test_recipient text, p_mode text) OWNER TO postgres;

--
-- Name: claim_quote_mail(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.claim_quote_mail(p_quote uuid DEFAULT NULL::uuid, p_test_recipient text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare n public.notifications; content jsonb;
begin
 if coalesce(auth.role(),'') <> 'service_role' then
   if p_quote is null then raise exception 'Worker credentials required'; end if;
   perform private.require_admin((select unit_id from public.quotes where id=p_quote));
 end if;
 for n in select x.* from public.notifications x
 where x.unit_id='10000000-0000-0000-0000-000000000002' and (p_quote is null or x.entity_id=p_quote)
 and x.status='Pending Integration' and x.mail_claim is null and x.due_at<=now()
 order by x.created_at for update skip locked loop
   content:=private.notification_mail(n);
   if content is null or nullif(content->>'recipient','') is null then continue; end if;
   if p_test_recipient is not null and lower(content->>'recipient')<>lower(p_test_recipient) then continue; end if;
   update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now(),recipient=content->>'recipient' where id=n.id returning * into n;
   return to_jsonb(n)||content;
 end loop;
 return null;
end $$;


ALTER FUNCTION public.claim_quote_mail(p_quote uuid, p_test_recipient text) OWNER TO postgres;

--
-- Name: customer_mail_status(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.customer_mail_status() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if not private.can_access('10000000-0000-0000-0000-000000000002') then raise exception 'Access denied'; end if;
 return jsonb_build_object('activated_at',(select enabled_at from private.customer_mail_activation where unit_id='10000000-0000-0000-0000-000000000002'));
end $$;


ALTER FUNCTION public.customer_mail_status() OWNER TO postgres;

--
-- Name: finish_get_tagged_mail(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.finish_get_tagged_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_setting('request.jwt.claim.role',true),'')<>'service_role' then raise exception 'Worker credentials required' using errcode='42501'; end if;
 if nullif(p_provider_id,'') is null and p_error is null then raise exception 'Delivery result required'; end if;
 update public.notifications set status=case when nullif(p_provider_id,'') is not null then 'Sent' else 'Failed' end,
 provider_id=p_provider_id,mail_error=p_error,sent_at=case when nullif(p_provider_id,'') is not null then now() else null end
 where id=p_id and event in ('GET_TAGGED_REQUEST','GET_TAGGED_RECEIVED') and unit_id='10000000-0000-0000-0000-000000000002' and status='Queued' and mail_claim=p_claim;
 return found;
end $$;


ALTER FUNCTION public.finish_get_tagged_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text) OWNER TO postgres;

--
-- Name: finish_quote_mail(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.finish_quote_mail(p_id uuid, p_claim uuid, p_provider_id text DEFAULT NULL::text, p_error text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare n public.notifications;
begin
 select * into n from public.notifications where id=p_id for update;
 perform private.require_admin(n.unit_id);
 if n.mail_claim is distinct from p_claim or n.status<>'Queued' then return false; end if;
 if nullif(p_provider_id,'') is null and p_error is null then raise exception 'Delivery result required'; end if;
 update public.notifications set status=case when nullif(p_provider_id,'') is not null then 'Sent' else 'Failed' end,
 provider_id=p_provider_id,mail_error=p_error,sent_at=case when nullif(p_provider_id,'') is not null then now() else null end
 where id=p_id;
 if nullif(p_provider_id,'') is not null and n.event='Completion acknowledgment' then
   update public.jobs set completion_email_sent_at=now(),acceptance_deadline=coalesce(acceptance_deadline,now()+interval '3 days')
   where id=n.entity_id and status='Delivered – Pending Customer Acceptance';
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,due_at)
   values(n.unit_id,'Completion reminder',n.entity_id,'completion-reminder:'||n.entity_id,now()+interval '2 days') on conflict do nothing;
 end if;
 return true;
end $$;


ALTER FUNCTION public.finish_quote_mail(p_id uuid, p_claim uuid, p_provider_id text, p_error text) OWNER TO postgres;

--
-- Name: quote_delivery(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.quote_delivery(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare q public.quotes; token text; a public.agreements; snapshot jsonb;
begin
 select * into q from public.quotes where id=p_id;
 perform private.require_admin(q.unit_id);
 select d.token into token from private.quote_delivery d where d.quote_id=p_id;
 select * into a from public.agreements where quote_id=p_id;
 snapshot:=coalesce(a.commercial_snapshot,q.review_snapshot,private.quote_snapshot(p_id));
 return jsonb_build_object('token',token,'snapshot',snapshot,'accepted',a.id is not null,
 'job_code',(select code from public.jobs where id=a.job_id),'delivery','Pending Integration','recipient',(select d.recipient from private.quote_delivery d where d.quote_id=p_id));
end $$;


ALTER FUNCTION public.quote_delivery(p_id uuid) OWNER TO postgres;

--
-- Name: resend_quote(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.resend_quote(p_id uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare q public.quotes; previous public.notifications; destination text; token text; wait_seconds integer;
begin
 select * into q from public.quotes where id=p_id for update;
 if q.id is null then raise exception 'Quote not found'; end if;
 perform private.require_admin(q.unit_id);
 if q.status not in ('Sent','Viewed') or q.expires_at is null or q.expires_at<=now() then
  raise exception 'Only a sent, active Quote can be resent. Create a revision if it expired or was accepted';
 end if;
 select * into previous from public.notifications where entity_id=q.id and event='Quote Sent' order by created_at desc,id desc limit 1 for update;
 if previous.id is null then raise exception 'Send the Quote first'; end if;
 wait_seconds:=ceil(extract(epoch from (greatest(previous.created_at,previous.mail_attempted_at,(previous.payload->>'resend_requested_at')::timestamptz)+interval '90 seconds'-clock_timestamp())));
 if wait_seconds>0 then raise exception 'Wait % seconds before resending the Quote',wait_seconds; end if;
 if coalesce(previous.payload->>'test','false')='true' then raise exception 'Test notifications cannot be resent from this action'; end if;
 if previous.status not in ('Sent','Pending Integration') or (previous.status='Pending Integration' and previous.mail_claim is not null) or exists(select 1 from public.notifications where entity_id=q.id and event='Quote Sent' and id<>previous.id and status in ('Queued','Pending Integration')) then
  raise exception 'The previous send requires review before resending to avoid duplicates';
 end if;
 select d.recipient,d.token into destination,token from private.quote_delivery d where d.quote_id=q.id;
 if nullif(destination,'') is null or token is null or q.review_snapshot is null then raise exception 'Original send data is incomplete'; end if;
 if previous.status='Pending Integration' then
  update public.notifications set recipient=destination,payload=payload||jsonb_build_object('resend_requested_at',clock_timestamp(),'resend',true,'live_eligible',true) where id=previous.id;
 else
  insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload)
  values(q.unit_id,'Quote Sent',q.id,'quote-resend:'||q.id||':'||gen_random_uuid(),destination,
   jsonb_build_object('template','quote','snapshot',q.review_snapshot,'live_eligible',true,'resend',true,'resend_requested_at',clock_timestamp(),'previous_notification_id',previous.id));
 end if;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value)
 values(q.unit_id,auth.uid(),'quotes',q.id,'quote_resend_requested',jsonb_build_object('recipient',destination,'requested_at',now(),'previous_notification_id',previous.id));
 return token;
end
$$;


ALTER FUNCTION public.resend_quote(p_id uuid) OWNER TO postgres;

--
-- Name: retry_customer_notification(uuid, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.retry_customer_notification(p_id uuid, p_reconciled boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare n public.notifications;
begin
 select * into n from public.notifications where id=p_id for update; perform private.require_admin(n.unit_id);
 if n.payload->>'template'='accepted_pdf' then raise exception 'Use the accepted document controls'; end if;
 if n.status='Sent' then raise exception 'This message has already been sent'; end if;
 if n.status='Queued' and n.mail_attempted_at>now()-interval '10 minutes' then raise exception 'Delivery still in progress'; end if;
 if not p_reconciled then raise exception 'Confirm that this specific message should be sent and was not already delivered'; end if;
 if not exists(select 1 from private.customer_mail_activation where unit_id=n.unit_id) then raise exception 'Activate production mail first'; end if;
 update public.notifications set delivery_phase='production',status='Pending Integration',mail_claim=null,mail_error=null where id=p_id;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values(n.unit_id,auth.uid(),'notifications',n.id,'manual_retry_authorized',to_jsonb(now()));
end $$;


ALTER FUNCTION public.retry_customer_notification(p_id uuid, p_reconciled boolean) OWNER TO postgres;

--
-- Name: send_quote(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.send_quote(p_id uuid) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select private.send_review(p_id,false);
$$;


ALTER FUNCTION public.send_quote(p_id uuid) OWNER TO postgres;

--
-- Name: send_quote_to(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.send_quote_to(p_id uuid, p_recipient text, p_regenerate boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare q public.quotes; c public.customers; destination text:=trim(p_recipient); token text; snap jsonb; prior text;
begin
 select * into q from public.quotes where id=p_id for update;
 perform private.require_admin(q.unit_id);
 select x.* into c from public.customers x join public.commercial_flows f on f.customer_id=x.id where f.id=q.flow_id and x.unit_id=q.unit_id;
 select d.recipient into prior from private.quote_delivery d where d.quote_id=p_id;
 if nullif(destination,'') is null or destination !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or
 not (lower(destination)=lower(coalesce(prior,'')) or lower(destination)=lower(coalesce(trim(c.email),'')) or lower(destination)=lower(coalesce(trim(c.company_email),''))) then
   raise exception 'Select the registered personal or company email for this customer';
 end if;
 perform 1 from public.notifications where entity_id=q.id and event in ('Quote Sent','Quote expiration reminder') order by id for update;
 if exists(select 1 from public.notifications where entity_id=q.id and event in ('Quote Sent','Quote expiration reminder') and status='Queued') then
   raise exception 'A send is already in progress. Wait before changing the recipient';
 end if;
 select d.recipient into prior from private.quote_delivery d where d.quote_id=p_id;
 if prior is not null and lower(prior)<>lower(destination) then raise exception 'The recipient for this revision is locked. Create a revision to change it'; end if;
 token:=private.send_review(p_id,p_regenerate);
 select recipient into prior from private.quote_delivery where quote_id=p_id;
 update private.quote_delivery set recipient=destination where quote_id=p_id;
 update public.notifications set recipient=destination where entity_id=p_id and event in ('Quote Sent','Quote expiration reminder') and status='Pending Integration';
 select review_snapshot into snap from public.quotes where id=p_id;
 if exists(select 1 from public.notifications where entity_id=p_id and event='Quote Sent' and status='Sent') and
 not exists(select 1 from public.notifications where entity_id=p_id and event='Quote Sent' and lower(recipient)=lower(destination) and status in ('Sent','Queued','Pending Integration')) then
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload)
   values(q.unit_id,'Quote Sent',q.id,'quote:'||q.id||':recipient:'||encode(sha256(convert_to(lower(destination),'UTF8')),'hex'),destination,jsonb_build_object('template','quote','snapshot',snap)) on conflict do nothing;
 end if;
 if prior is distinct from destination then
   insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,old_value,new_value)
   values(q.unit_id,auth.uid(),'quotes',q.id,'mail_recipient',to_jsonb(prior),to_jsonb(destination));
 end if;
 return token;
end
$_$;


ALTER FUNCTION public.send_quote_to(p_id uuid, p_recipient text, p_regenerate boolean) OWNER TO postgres;

--
-- Name: customer_mail_activation; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.customer_mail_activation (
    unit_id uuid NOT NULL,
    enabled_at timestamp with time zone NOT NULL
);


ALTER TABLE private.customer_mail_activation OWNER TO postgres;

--
-- Name: job_mail_links; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.job_mail_links (
    job_id uuid NOT NULL,
    token text NOT NULL
);


ALTER TABLE private.job_mail_links OWNER TO postgres;

--
-- Name: quote_delivery; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.quote_delivery (
    quote_id uuid NOT NULL,
    token text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    recipient text
);


ALTER TABLE private.quote_delivery OWNER TO postgres;

