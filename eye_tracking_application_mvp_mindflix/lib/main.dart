import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:eye_tracking/eye_tracking.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: const GazeTracker(),
  );
}

enum TrackerPhase { calibrating, tracking }

class GazeTracker extends StatefulWidget {
  const GazeTracker({super.key});

  @override
  State<GazeTracker> createState() => _GazeTrackerState();
}

class _GazeTrackerState extends State<GazeTracker>
    with SingleTickerProviderStateMixin {
  final EyeTracking _tracker = EyeTracking();
  StreamSubscription<GazeData>? _subscription;
  bool _ready = false;
  bool _tracking = false;
  String? _errorMessage;

  Offset _dot = Offset.zero;
  final List<Offset> _history = [];
  static const int _maxHistory = 6;
  static const double _maxNormalizedJump = 0.2;
  static const double _emaWeight = 0.35;

  Offset? _smoothedRawGaze;
  DateTime? _lastLogAt;
  static const Duration _logInterval = Duration(seconds: 2);

  late final AnimationController _blink;
  late final Animation<double> _blinkOp;

  TrackerPhase _phase = TrackerPhase.calibrating;
  final List<Offset> _calibrationTargets = const [
    Offset(0.1, 0.1),
    Offset(0.5, 0.1),
    Offset(0.9, 0.1),
    Offset(0.9, 0.5),
    Offset(0.9, 0.9),
    Offset(0.5, 0.9),
    Offset(0.1, 0.9),
    Offset(0.1, 0.5),
    Offset(0.5, 0.5),
  ];
  late final List<List<Offset>> _calibrationSamples;
  int _calibrationIndex = 0;
  int _displayTargetIndex = 0;
  bool _isCollecting = false;
  Timer? _collectDelayTimer;
  Timer? _calibrationTimer;
  static const Duration _dwellDuration = Duration(seconds: 4);
  static const Duration _travelDuration = Duration(seconds: 1);
  static const Duration _settleDuration = Duration(seconds: 1);
  Offset _mappingSlope = const Offset(1, 1);
  Offset _mappingIntercept = Offset.zero;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _blinkOp = Tween(begin: 0.3, end: 1.0).animate(_blink);
    _calibrationSamples =
        List.generate(_calibrationTargets.length, (_) => <Offset>[]);
    _init();
  }

  Future<void> _init() async {
    try {
      _log('Initializing eye tracking...');
      await _tracker.initialize();
      final hasPermission = await _tracker.requestCameraPermission();
      if (!hasPermission) {
        throw Exception('Camera permission denied');
      }
      await _tracker.startTracking();
      _log('Eye tracking started.');
      _beginCalibrationRun();
      _subscription = _tracker.getGazeStream().listen(_handleGaze);
      setState(() {
        _ready = true;
        _tracking = true;
      });
    } catch (e) {
      _log('Eye tracking init failed: $e');
      setState(() {
        _errorMessage = e.toString();
        _ready = true;
      });
    }
  }

  void _handleGaze(GazeData gaze) {
    final screen = MediaQuery.of(context).size;
    if (screen.width == 0 || screen.height == 0) return;

    final raw = Offset(
      (gaze.x / screen.width).clamp(0.0, 1.0),
      (gaze.y / screen.height).clamp(0.0, 1.0),
    );
    final stableRaw = _smoothRawGaze(raw);

    if (_phase == TrackerPhase.calibrating) {
      _handleCalibrationSample(stableRaw, screen);
      return;
    }

    final mappedNorm = _applyMapping(stableRaw);
    final mapped = Offset(
      mappedNorm.dx * screen.width,
      mappedNorm.dy * screen.height,
    );

    _history.add(mapped);
    if (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
    final avg = _history.reduce((a, b) => a + b) / _history.length.toDouble();
    final clamped = Offset(
      avg.dx.clamp(0, screen.width),
      avg.dy.clamp(0, screen.height),
    );

    if (mounted) {
      setState(() => _dot = clamped);
    }

    _log(
      'Gaze raw: ${_formatOffset(raw)} | mapped: ${_formatOffset(mappedNorm)}',
    );
  }

  Offset _smoothRawGaze(Offset raw) {
    if (_smoothedRawGaze == null) {
      _smoothedRawGaze = raw;
      return raw;
    }
    final prev = _smoothedRawGaze!;
    final delta = (raw - prev).distance;
    if (delta > _maxNormalizedJump) {
      final scale = _maxNormalizedJump / delta;
      raw = prev + (raw - prev) * scale;
    }
    final smoothed = Offset(
      prev.dx + (raw.dx - prev.dx) * _emaWeight,
      prev.dy + (raw.dy - prev.dy) * _emaWeight,
    );
    _smoothedRawGaze = smoothed;
    return smoothed;
  }

  Offset _medianOffset(List<Offset> samples) {
    double median(List<double> values) {
      values.sort();
      final mid = values.length ~/ 2;
      if (values.length.isOdd) return values[mid];
      return (values[mid - 1] + values[mid]) / 2.0;
    }

    final xs = samples.map((e) => e.dx).toList();
    final ys = samples.map((e) => e.dy).toList();
    return Offset(median(xs), median(ys));
  }

  void _handleCalibrationSample(Offset rawGaze, Size screen) {
    if (!_isCollecting) return;
    final currentSamples = _calibrationSamples[_calibrationIndex];
    currentSamples.add(rawGaze);

    if (currentSamples.length == 1) {
      _log(
        'Collecting samples for target ${_calibrationIndex + 1}/${_calibrationTargets.length}',
      );
    }

    _dot = Offset(
      _calibrationTargets[_calibrationIndex].dx * screen.width,
      _calibrationTargets[_calibrationIndex].dy * screen.height,
    );
  }

  Offset _applyMapping(Offset rawGaze) {
    if (_phase != TrackerPhase.tracking) return rawGaze;
    final mapped = Offset(
      _mappingSlope.dx * rawGaze.dx + _mappingIntercept.dx,
      _mappingSlope.dy * rawGaze.dy + _mappingIntercept.dy,
    );
    return Offset(
      mapped.dx.clamp(0.0, 1.0),
      mapped.dy.clamp(0.0, 1.0),
    );
  }

  void _finalizeCalibration() {
    _calibrationTimer?.cancel();
    _collectDelayTimer?.cancel();
    _isCollecting = false;
    _log('Finalizing calibration with collected samples...');
    final List<Offset> gazeMeans = [];
    for (int i = 0; i < _calibrationSamples.length; i++) {
      final samples = _calibrationSamples[i];
      if (samples.isEmpty) {
        _log('No samples for target ${i + 1}, falling back to target location.');
        gazeMeans.add(_calibrationTargets[i]);
      } else {
        gazeMeans.add(_medianOffset(samples));
      }
    }

    final targetMeans = _calibrationTargets;
    double gazeMeanX = 0, gazeMeanY = 0, targetMeanX = 0, targetMeanY = 0;
    for (int i = 0; i < gazeMeans.length; i++) {
      gazeMeanX += gazeMeans[i].dx;
      gazeMeanY += gazeMeans[i].dy;
      targetMeanX += targetMeans[i].dx;
      targetMeanY += targetMeans[i].dy;
    }
    gazeMeanX /= gazeMeans.length;
    gazeMeanY /= gazeMeans.length;
    targetMeanX /= targetMeans.length;
    targetMeanY /= targetMeans.length;

    double varGazeX = 0, varGazeY = 0, covX = 0, covY = 0;
    for (int i = 0; i < gazeMeans.length; i++) {
      final dxGaze = gazeMeans[i].dx - gazeMeanX;
      final dyGaze = gazeMeans[i].dy - gazeMeanY;
      varGazeX += dxGaze * dxGaze;
      varGazeY += dyGaze * dyGaze;
      covX += dxGaze * (targetMeans[i].dx - targetMeanX);
      covY += dyGaze * (targetMeans[i].dy - targetMeanY);
    }

    varGazeX = varGazeX == 0 ? 1e-6 : varGazeX;
    varGazeY = varGazeY == 0 ? 1e-6 : varGazeY;

    final slopeX = covX / varGazeX;
    final slopeY = covY / varGazeY;
    final interceptX = targetMeanX - slopeX * gazeMeanX;
    final interceptY = targetMeanY - slopeY * gazeMeanY;

    setState(() {
      _mappingSlope = Offset(slopeX, slopeY);
      _mappingIntercept = Offset(interceptX, interceptY);
      _phase = TrackerPhase.tracking;
      _history.clear();
    });

    _log(
      'Calibration complete. Slope: ${_formatOffset(_mappingSlope)}, '
      'Intercept: ${_formatOffset(_mappingIntercept)}',
    );
  }

  void _beginCalibrationRun() {
    _calibrationTimer?.cancel();
    _calibrationIndex = 0;
    _displayTargetIndex = 0;
    _phase = TrackerPhase.calibrating;
    _startTargetWindow();
  }

  void _startTargetWindow() {
    if (_calibrationIndex >= _calibrationTargets.length) {
      _finalizeCalibration();
      return;
    }
    _isCollecting = false;
    _calibrationSamples[_calibrationIndex].clear();
    _displayTargetIndex = _calibrationIndex;
    _placeDotAtTarget(_displayTargetIndex);
    _log(
      'Target ${_calibrationIndex + 1}/${_calibrationTargets.length}: '
      '${_dwellDuration.inSeconds}s dwell',
    );
    _collectDelayTimer?.cancel();
    _collectDelayTimer = Timer(_settleDuration, () {
      _isCollecting = true;
      _log('Sampling target ${_calibrationIndex + 1} after settle.');
    });
    _calibrationTimer?.cancel();
    _calibrationTimer = Timer(_dwellDuration, _startTransitionWindow);
    setState(() {});
  }

  void _startTransitionWindow() {
    _isCollecting = false;
    _log(
      'Transitioning to next target (${_travelDuration.inSeconds}s).',
    );
    _calibrationTimer?.cancel();
    _displayTargetIndex = (_calibrationIndex + 1)
        .clamp(0, _calibrationTargets.length - 1);
    _placeDotAtTarget(_displayTargetIndex);
    _calibrationTimer = Timer(_travelDuration, () {
      _calibrationIndex++;
      _startTargetWindow();
    });
    setState(() {});
  }

  void _placeDotAtTarget(int index) {
    final screen = MediaQuery.of(context).size;
    _dot = Offset(
      _calibrationTargets[index].dx * screen.width,
      _calibrationTargets[index].dy * screen.height,
    );
  }

  void _log(String message) {
    final now = DateTime.now();
    if (_lastLogAt == null || now.difference(_lastLogAt!) >= _logInterval) {
      debugPrint(message);
      _lastLogAt = now;
    }
  }

  String _formatOffset(Offset offset) =>
      '(${offset.dx.toStringAsFixed(2)}, ${offset.dy.toStringAsFixed(2)})';

  @override
  void dispose() {
    _subscription?.cancel();
    _tracker.stopTracking();
    _tracker.dispose();
    _blink.dispose();
    _collectDelayTimer?.cancel();
    _calibrationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.redAccent),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;
    final dotPos =
        _dot == Offset.zero ? Offset(size.width / 2, size.height / 2) : _dot;

    return Scaffold(
      body: Stack(
        children: [
          Container(color: Colors.black),
          Positioned(
            left: 16,
            top: 16,
            child: Row(
              children: [
                const Icon(Icons.visibility, color: Colors.white70),
                const SizedBox(width: 8),
                Text(
                  _phase == TrackerPhase.calibrating
                      ? 'Calibrating (${_calibrationIndex + 1}/${_calibrationTargets.length})'
                      : (_tracking ? 'Tracking eyes' : 'Starting tracker...'),
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          if (_phase == TrackerPhase.calibrating)
            Positioned(
              left: _calibrationTargets[_displayTargetIndex].dx * size.width - 16,
              top: _calibrationTargets[_displayTargetIndex].dy * size.height - 16,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.redAccent, width: 3),
                ),
              ),
            ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            left: dotPos.dx - 10,
            top: dotPos.dy - 10,
            child: FadeTransition(
              opacity: _blinkOp,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Colors.blueAccent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blueAccent.withOpacity(.6),
                      blurRadius: 8,
                      spreadRadius: 3,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
