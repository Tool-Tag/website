
create or replace function private.notification_mail_base(n public.notifications)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
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
end $$;
