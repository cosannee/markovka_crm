-- Compare a batch payout against the original order snapshot only once per order.
-- Additional payout lines may update that order inside this same locked transaction.
do $migration$
declare
  current_definition text;
  old_declaration text := 'recipient text; old_payment jsonb;';
  new_declaration text := 'recipient text; old_payment jsonb; snapshots jsonb:=''{}'';';
  old_guard text := $old$   if e->'expected' is distinct from crm_private.pick(j,array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']) then
    raise exception 'Заказ % изменился. Обновите расчёт',coalesce(j->>'num',oid)
      using detail='Не совпали поля: '||coalesce((select string_agg(f,', ') from unnest(array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']) as x(f) where (e->'expected')->f is distinct from j->f),'структура записи');
   end if;$old$;
  new_guard text := $new$   if snapshots ? oid then
    if e->'expected' is distinct from snapshots->oid then raise exception 'В заказе % разные исходные расчёты',coalesce(j->>'num',oid);end if;
   else
    if e->'expected' is distinct from crm_private.pick(j,array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']) then
     raise exception 'Заказ % изменился. Обновите расчёт',coalesce(j->>'num',oid)
       using detail='Не совпали поля: '||coalesce((select string_agg(f,', ') from unnest(array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']) as x(f) where (e->'expected')->f is distinct from j->f),'структура записи');
    end if;
    snapshots:=snapshots||jsonb_build_object(oid,crm_private.pick(j,array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']));
   end if;$new$;
begin
  select pg_get_functiondef('public.crm_finance_action(text,text,jsonb)'::regprocedure)
    into current_definition;
  if position(new_declaration in current_definition)=0 then
    if position(old_declaration in current_definition)=0 then
      raise exception 'Unexpected finance function declaration; no change applied';
    end if;
    current_definition:=replace(current_definition,old_declaration,new_declaration);
  end if;
  if position(new_guard in current_definition)>0 then
    execute current_definition;
    return;
  end if;
  if position(old_guard in current_definition)=0 then
    raise exception 'Unexpected payout guard; no change applied';
  end if;
  if position(old_guard in substring(current_definition from position(old_guard in current_definition)+length(old_guard)))>0 then
    raise exception 'Payout guard occurs more than once; no change applied';
  end if;
  execute replace(current_definition,old_guard,new_guard);
end
$migration$;
