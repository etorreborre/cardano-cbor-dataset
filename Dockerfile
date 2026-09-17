# syntax=docker/dockerfile:1

ARG HASKELL_IMAGE=docker.io/library/haskell:9.6.7@sha256:9ae9287b4b48a8e437c290b8aa1a4a0433a1c2a3d3cff965ad0883426a41c960
ARG LEDGER_COMMIT=6176e413b2be9880c23cedbdaa899f9752693b22  #9714940b3f6527633ba37e47b93342b882ff7e67

FROM ${HASKELL_IMAGE} AS crypto-base

ARG CABAL_JOBS=8

ENV LANG=C.UTF-8 \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      autotools-dev \
      libtool \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/crypto

FROM crypto-base AS libsodium-builder

ARG LIBSODIUM_COMMIT=dbb48cce5429cb6585c9034f002568964f1ce567

RUN git init libsodium \
    && cd libsodium \
    && git remote add origin https://github.com/input-output-hk/libsodium.git \
    && git fetch --depth 1 origin "${LIBSODIUM_COMMIT}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${LIBSODIUM_COMMIT}" \
    && autoreconf -fi \
    && install -m 0755 /usr/share/misc/config.guess build-aux/config.guess \
    && install -m 0755 /usr/share/misc/config.sub build-aux/config.sub \
    && ./configure --prefix=/usr/local --with-pic \
    && make -j"${CABAL_JOBS}" \
    && make DESTDIR=/opt/crypto-root install

FROM crypto-base AS secp256k1-builder

ARG LIBSECP256K1_COMMIT=acf5c55ae6a94e5ca847e07def40427547876101

RUN git init secp256k1 \
    && cd secp256k1 \
    && git remote add origin https://github.com/bitcoin-core/secp256k1.git \
    && git fetch --depth 1 origin "${LIBSECP256K1_COMMIT}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${LIBSECP256K1_COMMIT}" \
    && ./autogen.sh \
    && ./configure \
      --prefix=/usr/local \
      --with-pic \
      --enable-module-schnorrsig \
      --enable-module-recovery \
      --enable-module-ecdh \
    && make -j"${CABAL_JOBS}" \
    && make DESTDIR=/opt/crypto-root install

FROM crypto-base AS blst-builder

ARG LIBBLST_COMMIT=8c7db7fe8d2ce6e76dc398ebd4d475c0ec564355

RUN git init blst \
    && cd blst \
    && git remote add origin https://github.com/supranational/blst.git \
    && git fetch --depth 1 origin "${LIBBLST_COMMIT}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${LIBBLST_COMMIT}" \
    && ./build.sh \
    && install -Dm 0644 libblst.a /opt/crypto-root/usr/local/lib/libblst.a \
    && install -Dm 0644 bindings/blst.h /opt/crypto-root/usr/local/include/blst.h \
    && install -Dm 0644 bindings/blst_aux.h /opt/crypto-root/usr/local/include/blst_aux.h \
    && mkdir -p /opt/crypto-root/usr/local/lib/pkgconfig \
    && printf '%s\n' \
      'prefix=/usr/local' \
      'exec_prefix=${prefix}' \
      'libdir=${exec_prefix}/lib' \
      'includedir=${prefix}/include' \
      '' \
      'Name: libblst' \
      'Description: BLS12-381 signature library' \
      'Version: 0.3.14' \
      'Libs: -L${libdir} -lblst' \
      'Cflags: -I${includedir}' \
      > /opt/crypto-root/usr/local/lib/pkgconfig/libblst.pc

FROM crypto-base AS crypto-builder

COPY --from=libsodium-builder /opt/crypto-root/ /
COPY --from=secp256k1-builder /opt/crypto-root/ /
COPY --from=blst-builder /opt/crypto-root/ /

RUN ldconfig \
    && ln -sf libsodium.pc /usr/local/lib/pkgconfig/libsodium-any.pc \
    && ln -sf libsecp256k1.pc /usr/local/lib/pkgconfig/libsecp256k1-any.pc \
    && ln -sf libblst.pc /usr/local/lib/pkgconfig/libblst-any.pc \
    && pkg-config --print-errors --exists \
      libsodium-any \
      libsecp256k1-any \
      'libblst-any >= 0.3.14'

FROM crypto-builder AS builder

ARG LEDGER_COMMIT

ENV CABAL_DIR=/root/.cabal

WORKDIR /opt/cardano-ledger
RUN git init . \
    && git remote add origin https://github.com/IntersectMBO/cardano-ledger.git \
    && git fetch --depth 1 origin "${LEDGER_COMMIT}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${LEDGER_COMMIT}"

RUN cabal update

COPY cardano-cbor-dataset.cabal cbor-dataset/cardano-cbor-dataset.cabal
COPY app/ cbor-dataset/app/
COPY scripts/stage-hpc /usr/local/bin/stage-hpc

RUN printf '%s\n' \
      'tests: False' \
      'benchmarks: False' \
      'coverage: True' \
      'optimization: False' \
      'packages: ./cbor-dataset' \
      'package cborg' \
      '  coverage: True' \
      '  optimization: False' \
      'package cardano-crypto-praos' \
      '  flags: -external-libsodium-vrf' \
      > cabal.project.local

RUN --mount=type=cache,target=/root/.cabal/store,sharing=locked \
    --mount=type=cache,target=/opt/cardano-ledger/dist-newstyle,sharing=locked \
    cabal build --jobs="${CABAL_JOBS}" \
      cardano-ledger-api:exe:generate-cbor \
      cardano-cbor-dataset:exe:cbor \
    && generate_cbor="$(cabal list-bin cardano-ledger-api:exe:generate-cbor | tail -n 1)" \
    && cbor="$(cabal list-bin cardano-cbor-dataset:exe:cbor | tail -n 1)" \
    && test -x "$generate_cbor" \
    && test -x "$cbor" \
    && install -m 0755 "$generate_cbor" /usr/local/bin/generate-cbor \
    && install -m 0755 "$cbor" /usr/local/bin/cbor \
    && sh /usr/local/bin/stage-hpc \
      /opt/cardano-ledger \
      /opt/hpc \
      /usr/local/bin/cbor

# The normalization vectors pin the specification, so checking them is its own
# stage: a stale vector fails here without blocking a build of the tool, and the
# runtime image never depends on this stage.
FROM builder AS vector-check

ARG CABAL_JOBS=8

COPY test/ cbor-dataset/test/
COPY normalization-vectors/ cbor-dataset/normalization-vectors/

RUN printf '%s\n' \
      'tests: True' \
      'benchmarks: False' \
      'optimization: False' \
      'packages: ./cbor-dataset' \
      'package cardano-crypto-praos' \
      '  flags: -external-libsodium-vrf' \
      > cabal.project.local

# The binary is run directly rather than through `cabal test`, so the vector
# directory can be named as an argument and a failure prints the offending case
# instead of a captured log path.
RUN --mount=type=cache,target=/root/.cabal/store,sharing=locked \
    --mount=type=cache,target=/opt/cardano-ledger/dist-newstyle,sharing=locked \
    cabal build --jobs="${CABAL_JOBS}" \
      cardano-cbor-dataset:test:normalization-vectors \
    && check="$(cabal list-bin cardano-cbor-dataset:test:normalization-vectors | tail -n 1)" \
    && test -x "$check" \
    && "$check" cbor-dataset/normalization-vectors

FROM ${HASKELL_IMAGE} AS runtime

ARG LEDGER_COMMIT

ENV LANG=C.UTF-8

LABEL org.opencontainers.image.source="https://github.com/r2rationality/cardano-conway-cbor" \
      org.opencontainers.image.title="Cardano CBOR dataset generator and verifier" \
      io.github.r2rationality.cardano-ledger.revision="${LEDGER_COMMIT}"

COPY --from=builder /usr/local/bin/generate-cbor /usr/local/bin/generate-cbor
COPY --from=builder /usr/local/bin/cbor /usr/local/bin/cbor
COPY scripts/cbor-entrypoint /usr/local/bin/cbor-entrypoint
COPY --from=builder /opt/hpc/mix/ /opt/hpc/mix/
COPY --from=builder /opt/hpc/hpcdirs /opt/hpc/hpcdirs
COPY --from=builder /opt/hpc/srcdirs /opt/hpc/srcdirs
COPY --from=builder /opt/hpc/src/ /
COPY --from=crypto-builder /usr/local/lib/ /usr/local/lib/

RUN ldconfig \
    && command -v hpc > /dev/null \
    && chmod 0755 /usr/local/bin/cbor-entrypoint \
    && mkdir -p /output

ENTRYPOINT ["/usr/local/bin/cbor-entrypoint"]
