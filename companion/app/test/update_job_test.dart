// The install job as the app reads and shows it (PROTOCOL §12d).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/update/update_job.dart';
import 'package:nexusq_companion/update/update_job_view.dart';

Map<String, dynamic> jobJson({
  String phase = 'downloading',
  String state = 'running',
  String kind = 'system',
  Map<String, dynamic> progress = const {},
  bool stalled = false,
  bool resumed = false,
  String? error,
  Map<String, dynamic>? result,
}) => {
  'id': '20261115-101500-$kind',
  'kind': kind,
  'state': state,
  'phase': phase,
  'attempt': resumed ? 2 : 1,
  'resumed': resumed,
  'stalled': stalled,
  'progress': {
    'percent': 30,
    'phasePercent': 45,
    'packagesDone': 0,
    'packagesTotal': 0,
    'current': null,
    'bytesDone': null,
    'bytesTotal': null,
    'etaS': null,
    ...progress,
  },
  'result': result,
  'error': error,
};

void main() {
  group('reading', () {
    test('a job object', () {
      final j = UpdateJob.fromJson(
        jobJson(
          progress: {
            'bytesDone': 45 << 20,
            'bytesTotal': 120 << 20,
            'packagesTotal': 140,
            'etaS': 240,
          },
        ),
      )!;
      expect(j.running, isTrue);
      expect(j.isSystem, isTrue);
      expect(j.phase, UpdatePhase.downloading);
      expect(j.fraction, closeTo(0.30, 1e-9));
      expect(j.bytesTotal, 120 << 20);
    });

    test('anything else is not a job', () {
      expect(UpdateJob.fromJson(null), isNull);
      expect(UpdateJob.fromJson('job'), isNull);
      expect(UpdateJob.fromJson({'id': 1}), isNull);
    });

    test('a phase from a newer bridge falls back on the state', () {
      expect(
        UpdateJob.fromJson(jobJson(phase: 'verifying'))!.phase,
        UpdatePhase.preparing,
      );
      expect(
        UpdateJob.fromJson(jobJson(phase: 'verifying', state: 'done'))!.phase,
        UpdatePhase.done,
      );
    });

    test('a percent out of range is clamped', () {
      expect(
        UpdateJob.fromJson(jobJson(progress: {'percent': 140}))!.percent,
        100,
      );
    });

    test('the reboot a done job recommended', () {
      final j = UpdateJob.fromJson(
        jobJson(
          state: 'done',
          phase: 'done',
          result: {'rebootRecommended': true},
        ),
      )!;
      expect(j.rebootRecommended, isTrue);
    });
  });

  group('in words', () {
    test('downloading: how much, of how many packages, how long', () {
      final j = UpdateJob.fromJson(
        jobJson(
          progress: {
            'bytesDone': 45 << 20,
            'bytesTotal': 120 << 20,
            'packagesTotal': 140,
            'etaS': 240,
          },
        ),
      )!;
      expect(j.headline, 'Downloading the update');
      expect(j.detail, '45 MB of 120 MB · 140 packages · about 4 min left');
    });

    test('installing: which package of how many', () {
      final j = UpdateJob.fromJson(
        jobJson(
          phase: 'installing',
          progress: {
            'packagesDone': 125,
            'packagesTotal': 393,
            'current': 'pulseaudio',
            'etaS': 40,
          },
        ),
      )!;
      expect(j.headline, 'Installing the update');
      expect(
        j.detail,
        '125 of 393 packages · pulseaudio · about a minute left',
      );
    });

    test('an interrupted update says it is finishing', () {
      final j = UpdateJob.fromJson(jobJson(phase: 'preparing', resumed: true))!;
      expect(j.headline, 'Finishing an interrupted update');
    });

    test('no estimate until the Q can tell, and none once it ended', () {
      expect(UpdateJob.fromJson(jobJson())!.etaText, isNull);
      expect(
        UpdateJob.fromJson(
          jobJson(state: 'done', phase: 'done', progress: {'etaS': 30}),
        )!.etaText,
        isNull,
      );
    });

    test('small downloads keep a decimal', () {
      final j = UpdateJob.fromJson(
        jobJson(progress: {'bytesDone': 1 << 20, 'bytesTotal': 3 << 19}),
      )!;
      expect(j.detail, '1.0 MB of 1.5 MB');
    });
  });

  group('the progress view', () {
    Future<void> pump(WidgetTester t, UpdateJob job, {bool linkUp = true}) =>
        t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UpdateJobProgressView(job: job, linkUp: linkUp),
            ),
          ),
        );

    testWidgets('shows the phase, the percent and the numbers', (t) async {
      await pump(
        t,
        UpdateJob.fromJson(
          jobJson(
            phase: 'installing',
            progress: {
              'percent': 71,
              'packagesDone': 125,
              'packagesTotal': 393,
            },
          ),
        )!,
      );
      await t.pumpAndSettle();
      expect(find.text('Installing the update'), findsOneWidget);
      expect(find.text('71%'), findsOneWidget);
      expect(find.text('125 of 393 packages'), findsOneWidget);
      final bar = t.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.71, 1e-9));
    });

    testWidgets('says when the install stalls and when the Q is away', (
      t,
    ) async {
      await pump(
        t,
        UpdateJob.fromJson(jobJson(phase: 'installing', stalled: true))!,
        linkUp: false,
      );
      expect(find.textContaining('No progress for a while'), findsOneWidget);
      expect(find.text('Waiting for the Q to answer…'), findsOneWidget);
    });

    testWidgets('the download and the install in the ring\'s colours', (
      t,
    ) async {
      Color? colorOf() => t
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .color;
      await pump(t, UpdateJob.fromJson(jobJson())!);
      final download = colorOf();
      await pump(t, UpdateJob.fromJson(jobJson(phase: 'installing'))!);
      expect(colorOf(), isNot(download));
    });
  });
}
