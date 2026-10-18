insert into public.role_blocks select r.id, 'quotes.manage' from public.roles r where r.system_key = 'Employee' on conflict do nothing;
