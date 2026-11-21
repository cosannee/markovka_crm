import fs from 'node:fs';
import assert from 'node:assert/strict';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE);
const source=fs.readFileSync('index.html','utf8');
const styles=[...source.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m=>m[1]).join('\n');
const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
try{
  const page=await browser.newPage();
  const rows=Array.from({length:8},(_,i)=>`<article class="attention-row"><div class="attention-main"><div class="attention-title"><button class="order-reference">И${360+i}</button><span class="attention-client">Клиент ${i+1}</span>${i===1?'<span class="attention-urgent">Срочно</span>':''}</div><div class="attention-meta">Света · Мишка × 1</div></div><div class="attention-state"><strong>${i%2?'Нужна накладная':'Доплата 8 400 ₽'}</strong><small>${i%2?'Игрушки готовы к упаковке':'Готов 2 дн.'}</small></div><button class="btn btn-sm btn-secondary attention-primary">${i%2?'Накладная':'Написать'}</button><details class="attention-more"><summary>···</summary><div class="attention-menu"><button>Открыть карточку</button></div></details></article>`).join('');
  await page.setContent(`<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>${styles}</style><main style="max-width:980px;margin:auto;padding:16px"><section class="overview-priority"><div class="overview-priority-head"><div class="overview-priority-title"><h2>Требуют внимания · 8</h2><p>Только заказы, где сейчас нужно действие</p></div><div class="overview-master-filter"><label>Мастер</label><select><option>Все мастера</option></select></div></div><div class="attention-filters"><button class="attention-filter selected">Все<b>8</b></button><button class="attention-filter">Проверить<b>1</b></button><button class="attention-filter">Ждут оплаты<b>3</b></button><button class="attention-filter">Нужна накладная<b>4</b></button></div><div class="attention-list">${rows}</div></section><details class="overview-tools"><summary><span>Производство и загрузка</span><small>21 в работе</small></summary></details><details class="overview-tools"><summary><span>Оплаты и отправки</span><small>16 заказов</small></summary></details></main>`);
  for(const width of [390,1200]){
    await page.setViewportSize({width,height:1000});
    assert.ok(await page.locator('.attention-row').first().isVisible());
    assert.equal(await page.locator('.overview-tools[open]').count(),0);
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
    await page.screenshot({path:`/private/tmp/markovka-attention-${width}.png`,fullPage:true});
  }
  console.log('PASS compact attention rows, collapsed secondary sections, mobile overflow');
}finally{await browser.close();}
