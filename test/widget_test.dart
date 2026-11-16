import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:catvp/main.dart';

void main() {
  testWidgets('home remains usable on a small iPhone', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const CatVpnApp());
    expect(find.text('CatVPN Nord'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -400),
    );
    await tester.pump();
    expect(find.text('Đổi IP').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('telemetry pauses in background and resumes', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.catvpn.nord/vpn');
    var polls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'loadPrefs') return <String, String>{};
      if (call.method == 'getStatus') {
        polls++;
        return {'state': 'DOWN', 'rxBytes': 0, 'txBytes': 0};
      }
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(const CatVpnApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final foregroundPolls = polls;
    expect(foregroundPolls, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 4));
    expect(polls, foregroundPolls);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(polls, greaterThan(foregroundPolls));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
