-- Change only the postpay guard in the deployed function. Preserve all other logic.
do $migration$
declare
  current_definition text := pg_get_functiondef('public.crm_finance_action(text,text,jsonb)'::regprocedure);
  old_guard text := $old$if k='postpay' and j->>'status' not in ('ready','planned','sent','done','archived') then raise exception 'Заказ ещё не готов';end if;$old$;
  new_guard text := $new$if k='postpay' and (j->>'status' not in ('ready','planned','sent','done','archived') or (j->>'status'='archived' and ((nullif(j->>'prevStatus','') is not null and j->>'prevStatus' not in ('ready','planned','sent','done')) or (nullif(j->>'prevStatus','') is null and coalesce(c->>'closed','false')<>'true')))) then raise exception 'Заказ ещё не готов';end if;$new$;
begin
  if position(old_guard in current_definition)=0 then
    raise exception 'Unexpected finance function version; no change applied';
  end if;
  if position(old_guard in substring(current_definition from position(old_guard in current_definition)+length(old_guard)))>0 then
    raise exception 'Guard occurs more than once; no change applied';
  end if;
  execute replace(current_definition,old_guard,new_guard);
end
$migration$;
