begin;
-- Annual, contiguous reporting periods. Dates are month/day, not destructive resets.
create function private.valid_tax_quarters(p_starts text[]) returns boolean
language plpgsql immutable set search_path='' as $$
declare i integer; wraps integer:=0;begin
 if p_starts is null or cardinality(p_starts)<>4 or array_ndims(p_starts)<>1 or array_lower(p_starts,1)<>1 then return false;end if;
 for i in 1..4 loop
  if p_starts[i] is null or p_starts[i] !~ '^[0-9]{2}-[0-9]{2}$' then return false;end if;
  -- A non-leap year prevents an annual boundary that is missing in some years.
  perform make_date(2001,substring(p_starts[i],1,2)::integer,substring(p_starts[i],4,2)::integer);
  if p_starts[i]=p_starts[(i%4)+1] then return false;end if;
  if p_starts[i]>p_starts[(i%4)+1] then wraps:=wraps+1;end if;
 end loop;
 return wraps=1 and (select count(distinct x)=4 from unnest(p_starts) x);
exception when datetime_field_overflow or invalid_datetime_format or invalid_text_representation then return false;
end$$;
revoke all on function private.valid_tax_quarters(text[]) from public,anon,authenticated;
alter table public.unit_settings add column sales_tax_quarter_starts text[] not null default array['01-01','04-01','07-01','10-01']
 check(private.valid_tax_quarters(sales_tax_quarter_starts));
create function public.save_tax_quarters(p_starts text[]) returns void
language plpgsql security definer set search_path='' as $$begin
 perform private.require_owner('10000000-0000-0000-0000-000000000002');
 if not private.valid_tax_quarters(p_starts) then raise exception 'Enter four different valid annual start dates in quarter order. February 29 is unavailable.';end if;
 update public.unit_settings set sales_tax_quarter_starts=p_starts where unit_id='10000000-0000-0000-0000-000000000002';
 perform private.rbac_log('settings.sales_tax_quarters.saved','10000000-0000-0000-0000-000000000002',jsonb_build_object('starts',p_starts));
end$$;
revoke all on function public.save_tax_quarters(text[]) from public,anon;
grant execute on function public.save_tax_quarters(text[]) to authenticated;
-- Finance readers receive only reporting dates, not the entire settings row.
create function public.tax_quarter_dates() returns text[]
language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_block('10000000-0000-0000-0000-000000000002','payments.view') then raise exception 'Finance access required' using errcode='42501';end if;
 return (select sales_tax_quarter_starts from public.unit_settings where unit_id='10000000-0000-0000-0000-000000000002');
end$$;
revoke all on function public.tax_quarter_dates() from public,anon;
grant execute on function public.tax_quarter_dates() to authenticated;
notify pgrst,'reload schema';
commit;
