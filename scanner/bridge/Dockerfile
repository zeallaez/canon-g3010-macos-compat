FROM debian:bookworm-slim

ARG AIRSANE_VERSION=v0.4.12

LABEL org.opencontainers.image.title="Canon G3010 AirScan bridge"
LABEL org.opencontainers.image.description="WSD/SANE to eSCL/AirScan bridge for macOS Image Capture"
LABEL org.opencontainers.image.source="https://github.com/zeallaez/canon-g3010-macos-compat"

RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' \
      /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      avahi-daemon \
      ca-certificates \
      cmake \
      dbus \
      g++ \
      git \
      libavahi-client-dev \
      libjpeg-dev \
      libpng-dev \
      libsane-dev \
      libusb-1.0-0-dev \
      make \
      sane-airscan \
      sane-utils \
    && git clone \
      --branch "${AIRSANE_VERSION}" \
      --depth 1 \
      https://github.com/SimulPiscator/AirSane.git \
      /tmp/AirSane \
    && cmake \
      -S /tmp/AirSane \
      -B /tmp/AirSane-build \
      -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /tmp/AirSane-build --parallel \
    && cmake --install /tmp/AirSane-build \
    && rm -rf /tmp/AirSane /tmp/AirSane-build /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/canon-g3010-airsane-entrypoint
RUN chmod 0755 /usr/local/bin/canon-g3010-airsane-entrypoint

ENTRYPOINT ["/usr/local/bin/canon-g3010-airsane-entrypoint"]
