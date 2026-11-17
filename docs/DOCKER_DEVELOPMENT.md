# Locentra Docker development environment

The root `Dockerfile` pins the shared Android and Cloudflare toolchain:

- Flutter 3.47.1 / Dart 3.13.1
- Node.js 24.14.1 / npm 11.11.0
- OpenJDK 17
- Android platform 36, Build Tools 36.0.0, NDK 28.2.13676358, and CMake 3.22.1
- Gradle 8.14 from the Android Gradle wrapper

Flutter and Node package versions remain pinned by `pubspec.lock` and the
Cloudflare `package-lock.json` files. Docker caches are named volumes, so Linux
native packages are not written into the Windows `node_modules` folders.

## Start a project shell

From the repository root, build the image and open a shell:

```powershell
docker compose build
docker compose run --rm locentra-dev
```

Inside the container, install the locked dependencies as needed:

```bash
flutter pub get
npm --prefix cloudflare/backend-worker ci
npm --prefix cloudflare/worker ci
```

For the trial APK, provide `config/local.json` and the signing files locally,
then build using the project’s existing release settings:

```bash
flutter build apk --flavor trial --release --target-platform android-arm64 \
  --dart-define=LOCALSPOT_TRIAL_RELEASE=true \
  --dart-define=LOCALSPOT_BACKEND_URL="$LOCALSPOT_BACKEND_URL" \
  --dart-define-from-file=config/local.json \
  --android-project-arg=localspotReleaseEnvironment=trial \
  --android-project-arg=localspotReleaseProjectId=locentra-spark-trial-20261117 \
  --android-project-arg=localspotReleaseApplicationId=app.locentra.mobile
```

The project is bind-mounted, so build outputs appear in the host project’s
`build/` folder. `.dockerignore` keeps local config, signing keys, dependency
folders, build outputs, and secrets out of the Docker image. `Dockerfile`,
Compose configuration, and this guide are not declared Flutter assets and are
not added to APKs.
