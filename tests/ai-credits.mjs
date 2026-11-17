import fs from 'node:fs';import vm from 'node:vm';import assert from 'node:assert/strict';
const s=fs.readFileSync('index.html','utf8');const code=s.slice(s.indexOf('const OPENROUTER_PROXY='),s.indexOf('// ── СТАРОЕ ХРАНИЛИЩЕ'));
async function check(responses){let calls=0;const ctx={console:{error(){}},setTimeout:f=>f(),fetch:async()=>{const x=responses[calls++];return {ok:x.status===200,status:x.status,text:async()=>JSON.stringify(x.body||{error:{message:'test'}})};}};vm.createContext(ctx);vm.runInContext(code,ctx);try{return {result:await ctx.aiProxyRequest('synthetic',1800),calls};}catch(e){return {error:e.message,calls};}}
let x=await check([{status:402},{status:402}]);assert.match(x.error,/Недостаточно средств/);assert.equal(x.calls,2);
x=await check([{status:402},{status:200,body:{choices:[{message:{content:'{}'}}]}}]);assert.ok(x.result);
x=await check([{status:403},{status:403}]);assert.match(x.error,/отклонил/);
x=await check([{status:402},{status:503},{status:503}]);assert.match(x.error,/Недостаточно средств/);
for(const m of s.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))if(m[1].trim())new vm.Script(m[1]);
console.log('PASS insufficient credits message, cheaper fallback, access error, mixed errors, script syntax');
