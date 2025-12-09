import 'dart:async';
import 'dart:typed_data';

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

enum TrackerPhase { calibrating, tracking }

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
  bool _processing = false;
  late int _sensorOrientation;
  Offset _dot = Offset.zero;
  final List<Offset> _history = [];
  static const int _maxHistory = 6;
  static const int _logEveryNFrames = 12;
  int _frameCounter = 0;
  late final AnimationController _blink;
  late final Animation<double> _blinkOp;
  TrackerPhase _phase = TrackerPhase.calibrating;
  final List<Offset> _calibrationTargets = const [
    Offset(0.5, 0.5),
    Offset(0.15, 0.15),
    Offset(0.85, 0.15),
    Offset(0.85, 0.85),
    Offset(0.15, 0.85),
  ];
  late final List<List<Offset>> _calibrationSamples;
  final int _samplesPerTarget = 18;
  int _calibrationIndex = 0;
  Offset _mappingSlope = const Offset(1, 1);
  Offset _mappingIntercept = Offset.zero;
  bool get _hasCalibration => _phase == TrackerPhase.tracking;

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
    debugPrint('Initializing camera controller...');
    _sensorOrientation = widget.camera.sensorOrientation;
    debugPrint('Sensor orientation: $_sensorOrientation');
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
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
    debugPrint('Starting image stream for face detection...');
    _controller.startImageStream((image) async {
      if (_processing || !_controller.value.isStreamingImages) return;
      _processing = true;
      try {
        final inputImage = _inputImageFromCameraImage(image);
        await _analyze(inputImage);
      } catch (e) {
        debugPrint('Frame analysis failed: $e');
      } finally {
        _processing = false;
      }
    });
  }

  InputImage _inputImageFromCameraImage(CameraImage image) {
    final rotation = InputImageRotationValue.fromRawValue(
          widget.camera.sensorOrientation,
        ) ??
        InputImageRotation.rotation0deg;
    final format = InputImageFormatValue.fromRawValue(image.format.raw) ??
        InputImageFormat.nv21;
    final bytes = WriteBuffer();
    for (final plane in image.planes) {
      bytes.putUint8List(plane.bytes);
    }
    final data = bytes.done().buffer.asUint8List();
    return InputImage.fromBytes(
      bytes: data,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Future<void> _analyze(InputImage img) async {
    _frameCounter++;
    if (_frameCounter % _logEveryNFrames == 0) {
      debugPrint('Analyzing streaming frame...');
    }
    final faces = await _detector.processImage(img);
    if (_frameCounter % _logEveryNFrames == 0) {
      debugPrint('Faces detected: ${faces.length}');
    }
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
        if (_frameCounter % _logEveryNFrames == 0) {
          debugPrint(
              'Face ${faces.indexOf(f)} missing eye landmarks (left: $l, right: $r)');
        }
      }
    }
    if (n == 0) {
      if (_frameCounter % _logEveryNFrames == 0) {
        debugPrint('No eyes found in detected faces');
      }
      return;
    }

    final preview = _controller.value.previewSize!;
    final screen = MediaQuery.of(context).size;
    final raw = _normalizePoint(Offset(x / n, y / n), preview);
    if (_phase == TrackerPhase.calibrating) {
      _handleCalibrationSample(raw, screen);
    } else {
      final mappedNorm = _applyMapping(raw);
      final mapped = Offset(
        mappedNorm.dx * screen.width,
        mappedNorm.dy * screen.height,
      );

      if (_frameCounter % _logEveryNFrames == 0) {
        debugPrint('Raw eye avg: $raw | Mapped to screen: $mapped');
      }

      _history.add(mapped);
      if (_history.length > _maxHistory) {
        _history.removeAt(0);
      }
      final avg =
          _history.reduce((a, b) => a + b) / _history.length.toDouble();
      final clamped = Offset(
        avg.dx.clamp(0, screen.width),
        avg.dy.clamp(0, screen.height),
      );

      if (mounted) {
        setState(() => _dot = clamped);
        if (_frameCounter % _logEveryNFrames == 0) {
          debugPrint(
              'Updated dot position to $clamped with history ${_history.length}');
        }
      }
    }
  }

  Offset _normalizePoint(Offset p, Size imageSize) {
    double x = p.dx;
    double y = p.dy;
    double targetW = imageSize.width;
    double targetH = imageSize.height;

    switch (_sensorOrientation) {
      case 90:
        x = p.dy;
        y = imageSize.width - p.dx;
        targetW = imageSize.height;
        targetH = imageSize.width;
        break;
      case 180:
        x = imageSize.width - p.dx;
        y = imageSize.height - p.dy;
        break;
      case 270:
        x = imageSize.height - p.dy;
        y = p.dx;
        targetW = imageSize.height;
        targetH = imageSize.width;
        break;
      default:
        break;
    }

    if (widget.camera.lensDirection == CameraLensDirection.front) {
      x = targetW - x;
    }

    final normalized = Offset(
      (x / targetW).clamp(0.0, 1.0),
      (y / targetH).clamp(0.0, 1.0),
    );

    if (_frameCounter % _logEveryNFrames == 0) {
      debugPrint('Normalized eye point $p to $normalized using size $imageSize');
    }
    return normalized;
  }

  void _handleCalibrationSample(Offset rawEye, Size screen) {
    final currentSamples = _calibrationSamples[_calibrationIndex];
    currentSamples.add(rawEye);

    if (currentSamples.length == 1) {
      debugPrint(
          'Collecting samples for target ${_calibrationIndex + 1}/${_calibrationTargets.length}');
    }

    _dot = Offset(
      _calibrationTargets[_calibrationIndex].dx * screen.width,
      _calibrationTargets[_calibrationIndex].dy * screen.height,
    );

    if (currentSamples.length >= _samplesPerTarget) {
      debugPrint(
          'Completed target ${_calibrationIndex + 1}, computing next target');
      if (_calibrationIndex < _calibrationTargets.length - 1) {
        _calibrationIndex++;
      } else {
        _finalizeCalibration();
      }
      if (mounted) setState(() {});
    } else {
      if (mounted && _frameCounter % _logEveryNFrames == 0) {
        setState(() {});
      }
    }
  }

  Offset _applyMapping(Offset rawEye) {
    if (!_hasCalibration) return rawEye;
    final mapped = Offset(
      _mappingSlope.dx * rawEye.dx + _mappingIntercept.dx,
      _mappingSlope.dy * rawEye.dy + _mappingIntercept.dy,
    );
    return Offset(
      mapped.dx.clamp(0.0, 1.0),
      mapped.dy.clamp(0.0, 1.0),
    );
  }

  void _finalizeCalibration() {
    debugPrint('Finalizing calibration with collected samples...');
    final List<Offset> eyeMeans = _calibrationSamples.map((samples) {
      final total = samples.reduce((a, b) => a + b);
      return total / samples.length.toDouble();
    }).toList();

    final targetMeans = _calibrationTargets;

    double eyeMeanX = 0, eyeMeanY = 0, targetMeanX = 0, targetMeanY = 0;
    for (int i = 0; i < eyeMeans.length; i++) {
      eyeMeanX += eyeMeans[i].dx;
      eyeMeanY += eyeMeans[i].dy;
      targetMeanX += targetMeans[i].dx;
      targetMeanY += targetMeans[i].dy;
    }
    eyeMeanX /= eyeMeans.length;
    eyeMeanY /= eyeMeans.length;
    targetMeanX /= targetMeans.length;
    targetMeanY /= targetMeans.length;

    double varEyeX = 0, varEyeY = 0, covX = 0, covY = 0;
    for (int i = 0; i < eyeMeans.length; i++) {
      final dxEye = eyeMeans[i].dx - eyeMeanX;
      final dyEye = eyeMeans[i].dy - eyeMeanY;
      varEyeX += dxEye * dxEye;
      varEyeY += dyEye * dyEye;
      covX += dxEye * (targetMeans[i].dx - targetMeanX);
      covY += dyEye * (targetMeans[i].dy - targetMeanY);
    }

    varEyeX = varEyeX == 0 ? 1e-6 : varEyeX;
    varEyeY = varEyeY == 0 ? 1e-6 : varEyeY;

    final slopeX = covX / varEyeX;
    final slopeY = covY / varEyeY;
    final interceptX = targetMeanX - slopeX * eyeMeanX;
    final interceptY = targetMeanY - slopeY * eyeMeanY;

    _mappingSlope = Offset(slopeX, slopeY);
    _mappingIntercept = Offset(interceptX, interceptY);
    _phase = TrackerPhase.tracking;
    _history.clear();

    debugPrint(
        'Calibration complete. Slope: $_mappingSlope, Intercept: $_mappingIntercept');
  }

  @override
  void dispose() {
    _controller.dispose();
    _detector.close();
    _blink.dispose();
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
                  _phase == TrackerPhase.calibrating
                      ? "Calibrating (${_calibrationIndex + 1}/${_calibrationTargets.length})"
                      : (_tracking ? "Tracking eyes" : "Starting camera..."),
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          if (_phase == TrackerPhase.calibrating)
            Positioned(
              left: _calibrationTargets[_calibrationIndex].dx * size.width - 16,
              top: _calibrationTargets[_calibrationIndex].dy * size.height - 16,
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
