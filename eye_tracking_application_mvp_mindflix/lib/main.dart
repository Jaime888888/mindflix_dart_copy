import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
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
  bool _ready = false,
      _running = false,
      _calibrating = false,
      _calibrated = false;
  bool _flipX = false, _flipY = true;
  double _dotX = 0, _dotY = 0, _calibX = 0, _calibY = 0;
  int _left = 0, _right = 0, _secs = 10;
  Timer? _frameT, _countT;
  double _xSens = 10.0, _ySens = 8.0; // amplified default
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
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.low,
      enableAudio: false,
    );
    await _controller.initialize();
    await _controller.setFlashMode(FlashMode.off);
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    setState(() => _ready = true);
  }

  Future<Offset?> _eyePos() async {
    try {
      final pic = await _controller.takePicture();
      final img = InputImage.fromFilePath(pic.path);
      final faces = await _detector.processImage(img);
      if (faces.isEmpty) return null;
      double x = 0, y = 0;
      int n = 0;
      for (var f in faces) {
        final l = f.landmarks[FaceLandmarkType.leftEye];
        final r = f.landmarks[FaceLandmarkType.rightEye];
        if (l != null && r != null) {
          x += (l.position.x + r.position.x) / 2;
          y += (l.position.y + r.position.y) / 2;
          n++;
        }
      }
      return n == 0 ? null : Offset(x / n, y / n);
    } catch (_) {
      return null;
    }
  }

  Future<void> _calibrate() async {
    if (_running || _calibrating) return;
    setState(() => _calibrating = true);
    final s = MediaQuery.of(context).size;
    final pts = [
      Offset(s.width * .1, s.height * .1),
      Offset(s.width * .9, s.height * .1),
      Offset(s.width * .1, s.height * .9),
      Offset(s.width * .9, s.height * .9),
      Offset(s.width * .5, s.height * .5),
    ];
    double tx = 0, ty = 0;
    int n = 0;
    for (var p in pts) {
      setState(() {
        _dotX = p.dx;
        _dotY = p.dy;
      });
      for (int i = 0; i < 4; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final e = await _eyePos();
        if (e != null) {
          tx += e.dx;
          ty += e.dy;
          n++;
        }
      }
    }
    if (n > 0) {
      _calibX = tx / n;
      _calibY = ty / n;
      _calibrated = true;
      _show("✅ Calibration Complete", "You can start the test now.");
    } else {
      _show("⚠️ Calibration Failed", "Please retry.");
    }
    setState(() => _calibrating = false);
  }

  void _start() {
    if (!_calibrated) return _snack("Please calibrate first!");
    if (_running) return;
    setState(() {
      _running = true;
      _secs = 10;
      _left = 0;
      _right = 0;
    });
    _countT = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _secs--);
      if (_secs <= 0) {
        t.cancel();
        _stop();
      }
    });
    _frameT = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!_controller.value.isInitialized || _controller.value.isTakingPicture)
        return;
      final pic = await _controller.takePicture();
      await _analyze(pic.path);
    });
  }

  Future<void> _analyze(String path) async {
    final img = InputImage.fromFilePath(path);
    final faces = await _detector.processImage(img);
    if (faces.isEmpty) return;
    final s = MediaQuery.of(context).size;
    double x = 0, y = 0;
    int n = 0;
    for (var f in faces) {
      final l = f.landmarks[FaceLandmarkType.leftEye];
      final r = f.landmarks[FaceLandmarkType.rightEye];
      if (l != null && r != null) {
        x += (l.position.x + r.position.x) / 2;
        y += (l.position.y + r.position.y) / 2;
        n++;
      }
    }
    if (n == 0) return;
    x /= n;
    y /= n;
    final p = _controller.value.previewSize!;
    double nx = _flipX ? (1 - x / p.width) * s.width : (x / p.width) * s.width;
    double ny = _flipY
        ? (1 - y / p.height) * s.height
        : (y / p.height) * s.height;
    double dx =
        ((nx - s.width / 2) - ((_calibX / p.width - .5) * s.width)) * _xSens +
        s.width / 2;
    double dy =
        ((ny - s.height / 2) - ((_calibY / p.height - .5) * s.height)) *
            _ySens +
        s.height / 2;
    setState(() {
      _dotX = dx.clamp(0, s.width);
      _dotY = dy.clamp(0, s.height);
    });
    if (dx < s.width / 2)
      _left++;
    else
      _right++;
  }

  Future<void> _stop() async {
    _frameT?.cancel();
    _countT?.cancel();
    setState(() => _running = false);
    final res = _left > _right
        ? "👁 Looked more at LEFT image"
        : _right > _left
        ? "👁 Looked more at RIGHT image"
        : "🤷‍♂️ Looked equally at both";
    _show("Test Result", "⏱ 10s\n👈 $_left left\n👉 $_right right\n\n$res");
  }

  void _snack(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  void _show(String t, String m) => showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(t),
      content: Text(m),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("OK"),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    _detector.close();
    _blink.dispose();
    _frameT?.cancel();
    _countT?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              Expanded(
                child: Image.asset(
                  'images/golden-retriever-tongue-out.jpg',
                  fit: BoxFit.cover,
                ),
              ),
              Expanded(
                child: Image.asset('images/orange-cat.jpg', fit: BoxFit.cover),
              ),
            ],
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            left: _dotX - 10,
            top: _dotY - 10,
            child: FadeTransition(
              opacity: _blinkOp,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: _calibrating ? Colors.orangeAccent : Colors.blueAccent,
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
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _calibrating
                        ? "Calibrating..."
                        : _running
                        ? "Time left: $_secs s"
                        : _calibrated
                        ? "✅ Calibrated! Ready"
                        : "Press Calibrate",
                    style: const TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: _running || _calibrating ? null : _calibrate,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 40,
                            vertical: 18,
                          ),
                        ),
                        child: const Text(
                          "Calibrate",
                          style: TextStyle(fontSize: 18),
                        ),
                      ),
                      const SizedBox(width: 20),
                      ElevatedButton(
                        onPressed: _running || _calibrating ? null : _start,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 40,
                            vertical: 18,
                          ),
                        ),
                        child: const Text(
                          "Start Test",
                          style: TextStyle(fontSize: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("Flip X"),
                      Switch(
                        value: _flipX,
                        onChanged: (v) => setState(() => _flipX = v),
                      ),
                      const SizedBox(width: 30),
                      const Text("Flip Y"),
                      Switch(
                        value: _flipY,
                        onChanged: (v) => setState(() => _flipY = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("X Sensitivity"),
                      Slider(
                        value: _xSens,
                        min: 2,
                        max: 15,
                        divisions: 13,
                        label: _xSens.toStringAsFixed(1),
                        onChanged: (v) => setState(() => _xSens = v),
                      ),
                      const Text("Y Sensitivity"),
                      Slider(
                        value: _ySens,
                        min: 2,
                        max: 15,
                        divisions: 13,
                        label: _ySens.toStringAsFixed(1),
                        onChanged: (v) => setState(() => _ySens = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
