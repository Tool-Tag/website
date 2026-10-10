
create or replace function public.accept_review(
  p_token text,
  p_quote_confirmed boolean,
  p_agreement_confirmed boolean,
  p_name text,
  p_email text,
  p_phone text
) returns uuid
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
end $$;
