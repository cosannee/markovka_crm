import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source=fs.readFileSync('index.html','utf8');
const start=source.indexOf('function dashboardCooOutstanding(o){');
const end=source.indexOf('function dashboardMaster(name){',start);
assert.ok(start>=0&&end>start,'dashboard COO functions not found');

const ctx={
 MASTERS:['Даша'],CRAFT_STAGES:[],
 finSum:(list,fn)=>list.reduce((sum,item)=>sum+fn(item),0),
 orderQty:o=>o.qty||1,productionReady:o=>['ready','planned','sent','done'].includes(o.status),
 effectiveCraftStage:()=>'',calcMasterPay:o=>o.masterPay||0,remainingPay:o=>o.masterLeft||0,
 calcCosts:o=>({sasha:o.coo||0}),finPaid:(o,k)=>k==='sasha'?(o.cooPaid||0):0,
 officeEligible:o=>Boolean(o.closed),orderTotal:o=>o.price||0
};
vm.createContext(ctx);
vm.runInContext(source.slice(start,end),ctx);
const nextStart=source.indexOf('function nextWeekFinanceData(assigned){');
const nextEnd=source.indexOf('function nextWeekFinanceHtml(data){',nextStart);
ctx.calcNastya=()=>0;
vm.runInContext(source.slice(nextStart,nextEnd),ctx);

const orders=[
 {id:'work',status:'work',master:'Даша',coo:1000,masterLeft:2000,qty:1},
 {id:'ready-paid',status:'ready',master:'Даша',coo:900,sashaPaid:true,masterLeft:0,qty:1},
 {id:'planned-part',status:'planned',master:'Даша',coo:800,cooPaid:300,masterLeft:500,qty:1},
 {id:'sent-unpaid',status:'sent',master:'Даша',coo:700,closed:true,qty:1},
 {id:'sent-paid',status:'sent',master:'Даша',coo:600,closed:true,sashaPaid:true,qty:1},
 {id:'next',status:'nextweek',master:'Даша',coo:500,qty:1}
];
const result=ctx.dashboardData(orders);
assert.equal(result.coo,2200,'COO forecast keeps active and closed unpaid amounts, less recorded partial payout');
assert.deepEqual(Array.from(result.cooOrders,o=>o.id),['work','planned-part','sent-unpaid']);
assert.equal(result.wages,4700,'total remaining combines current master balance and unpaid COO forecast');
assert.equal(ctx.dashboardCooOutstanding(orders[1]),0,'paid COO order is excluded before shipment');
assert.equal(ctx.dashboardCooOutstanding(orders[2]),500,'recorded payout is subtracted');
const next=ctx.nextWeekFinanceData({map:{'Даша':[orders[1],orders[5]]},unassignedToys:0});
assert.equal(next.coo,500,'next-week COO forecast excludes an order already paid to COO');

console.log('overview COO forecast: ok');
