# The AS2 COMPILER, and nothing else.
#
# mtasc is what ruffle's own CONTRIBUTING recommends for authoring AVM1
# tests. There is no Debian package and the 2007 binaries are 32-bit x86,
# so it is built from source — see build-mtasc.sh for what the 2015
# sources need doing to them to compile against a 2023 OCaml.
#
#   docker build -t handyplay-flash-as2c tools/as2/compiler
#   docker run --rm -v "$PWD:/work" handyplay-flash-as2c as2-compile Test.as test.swf
#
# Kept apart from the runner image on purpose: compiling is fast, pure and
# offline, while running needs a browser. Neither should wait on the other.

FROM debian:bookworm-slim AS build
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        git ca-certificates python3 \
        ocaml-nox camlp4 ocaml-findlib libextlib-ocaml-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
COPY build-mtasc.sh /build-mtasc.sh
RUN mkdir -p /build && sh /build-mtasc.sh

FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/mtasc /usr/local/bin/mtasc
COPY --from=build /usr/local/share/mtasc /usr/local/share/mtasc
COPY as2-compile.sh /usr/local/bin/as2-compile
RUN chmod +x /usr/local/bin/as2-compile
WORKDIR /work
ENTRYPOINT []
CMD ["mtasc"]
