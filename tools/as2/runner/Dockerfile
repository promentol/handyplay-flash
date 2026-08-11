# ARTIFACT GENERATION: run a SWF and keep what it drew and what it traced.
#
# The reference player is ruffle's PREBUILT web bundle driven through
# headless Chromium. Ruffle's native exporter would mean compiling the
# whole Rust workspace (multiple GB); the web build is a 10 MB download
# and runs the same core.
#
#   docker build -t handyplay-flash-ruffle tools/as2/runner
#   docker run --rm -v "$PWD:/work" handyplay-flash-ruffle \
#       node /opt/ruffle-run.mjs test.swf out.png out.txt 600

FROM debian:bookworm-slim

# Pinned so a rebuild renders the same pixels. Bump deliberately.
ARG RUFFLE_TAG=nightly-2026-08-10
ARG RUFFLE_ZIP=ruffle-nightly-2026_08_10-web-selfhosted.zip

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        chromium nodejs npm unzip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL -o /tmp/ruffle.zip \
        "https://github.com/ruffle-rs/ruffle/releases/download/${RUFFLE_TAG}/${RUFFLE_ZIP}" \
    && mkdir -p /opt/ruffle && unzip -q /tmp/ruffle.zip -d /opt/ruffle && rm /tmp/ruffle.zip

# puppeteer-core only: the browser is Debian's chromium, so nothing is
# fetched at run time.
ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN npm install -g --silent puppeteer-core@23
ENV NODE_PATH=/usr/local/lib/node_modules
ENV CHROMIUM=/usr/bin/chromium

COPY ruffle-run.mjs /opt/ruffle-run.mjs
WORKDIR /work
