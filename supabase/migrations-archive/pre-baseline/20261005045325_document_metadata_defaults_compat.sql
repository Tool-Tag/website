
create or replace function private.document_metadata_defaults()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
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

create trigger documents_metadata_defaults
before insert or update on public.documents
for each row execute function private.document_metadata_defaults();

update public.documents
set file_name=file_name
where true;
