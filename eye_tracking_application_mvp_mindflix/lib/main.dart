import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  final cameras = await availableCameras();
  final front = cameras.firstWhere(
    (c) => c.lensDirection == CameraLensDirection.front,
    orElse: () => cameras.first,
  );
  runApp(MyApp(camera: front));
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;
  const MyApp({super.key, required this.camera});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: GazeTracker(camera: camera),
  );
}

class GazeTracker extends StatefulWidget {
  final CameraDescription camera;
  const GazeTracker({super.key, required this.camera});
  @override
  State<GazeTracker> createState() => _GazeTrackerState();
}

class _GazeTrackerState extends State<GazeTracker>
    with SingleTickerProviderStateMixin {
  late CameraController _controller;
  late FaceDetector _detector;
  bool _ready = false;
  bool _tracking = false;
  Offset _dot = Offset.zero;
  final List<Offset> _history = [];
  static const int _maxHistory = 6;
  Timer? _frameT;
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
    debugPrint('Initializing camera controller...');
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.low,
      enableAudio: false,
    );
    await _controller.initialize();
    debugPrint('Camera initialized with preview size: '
        '${_controller.value.previewSize}');
    await _controller.setFlashMode(FlashMode.off);
    debugPrint('Flash mode set to off');
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    debugPrint('Face detector created with landmarks enabled');
    setState(() => _ready = true);
    debugPrint('Gaze tracker ready, starting tracking loop');
    _startTracking();
  }

  void _startTracking() {
    if (_tracking || !_controller.value.isInitialized) return;
    setState(() => _tracking = true);
    _frameT = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (!_controller.value.isInitialized || _controller.value.isTakingPicture) {
        return;
      }
      try {
        final pic = await _controller.takePicture();
        debugPrint('Captured frame at: ${pic.path}');
        await _analyze(pic.path);
      } catch (e) {
        debugPrint('Frame capture failed: $e');
      }
    });
  }

  Future<void> _analyze(String path) async {
    debugPrint('Analyzing frame: $path');
    final img = InputImage.fromFilePath(path);
    final faces = await _detector.processImage(img);
    debugPrint('Faces detected: ${faces.length}');
    if (faces.isEmpty || !_controller.value.isInitialized) return;

    double x = 0, y = 0;
    int n = 0;
    for (var f in faces) {
      final l = f.landmarks[FaceLandmarkType.leftEye];
      final r = f.landmarks[FaceLandmarkType.rightEye];
      if (l != null && r != null) {
        debugPrint(
            'Face ${faces.indexOf(f)} eye landmarks -> left: ${l.position}, right: ${r.position}');
        x += (l.position.x + r.position.x) / 2;
        y += (l.position.y + r.position.y) / 2;
        n++;
      } else {
        debugPrint(
            'Face ${faces.indexOf(f)} missing eye landmarks (left: $l, right: $r)');
      }
    }
    if (n == 0) {
      debugPrint('No eyes found in detected faces');
      return;
    }

    final preview = _controller.value.previewSize!;
    final screen = MediaQuery.of(context).size;
    final raw = Offset(x / n, y / n);
    final mapped = Offset(
      (raw.dx / preview.width) * screen.width,
      (raw.dy / preview.height) * screen.height,
    );

    debugPrint('Raw eye avg: $raw | Mapped to screen: $mapped');

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
      debugPrint('Updated dot position to $clamped with history ${_history.length}');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _detector.close();
    _blink.dispose();
    _frameT?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final size = MediaQuery.of(context).size;
    final dotPos = _dot == Offset.zero ? Offset(size.width / 2, size.height / 2) : _dot;
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
                  _tracking ? "Tracking eyes" : "Starting camera...",
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
