alter table public.quote_items add column paint_fee boolean not null default false;
create or replace function public.create_quote(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; fid uuid; qid uuid; y integer; seq integer; item jsonb; rev integer:=1; oldq public.quotes; mark jsonb;
begin
 perform private.require_admin(u);
 if jsonb_array_length(p->'items')=0 or p->'items' is null then raise exception 'Add at least one item'; end if;
 if nullif(p->>'revises_id','') is not null then
 select * into oldq from public.quotes where id=(p->>'revises_id')::uuid and unit_id=u for update;
 if oldq.id is null then raise exception 'Quote not found'; end if;
 fid:=oldq.flow_id;
 perform 1 from public.commercial_flows where id=fid for update;
 select coalesce(max(revision),0)+1 into rev from public.quotes where flow_id=fid;
 select year,sequence into y,seq from public.commercial_flows where id=fid;
 else
 y:=extract(year from now() at time zone (select timezone from public.unit_settings where unit_id=u));
 insert into private.annual_sequences(year,value) values(y,1) on conflict(year) do update set value=private.annual_sequences.value+1 returning value into seq;
 insert into public.commercial_flows(unit_id,customer_id,year,sequence) values(u,(p->>'customer_id')::uuid,y,seq) returning id into fid;
 end if;
 insert into public.quotes(unit_id,flow_id,revision,code,notes) values(u,fid,rev,'TT-Q-'||y||'-'||lpad(seq::text,5,'0'),p->>'notes') returning id into qid;
 for item in select value||jsonb_build_object('sort_order',ordinality-1) from jsonb_array_elements(p->'items') with ordinality loop
 for mark in select value from jsonb_array_elements(coalesce(item->'marks','[]'::jsonb)) loop
   if coalesce((mark->>'paint_fill')::boolean,false) and (
     coalesce(mark->'paint_details'->>'mode','') not in ('single','multiple') or
     (mark->'paint_details'->>'mode'='single' and nullif(trim(mark->'paint_details'->>'color'),'') is null) or
     (mark->'paint_details'->>'mode'='multiple' and nullif(trim(mark->'paint_details'->>'instructions'),'') is null)
   ) then raise exception 'Specify paint color or instructions for each colored engraving'; end if;
 end loop;
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,engraving_text,width_mm,height_mm,paint_fill,colors,unit_price,notes,sort_order,marks,paint_details)
 values(u,qid,item->>'article',(item->>'quantity')::integer,item->>'engraving_type',item->>'engraving_text',nullif(item->>'width_mm','')::numeric,nullif(item->>'height_mm','')::numeric,coalesce((item->>'paint_fill')::boolean,false),coalesce((item->>'colors')::integer,0),(item->>'unit_price')::numeric,item->>'notes',coalesce((item->>'sort_order')::integer,0),coalesce(item->'marks','[]'::jsonb),coalesce(item->'paint_details','{}'::jsonb));
 end loop;
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,unit_price,notes,adaptation_fee,sort_order)
 select u,qid,'Adaptación de imagen / logo para Falcon',count(distinct trim(m->>'url'))::integer,'Fee',3.00,'$3 por diseño diferente; se cobra una vez por cotización.',true,1000000
 from jsonb_array_elements(p->'items') i cross join lateral jsonb_array_elements(coalesce(i->'marks','[]'::jsonb)) m
 where i->>'engraving_type'<>'Fee' and m->>'type'='Image / Logo' and nullif(trim(m->>'url'),'') is not null
 having count(distinct trim(m->>'url'))>0;
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,unit_price,notes,paint_fee,sort_order)
 select u,qid,'Relleno de pintura',sum((i->>'quantity')::integer)::integer,'Fee',2.00,'$2 por pieza coloreada, una sola vez aunque tenga varios grabados con color.',true,1000001
 from jsonb_array_elements(p->'items') i
 where i->>'engraving_type'<>'Fee' and exists (
   select 1 from jsonb_array_elements(coalesce(i->'marks','[]'::jsonb)) m where coalesce((m->>'paint_fill')::boolean,false)
 ) having sum((i->>'quantity')::integer)>0;
 if (select sum(quantity*unit_price) from public.quote_items where quote_id=qid)<=0 then raise exception 'Quote total must be positive'; end if;
 return qid;
end $$;
