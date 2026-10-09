
create or replace function public.register_document_metadata(p jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
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
$$;

revoke all on function public.register_document_metadata(jsonb) from public,anon;
grant execute on function public.register_document_metadata(jsonb) to authenticated;
