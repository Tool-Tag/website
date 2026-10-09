
update public.quote_items i
set notes='$3 per unique design; charged once per Quote.'
from public.quotes q
where i.quote_id=q.id
  and q.status='Draft'
  and q.sent_at is null
  and i.notes='$3 por diseño diferente; se cobra una vez por cotización.';
