'use strict';
const $ = id => document.getElementById(id);
const A = globalThis.BRBStats;
const reasonNames = {
  Pee: 'Pee breaks',
  Snack: 'Snack raids',
  Drink: 'Hydration runs',
  Stretch: 'Stretch breaks',
  Technical: 'Tech gremlins',
  'Help Rachel': 'Helping Rachel',
  'Mental Break': 'Mental breaks',
  Other: 'Side quests',
  Unknown: 'Unsolved mysteries',
};
const reasonName = reason => reasonNames[reason] ?? reason;
const reasonLabels = item => A.assignedReasons(item).map(reasonName).join(' / ');
const colors = {Pee: '#bc2028', Snack: '#985182', Drink: '#23748a', Stretch: '#527346', Technical: '#586582', 'Help Rachel': '#96701d', 'Mental Break': '#6a51a3', Other: '#8a6842', Unknown: '#77736b'};
const pageSize = 24;
const state = {
  published: [], vod: 'all', month: 'all', reason: 'all', metric: 'count',
  query: '', sort: 'longest', loading: true, reportsStatus: 'loading',
  twitchStatus: 'loading', twitchMatches: null, stats: null, receipt: null,
  logEntries: [], receiptLimit: pageSize, vodLimit: pageSize, timelineLimit: pageSize,
};
let twitchRequest;
let publicationRequest;
const integer = value => Math.round(value).toLocaleString('en-US');
const fixed = (value, places = 1) => Number(value).toFixed(places);
const hoursLabel = hours => hours.toLocaleString('en-US', {maximumFractionDigits: 1}) + ' h';
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
function selectedReports() { return state.published.filter(report => (state.month === 'all' || A.month(report) === state.month) && (state.vod === 'all' || A.key(report) === state.vod)); }
function notice(message = '') { $('notice').textContent = message; $('notice').hidden = !message; }

function updateOptions() {
  const source = state.published;
  const months = [...new Set(source.map(A.month))].sort().reverse();
  if (!months.includes(state.month)) state.month = 'all';
  $('month').replaceChildren(new Option('All dates', 'all'));
  for (const month of months) $('month').add(new Option(month === 'unknown' ? 'Date unknown' : month, month));
  $('month').value = state.month;
  const reports = source.filter(report => state.month === 'all' || A.month(report) === state.month);
  if (!reports.some(report => A.key(report) === state.vod)) state.vod = 'all';
  $('vod').replaceChildren(new Option('All streams', 'all'));
  for (const report of reports) $('vod').add(new Option(report.title, A.key(report)));
  $('vod').value = state.vod;
  $('reason').value = state.reason;
  $('reason-metric').value = state.metric;
  $('search').value = state.query;
  $('log-sort').value = state.sort;
}
function renderReceiptTwitch() {
  if (!state.receipt) return;
  const {report, seconds} = state.receipt;
  const average = A.twitchAverage(report, state.twitchMatches);
  const note = $('receipt-twitch');
  note.hidden = average == null;
  if (average != null) {
    note.textContent = `Est. Twitch viewer-hours · ${hoursLabel(seconds * average / 3600)} · ${integer(average)} average viewers`;
  }
}

function renderTwitchViewerHours() {
  if (!state.stats) return;
  const vods = state.stats.vods;
  const {hours, matched} = A.twitchViewerHours(vods, state.twitchMatches);
  $('twitch-viewer-hours').textContent = hours == null ? '—' : hoursLabel(hours);
  const coverage = matched ? `${matched} of ${vods.length} VODs matched` : 'No matched Twitch data';
  $('twitch-coverage').textContent = {
    loading: 'Loading Twitch data…',
    unavailable: 'Twitch data unavailable',
    stale: `${coverage} · previously loaded`,
    ready: coverage,
  }[state.twitchStatus];
  for (const cell of $('vod-table').querySelectorAll('[data-twitch-index]')) {
    const {report, seconds} = vods[Number(cell.dataset.twitchIndex)];
    const average = A.twitchAverage(report, state.twitchMatches);
    cell.querySelector('strong').textContent = average == null ? '—' : hoursLabel(seconds * average / 3600);
    cell.querySelector('small').textContent = average == null ? '' : `${integer(average)} avg viewers`;
  }
  renderReceiptTwitch();
}

function render() {
  const focusKey = document.activeElement?.dataset.focusKey;
  updateOptions();
  const selected = selectedReports();
  const stats = A.compute(selected, state.reason);
  state.stats = stats;
  const hasReports = selected.length > 0;
  $('empty-board').hidden = hasReports || state.loading || state.reportsStatus !== 'ready';
  $('analytics-board').hidden = !hasReports;
  $('scope-summary').textContent = state.loading ? 'Checking the receipts…'
    : state.reportsStatus === 'unavailable' ? 'Reports unavailable'
    : `${selected.length} VOD${selected.length === 1 ? '' : 's'} · ${duration(stats.duration)} clocked`;
  $('refresh').disabled = state.loading;
  $('total').textContent = hasReports ? duration(stats.away) : '—';
  $('one-secs').textContent = hasReports ? `${integer(stats.away)} “one secs” and counting.`
    : state.reportsStatus === 'unavailable' ? 'Reports could not be loaded.' : 'Waiting for the first “one sec.”';
  $('share-fill').style.width = `${stats.percent}%`;
  const otherName = state.reason === 'all' ? 'Not BRB' : 'Everything else';
  const awayName = state.reason === 'all' ? 'BRB' : reasonName(state.reason);
  $('clock-label').textContent = state.reason === 'all' ? 'TIME SPENT ON BRB' : 'MATCHING BRB TIME';
  $('other-label').textContent = `${otherName}${hasReports ? ' ' + fixed(stats.duration ? 100 - stats.percent : 0) + '%' : ''}`;
  $('away-label').textContent = `${awayName}${hasReports ? ' ' + fixed(stats.percent) + '%' : ''}`;
  $('count').textContent = integer(stats.count);
  $('away-percent').textContent = `${fixed(stats.percent)}%`;
  $('away-metric-label').textContent = state.reason === 'all' ? 'STREAM SPENT BRB' : 'MATCHING BRB SHARE';
  $('average').textContent = duration(stats.average);
  $('median').textContent = duration(stats.median);
  $('rate').textContent = fixed(stats.rate, 2);
  renderReasons(stats);
  renderColumns('distribution', stats.distribution);
  renderColumns('phases', stats.phases, true);
  renderRecord('longest', stats.longest);
  renderRecord('shortest', stats.shortest);
  renderRecord('streak', stats.longestStreak, true);
  $('gap-mean').textContent = stats.meanGap == null ? '' : `Back at the desk for ${duration(stats.meanGap)} on average between breaks. A heroic effort. (All reasons.)`;
  renderVods();
  renderTimeline();
  renderLog();
  if (focusKey) {
    const replacement = [...document.querySelectorAll('[data-focus-key]')].find(e => e.dataset.focusKey === focusKey);
    (replacement ?? $(focusKey.split(':')[0]))?.focus({preventScroll: true});
  }
}

function applyFilters(filters) {
  Object.assign(state, filters, {receiptLimit: pageSize, vodLimit: pageSize, timelineLimit: pageSize});
  render();
}

function renderReasons(stats) {
  const groups = [...stats.groups].sort((a, b) => b[state.metric] - a[state.metric] || A.reasons.indexOf(a.reason) - A.reasons.indexOf(b.reason));
  $('reasons').replaceChildren();
  if (!groups.length) {
    $('leaderboard-note').textContent = 'No breaks match these filters.';
    return;
  }
  const max = groups[0][state.metric];
  const tied = groups.filter(group => Math.abs(group[state.metric] - max) < 0.000001);
  $('leaderboard-note').textContent = tied.length > 1
    ? `Shared podium · ${tied.map(group => reasonName(group.reason)).join(' / ')}`
    : state.metric === 'seconds'
      ? `Most time away · ${reasonName(groups[0].reason)}`
      : `Most frequent · ${reasonName(groups[0].reason)} · ${groups[0].count} of ${stats.count} breaks`;
  groups.forEach((group, index) => {
    const button = node('button', null, 'reason-row'); button.type = 'button';
    button.dataset.focusKey = 'reason:' + group.reason;
    button.setAttribute('aria-pressed', String(state.reason === group.reason));
    const countLabel = `${group.count} break${group.count === 1 ? '' : 's'}`;
    button.title = `Filter by ${reasonName(group.reason)} · ${countLabel} · ${duration(group.seconds)} as primary reason`;
    const middle = node('span');
    const track = node('span', null, 'reason-track');
    const fill = node('span', null, 'reason-fill');
    fill.style.width = `${max ? group[state.metric] / max * 100 : 0}%`; fill.style.backgroundColor = colors[group.reason];
    fill.hidden = !group[state.metric];
    track.append(fill); middle.append(node('span', reasonName(group.reason), 'reason-name'), track);
    const values = node('span', state.metric === 'count' ? String(group.count) : duration(group.seconds), 'reason-values');
    values.append(node('small', state.metric === 'count' ? duration(group.seconds) : countLabel));
    button.append(node('span', String(index + 1).padStart(2, '0'), 'reason-position'), middle, values);
    button.onclick = () => applyFilters({reason: state.reason === group.reason ? 'all' : group.reason});
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
  container.append(node('span', streak ? item.report.title : reasonName(item.reason), 'record-title'));
  const button = node('button', streak ? `View timeline · from ${stamp(item.start_seconds)}` : 'Show receipt', 'record-link');
  button.onclick = () => {
    if (!streak) { openReceipt(item); return; }
    applyFilters({vod: A.key(item.report)});
    const heading = $('timeline-title');
    heading.focus({preventScroll: true});
    heading.scrollIntoView?.({block: 'center'});
  };
  container.append(button);
}
function tableCell(label, value, className) {
  const cell = node('td', null, className);
  cell.setAttribute('role', 'cell');
  if (label) {
    const caption = node('span', label, 'table-label');
    caption.setAttribute('aria-hidden', 'true');
    cell.append(caption);
  }
  if (value != null) cell.append(node('span', value));
  return cell;
}

function renderVods() {
  const {vods} = state.stats;
  const rows = vods.slice(0, state.vodLimit).map((row, index) => {
    const tr = node('tr');
    tr.setAttribute('role', 'row');
    const title = tableCell(null, null, 'vod-title');
    const button = node('button', row.report.title, 'vod-name');
    button.type = 'button';
    button.dataset.focusKey = 'vod:' + A.key(row.report);
    button.onclick = () => applyFilters({vod: A.key(row.report)});
    title.append(node('span', String(index + 1).padStart(2, '0'), 'vod-rank'), button);
    const twitch = tableCell('Est. Twitch viewer-hours', null, 'vod-twitch');
    twitch.dataset.twitchIndex = index;
    twitch.append(node('strong'), node('small'));
    tr.append(title,
      tableCell('VOD date', row.report.vod_date || 'Unknown', 'vod-date'),
      tableCell('Length', duration(row.report.duration_seconds)),
      tableCell('Breaks', row.count),
      tableCell('Time away', duration(row.seconds)),
      tableCell('BRB share', `${fixed(row.percent)}%`, 'share-number'),
      tableCell('Breaks / h', fixed(row.rate, 2)), twitch);
    return tr;
  });
  $('vod-table').replaceChildren(...rows);
  $('more-vods').hidden = vods.length <= state.vodLimit;
  renderTwitchViewerHours();
}

function renderTimeline() {
  const stats = state.stats;
  const reasons = new Set(stats.entries.map(item => item.reason));
  $('timeline-key').hidden = !reasons.size;
  $('timeline-legend').replaceChildren(...A.reasons.filter(reason => reasons.has(reason)).map(reason => {
    const label = node('li', reasonName(reason));
    const swatch = node('span', null, 'reason-swatch');
    swatch.setAttribute('aria-hidden', 'true');
    swatch.style.backgroundColor = colors[reason];
    label.prepend(swatch);
    return label;
  }));
  const rows = stats.reports.slice(0, state.timelineLimit).map(report => {
    const row = node('div', null, 'timeline-row');
    const name = node('p', report.title, 'timeline-name');
    name.tabIndex = -1;
    const items = stats.entriesByReport.get(report);
    const track = node('div', null, 'timeline-track');
    const marks = items.map(item => {
      const mark = node('button', null, 'break-mark');
      mark.type = 'button';
      mark.style.left = `${report.duration_seconds ? item.start_seconds / report.duration_seconds * 100 : 0}%`;
      mark.style.width = `${report.duration_seconds ? item.seconds / report.duration_seconds * 100 : 0}%`;
      mark.style.backgroundColor = colors[item.reason];
      mark.setAttribute('aria-label', `${reasonLabels(item)}, ${stamp(item.start_seconds)}, ${duration(item.seconds)}`);
      mark.title = mark.getAttribute('aria-label');
      mark.onclick = () => openReceipt(item);
      return mark;
    });
    track.append(...marks);
    if (marks.length) {
      track.onclick = event => {
        if (event.target.closest('button')) return;
        let nearest = 16;
        let target = null;
        for (const [index, mark] of marks.entries()) {
          const bounds = mark.getBoundingClientRect();
          const gap = Math.max(bounds.left - event.clientX, event.clientX - bounds.right, 0);
          if (gap <= nearest) { nearest = gap; target = index; }
        }
        if (target != null) openReceipt(items[target], marks[target]);
      };
    }
    const axis = node('div', null, 'timeline-axis');
    axis.append(node('span', '0:00'), node('span', stamp(report.duration_seconds)));
    row.append(name, track, axis);
    return row;
  });
  $('timeline').replaceChildren(...rows);
  $('more-timelines').hidden = stats.reports.length <= state.timelineLimit;
}

function renderLog() {
  const {entries: scoped, count} = state.stats;
  const query = state.query.trim().toLocaleLowerCase();
  const entries = scoped.filter(item => !query || `${item.report.title} ${reasonLabels(item)} ${A.assignedReasons(item).join(" ")} ${item.evidence}`.toLocaleLowerCase().includes(query));
  if (state.sort === 'stream') entries.sort(A.chronological);
  else entries.sort((a, b) => state.sort === 'longest' ? b.seconds - a.seconds : a.seconds - b.seconds);
  state.logEntries = entries;
  $('log-count').textContent = query ? `${entries.length} / ${count}` : `(${entries.length})`;
  $('empty').hidden = entries.length > 0;
  $('csv-export').disabled = !entries.length;
  $('more-receipts').hidden = entries.length <= state.receiptLimit;
  const rows = entries.slice(0, state.receiptLimit).map(item => {
    const row = node('tr', null, 'receipt-row');
    row.setAttribute('role', 'row');
    const source = tableCell(null, null, 'receipt-source');
    const button = node('button', item.report.title, 'receipt-open');
    button.type = 'button';
    button.setAttribute('aria-label', `Open ${A.assignedReasons(item).join(' / ')} receipt at ${stamp(item.start_seconds)} for ${item.report.title}`);
    button.onclick = () => openReceipt(item);
    row.onclick = event => {
      if (!event.target.closest('button') && !window.getSelection()?.toString()) {
        openReceipt(item, button);
      }
    };
    source.append(button, node('small', item.report.vod_date || 'Date unknown'), node('small', `${stamp(item.start_seconds)} → ${stamp(item.end_seconds)}`));
    const reason = tableCell(null, null, 'receipt-reason');
    reason.append(node('span', reasonLabels(item), 'reason-tag'));
    const quote = tableCell(null, null, 'receipt-quote-cell');
    quote.append(node('div', item.evidence ? `“${item.evidence}”` : 'No quote on file.', 'quote-preview'));
    row.append(source, tableCell(null, duration(item.seconds) + (item.truncated ? '+' : ''), 'receipt-duration'), reason, quote);
    return row;
  });
  $('breaks').replaceChildren(...rows);
}
function openReceipt(item, trigger) {
  if (trigger) trigger.focus({preventScroll: true});
  state.receipt = item;
  $('receipt-title').textContent = `${reasonLabels(item)} · ${duration(item.seconds)}${item.truncated ? '+' : ''}`;
  $('receipt-meta').textContent = `${item.report.title} · ${item.report.vod_date || 'Date unknown'} · ${stamp(item.start_seconds)} → ${stamp(item.end_seconds)}${item.truncated ? ' · Still BRB when the VOD ends.' : ''}`;
  $('receipt-quote').textContent = item.evidence || 'No quote on file.';
  renderReceiptTwitch();
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
const liveSite = window.location.origin === 'https://mactimit.github.io';
function dataUrl(file) {
  return liveSite ? `https://raw.githubusercontent.com/MacTimiT/brb-tracker/main/docs/data/${file}` : `data/${file}`;
}

function fetchJson(url, cache = 'no-store') {
  const options = {cache};
  if (typeof AbortSignal.timeout === 'function') options.signal = AbortSignal.timeout(12000);
  return fetch(url, options).then(response => {
    if (!response.ok) throw Error('The receipts didn’t arrive. Try Refresh.');
    return response.json();
  });
}

function refreshTwitchMatches() {
  if (twitchRequest) return;
  twitchRequest = fetchJson(dataUrl('twitch-viewership.json')).then(data => {
    if (data.schema_version !== 1 || !data.matches || typeof data.matches !== 'object' || Array.isArray(data.matches)) {
      throw Error('Twitch data is invalid.');
    }
    state.twitchMatches = data.matches;
    state.twitchStatus = 'ready';
  }).catch(() => {
    state.twitchStatus = state.twitchMatches ? 'stale' : 'unavailable';
  }).finally(() => {
    twitchRequest = null;
    renderTwitchViewerHours();
  });
}

function refreshPublication() {
  if (!liveSite || publicationRequest) return;
  const url = 'https://api.github.com/repos/MacTimiT/brb-tracker/commits?sha=main&path=docs/data/reports.json&per_page=1';
  publicationRequest = fetchJson(url, 'default').then(commits => {
    const date = commits[0]?.commit?.committer?.date;
    if (!date || !Number.isFinite(Date.parse(date))) return;
    const time = $('published-time');
    time.dateTime = date;
    time.textContent = new Intl.DateTimeFormat(undefined, {dateStyle: 'medium', timeStyle: 'short'}).format(new Date(date));
    $('publication').hidden = false;
  }).catch(() => {
    // Publication metadata is optional and can be rate limited by GitHub.
  }).finally(() => { publicationRequest = null; });
}

async function refreshReports(announce = false) {
  state.loading = true;
  const reports = fetchJson(dataUrl('reports.json'));
  refreshTwitchMatches();
  refreshPublication();
  render();
  try {
    const next = A.validate(await reports).filter(report => !report.is_demo);
    if (announce) {
      const changed = JSON.stringify(next) !== JSON.stringify(state.published);
      notice(changed ? 'New report data loaded.' : 'Same report data received.');
    }
    state.published = next;
    state.reportsStatus = 'ready';
  } catch (error) {
    state.reportsStatus = state.published.length ? 'stale' : 'unavailable';
    notice(state.reportsStatus === 'stale' ? `${error.message} Showing previously loaded reports.` : error.message);
  } finally {
    state.loading = false;
    render();
  }
}

$('vod').onchange = event => applyFilters({vod: event.target.value});
$('month').onchange = event => applyFilters({month: event.target.value});
for (const reason of A.reasons) $('reason').add(new Option(reasonName(reason), reason));
$('reason').onchange = event => applyFilters({reason: event.target.value});
$('reason-metric').onchange = event => { state.metric = event.target.value; render(); };
$('search').oninput = event => { state.query = event.target.value; state.receiptLimit = pageSize; renderLog(); };
$('log-sort').onchange = event => { state.sort = event.target.value; state.receiptLimit = pageSize; renderLog(); };
$('refresh').onclick = () => refreshReports(true);

for (const [id, limit, renderItems, focusSelector] of [
  ['more-vods', 'vodLimit', renderVods, '.vod-name'],
  ['more-timelines', 'timelineLimit', renderTimeline, '.timeline-name'],
  ['more-receipts', 'receiptLimit', renderLog, '.receipt-open'],
]) {
  $(id).onclick = () => {
    const first = state[limit];
    state[limit] += pageSize;
    renderItems();
    document.querySelectorAll(focusSelector)[first]?.focus();
  };
}
$('export').title = 'Download reports in the current month and stream filters as JSON';
$('export').onclick = () => download(JSON.stringify({schema_version: 1, reports: selectedReports()}, null, 2), 'application/json', 'gone4hope-reports.json');
$('csv-export').title = 'Download the receipts matching the current filters and search';
$('csv-export').onclick = () => download(A.csv(state.logEntries), 'text/csv;charset=utf-8', 'gone4hope-receipts.csv');
$('receipt-dialog').onclose = () => { state.receipt = null; };
$('twitch-viewer-hours-help').onclick = () => $('twitch-viewer-hours-dialog').showModal();
refreshReports();
