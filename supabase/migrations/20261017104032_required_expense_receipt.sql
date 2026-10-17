begin;
-- Stage the image in Storage first; link receipt + expense in one database transaction.
-- Only new manual ToolTag expense registrations are affected, never historical rows.
alter function public.record_movement(jsonb) rename to record_movement_before_required_receipt;
revoke all on function public.record_movement_before_required_receipt(jsonb) from public,anon,authenticated;
create function public.record_movement(p jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid;d public.documents;tid uuid;proof uuid:=nullif(p->>'proof_id','')::uuid;begin
 if u is distinct from '10000000-0000-0000-0000-000000000002'::uuid or p->>'type' is distinct from 'EXPENSE' then return public.record_movement_before_required_receipt(p);end if;
 perform private.require_owner(u);
 perform 1 from public.business_units where id=u for update;
 -- Existing request retries keep their original payload/idempotency contract.
 if exists(select 1 from private.mutation_requests where unit_id=u and request_id=nullif(p->>'request_id','')::uuid) then return public.record_movement_before_required_receipt(p);end if;
 if (p->>'amount')::numeric>=75 and proof is null then raise exception 'A receipt image is required for expenses of $75 or more. Upload a photo before saving.';end if;
 if proof is not null then
  select * into d from public.documents where id=proof for update;
  if d.id is null or d.unit_id<>u or d.uploaded_by is distinct from auth.uid() or d.type<>'Other' or d.transaction_id is not null or d.job_id is not null or d.quote_id is not null or d.status<>'Available' or d.storage_status<>'stored' or d.storage_provider<>'supabase_storage' or d.visibility<>'internal' or coalesce(d.mime_type,'') not in ('image/jpeg','image/png','image/webp') or coalesce(d.file_size,0)<=0 or d.file_size>3670016
    or not exists(select 1 from storage.objects o where o.bucket_id='tooltag-files' and o.bucket_id=d.storage_bucket and o.name=d.storage_path) then
   raise exception 'Upload an available receipt image for this expense. Unstored, foreign or previously linked proofs cannot be used.';
  end if;
 end if;
 tid:=public.record_movement_before_required_receipt(p);
 if proof is not null then
  update public.documents set type='Receipt',folder_kind=private.document_folder_kind('Receipt'),transaction_id=tid,logical_key='upload:'||tid||':Receipt:'||d.sha256 where id=proof;
  perform private.rbac_log('expense.receipt.linked',tid,jsonb_build_object('document_id',proof));
 end if;
 return tid;
end$$;
revoke all on function public.record_movement(jsonb) from public,anon;
grant execute on function public.record_movement(jsonb) to authenticated;
-- Keep legacy receipts readable and recognize actual Supabase receipt storage.
do $$declare d text;begin
 d:=pg_get_viewdef('public.expense_details'::regclass,true);
 if position('d.drive_file_id IS NOT NULL' in d)=0 then raise exception 'Unexpected receipt-status view';end if;
 d:=replace(d,'d.drive_file_id IS NOT NULL','(d.drive_file_id IS NOT NULL OR (d.storage_provider=''supabase_storage'' AND d.storage_status=''stored'' AND d.storage_path IS NOT NULL))');
 execute 'create or replace view public.expense_details with(security_invoker=true) as '||d;
end$$;
notify pgrst,'reload schema';
commit;
