-- Disable new advance payouts. Historical advance records remain available for audit and cancellation.
do $migration$
declare
  current_definition text;
  old_guard text := $old$if k='advance' and (j->>'master'<>'Света' or j->>'status' not in ('new','nextweek','work') or crm_private.fin_num(c,'advance')<=0) then raise exception 'Аванс сейчас недоступен';end if;$old$;
  new_guard text := $new$if k='advance' then raise exception 'Авансовая система отключена';end if;$new$;
begin
  select pg_get_functiondef('public.crm_finance_action(text,text,jsonb)'::regprocedure)
    into current_definition;
  if position(new_guard in current_definition)>0 then
    return;
  end if;
  if position(old_guard in current_definition)=0 then
    raise exception 'Unexpected finance function version; no change applied';
  end if;
  if position(old_guard in substring(current_definition from position(old_guard in current_definition)+length(old_guard)))>0 then
    raise exception 'Advance guard occurs more than once; no change applied';
  end if;
  execute replace(current_definition,old_guard,new_guard);
end
$migration$;
