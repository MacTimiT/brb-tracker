const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {JSDOM} = require('jsdom');
const path = require('node:path');
const sample = JSON.parse(fs.readFileSync('docs/data/demo.json', 'utf8'));
async function page(data = sample) {
  const dom = new JSDOM(fs.readFileSync('docs/index.html', 'utf8'), {url: 'http://localhost/', runScripts: 'outside-only'});
  dom.window.fetch = async path => ({ok: true, json: async () => structuredClone(path.includes('demo.json') ? sample : data)});
  for (const dialog of dom.window.document.querySelectorAll('dialog')) {
    dialog.showModal = () => { dialog.open = true; };
    dialog.close = () => { dialog.open = false; };
  }
  dom.window.eval(fs.readFileSync('docs/analytics.js', 'utf8'));
  dom.window.eval(fs.readFileSync('docs/app.js', 'utf8'));
  await new Promise(resolve => setImmediate(resolve));
  return dom;
}
function change(dom, id, value, type = 'change') {
  const control = dom.window.document.getElementById(id);
  control.value = value;
  control.dispatchEvent(new dom.window.Event(type));
}
test('published view does not pass off invented demo numbers as real attendance', async () => {
  const dom = await page(); const d = dom.window.document;
  assert.equal(d.getElementById('total').textContent, '—');
  assert.equal(d.getElementById('empty-board').hidden, false);
  assert.equal(d.getElementById('analytics-board').hidden, true);
  assert.equal(d.getElementById('data-mode').textContent, 'Published VODs');
  assert.doesNotMatch(d.body.textContent, /not proof|unverified suggestion|A note on the numbers|Invented sample data/i);
  d.getElementById('demo-empty').click();
  assert.equal(d.getElementById('data-mode').textContent, 'Demo round');
  assert.equal(d.getElementById('count').textContent, '6');
  assert.equal(d.getElementById('total').textContent, '22m 0s');
  assert.equal(d.getElementById('median').textContent, '3m 15s');
  assert.equal(d.getElementById('rate').textContent, '1.50');
  assert.equal(d.getElementById('empty-board').hidden, true);
  dom.window.close();
});
test('real published reports render automatically; reason filters keep the full VOD denominator', async () => {
  const real = structuredClone(sample); real.reports[0].is_demo = false;
  const dom = await page(real); const d = dom.window.document;
  assert.equal(d.getElementById('count').textContent, '6');
  assert.equal(d.getElementById('analytics-board').hidden, false);
  change(dom, 'reason', 'Pee');
  assert.equal(d.getElementById('count').textContent, '3');
  assert.equal(d.getElementById('total').textContent, '9m 0s');
  assert.equal(d.getElementById('away-percent').textContent, '3.8%');
  assert.equal(d.querySelectorAll('#breaks tr').length, 3);
  assert.equal(d.getElementById('streak').querySelector('.record-value').textContent, '41m 20s');
  dom.window.close();
});
test('leaderboard switches between counts and total minutes and supports click filtering', async () => {
  const r = structuredClone(sample.reports[0]); r.is_demo = false;
  // One long snack break beats more numerous short bathroom breaks by time.
  r.breaks[1].end_seconds = 5200;
  const dom = await page({schema_version: 1, reports: [r]}); const d = dom.window.document;
  assert.match(d.querySelector('.reason-row').textContent, /Pee breaks/);
  change(dom, 'reason-metric', 'seconds');
  assert.match(d.querySelector('.reason-row').textContent, /Snack raids/);
  d.querySelector('.reason-row').click();
  assert.equal(d.getElementById('reason').value, 'Snack');
  assert.equal(d.getElementById('count').textContent, '1');
  dom.window.close();
});
test('search and ordering affect the receipt list while analytics keep their scope', async () => {
  const real = structuredClone(sample); real.reports[0].is_demo = false;
  const dom = await page(real); const d = dom.window.document;
  assert.equal(d.querySelector('#breaks .reason-tag').textContent, 'Snack raids');
  change(dom, 'log-sort', 'shortest');
  assert.equal(d.querySelector('#breaks .reason-tag').textContent, 'Unsolved mysteries');
  change(dom, 'search', 'water', 'input');
  assert.equal(d.querySelectorAll('#breaks tr').length, 1);
  assert.equal(d.getElementById('log-count').textContent, '1 / 6');
  assert.equal(d.getElementById('count').textContent, '6');
  dom.window.close();
});
test('receipt dialogs preserve literal quotes and validated timestamp links', async () => {
  const r = structuredClone(sample.reports[0]);
  r.is_demo = false; r.title = '<img src=x onerror=alert(1)>'; r.video_id = 'IW2rEIuKGSs';
  r.breaks[1].evidence = '<script>alert("x")</script>';
  const dom = await page({schema_version: 1, reports: [r]}); const d = dom.window.document;
  d.querySelector('.receipt-open').click();
  assert.equal(d.getElementById('receipt-dialog').open, true);
  assert.equal(d.getElementById('receipt-quote').textContent, '<script>alert("x")</script>');
  assert.equal(d.querySelectorAll('img').length, 1); // Creator photo only.
  assert.equal(d.getElementById('receipt-watch').href, 'https://www.youtube.com/watch?v=IW2rEIuKGSs&t=4200s');
  assert.equal(d.getElementById('receipt-watch').hidden, false);
  dom.window.close();
});
test('public dashboard exposes no upload, editing or admin app controls', async () => {
  const dom = await page(); const d = dom.window.document;
  assert.equal(d.querySelectorAll('input[type="file"],textarea,[contenteditable],#import-open,#import-dialog').length, 0);
  assert.doesNotMatch(d.body.textContent, /import|bring your own|Get the app|Android app|hit Publish/i);
  assert.equal(d.querySelectorAll('a[href*=".apk"],a[href*="releases"]').length, 0);
  dom.window.close();
});
test('VOD ranking buttons select a stream by stable identity', async () => {
  const first = structuredClone(sample.reports[0]); first.is_demo = false; first.id = 'first'; first.title = 'First stream';
  const second = structuredClone(first); second.id = 'second'; second.title = 'Second stream'; second.breaks = [];
  const dom = await page({schema_version: 1, reports: [first, second]}); const d = dom.window.document;
  assert.equal(d.querySelectorAll('#vod-table tr').length, 2);
  d.querySelectorAll('.vod-name')[1].click();
  assert.equal(d.getElementById('vod').value, 'second');
  assert.equal(d.getElementById('count').textContent, '0');
  assert.equal(d.querySelectorAll('#vod-table tr').length, 1);
  dom.window.close();
});
test('refresh failures keep the last published numbers on the board', async () => {
  const real = structuredClone(sample); real.reports[0].is_demo = false;
  const dom = await page(real); const d = dom.window.document;
  dom.window.fetch = async () => ({ok: false});
  d.getElementById('refresh').click();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(d.getElementById('count').textContent, '6');
  assert.equal(d.getElementById('notice').hidden, false);
  assert.match(d.getElementById('notice').textContent, /receipts didn’t arrive/);
  dom.window.close();
});
test('new stylesheet parses and every local page/font asset exists', async () => {
  const dom = await page();
  const d = dom.window.document;
  const css = fs.readFileSync('docs/style.css', 'utf8');
  const style = d.createElement('style'); style.textContent = css; d.head.append(style);
  assert.ok(style.sheet.cssRules.length > 80);
  for (const element of d.querySelectorAll('link[href],script[src],img[src]')) {
    const url = element.getAttribute('href') || element.getAttribute('src');
    if (/^https?:/.test(url)) continue;
    assert.ok(fs.existsSync(path.join('docs', url.split('?')[0])), url);
  }
  for (const match of css.matchAll(/url\(['"]?([^'"\)]+)['"]?\)/g)) assert.ok(fs.existsSync(path.join('docs', match[1])), match[1]);
  dom.window.close();
});

test('month filter uses original VOD date and keeps undated legacy reports separate', async () => {
  const old = {...structuredClone(sample.reports[0]), is_demo: false, id: 'old', vod_date: '2026-10-22', analyzed_at: '2026-11-12T15:00:00Z'};
  const recent = {...structuredClone(old), id: 'recent', vod_date: '2026-11-01'};
  const legacy = {...structuredClone(old), id: 'legacy', vod_date: null};
  const dom = await page({schema_version: 1, reports: [old, recent, legacy]}); const d = dom.window.document;
  change(dom, 'month', '2026-10');
  assert.equal(d.querySelectorAll('#vod-table tr').length, 1);
  assert.match(d.getElementById('vod-table').textContent, /2026-10-22/);
  assert.equal(d.getElementById('count').textContent, '6');
  change(dom, 'month', 'unknown');
  assert.equal(d.querySelectorAll('#vod-table tr').length, 1);
  assert.match(d.getElementById('vod-table').textContent, /Unknown/);
  dom.window.close();
});
