-- Apply the order tax after the existing commission and production costs.
do $migration$
declare
  definition text := pg_get_functiondef('crm_private.fin_calc(jsonb)'::regprocedure);
  old_formula constant text := $old$profit:=total-materials-commission-wage-case when nm='Даша' then 350*qty else 0 end;$old$;
  new_formula constant text := $new$profit:=total-materials-commission-wage-case when nm='Даша' then 350*qty else 0 end-round(total*.05);$new$;
  sample constant jsonb := '{"master":"Даша","price":15000,"weightG":2000,"status":"done","closed":true,"prepaid":15000}';
  before_change jsonb;
  after_change jsonb;
begin
  if strpos(definition,new_formula)>0 and strpos(definition,old_formula)=0 then return; end if;
  if strpos(definition,old_formula)=0 or strpos(definition,new_formula)>0
     or strpos(substr(definition,strpos(definition,old_formula)+length(old_formula)),old_formula)>0
     or strpos(definition,$rate$'dividend',round(greatest(0,profit)*.15),$rate$)=0 then
    raise exception 'Unexpected finance calculation; order tax was not applied';
  end if;

  before_change := crm_private.fin_calc(sample);
  execute replace(definition,old_formula,new_formula);
  after_change := crm_private.fin_calc(sample);
  if after_change->'sasha' is distinct from before_change->'sasha'
     or (after_change->>'profit')::numeric is distinct from (before_change->>'profit')::numeric - 750
     or (after_change->>'dividend')::numeric is distinct from round(greatest(0,(after_change->>'profit')::numeric)*.15) then
    raise exception 'Order tax verification failed';
  end if;
end
$migration$;
