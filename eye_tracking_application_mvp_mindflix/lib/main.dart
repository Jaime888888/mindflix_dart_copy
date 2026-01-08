import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:eyedid_flutter/eyedid_flutter.dart';
import 'package:eyedid_flutter/gaze_tracker_options.dart';
import 'package:eyedid_flutter/eyedid_flutter_initialized_result.dart';
import 'package:eyedid_flutter/events/eyedid_flutter_metrics.dart';

void main() {
  runApp(const MaterialApp(home: EyedidMinimalDemo()));
}

class EyedidMinimalDemo extends StatefulWidget {
  const EyedidMinimalDemo({super.key});

  @override
  State<EyedidMinimalDemo> createState() => _EyedidMinimalDemoState();
}

class _EyedidMinimalDemoState extends State<EyedidMinimalDemo> {
  final _sdk = EyedidFlutter();
  StreamSubscription? _sub;

  // Pega aquí tu Development Key de Eyedid/SeeSo
  static const _licenseKey = 'dev_d7dhqz669r2vfxjc60f0gvke1k7og1n8v8pznh5n';

  String _status = 'Starting...';
  double _x = 0.0;
  double _y = 0.0;
  bool _hasGaze = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      var hasPerm = await _sdk.checkCameraPermission();
      if (!hasPerm) {
        hasPerm = await _sdk.requestCameraPermission();
      }
      if (!hasPerm) {
        setState(() => _status = 'Camera permission denied');
        return;
      }

      final options = GazeTrackerOptionsBuilder()
          .setPreset(CameraPreset.vga640x480)
          .setUseGazeFilter(false)
          .setUseBlink(false)
          .setUseUserStatus(false)
          .build();

      final InitializedResult initResult =
          await _sdk.initGazeTracker(licenseKey: _licenseKey, options: options);

      if (!initResult.result) {
        setState(() => _status = 'initGazeTracker failed');
        return;
      }

      _sub?.cancel();
      _sub = _sdk.getTrackingEvent().listen((event) {
        final info = MetricsInfo(event);

        if (!mounted) return;

        if (info.gazeInfo.trackingState == TrackingState.success) {
          setState(() {
            _status = 'Tracking';
            _hasGaze = true;
            _x = info.gazeInfo.gaze.x;
            _y = info.gazeInfo.gaze.y;
          });
        } else {
          setState(() {
            _status = 'Tracking (no gaze)';
            _hasGaze = false;
          });
        }
      });

      await _sdk.startTracking();
    } on PlatformException catch (e) {
      setState(() => _status = 'PlatformException: ${e.message ?? e.code}');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    // EyedidFlutter no tiene dispose(); usa stop + release. 
    unawaited(_sdk.stopTracking());
    unawaited(_sdk.releaseGazeTracker());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned(top: 60, left: 16, child: Text(_status)),
          if (_hasGaze)
            Positioned(
              left: _x - 6,
              top: _y - 6,
              child: Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
