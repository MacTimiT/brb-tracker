(function (root) {
  'use strict';
  const reasons = ['Pee', 'Snack', 'Drink', 'Stretch', 'Technical', 'Help Rachel', 'Mental Break', 'Other', 'Unknown'];
  const sum = values => values.reduce((total, value) => total + value, 0);
  const key = report => report.video_id || report.id;
  const assignedReasons = item => [item.reason, ...(item.additional_reasons ?? [])];
  const median = values => {
    if (!values.length) return null;
    const sorted = [...values].sort((a, b) => a - b);
    const middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  };

  const month = report => report.vod_date ? report.vod_date.slice(0, 7) : 'unknown';
  function validDate(value) { return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value; }
  function validate(data) {
    if (!data || typeof data !== 'object' || data.schema_version !== 1) throw Error('Use a version 1 BRB report.');
    const list = Array.isArray(data.reports) ? data.reports : [data];
    const seen = new Set();
    for (const report of list) {
      if (!report || report.schema_version !== 1 || typeof report.id !== 'string' || !report.id || typeof report.title !== 'string' || !Number.isFinite(report.duration_seconds) || report.duration_seconds < 0 || !Number.isFinite(report.sample_interval_seconds) || report.sample_interval_seconds <= 0 || !Array.isArray(report.breaks)) throw Error('That VOD report is missing its title, timing, or breaks.');
      if (report.vod_date != null && !validDate(report.vod_date)) throw Error('Invalid VOD date.');
      if (report.video_id != null && (typeof report.video_id !== 'string' || !/^[A-Za-z0-9_-]{11}$/.test(report.video_id))) throw Error('Invalid YouTube video ID.');
      if (seen.has(key(report))) throw Error('Duplicate VODs would count the same escape twice.');
      seen.add(key(report));
      if (report.is_demo != null && typeof report.is_demo !== 'boolean') throw Error('Invalid demo field.');
      if (report.warnings != null && (!Array.isArray(report.warnings) || report.warnings.some(value => typeof value !== 'string'))) throw Error('Invalid report notes.');
      let previousEnd = 0;
      for (const item of report.breaks) {
        if (!item || !Number.isFinite(item.start_seconds) || !Number.isFinite(item.end_seconds) || item.start_seconds < previousEnd || item.end_seconds < item.start_seconds || item.end_seconds > report.duration_seconds || !reasons.includes(item.reason) || typeof item.evidence !== 'string') throw Error('Invalid break timing, reason, or quote.');
        const extra = item.additional_reasons;
        if (extra != null && (!Array.isArray(extra) || new Set(extra).size !== extra.length || extra.some(value => value === item.reason || value === 'Unknown' || item.reason === 'Unknown' || !reasons.includes(value)))) throw Error('Invalid additional reasons.');
        for (const field of ['reviewed', 'truncated']) if (item[field] != null && typeof item[field] !== 'boolean') throw Error('Invalid break status.');
        previousEnd = item.end_seconds;
      }
    }
    return list;
  }

  function compute(reports, reason = 'all') {
    const all = reports.flatMap(report => report.breaks.map((item, index) => ({...item, report, index, seconds: item.end_seconds - item.start_seconds})));
    const entries = all.filter(item => reason === 'all' || assignedReasons(item).includes(reason));
    const duration = sum(reports.map(report => report.duration_seconds));
    const away = sum(entries.map(item => item.seconds));
    const groups = reasons.map(name => {
      const items = entries.filter(item => assignedReasons(item).includes(name));
      const primary = items.filter(item => item.reason === name);
      return {reason: name, count: items.length, seconds: sum(primary.map(item => item.seconds)), median: median(primary.map(item => item.seconds))};
    }).filter(group => group.count);
    const most = Math.max(0, ...groups.map(group => group.count));
    const leaders = groups.filter(group => group.count === most).map(group => group.reason);
    const bounds = [0, 60, 180, 300, 600, Infinity];
    const labels = ['< 1m', '1–3m', '3–5m', '5–10m', '10m+'];
    const distribution = labels.map((label, index) => ({label, count: entries.filter(item => item.seconds >= bounds[index] && item.seconds < bounds[index + 1]).length}));
    const phases = ['First quarter', 'Second quarter', 'Third quarter', 'Final quarter'].map((label, index) => {
      const count = entries.filter(item => item.report.duration_seconds > 0 && Math.min(3, Math.floor(item.start_seconds / item.report.duration_seconds * 4)) === index).length;
      const hours = duration / 4 / 3600;
      return {label, count, rate: hours ? count / hours : 0};
    });
    let longestStreak = null;
    const gaps = [];
    // Attendance streaks use every break, even when a reason is filtered out.
    // Boundaries never cross from one VOD into another.
    for (const report of reports) {
      let cursor = 0;
      const consider = end => {
        const candidate = {report, start_seconds: cursor, end_seconds: end, seconds: end - cursor};
        if (longestStreak === null || candidate.seconds > longestStreak.seconds) longestStreak = candidate;
      };
      report.breaks.forEach((item, index) => {
        consider(item.start_seconds);
        if (index > 0) gaps.push(item.start_seconds - cursor);
        cursor = item.end_seconds;
      });
      consider(report.duration_seconds);
    }
    const entriesByReport = new Map(reports.map(report => [report, []]));
    for (const item of entries) entriesByReport.get(item.report).push(item);
    const vods = reports.map(report => {
      const items = entriesByReport.get(report);
      const seconds = sum(items.map(item => item.seconds));
      const hours = report.duration_seconds / 3600;
      return {report, count: items.length, seconds, percent: report.duration_seconds ? seconds / report.duration_seconds * 100 : 0, rate: hours ? items.length / hours : 0};
    }).sort((a, b) => b.percent - a.percent || b.seconds - a.seconds || a.report.title.localeCompare(b.report.title));
    const ordered = [...entries].sort((a, b) => b.seconds - a.seconds || a.start_seconds - b.start_seconds);
    return {
      reports, entries, entriesByReport, duration, away, count: entries.length,
      percent: duration ? away / duration * 100 : 0,
      average: entries.length ? away / entries.length : null,
      median: median(entries.map(item => item.seconds)),
      rate: duration ? entries.length / (duration / 3600) : 0,
      groups, leaders, distribution, phases, vods,
      longest: ordered[0] || null,
      shortest: ordered.length ? ordered[ordered.length - 1] : null,
      longestStreak, meanGap: gaps.length ? sum(gaps) / gaps.length : null,
    };
  }

  function twitchAverage(report, matches) {
    const entry = matches?.[report.video_id];
    if (!entry || report.is_demo ||
        entry.vod_started_at !== report.stream_started_at ||
        entry.vod_duration_seconds !== report.duration_seconds ||
        !Number.isSafeInteger(entry.average_viewers) || entry.average_viewers <= 0) return null;
    return entry.average_viewers;
  }

  function twitchViewerHours(vods, matches) {
    let hours = 0;
    let matched = 0;
    for (const {report, seconds} of vods) {
      const average = twitchAverage(report, matches);
      if (average == null) continue;
      hours += seconds * average / 3600;
      matched++;
    }
    return {hours: matched ? hours : null, matched};
  }

  function chronological(a, b) {
    const byDate = (a.report.vod_date ?? '9999-12-31').localeCompare(b.report.vod_date ?? '9999-12-31');
    if (byDate) return byDate;
    const startA = Date.parse(a.report.stream_started_at);
    const startB = Date.parse(b.report.stream_started_at);
    if (Number.isFinite(startA) && Number.isFinite(startB) && startA !== startB) return startA - startB;
    if (Number.isFinite(startA) !== Number.isFinite(startB)) return Number.isFinite(startA) ? -1 : 1;
    return key(a.report).localeCompare(key(b.report)) || a.start_seconds - b.start_seconds;
  }

  function csv(entries) {
    const cell = value => {
      let text = String(value ?? '');
      if (/^[\s]*[=+@-]/.test(text)) text = "'" + text;
      return '"' + text.replaceAll('"', '""') + '"';
    };
    const rows = [['VOD', 'VOD date', 'Date source', 'Analyzed at', 'Start seconds', 'End seconds', 'Duration seconds', 'Reason', 'Quote', 'YouTube URL', 'Additional reasons']];
    for (const item of entries) rows.push([item.report.title, item.report.vod_date, item.report.vod_date_source, item.report.analyzed_at, item.start_seconds, item.end_seconds, item.seconds, item.reason, item.evidence, item.report.video_id ? `https://www.youtube.com/watch?v=${item.report.video_id}&t=${Math.floor(item.start_seconds)}s` : '', (item.additional_reasons ?? []).join(' / ')]);
    return rows.map(row => row.map(cell).join(',')).join('\r\n') + '\r\n';
  }
  const api = {reasons, key, assignedReasons, month, validDate, median, validate, compute, twitchAverage, twitchViewerHours, chronological, csv};
  root.BRBStats = api;
  if (typeof module === 'object' && module.exports) module.exports = api;
})(globalThis);
