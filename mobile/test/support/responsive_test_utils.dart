import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sets the test surface to a fixed logical size (dpr = 1 so logical == given),
/// and restores it after the test.
Future<void> setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

const Size phoneSize = Size(360, 740);
const Size smallPhoneSize = Size(320, 568);
const Size desktopSize = Size(1400, 900);
