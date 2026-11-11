'use strict';
const $ = (id) => document.getElementById(id);
const allowedReasons = ['Pee', 'Snack', 'Drink', 'Stretch', 'Technical', 'Other', 'Unknown'];
let reports = [];
function duration(s) {
  s = Math.round(s);
  return s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.floor(s % 3600 / 60)}m` : s >= 60 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${s}s`;
}
function stamp(s) { s = Math.floor(s); return `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`; }
function element(tag, text, className) { const node = document.createElement(tag); if (text != null) node.textContent = text; if (className) node.className = className; return node; }
function validate(data) {
  const list = Array.isArray(data.reports) ? data.reports : [data];
  if (list.length > 500) throw Error('Import at most 500 VODs at once.');
  const seen = new Set();
  for (const r of list) {
    if (r.schema_version !== 1 || typeof r.id !== 'string' || !r.id || typeof r.title !== 'string' || !Number.isFinite(r.duration_seconds) || r.duration_seconds < 0 || !Array.isArray(r.breaks) || !Number.isFinite(r.sample_interval_seconds) || r.sample_interval_seconds <= 0) throw Error('Invalid version 1 VOD report.');
    if (r.video_id != null && !/^[\w-]{11}$/.test(r.video_id)) throw Error('Invalid YouTube video ID.');
    const identity = r.video_id || r.id;
    if (seen.has(identity)) throw Error('Duplicate VODs would inflate totals. Import one report per VOD.');
    seen.add(identity);
    if (r.is_demo != null && typeof r.is_demo !== 'boolean') throw Error('Invalid demo flag.');
    if (r.warnings != null && (!Array.isArray(r.warnings) || r.warnings.some(w => typeof w !== 'string'))) throw Error('Invalid report warnings.');
    let previousEnd = 0;
    for (const b of r.breaks) {
      if (!Number.isFinite(b.start_seconds) || !Number.isFinite(b.end_seconds) || b.start_seconds < previousEnd || b.end_seconds < b.start_seconds || b.end_seconds > r.duration_seconds || !allowedReasons.includes(b.reason) || typeof b.evidence !== 'string') throw Error('Invalid break timing, reason, or evidence.');
      previousEnd = b.end_seconds;
    }
  }
  return list;
}
function load(data, local = false) {
  const validated = validate(data);
  reports = validated;
  $('vod').replaceChildren(new Option('All VODs', 'all'));
  reports.forEach((r, i) => $('vod').add(new Option(r.title, String(i))));
  $('reason').value = 'all';
  $('notice').dataset.local = local ? 'true' : 'false';
  render();
}
function render() {
  const selected = reports.filter((_, i) => $('vod').value === 'all' || $('vod').value === String(i));
  const entries = selected.flatMap(r => r.breaks.map(b => ({...b, report: r, seconds: b.end_seconds - b.start_seconds}))).filter(b => $('reason').value === 'all' || b.reason === $('reason').value);
  const total = entries.reduce((sum, b) => sum + b.seconds, 0);
  const vodTime = selected.reduce((sum, r) => sum + r.duration_seconds, 0);
  const counts = allowedReasons.map(reason => ({reason, entries: entries.filter(b => b.reason === reason)})).filter(g => g.entries.length).sort((a, b) => b.entries.length - a.entries.length);
  $('total').textContent = duration(total);
  $('count').textContent = String(entries.length).padStart(2, '0');
  $('away-share').textContent = `${vodTime ? (100 * total / vodTime).toFixed(1) : '0.0'}% of ${duration(vodTime)} in selected VODs`;
  $('average').textContent = duration(entries.length ? total / entries.length : 0);
  $('longest').textContent = `Longest: ${duration(Math.max(0, ...entries.map(b => b.seconds)))}`;
  $('reviewed').textContent = `${entries.filter(b => b.reviewed === true).length} reviewed · ${entries.filter(b => b.reviewed !== true).length} need review`;
  const leaders = counts.filter(g => g.entries.length === counts[0]?.entries.length);
  $('common').textContent = leaders.length > 1 ? 'Tied' : leaders[0]?.reason || '—';
  $('common-detail').textContent = leaders.length > 1 ? leaders.map(g => g.reason).join(' / ') : entries.length ? `${counts[0].entries.length} of ${entries.length} breaks · ${(100 * counts[0].entries.length / entries.length).toFixed(0)}%` : 'No breaks in view';
  const demo = selected.some(r => r.is_demo);
  $('notice').textContent = `${demo ? 'SAMPLE DATA — Invented for demonstration; not Gamin4Hope’s actual activity.' : 'Imported analysis — reason suggestions require review.'}${$('notice').dataset.local === 'true' ? ' Local view only; nothing uploaded.' : ''}`;
  $('reasons').replaceChildren();
  if (!counts.length) $('reasons').append(element('p', 'No breaks in this selection.', 'muted'));
  for (const group of counts) {
    const row = element('div', null, 'reason-row');
    const track = element('div', null, 'track');
    const fill = element('div', null, 'fill'); fill.style.width = `${100 * group.entries.length / counts[0].entries.length}%`; track.append(fill);
    row.append(element('span', group.reason), track, element('small', `${group.entries.length} · ${duration(group.entries.reduce((s, b) => s + b.seconds, 0))}`));
    $('reasons').append(row);
  }
  $('timeline').replaceChildren();
  for (const r of selected) {
    const row = element('div', null, 'timeline-row');
    const track = element('div', null, 'timeline-track');
    for (const b of entries.filter(b => b.report === r)) {
      const mark = element('span', null, 'break-mark');
      mark.style.left = `${r.duration_seconds ? 100 * b.start_seconds / r.duration_seconds : 0}%`;
      mark.style.width = `${r.duration_seconds ? 100 * b.seconds / r.duration_seconds : 0}%`;
      mark.title = `${b.reason} · ${stamp(b.start_seconds)} · ${duration(b.seconds)}`;
      track.append(mark);
    }
    const axis = element('div', null, 'axis'); axis.append(element('span', '0:00'), element('span', stamp(r.duration_seconds)));
    row.append(element('p', r.title, 'timeline-name'), track, axis); $('timeline').append(row);
  }
  $('breaks').replaceChildren();
  for (const b of entries) {
    const row = element('tr');
    const source = element('td');
    if (b.report.video_id) {
      const link = element('a', `${stamp(b.start_seconds)} ↗`); link.href = `https://www.youtube.com/watch?v=${b.report.video_id}&t=${Math.floor(b.start_seconds)}s`; link.target = '_blank'; link.rel = 'noopener noreferrer'; source.append(link);
    } else source.append(element('span', stamp(b.start_seconds)));
    source.append(element('small', b.report.title));
    const time = element('td', duration(b.seconds)); if (b.truncated) time.append(element('small', 'Still BRB at VOD end'));
    const reason = element('td'); reason.append(element('span', b.reason, `badge${b.reason === 'Unknown' ? ' unknown' : ''}`), element('small', b.reviewed === true ? 'Manually reviewed' : 'Unverified suggestion'));
    row.append(source, time, reason, element('td', b.evidence ? `“${b.evidence}”` : 'No preceding transcript available.'));
    $('breaks').append(row);
  }
  $('log-count').textContent = `(${entries.length})`; $('empty').hidden = entries.length > 0;
  const list = element('ul'); for (const warning of new Set(selected.flatMap(r => r.warnings || []))) list.append(element('li', warning));
  $('warnings').replaceChildren(list);
}
function importText(text) {
  try { load(JSON.parse(text), true); $('import-dialog').close(); $('import-error').textContent = ''; }
  catch (e) { $('import-error').textContent = e.message; }
}
$('vod').addEventListener('change', render); $('reason').addEventListener('change', render);
$('import-open').onclick = () => $('import-dialog').showModal();
$('file').onchange = async (event) => { const file = event.target.files[0]; if (!file) return; if (file.size > 10 * 1024 * 1024) { $('import-error').textContent = 'Use a report smaller than 10 MB.'; return; } importText(await file.text()); event.target.value = ''; };
$('import-paste').onclick = () => importText($('paste').value);
$('export').onclick = () => {
  const url = URL.createObjectURL(new Blob([JSON.stringify({schema_version: 1, reports}, null, 2)], {type: 'application/json'}));
  const link = element('a'); link.href = url; link.download = 'brb-reports.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
};
fetch('data/reports.json').then(response => { if (!response.ok) throw Error('Report data could not be loaded.'); return response.json(); }).then(data => load(data)).catch(e => { $('notice').textContent = `${e.message} Import a JSON report to get started.`; });
