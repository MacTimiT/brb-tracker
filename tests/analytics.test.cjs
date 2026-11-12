const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const A = require('../docs/analytics.js');
const demo = JSON.parse(fs.readFileSync('docs/data/demo.json', 'utf8')).reports;

function report(id, length, breaks = []) {
  return {schema_version: 1, id, title: id, duration_seconds: length, sample_interval_seconds: 2, breaks: breaks.map(([start, end, reason = 'Pee']) => ({start_seconds: start, end_seconds: end, reason, evidence: ''}))};
}
test('demo totals, median, rate, buckets and actual uninterrupted intervals', () => {
  const data = A.compute(A.validate({schema_version: 1, reports: demo}));
  assert.equal(data.away, 1320);
  assert.equal(data.count, 6);
  assert.equal(data.average, 220);
  assert.equal(data.median, 195);
  assert.equal(data.rate, 1.5);
  assert.ok(Math.abs(data.percent - 9.1666666667) < 0.00001);
  assert.deepEqual(data.leaders, ['Pee']);
  assert.deepEqual(data.distribution.map(bin => bin.count), [0, 2, 3, 1, 0]);
  assert.deepEqual(data.phases.map(phase => phase.count), [1, 2, 1, 2]);
  assert.equal(data.longest.seconds, 420);
  assert.equal(data.shortest.seconds, 120);
  assert.equal(data.longestStreak.seconds, 2480);
  assert.equal(data.meanGap, 2018);
});
test('aggregate percentages and rates are weighted by VOD duration', () => {
  const data = A.compute([report('short', 100, [[10, 20]]), report('long', 900, [[100, 280, 'Snack']])]);
  assert.equal(data.percent, 19);
  assert.ok(Math.abs(data.rate - 7.2) < 1e-9);
  assert.equal(data.median, 95);
  assert.equal(data.vods[0].report.id, 'long');
  assert.equal(data.meanGap, null); // Never invent a gap across two different streams.
  assert.equal(data.longestStreak.seconds, 620);
});
test('reason filters retain VOD exposure and do not hide breaks from streak calculations', () => {
  const reports = [report('short', 100, [[10, 20]]), report('long', 900, [[100, 280, 'Snack']])];
  const data = A.compute(reports, 'Pee');
  assert.equal(data.away, 10);
  assert.equal(data.percent, 1);
  assert.ok(Math.abs(data.rate - 3.6) < 1e-9);
  assert.equal(data.longestStreak.seconds, 620);
  assert.equal(data.longestStreak.report.id, 'long');
});
test('quarter boundaries and duration buckets include each boundary exactly once', () => {
  const phases = A.compute([report('phases', 100, [[0, 1], [25, 26], [50, 51], [75, 76]])]);
  assert.deepEqual(phases.phases.map(phase => phase.count), [1, 1, 1, 1]);
  assert.equal(phases.phases.reduce((sum, phase) => sum + phase.count, 0), 4);
  const lengths = [0, 59, 60, 179, 180, 299, 300, 599, 600];
  let cursor = 0;
  const breaks = lengths.map(length => { const item = [cursor, cursor + length]; cursor += length + 10; return item; });
  const data = A.compute([report('lengths', cursor, breaks)]);
  assert.deepEqual(data.distribution.map(bin => bin.count), [2, 2, 2, 2, 1]);
});
test('empty and zero-length VODs have finite rates and no invented break records', () => {
  for (const reports of [[], [report('empty', 0)]]) {
    const data = A.compute(reports);
    assert.equal(data.count, 0);
    assert.equal(data.percent, 0);
    assert.equal(data.rate, 0);
    assert.equal(data.average, null);
    assert.equal(data.median, null);
    assert.equal(data.longest, null);
    assert.equal(data.shortest, null);
    assert.ok(data.phases.every(phase => Number.isFinite(phase.rate)));
  }
  assert.equal(A.compute([report('no-break', 600)]).longestStreak.seconds, 600);
});
test('validation rejects overlaps, out-of-bounds breaks and duplicate YouTube VODs', () => {
  assert.throws(() => A.validate(report('bad', 100, [[5, 20], [15, 30]])), /Invalid break/);
  assert.throws(() => A.validate(report('bad', 100, [[5, 101]])), /Invalid break/);
  assert.throws(() => A.validate({...report('bad', 100), duration_seconds: Infinity}), /missing/);
  assert.throws(() => A.validate({schema_version: 1, reports: [{...report('a', 100), video_id: 'IW2rEIuKGSs'}, {...report('b', 100), video_id: 'IW2rEIuKGSs'}]}), /Duplicate VODs/);
  assert.throws(() => A.validate(null), /version 1/);
});
test('CSV preserves quotes/newlines and treats spreadsheet formulas as text', () => {
  const r = report('=HYPERLINK("example")', 100, [[10, 20]]);
  r.title = '=1+1';
  r.breaks[0].evidence = 'He said "water",\nthen left.';
  const text = A.csv(A.compute([r]).entries);
  assert.ok(text.startsWith('"VOD","VOD date"'));
  assert.ok(text.includes('"\'=1+1"'));
  assert.ok(text.includes('"He said ""water"",\nthen left."'));
  assert.equal(r.title, '=1+1');
});
test('median does not mutate its source and handles fractional even-count medians', () => {
  const values = [8, 1, 6, 3];
  assert.equal(A.median(values), 4.5);
  assert.deepEqual(values, [8, 1, 6, 3]);
});

test('original VOD date is exported separately from scan date; invalid dates are rejected', () => {
  const r = {...report('old-stream', 100, [[10, 20]]), vod_date: '2026-10-22', vod_date_source: 'release_timestamp', analyzed_at: '2026-11-12T15:00:00Z'};
  assert.equal(A.month(r), '2026-10');
  assert.equal(A.month(report('legacy', 100)), 'unknown');
  const csv = A.csv(A.compute(A.validate(r)).entries);
  assert.ok(csv.includes('"2026-10-22","release_timestamp","2026-11-12T15:00:00Z"'));
  for (const value of ['2026-02-30', 'today', 123]) assert.throws(() => A.validate({...r, vod_date: value}), /Invalid VOD date/);
});
