# Reproducible Locentra Android and Cloudflare Worker development toolchain.
# Keep this file at the repository root; it is not a Flutter asset.
FROM node:24.14.1-bookworm

ARG FLUTTER_VERSION=3.47.1
ARG FLUTTER_SHA256=a1d8166c0309267cb7dc99f1424eecf08b86946ad3b50723c6f59945964aea45
ARG ANDROID_CMDLINE_TOOLS_REVISION=15859902
ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
ARG ANDROID_PLATFORM=36
ARG ANDROID_BUILD_TOOLS=36.0.0
ARG ANDROID_NDK=28.2.13676358
ARG ANDROID_CMAKE=3.22.1

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    FLUTTER_HOME=/opt/flutter \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    PATH=/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/lib/jvm/java-17-openjdk-amd64/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip \
      openjdk-17-jdk libglu1-mesa libc6-i386 lib32stdc++6 lib32z1 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install --global npm@11.11.0 \
    && node --version \
    && npm --version

RUN set -eux; \
    curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" -o /tmp/flutter.tar.xz; \
    echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/flutter.tar.xz -C /opt; \
    rm /tmp/flutter.tar.xz; \
    git config --global --add safe.directory /opt/flutter; \
    flutter --version

RUN set -eux; \
    mkdir -p "${ANDROID_HOME}/cmdline-tools"; \
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_REVISION}_latest.zip" -o /tmp/android-tools.zip; \
    echo "${ANDROID_CMDLINE_TOOLS_SHA256}  /tmp/android-tools.zip" | sha256sum -c -; \
    mkdir -p /tmp/android-tools; \
    unzip -q /tmp/android-tools.zip -d /tmp/android-tools; \
    mv /tmp/android-tools/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest"; \
    rm -rf /tmp/android-tools /tmp/android-tools.zip; \
    yes | sdkmanager --licenses >/dev/null; \
    sdkmanager \
      "platform-tools" \
      "platforms;android-${ANDROID_PLATFORM}" \
      "build-tools;${ANDROID_BUILD_TOOLS}" \
      "ndk;${ANDROID_NDK}" \
      "cmake;${ANDROID_CMAKE}"; \
    flutter precache --android

WORKDIR /workspace
CMD ["bash"]
