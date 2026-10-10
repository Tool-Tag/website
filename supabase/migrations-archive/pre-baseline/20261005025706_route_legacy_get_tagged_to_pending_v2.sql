
create or replace function public.submit_get_tagged(
  p_key uuid,
  p_network text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
begin
  return public.submit_get_tagged_v2(p_key,p_network,p_payload);
end $$;

revoke all on function public.submit_get_tagged(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.submit_get_tagged(uuid,text,jsonb) to service_role;
