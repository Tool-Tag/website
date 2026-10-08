
alter table public.documents
  add column if not exists evidence_metadata jsonb not null default '{}'::jsonb;

alter table public.documents
  add constraint documents_evidence_metadata_object_check
  check (jsonb_typeof(evidence_metadata)='object');

create or replace function public.update_document_evidence_metadata(
  p_document uuid,
  p_metadata jsonb
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
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

revoke all on function public.update_document_evidence_metadata(uuid,jsonb)
  from public,anon;
grant execute on function public.update_document_evidence_metadata(uuid,jsonb)
  to authenticated;
