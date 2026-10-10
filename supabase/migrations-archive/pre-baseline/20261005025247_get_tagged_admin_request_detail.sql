
create or replace function public.get_get_tagged_request(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  r private.get_tagged_receipts;
begin
  perform private.require_admin(u);

  select * into r
  from private.get_tagged_receipts
  where id=p_id;

  if r.id is null then
    raise exception 'Request not found';
  end if;

  return jsonb_build_object(
    'id',r.id,
    'reference',r.reference,
    'request_status',r.request_status,
    'matching',r.matching,
    'created_at',r.created_at,
    'approved_at',r.approved_at,
    'rejected_at',r.rejected_at,
    'rejection_reason',r.rejection_reason,
    'quote_id',r.quote_id,
    'customer_id',r.customer_id,
    'details',r.details,
    'candidates',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',c.id,
          'name',c.name,
          'email',c.email,
          'phone',c.phone
        )
        order by c.name,c.id
      )
      from public.customers c
      where c.id=any(r.candidates)
    ),'[]'::jsonb)
  );
end $$;

revoke all on function public.get_get_tagged_request(uuid) from public,anon;
grant execute on function public.get_get_tagged_request(uuid) to authenticated;
