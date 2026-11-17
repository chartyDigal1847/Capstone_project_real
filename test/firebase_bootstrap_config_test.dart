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

  test('emulator ports are validated and may be overridden for local runs', () {
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: true,
        useEmulators: true,
        previewBuild: false,
        emulatorProjectId: 'demo-localspot',
        emulatorHost: '192.168.1.58',
        authEmulatorPort: 19099,
        firestoreEmulatorPort: 18080,
      ),
      returnsNormally,
    );
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: true,
        useEmulators: true,
        previewBuild: false,
        emulatorProjectId: 'demo-localspot',
        emulatorHost: '192.168.1.58',
        authEmulatorPort: 70000,
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

  test('trial release requires a remote HTTPS Worker hostname', () {
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: false,
        useEmulators: false,
        previewBuild: false,
        trialBuild: true,
        workerBackendUrl: '',
        emulatorProjectId: 'trial-project',
        emulatorHost: '',
      ),
      throwsStateError,
    );
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: false,
        useEmulators: false,
        previewBuild: false,
        trialBuild: true,
        workerBackendUrl: 'https://127.0.0.1:8787',
        emulatorProjectId: 'trial-project',
        emulatorHost: '',
      ),
      throwsStateError,
    );
    expect(
      () => validateFirebaseBootstrapConfiguration(
        debugBuild: false,
        useEmulators: false,
        previewBuild: false,
        trialBuild: true,
        workerBackendUrl: 'https://localspot.example.workers.dev',
        emulatorProjectId: 'trial-project',
        emulatorHost: '',
      ),
      returnsNormally,
    );
    for (final url in [
      'http://localspot.example.workers.dev',
      'https://localhost.',
      'https://gateway.local',
      'https://worker.home.arpa',
      'https://192.168.1.10',
    ]) {
      expect(
        () => validateFirebaseBootstrapConfiguration(
          debugBuild: false,
          useEmulators: false,
          previewBuild: false,
          trialBuild: true,
          workerBackendUrl: url,
          emulatorProjectId: 'trial-project',
          emulatorHost: '',
        ),
        throwsStateError,
        reason: 'Trial releases must reject $url',
      );
    }
  });
}
