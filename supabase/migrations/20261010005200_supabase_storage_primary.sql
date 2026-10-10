-- Supabase Storage is the primary binary store for ToolTag.
-- Forward-only migration. Historical Drive references remain read-only.

insert into storage.buckets (id,name,public,file_size_limit)
values ('tooltag-files','tooltag-files',false,4194304)
on conflict (id) do update
set name=excluded.name, public=false, file_size_limit=excluded.file_size_limit;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'quote-images','quote-images',false,3145728,
  array['image/png','image/jpeg','image/webp']::text[]
)
on conflict (id) do update
set name=excluded.name,
    public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists tooltag_files_member_read on storage.objects;
create policy tooltag_files_member_read
on storage.objects for select to authenticated
using (
  bucket_id='tooltag-files'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
  )
);

drop policy if exists tooltag_files_admin_insert on storage.objects;
create policy tooltag_files_admin_insert
on storage.objects for insert to authenticated
with check (
  bucket_id='tooltag-files'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
      and m.role='admin'
  )
);

drop policy if exists tooltag_files_admin_update on storage.objects;
create policy tooltag_files_admin_update
on storage.objects for update to authenticated
using (
  bucket_id='tooltag-files'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
      and m.role='admin'
  )
)
with check (
  bucket_id='tooltag-files'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
      and m.role='admin'
  )
);

drop policy if exists tooltag_files_admin_delete on storage.objects;
create policy tooltag_files_admin_delete
on storage.objects for delete to authenticated
using (
  bucket_id='tooltag-files'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
      and m.role='admin'
  )
);

drop policy if exists quote_images_member_read on storage.objects;
create policy quote_images_member_read
on storage.objects for select to authenticated
using (
  bucket_id='quote-images'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
  )
);

drop policy if exists quote_images_admin_insert on storage.objects;
create policy quote_images_admin_insert
on storage.objects for insert to authenticated
with check (
  bucket_id='quote-images'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
      and m.role='admin'
  )
);

drop policy if exists quote_images_admin_update on storage.objects;
create policy quote_images_admin_update
on storage.objects for update to authenticated
using (
  bucket_id='quote-images'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
      and m.role='admin'
  )
)
with check (
  bucket_id='quote-images'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
      and m.role='admin'
  )
);

drop policy if exists quote_images_admin_delete on storage.objects;
create policy quote_images_admin_delete
on storage.objects for delete to authenticated
using (
  bucket_id='quote-images'
  and exists (
    select 1 from public.memberships m
    where m.user_id=(select auth.uid())
      and m.unit_id::text=(storage.foldername(name))[1]
      and m.role='admin'
  )
);

alter table public.documents
  add column if not exists storage_bucket text,
  add column if not exists storage_path text,
  add column if not exists storage_error text;

alter table public.documents
  drop constraint if exists documents_status_check,
  drop constraint if exists documents_storage_provider_check,
  drop constraint if exists documents_storage_status_check;

alter table public.documents
  add constraint documents_status_check check (
    status = any (array[
      'Pending','Pending Upload','Pending Storage','Available',
      'Failed','Storage Failed','Archived'
    ]::text[])
  ),
  add constraint documents_storage_provider_check check (
    storage_provider = any (array[
      'pending_drive','google_drive','legacy_drive','temporary',
      'supabase_storage','postgres'
    ]::text[])
  ),
  add constraint documents_storage_status_check check (
    storage_status = any (array[
      'Pending Upload','Stored Locally/Temporary','Pending Drive Upload',
      'Upload In Progress','Uploaded','Upload Failed','Retry Required',
      'Failed','Archived','pending','stored','failed','not_applicable'
    ]::text[])
  );

alter table public.documents
  alter column storage_provider set default 'supabase_storage',
  alter column storage_status set default 'pending';

alter table public.accepted_document_status
  add column if not exists storage_bucket text,
  add column if not exists storage_path text,
  add column if not exists storage_error text;

alter table public.accepted_document_status
  alter column storage_status set default 'pending';

alter table public.job_receipts
  alter column storage_status set default 'not_applicable';

create or replace function private.document_metadata_defaults()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  j public.jobs;
  cid uuid;
begin
  if tg_op='INSERT' then
    if new.drive_file_id is not null then
      raise exception 'Legacy Drive references are read-only; upload new files to Supabase Storage';
    end if;
  elsif tg_op='UPDATE' then
    if new.drive_file_id is distinct from old.drive_file_id then
      raise exception 'Legacy Drive references are read-only';
    end if;
  end if;

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

  if new.type in ('Payment Receipt','Final Receipt','Refund Receipt')
     and new.content_snapshot is not null
     and new.storage_path is null
  then
    new.storage_provider:='postgres';
    new.storage_status:='not_applicable';
    new.status:='Available';
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
$function$;

create or replace function public.register_document_metadata(p jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $function$
declare
  u uuid:=(p->>'unit_id')::uuid;
  did uuid;
  jid uuid:=nullif(p->>'job_id','')::uuid;
  item_id uuid:=nullif(p->>'job_item_id','')::uuid;
  stop_id uuid:=nullif(p->>'pick_return_stop_id','')::uuid;
  ext_id uuid:=nullif(p->>'job_extension_id','')::uuid;
  pay_id uuid:=nullif(p->>'payment_request_id','')::uuid;
  cancel_id uuid:=nullif(p->>'cancellation_request_id','')::uuid;
  tx_id uuid:=nullif(p->>'transaction_id','')::uuid;
  item public.job_items;
  stop public.pick_return_stops;
  j public.jobs;
  tx public.transactions;
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
    'Refund Review Evidence','Customer Document','Receipt','Other'
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
    raise exception 'Legacy Drive references are read-only; upload new files to Supabase Storage';
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

  if tx_id is not null then
    select x.* into tx
    from public.transactions x
    where x.id=tx_id;

    if tx.id is null or tx.unit_id<>u then
      raise exception 'Transaction not found';
    end if;

    cid:=coalesce(cid,tx.customer_id);
  end if;

  if doc_type='Receipt' and tx_id is null then
    raise exception 'Receipt upload must belong to a transaction';
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

  logical:=case
    when tx_id is not null then
      'upload:'||tx_id::text||':'||doc_type||':'||doc_sha
    else
      'evidence:'||
      coalesce(jid::text,'-')||':'||
      coalesce(item_id::text,'-')||':'||
      coalesce(stop_id::text,'-')||':'||
      doc_type||':'||doc_sha
  end;

  insert into public.documents(
    unit_id,type,file_name,original_file_name,mime_type,file_size,sha256,
    visibility,status,storage_provider,storage_status,folder_kind,
    customer_id,quote_id,job_id,job_item_id,job_extension_id,
    pick_return_stop_id,payment_request_id,cancellation_request_id,
    transaction_id,notes,uploaded_by,logical_key
  )
  values(
    u,doc_type,doc_name,original_name,nullif(p->>'mime_type',''),
    (p->>'file_size')::bigint,doc_sha,
    doc_visibility,'Pending Storage','supabase_storage','pending',
    private.document_folder_kind(doc_type),
    coalesce(nullif(p->>'customer_id','')::uuid,cid),
    coalesce(nullif(p->>'quote_id','')::uuid,qid),
    jid,item_id,ext_id,stop_id,pay_id,cancel_id,tx_id,
    nullif(p->>'notes',''),auth.uid(),logical
  )
  on conflict(unit_id,logical_key) do nothing
  returning id into did;

  if did is null then
    select d.id into did
    from public.documents d
    where d.unit_id=u and d.logical_key=logical;
  end if;

  return did;
end
$function$;

create or replace function public.finish_document_storage(
  p_id uuid,
  p_bucket text,
  p_path text,
  p_status text,
  p_error text default null
)
returns boolean
language plpgsql
security definer
set search_path=''
as $function$
declare
  d public.documents;
  item public.job_items;
  tx public.transactions;
begin
  select * into d
  from public.documents
  where id=p_id
  for update;

  if d.id is null then raise exception 'Document not found'; end if;
  perform private.require_admin(d.unit_id);

  if p_status not in ('stored','failed') then
    raise exception 'Invalid storage status';
  end if;

  if p_status='stored' then
    if p_bucket<>'tooltag-files'
       or p_path is null
       or p_path not like d.unit_id::text||'/%'
    then
      raise exception 'Invalid storage object';
    end if;

    update public.documents
    set storage_provider='supabase_storage',
        storage_status='stored',
        storage_bucket=p_bucket,
        storage_path=p_path,
        storage_error=null,
        status='Available',
        uploaded_at=coalesce(uploaded_at,now())
    where id=d.id;

    if d.type='Production Evidence' and d.job_item_id is not null then
      select * into item from public.job_items where id=d.job_item_id for update;
      update public.job_items
      set stage=case when stage='Engraving' then 'Finished Evidence' else stage end,
          evidence_completed_at=coalesce(evidence_completed_at,now()),
          updated_at=now()
      where id=item.id
        and stage in ('Engraving','Finished Evidence');
    end if;

    if d.transaction_id is not null then
      select * into tx from public.transactions where id=d.transaction_id;
      update public.monthly_closes
      set status=case
        when status='Reclose Required' then status
        else 'Documentation Updated'
      end
      where unit_id=d.unit_id
        and month=date_trunc('month',tx.transaction_date)::date
        and status<>'Superseded';
    end if;
  else
    update public.documents
    set storage_provider='supabase_storage',
        storage_status='failed',
        storage_error=left(coalesce(p_error,'STORAGE_UPLOAD_FAILED'),500),
        status='Storage Failed'
    where id=d.id;
  end if;

  return true;
end
$function$;

create or replace function public.add_document(p jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $function$
begin
  if nullif(trim(p->>'drive_file_id'),'') is not null then
    raise exception 'Legacy Drive references are read-only; upload new files to Supabase Storage';
  end if;
  return public.register_document_metadata(p);
end
$function$;

create or replace function private.sync_accepted_document_metadata()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
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
    'customer','Pending Storage','supabase_storage','pending','commercial',
    new.customer_id,new.quote_id,new.job_id,new.agreement_id,new.id,
    new.snapshot,'accepted-agreement:'||new.id::text
  )
  on conflict(unit_id,logical_key) do nothing;

  return new;
end
$function$;

create or replace function private.sync_job_receipt_metadata()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
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
    new.unit_id,'Final Receipt',j.code||'-Final-Receipt',
    j.code||'-Final-Receipt','application/json',new.snapshot_sha256,
    'customer','Available','postgres','not_applicable','payments',
    cid,j.quote_id,j.id,new.id,new.snapshot,'final-receipt:'||new.id::text
  )
  on conflict(unit_id,logical_key) do nothing;

  return new;
end
$function$;

create or replace function public.finish_accepted_pdf_storage(
  p_id uuid,
  p_claim uuid,
  p_bucket text default null,
  p_path text default null,
  p_sha256 text default null,
  p_error text default null
)
returns boolean
language plpgsql
security definer
set search_path=''
as $function$
declare
  s public.accepted_document_status;
  d public.accepted_documents;
begin
  select * into s
  from public.accepted_document_status
  where document_id=p_id
  for update;

  if s.document_id is null then raise exception 'Document status not found'; end if;

  if coalesce(auth.role(),'')<>'service_role' then
    perform private.require_admin(s.unit_id);
  end if;

  if s.pdf_status<>'Generating' or s.pdf_claim is distinct from p_claim then
    return false;
  end if;

  select * into d from public.accepted_documents where id=p_id;

  if p_error is not null then
    update public.accepted_document_status
    set pdf_status='PDF Generation Failed',
        pdf_error=left(p_error,500),
        storage_status='failed',
        storage_error=left(p_error,500),
        updated_at=now()
    where document_id=p_id;

    update public.documents
    set status='Storage Failed',
        storage_provider='supabase_storage',
        storage_status='failed',
        storage_error=left(p_error,500)
    where accepted_document_id=p_id;

    return true;
  end if;

  if p_bucket<>'tooltag-files'
     or p_path is null
     or p_path not like s.unit_id::text||'/%'
     or p_sha256 is null
     or p_sha256 !~ '^[0-9a-f]{64}$'
  then
    raise exception 'Invalid accepted PDF storage result';
  end if;

  update public.accepted_document_status
  set pdf_status='Ready',
      pdf_sha256=p_sha256,
      pdf_error=null,
      storage_status='stored',
      storage_bucket=p_bucket,
      storage_path=p_path,
      storage_error=null,
      updated_at=now()
  where document_id=p_id;

  update public.documents
  set status='Available',
      storage_provider='supabase_storage',
      storage_status='stored',
      storage_bucket=p_bucket,
      storage_path=p_path,
      storage_error=null,
      uploaded_at=coalesce(uploaded_at,now()),
      file_size=null,
      sha256=p_sha256
  where accepted_document_id=p_id;

  return true;
end
$function$;

create or replace function public.accepted_pdf_file(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  d public.accepted_documents;
  s public.accepted_document_status;
  legacy jsonb;
begin
  select * into d from public.accepted_documents where id=p_id;
  if d.id is null then raise exception 'Document not found'; end if;

  if coalesce(auth.role(),'')<>'service_role'
     and not private.can_access(d.unit_id)
  then
    raise exception 'Access denied';
  end if;

  select * into s
  from public.accepted_document_status
  where document_id=p_id;

  if s.storage_status='stored'
     and s.storage_bucket is not null
     and s.storage_path is not null
  then
    return jsonb_build_object(
      'file_name',d.file_name,
      'storage_status','stored',
      'storage_bucket',s.storage_bucket,
      'storage_path',s.storage_path,
      'sha256',s.pdf_sha256
    );
  end if;

  select jsonb_build_object(
    'file_name',d.file_name,
    'storage_status','legacy_database_artifact',
    'pdf',encode(a.pdf,'base64'),
    'sha256',a.pdf_sha256
  )
  into legacy
  from private.accepted_pdf_artifacts a
  where a.document_id=p_id;

  return legacy;
end
$function$;

create or replace function public.public_job_document(p_token text, p_document uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
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
    'storage_provider',d.storage_provider,
    'storage_status',d.storage_status,
    'storage_bucket',d.storage_bucket,
    'storage_path',d.storage_path,
    'folder_kind',d.folder_kind,
    'job_item_id',d.job_item_id,
    'created_at',d.created_at
  );
end
$function$;

create or replace function public.public_job_documents(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
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
        'storage_provider',d.storage_provider,
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
$function$;

revoke all on function public.finish_document_storage(uuid,text,text,text,text) from public,anon;
grant execute on function public.finish_document_storage(uuid,text,text,text,text) to authenticated,service_role;

revoke all on function public.finish_accepted_pdf_storage(uuid,uuid,text,text,text,text) from public,anon;
grant execute on function public.finish_accepted_pdf_storage(uuid,uuid,text,text,text,text) to authenticated,service_role;
