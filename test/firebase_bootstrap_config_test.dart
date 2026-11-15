import 'package:flutter_test/flutter_test.dart';
import 'package:localspot/firebase/bootstrap.dart';

void main() {
  test('debug build refuses Firebase without explicit emulator selection', () {
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: true,
        useEmulators: false,
        previewBuild: false,
        emulatorProjectId: 'demo-localspot',
        emulatorHost: '',
      ),
      throwsStateError,
    );
  });

  test('emulator build requires the demo project and an explicit host', () {
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: true,
        useEmulators: true,
        previewBuild: false,
        emulatorProjectId: 'production-project',
        emulatorHost: '192.168.1.58',
      ),
      throwsStateError,
    );
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: true,
        useEmulators: true,
        previewBuild: false,
        emulatorProjectId: 'demo-localspot',
        emulatorHost: '',
      ),
      throwsStateError,
    );
  });

  test('emulator configuration is rejected in release builds', () {
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: false,
        useEmulators: true,
        previewBuild: true,
        emulatorProjectId: 'demo-localspot',
        emulatorHost: '192.168.1.58',
      ),
      throwsStateError,
    );
  });

  test('release preview configuration passes without emulator settings', () {
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: false,
        useEmulators: false,
        previewBuild: true,
        emulatorProjectId: 'demo-localspot',
        emulatorHost: '',
      ),
      returnsNormally,
    );
  });

  test('release configuration fails closed without explicit preview mode', () {
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: false,
        useEmulators: false,
        previewBuild: false,
        emulatorProjectId: 'demo-localspot',
        emulatorHost: '',
      ),
      throwsStateError,
    );
  });
}
