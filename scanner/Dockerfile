FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Canon G3010 WSD/SANE scanner runtime"
LABEL org.opencontainers.image.description="Local-only sane-airscan runtime for Canon G3010 series network scanning"
LABEL org.opencontainers.image.source="https://github.com/zeallaez/canon-g3010-macos-compat"

RUN apt-get update \
    && apt-get install -y --no-install-recommends sane-airscan sane-utils \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["scanimage"]
