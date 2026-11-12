'use strict';
const $ = id => document.getElementById(id);
const A = globalThis.BRBStats;
const reasonNames = {Pee: 'Pee breaks', Snack: 'Snack raids', Drink: 'Hydration runs', Stretch: 'Touching grass', Technical: 'Tech gremlins', Other: 'Side quests', Unknown: 'Unsolved mysteries'};
const colors = {Pee: '#bc2028', Snack: '#985182', Drink: '#23748a', Stretch: '#527346', Technical: '#586582', Other: '#8a6842', Unknown: '#77736b'};
const state = {published: [], demo: [], mode: 'published', vod: 'all', reason: 'all', metric: 'count', query: '', sort: 'longest', loading: true, logEntries: []};
const integer = value => Math.round(value).toLocaleString('en-US');
const fixed = (value, places = 1) => Number(value).toFixed(places);
function duration(value) {
  if (value == null) return '—';
  const seconds = Math.round(value);
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
  if (seconds >= 60) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${seconds}s`;
}
function stamp(value) { const seconds = Math.floor(value); return `${Math.floor(seconds / 3600)}:${String(Math.floor(seconds / 60) % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`; }
function node(tag, text, className) { const item = document.createElement(tag); if (text != null) item.textContent = text; if (className) item.className = className; return item; }
function watchURL(item) { return item.report.video_id ? `https://www.youtube.com/watch?v=${item.report.video_id}&t=${Math.floor(item.start_seconds)}s` : null; }
function activeReports() { return state.mode === 'published' ? state.published : state.demo; }
function notice(message = '') { $('notice').textContent = message; $('notice').hidden = !message; }

function updateOptions() {
  const reports = activeReports();
  if (!reports.some(report => A.key(report) === state.vod)) state.vod = 'all';
  $('vod').replaceChildren(new Option('All streams', 'all'));
  for (const report of reports) $('vod').add(new Option(report.title, A.key(report)));
  $('vod').value = state.vod;
  $('reason').value = state.reason;
  $('reason-metric').value = state.metric;
  $('search').value = state.query;
  $('log-sort').value = state.sort;
}
function switchMode(mode) {
  state.mode = mode; state.vod = 'all'; state.reason = 'all'; state.query = '';
  notice(); render();
}
function render() {
  updateOptions();
  const source = activeReports();
  const selected = source.filter(report => state.vod === 'all' || A.key(report) === state.vod);
  const stats = A.compute(selected, state.reason);
  const hasReports = selected.length > 0;
  $('empty-board').hidden = hasReports || state.loading;
  $('analytics-board').hidden = !hasReports;
  const labels = {published: 'Published VODs', demo: 'Demo round'};
  $('data-mode').textContent = labels[state.mode];
  $('data-mode').classList.toggle('demo', state.mode.startsWith('demo'));
  $('scope-summary').textContent = state.loading ? 'Checking the receipts…' : `${selected.length} VOD${selected.length === 1 ? '' : 's'} · ${duration(stats.duration)} clocked`;
  $('demo-toggle').textContent = state.mode === 'published' ? 'Try the demo' : 'Published VODs';
  $('demo-toggle').disabled = state.mode === 'published' && !state.demo.length;
  $('refresh').disabled = state.loading || state.mode !== 'published';
  $('total').textContent = hasReports ? duration(stats.away) : '—';
  $('one-secs').textContent = hasReports ? `${integer(stats.away)} “one secs” and counting.` : 'Waiting for the first “one sec.”';
  $('share-fill').style.width = `${stats.percent}%`;
  const otherName = state.reason === 'all' ? 'Not BRB' : 'Everything else';
  const awayName = state.reason === 'all' ? 'BRB' : state.reason;
  $('other-label').textContent = `${otherName}${hasReports ? ' ' + fixed(stats.duration ? 100 - stats.percent : 0) + '%' : ''}`;
  $('away-label').textContent = `${awayName}${hasReports ? ' ' + fixed(stats.percent) + '%' : ''}`;
  $('count').textContent = integer(stats.count);
  $('away-percent').textContent = `${fixed(stats.percent)}%`;
  $('away-metric-label').textContent = state.reason === 'all' ? 'STREAM SPENT BRB' : `STREAM SPENT ON ${state.reason.toUpperCase()}`;
  $('average').textContent = duration(stats.average);
  $('median').textContent = duration(stats.median);
  $('rate').textContent = fixed(stats.rate, 2);
  renderReasons(stats);
  renderColumns('distribution', stats.distribution);
  renderColumns('phases', stats.phases, true);
  renderRecord('longest', stats.longest);
  renderRecord('shortest', stats.shortest);
  renderRecord('streak', stats.longestStreak, true);
  $('gap-mean').textContent = stats.meanGap == null ? '' : `Back at the desk for ${duration(stats.meanGap)} on average between breaks. A heroic effort. (All excuses.)`;
  renderVods(stats);
  renderTimeline(stats);
  renderLog(stats);
}

function renderReasons(stats) {
  const groups = [...stats.groups].sort((a, b) => b[state.metric] - a[state.metric] || A.reasons.indexOf(a.reason) - A.reasons.indexOf(b.reason));
  $('reasons').replaceChildren();
  if (!groups.length) {
    $('leaderboard-note').textContent = 'A spotless excuse sheet. For now.';
    $('reasons').append(node('p', 'No matching side quests.', 'chart-empty'));
    return;
  }
  const max = groups[0][state.metric];
  const tied = groups.filter(group => Math.abs(group[state.metric] - max) < 0.000001);
  $('leaderboard-note').textContent = tied.length > 1
    ? `${tied.map(group => reasonNames[group.reason]).join(' / ')} are sharing the podium.`
    : state.metric === 'seconds'
      ? `Most expensive excuse: ${reasonNames[groups[0].reason].toLowerCase()}.`
      : `${reasonNames[groups[0].reason]} takes it: ${groups[0].count} of ${stats.count} breaks.`;
  groups.forEach((group, index) => {
    const button = node('button', null, 'reason-row'); button.type = 'button';
    button.setAttribute('aria-pressed', String(state.reason === group.reason));
    button.title = `Filter ${group.reason} · ${group.count} breaks · ${duration(group.seconds)}`;
    const middle = node('span');
    const track = node('span', null, 'reason-track');
    const fill = node('span', null, 'reason-fill');
    fill.style.width = `${max ? group[state.metric] / max * 100 : 0}%`; fill.style.backgroundColor = colors[group.reason];
    track.append(fill); middle.append(node('span', reasonNames[group.reason], 'reason-name'), track);
    const values = node('span', state.metric === 'count' ? String(group.count) : duration(group.seconds), 'reason-values');
    values.append(node('small', state.metric === 'count' ? duration(group.seconds) : `${group.count} breaks`));
    button.append(node('span', String(index + 1).padStart(2, '0'), 'reason-position'), middle, values);
    button.onclick = () => { state.reason = state.reason === group.reason ? 'all' : group.reason; render(); };
    $('reasons').append(button);
  });
}
function renderColumns(id, groups, phases = false) {
  const container = $(id); container.replaceChildren();
  const max = Math.max(1, ...groups.map(group => group.count));
  groups.forEach(group => {
    const column = node('div', null, `column${group.count ? '' : ' zero'}`);
    column.setAttribute('role', 'img');
    column.setAttribute('aria-label', `${group.label}: ${group.count} break${group.count === 1 ? '' : 's'}${phases ? ', ' + fixed(group.rate, 2) + ' per stream hour' : ''}`);
    column.title = column.getAttribute('aria-label');
    const space = node('div', null, 'column-space');
    const bar = node('div', null, 'column-bar'); bar.style.height = `${group.count / max * 100}%`;
    bar.append(node('span', group.count)); space.append(bar);
    column.append(space, node('div', group.label, 'column-label')); container.append(column);
  });
}

function renderRecord(id, item, streak = false) {
  const container = $(id); container.replaceChildren();
  container.append(node('strong', item ? duration(item.seconds) + (!streak && item.truncated ? '+' : '') : '—', 'record-value'));
  if (!item) { container.append(node('span', 'No contender on file.', 'record-title')); return; }
  container.append(node('span', streak ? item.report.title : reasonNames[item.reason], 'record-title'));
  const button = node('button', streak ? `From ${stamp(item.start_seconds)} ↗` : 'Show receipt ↗', 'record-link');
  button.onclick = () => {
    if (!streak) { openReceipt(item); return; }
    state.vod = A.key(item.report); render();
    $('timeline').scrollIntoView?.({behavior: 'smooth', block: 'center'});
  };
  container.append(button);
}
function renderVods(stats) {
  $('vod-table').replaceChildren();
  stats.vods.forEach((row, index) => {
    const tr = node('tr');
    const title = node('td');
    const button = node('button', row.report.title, 'vod-name');
    button.onclick = () => { state.vod = A.key(row.report); render(); };
    title.append(node('span', String(index + 1).padStart(2, '0'), 'vod-rank'), button);
    tr.append(title, node('td', duration(row.report.duration_seconds)), node('td', row.count), node('td', duration(row.seconds)), node('td', `${fixed(row.percent)}%`, 'share-number'), node('td', fixed(row.rate, 2)));
    $('vod-table').append(tr);
  });
}
function renderTimeline(stats) {
  $('timeline').replaceChildren();
  for (const report of stats.reports) {
    const row = node('div', null, 'timeline-row');
    const track = node('div', null, 'timeline-track');
    for (const item of stats.entries.filter(entry => entry.report === report)) {
      const mark = node('button', null, 'break-mark');
      mark.style.left = `${report.duration_seconds ? item.start_seconds / report.duration_seconds * 100 : 0}%`;
      mark.style.width = `${report.duration_seconds ? item.seconds / report.duration_seconds * 100 : 0}%`;
      mark.style.backgroundColor = colors[item.reason];
      mark.setAttribute('aria-label', `${item.reason}, ${stamp(item.start_seconds)}, ${duration(item.seconds)}`);
      mark.title = mark.getAttribute('aria-label'); mark.onclick = () => openReceipt(item);
      track.append(mark);
    }
    const axis = node('div', null, 'timeline-axis'); axis.append(node('span', '0:00'), node('span', stamp(report.duration_seconds)));
    row.append(node('p', report.title, 'timeline-name'), track, axis); $('timeline').append(row);
  }
}
function renderLog(stats) {
  const query = state.query.trim().toLocaleLowerCase();
  const entries = stats.entries.filter(item => !query || `${item.report.title} ${item.reason} ${reasonNames[item.reason]} ${item.evidence}`.toLocaleLowerCase().includes(query));
  if (state.sort !== 'stream') entries.sort((a, b) => state.sort === 'longest' ? b.seconds - a.seconds : a.seconds - b.seconds);
  state.logEntries = entries;
  $('breaks').replaceChildren();
  $('log-count').textContent = query ? `${entries.length} / ${stats.count}` : `(${entries.length})`;
  $('empty').hidden = entries.length > 0;
  for (const item of entries) {
    const row = node('tr');
    const source = node('td'); source.append(node('strong', item.report.title), node('small', `${stamp(item.start_seconds)} → ${stamp(item.end_seconds)}`));
    const reason = node('td'); reason.append(node('span', reasonNames[item.reason], 'reason-tag'));
    if (item.reviewed) { const checked = node('span', '✓', 'reviewed'); checked.title = 'Reviewed'; reason.append(checked); }
    const quote = node('td'); quote.append(node('div', item.evidence ? `“${item.evidence}”` : 'No quote on file.', 'quote-preview'));
    const action = node('td'); const button = node('button', '↗', 'receipt-open'); button.setAttribute('aria-label', `Open ${item.reason} receipt at ${stamp(item.start_seconds)}`); button.onclick = () => openReceipt(item); action.append(button);
    row.append(source, node('td', duration(item.seconds) + (item.truncated ? '+' : '')), reason, quote, action);
    $('breaks').append(row);
  }
}
function openReceipt(item) {
  $('receipt-title').textContent = `${reasonNames[item.reason]} · ${duration(item.seconds)}${item.truncated ? '+' : ''}`;
  $('receipt-meta').textContent = `${item.report.title} · ${stamp(item.start_seconds)} → ${stamp(item.end_seconds)}${item.truncated ? ' · Still BRB when the VOD ends.' : ''}`;
  $('receipt-quote').textContent = item.evidence || 'No quote on file.';
  $('receipt-review').textContent = item.reviewed ? 'Reviewed.' : '';
  $('receipt-review').hidden = !item.reviewed;
  const url = watchURL(item);
  $('receipt-watch').hidden = !url;
  if (url) $('receipt-watch').href = url; else $('receipt-watch').removeAttribute('href');
  $('receipt-dialog').showModal();
}

function download(value, type, filename) {
  const url = URL.createObjectURL(new Blob([value], {type}));
  const anchor = node('a'); anchor.href = url; anchor.download = filename; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
async function fetchReports(path) {
  const response = await fetch(path, {cache: 'no-store'});
  if (!response.ok) throw Error('The receipts didn’t arrive. Try Refresh.');
  return A.validate(await response.json());
}
async function initialize() {
  const results = await Promise.allSettled([fetchReports('data/reports.json'), fetchReports('data/demo.json')]);
  const published = results[0], demo = results[1];
  if (published.status === 'fulfilled') state.published = published.value.filter(report => !report.is_demo);
  if (demo.status === 'fulfilled') state.demo = demo.value.filter(report => report.is_demo);
  else if (published.status === 'fulfilled') state.demo = published.value.filter(report => report.is_demo);
  state.loading = false;
  if (published.status === 'rejected') notice(published.reason.message);
  render();
}
$('vod').onchange = event => { state.vod = event.target.value; render(); };
$('reason').onchange = event => { state.reason = event.target.value; render(); };
$('reason-metric').onchange = event => { state.metric = event.target.value; render(); };
$('search').oninput = event => { state.query = event.target.value; renderLog(A.compute(activeReports().filter(report => state.vod === 'all' || A.key(report) === state.vod), state.reason)); };
$('log-sort').onchange = event => { state.sort = event.target.value; render(); };
$('demo-toggle').onclick = () => switchMode(state.mode === 'published' ? 'demo' : 'published');
$('demo-empty').onclick = () => switchMode('demo');
$('refresh').onclick = async () => {
  state.loading = true; render();
  try { const reports = await fetchReports('data/reports.json'); state.published = reports.filter(report => !report.is_demo); notice('Fresh receipts. Board updated.'); }
  catch (error) { notice(error.message); }
  finally { state.loading = false; render(); }
};
$('export').title = 'Download the full current dataset as JSON';
$('export').onclick = () => download(JSON.stringify({schema_version: 1, reports: activeReports()}, null, 2), 'application/json', 'gone4hope-reports.json');
$('csv-export').title = 'Download the receipts matching the current filters and search';
$('csv-export').onclick = () => download(A.csv(state.logEntries), 'text/csv;charset=utf-8', 'gone4hope-receipts.csv');
initialize();
