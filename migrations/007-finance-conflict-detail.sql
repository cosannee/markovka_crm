-- Preserve the payout concurrency guard and report the affected order and fields.
do $migration$
declare
  current_definition text;
  old_guard text := $old$if e->'expected' is distinct from crm_private.pick(j,array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']) then raise exception 'Заказ изменился. Обновите расчёт';end if;$old$;
  new_guard text := $new$if e->'expected' is distinct from crm_private.pick(j,array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']) then
    raise exception 'Заказ % изменился. Обновите расчёт',coalesce(j->>'num',oid)
      using detail='Не совпали поля: '||coalesce((select string_agg(f,', ') from unnest(array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']) as x(f) where (e->'expected')->f is distinct from j->f),'структура записи');
   end if;$new$;
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
    raise exception 'Payout guard occurs more than once; no change applied';
  end if;
  execute replace(current_definition,old_guard,new_guard);
end
$migration$;
