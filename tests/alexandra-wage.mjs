import fs from 'node:fs';import vm from 'node:vm';import assert from 'node:assert/strict';
const {PGlite}=await import(process.env.PGLITE_MODULE);const db=new PGlite();
await db.exec(`create schema crm_private;create table public.finance(id text primary key,data jsonb);insert into public.finance values('app-settings','{"keep":123}');`);
const sql=fs.readFileSync('supabase/migrations/004-finance.sql','utf8');await db.exec(sql.slice(sql.indexOf('create or replace function crm_private.fin_num'),sql.indexOf('create or replace function crm_private.fin_flag')));
await db.exec(fs.readFileSync('release/014-alexandra-wage.sql','utf8'));
await db.exec(fs.readFileSync('release/014-alexandra-wage.sql','utf8'));
const s=fs.readFileSync('index.html','utf8');const ctx={finance:[{id:'app-settings',alexandraWageV1:true}],getItems:o=>o.items,orderQty:o=>o.items.reduce((s,i)=>s+i.count,0),urgentBonusPct:o=>o.urgent?.5:0,calcItemMasterPay:(i,m)=>(2800+(m==='Даша'?300:0)+i.embCount*400+(i.bandOn?200:0)+(i.capOn?300:0))*i.count};vm.createContext(ctx);vm.runInContext(s.slice(s.indexOf('function calcMasterPay(o){'),s.indexOf('function calcAdvance(o){')),ctx);
for(const master of ['Александра','Даша','Вика'])for(const urgent of [false,true])for(const paid of ['none','legacy','recorded']){
 const o={master,urgent,postpayPaid:paid!=='none',status:'ready',items:[{weightG:3200,count:2,embCount:1,price:10000,bandOn:true,capOn:true}]};
 if(paid==='recorded')o.financePayments={postpay:{amount:12345}};
 const expected=paid==='recorded'&&master==='Александра'?12345:(3700+(master==='Даша'||master==='Александра'&&paid==='none'?300:0))*2*(urgent?1.5:1);
 assert.equal(ctx.calcMasterPay(o),expected);
 const result=(await db.query('select crm_private.fin_calc($1::jsonb) c',[JSON.stringify(o)])).rows[0].c;assert.equal(result.master,expected);
}
assert.equal((await db.query("select data->>'keep' value from public.finance")).rows[0].value,'123');
console.log('PASS 18 client/server rate scenarios; legacy paid, recorded paid, extras, quantity, urgency, unchanged settings, repeat migration');await db.close();
