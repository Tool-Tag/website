
create or replace function private.priced_scope(p_items jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  result jsonb:='[]';
  item_json jsonb;
  mark_json jsonb;
  qty integer;
  cnt integer;
  extra numeric;
  paint numeric;
  base numeric;
  idx integer:=0;
  logos integer;
begin
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Add at least one item';
  end if;

  for item_json in select value from jsonb_array_elements(p_items) loop
    qty:=(item_json->>'quantity')::integer;
    base:=(item_json->>'unit_price')::numeric;

    if qty is null or qty<1 or qty>10000 or base is null or base<0 or base<>round(base,2)
       or nullif(trim(item_json->>'article'),'') is null then
      raise exception 'Invalid quantity, article or base price';
    end if;

    if coalesce(item_json->>'engraving_type','') not in ('Fee','Text','Image / Logo') then
      raise exception 'Invalid engraving type';
    end if;

    cnt:=case
      when item_json->>'engraving_type'='Fee' then 0
      else jsonb_array_length(coalesce(item_json->'marks','[]'))
    end;

    if item_json->>'engraving_type'<>'Fee' and cnt<1 then
      raise exception 'Add engraving details';
    end if;

    paint:=0;

    for mark_json in
      select value from jsonb_array_elements(coalesce(item_json->'marks','[]'))
    loop
      if item_json->>'engraving_type'='Fee' then exit; end if;

      if nullif(trim(mark_json->>'location'),'') is null
         or coalesce(mark_json->>'type','') not in ('Text','Image / Logo') then
        raise exception 'Engraving location and type required';
      end if;

      if mark_json->>'type'='Text' and nullif(trim(mark_json->>'text'),'') is null then
        raise exception 'Engraving text required';
      end if;

      if mark_json->>'type'='Image / Logo' and coalesce(mark_json->>'url','') !~ '^https?://' then
        raise exception 'Image link required';
      end if;

      if coalesce((mark_json->>'paint_fill')::boolean,false) then
        if coalesce(mark_json->'paint_details'->>'mode','') not in ('single','multiple')
           or (mark_json->'paint_details'->>'mode'='single'
               and nullif(trim(mark_json->'paint_details'->>'color'),'') is null)
           or (mark_json->'paint_details'->>'mode'='multiple'
               and nullif(trim(mark_json->'paint_details'->>'instructions'),'') is null) then
          raise exception 'Paint instructions required';
        end if;
        paint:=2;
      end if;
    end loop;

    extra:=greatest(cnt-1,0)*5;

    result:=result||jsonb_build_array(
      item_json||jsonb_build_object(
        'unit_price',base,
        'sort_order',idx,
        'adaptation_fee',false,
        'paint_fee',false,
        'additional_engraving_fee',false,
        'pricing',jsonb_build_object(
          'version',1,
          'engraving_count',cnt,
          'base_unit_price',base,
          'additional_engraving_unit_charge',extra,
          'additional_engraving_charge',extra*qty,
          'paint_unit_charge',paint,
          'paint_charge',paint*qty,
          'line_total',qty*(base+extra+paint)
        )
      )
    );
    idx:=idx+1;

    if extra>0 then
      result:=result||jsonb_build_array(
        jsonb_build_object(
          'article','Grabados adicionales · '||(item_json->>'article'),
          'quantity',qty*greatest(cnt-1,0),
          'unit_price',5,
          'engraving_type','Fee',
          'notes','Primer grabado incluido; $5 por grabado adicional y pieza.',
          'sort_order',idx,
          'additional_engraving_fee',true
        )
      );
      idx:=idx+1;
    end if;

    if paint>0 then
      result:=result||jsonb_build_array(
        jsonb_build_object(
          'article','Pintura · '||(item_json->>'article'),
          'quantity',qty,
          'unit_price',2,
          'engraving_type','Fee',
          'notes','$2 por pieza coloreada, independientemente del número de grabados con pintura.',
          'sort_order',idx,
          'paint_fee',true
        )
      );
      idx:=idx+1;
    end if;
  end loop;

  select count(distinct trim(mark_elem->>'url'))
  into logos
  from jsonb_array_elements(p_items) as item_elem
  cross join lateral jsonb_array_elements(coalesce(item_elem->'marks','[]')) as mark_elem
  where item_elem->>'engraving_type'<>'Fee'
    and mark_elem->>'type'='Image / Logo';

  if logos>0 then
    result:=result||jsonb_build_array(
      jsonb_build_object(
        'article','Adaptación de imagen / logo para Falcon',
        'quantity',logos,
        'unit_price',3,
        'engraving_type','Fee',
        'notes','$3 por diseño diferente.',
        'adaptation_fee',true,
        'sort_order',idx
      )
    );
  end if;

  return result;
end $$;
