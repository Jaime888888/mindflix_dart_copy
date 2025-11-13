# Gaze Tracker (Flutter + ML Kit)

A real-time eye gaze tracking app built with Flutter and Google ML Kit Face Detection.  
The app detects eye movements using the front camera, calibrates gaze positions, and visualizes the user’s focus as a moving dot. It is ideal for UX experiments, accessibility demos, and AI/ML research prototypes.

---

## Features

- Eye Landmark Tracking – Uses ML Kit to detect and track eye positions.  
- 5-Point Calibration – Guides the user through four corners and center to normalize gaze mapping.  
- 10-Second Gaze Test – Measures how long the user looks at the left vs right side of the screen.  
- Adjustable Sensitivity – Real-time sliders amplify gaze movement for better visibility.  
- Flip Axis Controls – Toggle horizontal or vertical inversion for different camera orientations.  
- Visual Feedback – A blinking dot follows the user’s eye direction in real time.  
- Cross-Platform – Works on Android, iOS, and desktop devices with camera support.

---

## Tech Stack

- Language: Dart  
- Framework: Flutter  
- ML Library: Google ML Kit (Face Detection)  
- Hardware: Device front camera

---

## How It Works

1. **Calibration**  
   The app displays blinking dots at the corners and center of the screen.  
   The user follows each dot with their eyes to record calibration data.

2. **Gaze Tracking**  
   Eye landmarks are detected, averaged, and mapped to the screen coordinates.  
   Movement is amplified using the adjustable sensitivity sliders.

3. **Test Mode**  
   A 10-second timer begins.  
   The app counts the user’s left and right gazes, then displays a summary result.

---

## Setup

1. Install Flutter and Dart SDK.  
2. Add the following dependencies to `pubspec.yaml`:
   ```yaml
   dependencies:
     camera: ^0.11.0
     google_mlkit_face_detection: ^0.11.0
