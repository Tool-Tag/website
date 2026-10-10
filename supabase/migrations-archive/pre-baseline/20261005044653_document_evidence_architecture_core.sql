
alter table public.documents
  drop constraint documents_type_check,
  drop constraint documents_status_check;

alter table public.documents
  add constraint documents_type_check check (
    type in (
      'Receipt','Quote','Agreement',
      'Accepted Quote','Accepted Agreement',
      'Receiving Evidence','Completed Evidence','Finished Evidence','Production Evidence',
      'Delivery Evidence','Delivery Acknowledgment',
      'Payment Receipt','Final Receipt','Refund Receipt',
      'Issue / Review','Issue / Review Evidence',
      'Cancellation Evidence','Refund Review Evidence','Customer Document','Customer Claim',
      'Job Extension','Other'
    )
  ),
  add constraint documents_status_check check (
    status in ('Pending','Pending Upload','Available','Failed','Archived')
  );

alter table public.documents
  add column if not exists quote_id uuid references public.quotes(id) on delete set null,
  add column if not exists job_extension_id uuid references public.job_extensions(id) on delete set null,
  add column if not exists payment_request_id uuid references public.payment_requests(id) on delete set null,
  add column if not exists cancellation_request_id uuid references public.cancellation_requests(id) on delete set null,
  add column if not exists accepted_document_id uuid references public.accepted_documents(id) on delete set null,
  add column if not exists job_receipt_id uuid references public.job_receipts(id) on delete set null,
  add column if not exists original_file_name text,
  add column if not exists mime_type text,
  add column if not exists file_size bigint,
  add column if not exists sha256 text,
  add column if not exists visibility text not null default 'internal',
  add column if not exists uploaded_at timestamptz,
  add column if not exists notes text,
  add column if not exists storage_provider text not null default 'pending_drive',
  add column if not exists storage_status text not null default 'Pending Drive Upload',
  add column if not exists drive_folder_id text,
  add column if not exists drive_web_view_link text,
  add column if not exists drive_download_metadata jsonb,
  add column if not exists folder_kind text,
  add column if not exists logical_key text;

alter table public.documents
  add constraint documents_file_size_nonnegative check (file_size is null or file_size >= 0),
  add constraint documents_sha256_format check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  add constraint documents_visibility_check check (visibility in ('internal','customer')),
  add constraint documents_storage_provider_check check (
    storage_provider in ('pending_drive','google_drive','legacy_drive','temporary')
  ),
  add constraint documents_storage_status_check check (
    storage_status in (
      'Pending Upload','Stored Locally/Temporary','Pending Drive Upload',
      'Upload In Progress','Uploaded','Upload Failed','Retry Required','Failed','Archived'
    )
  ),
  add constraint documents_folder_kind_check check (
    folder_kind is null or folder_kind in (
      'commercial','receiving','production','delivery','payments','issue_review','other'
    )
  );

create unique index documents_unit_logical_key_key
  on public.documents(unit_id,logical_key);

create unique index documents_accepted_document_key
  on public.documents(accepted_document_id)
  where accepted_document_id is not null;

create unique index documents_job_receipt_key
  on public.documents(job_receipt_id)
  where job_receipt_id is not null;

create index documents_quote_idx
  on public.documents(quote_id)
  where quote_id is not null;

create index documents_extension_idx
  on public.documents(job_extension_id)
  where job_extension_id is not null;

create index documents_storage_status_idx
  on public.documents(unit_id,storage_status,folder_kind);

alter table public.job_items
  add column if not exists display_label text,
  add column if not exists preparation_started_at timestamptz,
  add column if not exists completed_at timestamptz;

update public.job_items
set
  display_label=coalesce(
    display_label,
    'P'||lpad(sequence::text,3,'0')||' · '||article
  ),
  preparation_started_at=coalesce(
    preparation_started_at,
    case
      when sequence=1 or stage<>'Preparation' then created_at
      else null
    end
  ),
  completed_at=coalesce(completed_at,finished_at);

alter table public.job_items
  alter column display_label set not null;

create table if not exists public.storage_folders(
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.business_units(id),
  customer_id uuid not null references public.customers(id),
  job_id uuid references public.jobs(id) on delete cascade,
  folder_kind text not null check (
    folder_kind in (
      'commercial','receiving','production','delivery','payments','issue_review','other'
    )
  ),
  storage_provider text not null default 'pending_drive' check (
    storage_provider in ('pending_drive','google_drive')
  ),
  external_folder_id text,
  status text not null default 'Pending Drive Creation' check (
    status in (
      'Pending Drive Creation','Creating','Ready','Create Failed','Retry Required','Archived'
    )
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index storage_folders_logical_key
  on public.storage_folders(
    unit_id,
    customer_id,
    coalesce(job_id,'00000000-0000-0000-0000-000000000000'::uuid),
    folder_kind,
    storage_provider
  );

create unique index storage_folders_external_key
  on public.storage_folders(storage_provider,external_folder_id)
  where external_folder_id is not null;

alter table public.storage_folders enable row level security;

create policy storage_folders_read
on public.storage_folders
for select
to authenticated
using ((select private.can_access(storage_folders.unit_id)));

revoke all on table public.storage_folders from anon,authenticated;
grant select on table public.storage_folders to authenticated;

create or replace function private.document_folder_kind(p_type text)
returns text
language sql
immutable
set search_path=''
as $$
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

update public.documents d
set
  original_file_name=coalesce(d.original_file_name,d.file_name),
  storage_provider=case
    when d.drive_file_id is not null then 'legacy_drive'
    else 'pending_drive'
  end,
  storage_status=case
    when d.drive_file_id is not null then 'Uploaded'
    else 'Pending Drive Upload'
  end,
  uploaded_at=case
    when d.drive_file_id is not null then coalesce(d.uploaded_at,d.created_at)
    else d.uploaded_at
  end,
  folder_kind=coalesce(d.folder_kind,private.document_folder_kind(d.type));

update public.documents d
set
  quote_id=coalesce(d.quote_id,j.quote_id),
  customer_id=coalesce(d.customer_id,f.customer_id)
from public.jobs j
join public.commercial_flows f on f.id=j.flow_id
where d.job_id=j.id;

create or replace function private.job_item_metadata_defaults()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
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

create trigger job_items_metadata_defaults
before insert or update on public.job_items
for each row execute function private.job_item_metadata_defaults();

create or replace function private.sync_accepted_document_metadata()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
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

create trigger accepted_document_metadata_sync
after insert on public.accepted_documents
for each row execute function private.sync_accepted_document_metadata();

insert into public.documents(
  unit_id,type,file_name,original_file_name,mime_type,sha256,
  visibility,status,storage_provider,storage_status,folder_kind,
  customer_id,quote_id,job_id,agreement_id,accepted_document_id,
  content_snapshot,logical_key
)
select
  a.unit_id,'Accepted Agreement',a.file_name,a.file_name,
  'application/pdf',coalesce(s.pdf_sha256,a.acceptance_snapshot_sha256),
  'customer','Available',
  case when s.drive_file_id is not null then 'legacy_drive' else 'pending_drive' end,
  case when s.drive_file_id is not null then 'Uploaded' else 'Pending Drive Upload' end,
  'commercial',
  a.customer_id,a.quote_id,a.job_id,a.agreement_id,a.id,
  a.snapshot,'accepted-agreement:'||a.id::text
from public.accepted_documents a
left join public.accepted_document_status s on s.document_id=a.id
on conflict(unit_id,logical_key) do nothing;

create or replace function private.sync_job_receipt_metadata()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
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

create trigger job_receipt_metadata_sync
after insert on public.job_receipts
for each row execute function private.sync_job_receipt_metadata();

insert into public.documents(
  unit_id,type,file_name,original_file_name,mime_type,sha256,
  visibility,status,storage_provider,storage_status,folder_kind,
  customer_id,quote_id,job_id,job_receipt_id,content_snapshot,logical_key
)
select
  r.unit_id,'Final Receipt',j.code||'-Final-Receipt.pdf',
  j.code||'-Final-Receipt.pdf','application/pdf',r.snapshot_sha256,
  'customer','Available','pending_drive',
  coalesce(r.storage_status,'Pending Drive Upload'),'payments',
  f.customer_id,j.quote_id,j.id,r.id,r.snapshot,'final-receipt:'||r.id::text
from public.job_receipts r
join public.jobs j on j.id=r.job_id
join public.commercial_flows f on f.id=j.flow_id
on conflict(unit_id,logical_key) do nothing;
