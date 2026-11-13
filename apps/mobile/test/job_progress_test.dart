import 'package:brb_tracker/job_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'display uses phase percentage instead of weighted overall progress',
    () {
      final download = <String, dynamic>{
        'status': 'running',
        'stage': 'Downloading video to this phone',
        'progress': 0.15,
        'phase_progress': 0.5,
      };
      expect(jobStage(download), 'Downloading video to this phone');
      expect(jobFraction(download), 0.5);
      expect(jobFraction({...download, 'phase_progress': 0}), 0);
      expect(jobFraction({...download, 'phase_progress': null}), isNull);
      expect(jobFraction({'status': 'queued', 'progress': 0}), isNull);
      expect(jobFraction({'status': 'completed', 'progress': 1}), 1);
      expect(jobStage({...download, 'status': 'failed'}), 'Failed');
      expect(jobFraction({...download, 'status': 'failed'}), isNull);
      expect(jobStage({...download, 'status': 'cancelled'}), 'Cancelled');
      expect(jobFraction({...download, 'status': 'cancelled'}), isNull);
    },
  );
}
