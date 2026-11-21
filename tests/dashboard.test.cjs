const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {JSDOM} = require('jsdom');
const path = require('node:path');
const sample = JSON.parse(fs.readFileSync('tests/fixtures/dashboard-sample.json', 'utf8'));
async function page(data = sample, url = 'http://localhost/', twitch = null) {
  const dom = new JSDOM(fs.readFileSync('docs/index.html', 'utf8'), {url, runScripts: 'outside-only'});
  const requests = [];
  dom.window.fetch = async path => {
    requests.push(path);
    if (path.startsWith('https://api.github.com/')) {
      return {ok: true, json: async () => [{commit: {committer: {date: '2026-11-20T22:24:40Z'}}}]};
    }
    if (path.endsWith('/twitch-viewership.json')) {
      return {ok: twitch !== null, json: async () => structuredClone(twitch)};
    }
    return {ok: data !== null, json: async () => structuredClone(data)};
  };
  dom.requests = requests;
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
test('published view ignores demo reports and has no demo controls even when empty', async () => {
  const dom = await page(); const d = dom.window.document;
  assert.equal(d.getElementById('total').textContent, '—');
  assert.equal(d.getElementById('empty-board').hidden, false);
  assert.equal(d.getElementById('analytics-board').hidden, true);
  assert.equal(d.getElementById('data-mode').textContent, 'Published VODs');
  assert.doesNotMatch(d.body.textContent, /not proof|unverified suggestion|A note on the numbers|Invented sample data/i);
  assert.deepEqual(dom.requests, ['data/reports.json', 'data/twitch-viewership.json']);
  assert.equal(d.querySelectorAll('#demo-toggle, #demo-empty').length, 0);
  assert.doesNotMatch(d.body.textContent, /Try the demo|Take a demo lap/);
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
test('live Pages dashboard reads main directly at startup and on refresh', async () => {
  const data = structuredClone(sample);
  data.reports[0].is_demo = false;
  const dom = await page(data, 'https://mactimit.github.io/brb-tracker/');
  const path = 'https://raw.githubusercontent.com/MacTimiT/brb-tracker/main/docs/data/';
  const sources = [path + 'reports.json', path + 'twitch-viewership.json',
    'https://api.github.com/repos/MacTimiT/brb-tracker/commits?sha=main&path=docs/data/reports.json&per_page=1'];
  assert.deepEqual(dom.requests, sources);
  assert.equal(dom.window.document.getElementById('published-time').dateTime, '2026-11-20T22:24:40Z');
  assert.equal(dom.window.document.getElementById('count').textContent, '6');
  data.reports[0].breaks.pop();
  dom.window.document.getElementById('refresh').click();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(dom.requests, [...sources, ...sources]);
  assert.equal(dom.window.document.getElementById('count').textContent, '5');
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
test('reason labels agree across filters, the leaderboard, the timeline, and receipts', async () => {
  const report = structuredClone(sample.reports[0]);
  report.is_demo = false;
  report.breaks = [
    {...report.breaks[0], reason: 'Help Rachel'},
    {...report.breaks[1], reason: 'Mental Break'},
  ];
  const dom = await page({schema_version: 1, reports: [report]});
  const d = dom.window.document;
  assert.deepEqual([...d.querySelectorAll('#reason option')].map(option => option.textContent), [
    'All reasons', 'Pee breaks', 'Snack raids', 'Hydration runs', 'Stretch breaks',
    'Tech gremlins', 'Helping Rachel', 'Mental breaks', 'Side quests', 'Unsolved mysteries',
  ]);
  assert.deepEqual([...d.querySelectorAll('.reason-name')].map(row => row.textContent), ['Helping Rachel', 'Mental breaks']);
  assert.deepEqual([...d.querySelectorAll('#timeline-legend li')].map(label => label.textContent), ['Helping Rachel', 'Mental breaks']);
  assert.match(d.getElementById('leaderboard-note').textContent, /Helping Rachel \/ Mental breaks/);
  change(dom, 'reason-metric', 'seconds');
  assert.match(d.getElementById('leaderboard-note').textContent, /Mental breaks/);
  change(dom, 'reason', 'Mental Break');
  assert.match(d.getElementById('away-label').textContent, /^Mental breaks /);
  d.querySelector('.receipt-open').click();
  assert.match(d.getElementById('receipt-title').textContent, /Mental breaks/);
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

test('secondary reasons show in receipts and select the same break once', async () => {
  const report = structuredClone(sample.reports[0]);
  report.is_demo = false;
  report.breaks = [{...report.breaks[0], reason: 'Pee', additional_reasons: ['Help Rachel']}];
  const dom = await page({schema_version: 1, reports: [report]});
  const d = dom.window.document;
  const total = d.getElementById('total').textContent;
  change(dom, 'reason', 'Help Rachel');
  assert.equal(d.getElementById('count').textContent, '1');
  assert.equal(d.getElementById('total').textContent, total);
  assert.match(d.querySelector('.reason-tag').textContent, /Pee breaks \/ Helping Rachel/);
  d.querySelector('.receipt-open').click();
  assert.match(d.getElementById('receipt-title').textContent, /Helping Rachel/);
  dom.window.close();
});

test('estimated Twitch viewer-hours follow the filters and explain their coverage', async () => {
  const report = structuredClone(sample.reports[0]);
  report.video_id = 'fixture0001';
  report.stream_started_at = '2026-11-12T14:05:09Z';
  report.is_demo = false;
  const other = {...report, id: 'no-twitch-match', video_id: 'fixture0002'};
  const data = {schema_version: 1, reports: [report, other]};
  const twitch = {schema_version: 1, matches: {
    fixture0001: {
      average_viewers: 200,
      vod_started_at: report.stream_started_at,
      vod_duration_seconds: report.duration_seconds,
    },
  }};
  const dom = await page(data, 'http://localhost/', twitch);
  const d = dom.window.document;
  assert.equal(d.getElementById('twitch-viewer-hours').textContent, '73.3 h');
  assert.equal(d.getElementById('twitch-coverage').textContent, '1 of 2 VODs matched');
  assert.equal(d.querySelector('.vod-twitch strong').textContent, '73.3 h');
  assert.match(d.querySelector('.vod-twitch small').textContent, /200 avg viewers/);
  d.querySelector('.receipt-open').click();
  assert.match(d.getElementById('receipt-twitch').textContent, /200 average viewers/);
  change(dom, 'reason', 'Pee');
  assert.equal(d.getElementById('twitch-viewer-hours').textContent, '30 h');
  change(dom, 'vod', 'fixture0002');
  assert.equal(d.getElementById('twitch-viewer-hours').textContent, '—');
  d.getElementById('twitch-viewer-hours-help').click();
  const dialog = d.getElementById('twitch-viewer-hours-dialog');
  assert.equal(dialog.open, true);
  assert.match(dialog.textContent, /BRB seconds ÷ 3,600/);
  assert.match(dialog.textContent, /average across the whole Twitch broadcast/);
  dom.window.close();
});

test('reason and stream buttons keep focus and receipt rows include both review states', async () => {
  const data = structuredClone(sample); data.reports[0].is_demo = false;
  data.reports[0].breaks[0].reviewed = false;
  data.reports[0].breaks[1].reviewed = true;
  const dom = await page(data); const d = dom.window.document;
  assert.equal(d.querySelectorAll('.receipt-row').length, 6);
  assert.equal(d.querySelectorAll('.receipt-row .reviewed').length, 0);
  const reason = d.querySelector('.reason-row');
  reason.focus();
  const key = reason.dataset.focusKey;
  reason.click();
  assert.equal(d.activeElement.dataset.focusKey, key);
  const vod = d.querySelector('.vod-name');
  vod.focus(); vod.click();
  assert.equal(d.activeElement.dataset.focusKey, vod.dataset.focusKey);
  const cell = d.querySelector('.receipt-row .receipt-duration');
  cell.click();
  assert.equal(d.getElementById('receipt-dialog').open, true);
  dom.window.close();
});

test('missing sources are distinct from empty or unmatched data', async () => {
  const outage = await page(null);
  assert.equal(outage.window.document.getElementById('empty-board').hidden, true);
  assert.match(outage.window.document.getElementById('scope-summary').textContent, /unavailable/);
  outage.window.close();
  const data = structuredClone(sample); data.reports[0].is_demo = false;
  const dom = await page(data); const d = dom.window.document;
  assert.equal(d.getElementById('analytics-board').hidden, false);
  assert.match(d.getElementById('twitch-coverage').textContent, /unavailable/);
  change(dom, 'search', 'impossible-search-value', 'input');
  assert.equal(d.getElementById('csv-export').disabled, true);
  assert.equal(d.getElementById('export').disabled, false);
  dom.window.close();
});

test('large archives load with incremental rows and chronological receipts', async () => {
  const base = sample.reports[0];
  const reports = Array.from({length: 501}, (_, i) => ({
    ...base,
    id: `test-vod-${i}`, video_id: null, is_demo: false,
    vod_date: i ? '2026-11-20' : '2026-11-09',
    breaks: i ? base.breaks.slice(0, 1) : base.breaks.slice(0, 2),
  })).reverse();
  const dom = await page({schema_version: 1, reports}); const d = dom.window.document;
  assert.equal(d.getElementById('count').textContent, '502');
  change(dom, 'log-sort', 'stream');
  assert.match(d.querySelector('.receipt-row').textContent, /2026-11-09/);
  assert.equal(d.querySelectorAll('.receipt-row').length, 24);
  assert.equal(d.querySelectorAll('.timeline-row').length, 24);
  d.getElementById('more-receipts').click();
  assert.equal(d.querySelectorAll('.receipt-row').length, 48);
  assert.equal(d.activeElement.className, 'receipt-open');
  dom.window.close();
});

test('timeline colors identify primary reasons under a secondary reason filter', async () => {
  const data = structuredClone(sample);
  const report = data.reports[0]; report.is_demo = false;
  report.breaks = [{...report.breaks[0], reason: 'Pee', additional_reasons: ['Drink']}];
  const dom = await page(data); const d = dom.window.document;
  change(dom, 'reason', 'Drink');
  assert.equal(d.getElementById('timeline-legend').textContent, 'Pee breaks');
  assert.equal(d.querySelector('.reason-swatch').style.backgroundColor, d.querySelector('.break-mark').style.backgroundColor);
  dom.window.close();
});
