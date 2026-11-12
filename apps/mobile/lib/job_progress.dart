/// Display native phase progress; older jobs used a weighted overall percentage.
String jobStage(Map<String, dynamic> job) =>
    job['stage'] as String? ?? 'Preparing VOD';

double? jobFraction(Map<String, dynamic> job) {
  if (job['status'] == 'completed') return 1;
  final value = job['phase_progress'];
  if (value is! num || !value.isFinite) return null;
  return value.toDouble().clamp(0, 1);
}
