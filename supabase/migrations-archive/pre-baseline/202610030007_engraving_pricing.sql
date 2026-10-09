alter table public.quote_items add column additional_engraving_fee boolean not null default false, add column pricing jsonb not null default '{}';
create function private.priced_scope(p_items jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb:='[]'; i jsonb; m jsonb; qty integer; cnt integer; extra numeric; paint numeric; base numeric; idx integer:=0; logos integer;
begin
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item'; end if;
 for i in select value from jsonb_array_elements(p_items) loop
   qty:=(i->>'quantity')::integer; base:=(i->>'unit_price')::numeric;
   if qty is null or qty<1 or qty>10000 or base is null or base<0 or base<>round(base,2) or nullif(trim(i->>'article'),'') is null then raise exception 'Invalid quantity, article or base price'; end if;
   if coalesce(i->>'engraving_type','') not in ('Fee','Text','Image / Logo') then raise exception 'Invalid engraving type'; end if;
   cnt:=case when i->>'engraving_type'='Fee' then 0 else jsonb_array_length(coalesce(i->'marks','[]')) end;
   if i->>'engraving_type'<>'Fee' and cnt<1 then raise exception 'Add engraving details'; end if;
   paint:=0;
   for m in select value from jsonb_array_elements(coalesce(i->'marks','[]')) loop
     if i->>'engraving_type'='Fee' then exit; end if;
     if nullif(trim(m->>'location'),'') is null or coalesce(m->>'type','') not in ('Text','Image / Logo') then raise exception 'Engraving location and type required'; end if;
     if m->>'type'='Text' and nullif(trim(m->>'text'),'') is null then raise exception 'Engraving text required'; end if;
     if m->>'type'='Image / Logo' and coalesce(m->>'url','') !~ '^https?://' then raise exception 'Image link required'; end if;
     if coalesce((m->>'paint_fill')::boolean,false) then
       if coalesce(m->'paint_details'->>'mode','') not in ('single','multiple') or
         (m->'paint_details'->>'mode'='single' and nullif(trim(m->'paint_details'->>'color'),'') is null) or
         (m->'paint_details'->>'mode'='multiple' and nullif(trim(m->'paint_details'->>'instructions'),'') is null) then raise exception 'Paint instructions required'; end if;
       paint:=2;
     end if;
   end loop;
   extra:=greatest(cnt-1,0)*5;
   result:=result||jsonb_build_array(i||jsonb_build_object('unit_price',base,'sort_order',idx,'adaptation_fee',false,'paint_fee',false,'additional_engraving_fee',false,
     'pricing',jsonb_build_object('version',1,'engraving_count',cnt,'base_unit_price',base,'additional_engraving_unit_charge',extra,'additional_engraving_charge',extra*qty,'paint_unit_charge',paint,'paint_charge',paint*qty,'line_total',qty*(base+extra+paint))));
   idx:=idx+1;
   if extra>0 then
     result:=result||jsonb_build_array(jsonb_build_object('article','Grabados adicionales · '||(i->>'article'),'quantity',qty*greatest(cnt-1,0),'unit_price',5,'engraving_type','Fee','notes','Primer grabado incluido; $5 por grabado adicional y pieza.','sort_order',idx,'additional_engraving_fee',true)); idx:=idx+1;
   end if;
   if paint>0 then
     result:=result||jsonb_build_array(jsonb_build_object('article','Pintura · '||(i->>'article'),'quantity',qty,'unit_price',2,'engraving_type','Fee','notes','$2 por pieza coloreada, independientemente del número de grabados con pintura.','sort_order',idx,'paint_fee',true)); idx:=idx+1;
   end if;
 end loop;
 select count(distinct trim(m->>'url')) into logos from jsonb_array_elements(p_items) i cross join lateral jsonb_array_elements(coalesce(i->'marks','[]')) m where i->>'engraving_type'<>'Fee' and m->>'type'='Image / Logo';
 if logos>0 then result:=result||jsonb_build_array(jsonb_build_object('article','Adaptación de imagen / logo para Falcon','quantity',logos,'unit_price',3,'engraving_type','Fee','notes','$3 por diseño diferente.','adaptation_fee',true,'sort_order',idx)); end if;
 return result;
end $$;
revoke all on function private.priced_scope(jsonb) from public,anon,authenticated;
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
 for item in select value from jsonb_array_elements(private.priced_scope(p->'items')) loop
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,engraving_text,width_mm,height_mm,paint_fill,colors,unit_price,notes,sort_order,marks,paint_details,adaptation_fee,paint_fee,additional_engraving_fee,pricing)
 values(u,qid,item->>'article',(item->>'quantity')::integer,item->>'engraving_type',item->>'engraving_text',nullif(item->>'width_mm','')::numeric,nullif(item->>'height_mm','')::numeric,false,0,(item->>'unit_price')::numeric,item->>'notes',(item->>'sort_order')::integer,coalesce(item->'marks','[]'),coalesce(item->'paint_details','{}'),coalesce((item->>'adaptation_fee')::boolean,false),coalesce((item->>'paint_fee')::boolean,false),coalesce((item->>'additional_engraving_fee')::boolean,false),coalesce(item->'pricing','{}'));
 end loop;
 if (select sum(quantity*unit_price) from public.quote_items where quote_id=qid)<=0 then raise exception 'Quote total must be positive'; end if;
 return qid;
end $$;
