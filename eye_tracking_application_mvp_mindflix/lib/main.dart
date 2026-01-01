import 'dart:async';

import 'package:eye_tracking/eye_tracking.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _blinkOp = Tween(begin: 0.3, end: 1.0).animate(_blink);
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
    final mapped = Offset(
      stableRaw.dx * screen.width,
      stableRaw.dy * screen.height,
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

    _log('Gaze: ${_formatOffset(raw)}');
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
                  _tracking ? 'Tracking eyes' : 'Starting tracker...',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
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
