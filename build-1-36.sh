#!/bin/bash -e

# This scrip is for static cross compiling
# Please run this scrip in docker image: abcfy2/muslcc-toolchain-ubuntu:${CROSS_HOST}
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build abcfy2/muslcc-toolchain-ubuntu:arm-linux-musleabi /build/build.sh
# Artifacts will copy to the same directory.

set -o pipefail

# value from: https://musl.cc/ (without -cross or -native)
# export CROSS_HOST="${CROSS_HOST:-arm-linux-musleabi}"
# value from openssl source: ./Configure LIST
case "${CROSS_HOST}" in
arm-linux*)
  export OPENSSL_COMPILER=linux-armv4
  ;;
aarch64-linux*)
  export OPENSSL_COMPILER=linux-aarch64
  ;;
mips-linux* | mipsel-linux*)
  export OPENSSL_COMPILER=linux-mips32
  ;;
mips64-linux*)
  export OPENSSL_COMPILER=linux64-mips64
  ;;
x86_64-linux*)
  export OPENSSL_COMPILER=linux-x86_64
  ;;
*)
  export OPENSSL_COMPILER=gcc
  ;;
esac
# export CROSS_ROOT="${CROSS_ROOT:-/cross_root}"
export USE_ZLIB_NG="${USE_ZLIB_NG:-1}"

retry() {
  # max retry 5 times
  try=5
  # sleep 3s every retry
  sleep_time=3
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}

source /etc/os-release
dpkg --add-architecture i386
# Ubuntu mirror for local building
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  cat >/etc/apt/sources.list <<EOF
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
fi

export DEBIAN_FRONTEND=noninteractive

# keep debs in container for store cache in docker volume
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

apt update
apt install -y g++ \
  make \
  libtool \
  jq \
  pkgconf \
  file \
  tcl \
  autoconf \
  automake \
  autopoint \
  patch \
  wget

TARGET_ARCH="${CROSS_HOST%%-*}"
TARGET_HOST="${CROSS_HOST#*-}"
case "${TARGET_ARCH}" in
"armel"*)
  TARGET_ARCH=armel
  ;;
"arm"*)
  TARGET_ARCH=arm
  ;;
esac
case "${TARGET_HOST}" in
*"mingw"*)
  TARGET_HOST=win
  if [ ! -f "/usr/share/keyrings/winehq-archive.key" ]; then
    rm -f /usr/share/keyrings/winehq-archive.key.part
    retry wget -cT30 -O /usr/share/keyrings/winehq-archive.key.part https://dl.winehq.org/wine-builds/winehq.key
    mv -fv /usr/share/keyrings/winehq-archive.key.part /usr/share/keyrings/winehq-archive.key
  fi
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    WINEHQ_URL="http://mirrors.tuna.tsinghua.edu.cn/wine-builds/ubuntu/"
  else
    WINEHQ_URL="http://dl.winehq.org/wine-builds/ubuntu/"
  fi
  echo "deb [signed-by=/usr/share/keyrings/winehq-archive.key] ${WINEHQ_URL} ${UBUNTU_CODENAME} main" >/etc/apt/sources.list.d/winehq.list
  apt update
  apt install -y winehq-staging
  export WINEPREFIX=/tmp/
  RUNNER_CHECKER="wine"
  ;;
*)
  TARGET_HOST=linux
  apt install -y "qemu-user-static"
  RUNNER_CHECKER="qemu-${TARGET_ARCH}-static"
  ;;
esac

export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/lib64/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LDFLAGS="-L${CROSS_PREFIX}/lib64 -L${CROSS_PREFIX}/lib -s -static --static"
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"

# Create download cache directory
mkdir -p "${SELF_DIR}/downloads/"
export DOWNLOADS_DIR="${SELF_DIR}/downloads"

if [ x"${USE_ZLIB_NG}" = x1 ]; then
  ZLIB=zlib-ng
else
  ZLIB=zlib
fi
if [ x"${USE_LIBRESSL}" = x1 ]; then
  SSL=LibreSSL
else
  SSL=OpenSSL
fi

echo "## Build Info - ${CROSS_HOST} With ${SSL} and ${ZLIB}" >"${BUILD_INFO}"
echo "Building using these dependencies:" >>"${BUILD_INFO}"

prepare_toolchain() {
  mkdir -p "${CROSS_ROOT}"
  if [ -f "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz" ]; then
    cd "${DOWNLOADS_DIR}"
    cached_file_ts="$(stat -c '%Y' "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz")"
    current_ts="$(date +%s)"
    if [ "$((${current_ts} - "${cached_file_ts}"))" -gt 2592000 ]; then
      SHA512SUMS="$(retry wget -T30 -O- --compression=auto https://musl.cc/SHA512SUMS)"
      if echo "${SHA512SUMS}" | grep "${CROSS_HOST}-cross.tgz" | head -1 | sha512sum -c; then
        touch "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz"
      else
        rm -f "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz"
      fi
    fi
  fi

  if [ ! -f "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz" ]; then
    rm -f "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz.part"
    retry wget -cT30 --no-use-server-timestamps -O "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz.part" "https://musl.cc/${CROSS_HOST}-cross.tgz"
    mv -fv "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz.part" "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz"
  fi
  tar -zxf "${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz" --transform='s|^\./||S' --strip-components=1 -C "${CROSS_ROOT}"
}

prepare_zlib() {
  if [ x"${USE_ZLIB_NG}" = x"1" ]; then
    zlib_ng_latest_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/zlib-ng/zlib-ng/releases \| jq -r "'.[0].tag_name'")"
    zlib_ng_latest_url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${zlib_ng_latest_tag}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      zlib_ng_latest_url="https://ghproxy.com/${zlib_ng_latest_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${zlib_ng_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz"
    fi
    mkdir -p "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    tar -zxf "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    cd "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static --zlib-compat
    make -j$(nproc)
    make install
    zlib_ng_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
    echo "- zlib-ng: ${zlib_ng_ver}, source: ${zlib_ng_latest_url:-cached zlib-ng}" >>"${BUILD_INFO}"
    # Fix mingw build sharedlibdir lost issue
    sed -i 's@^sharedlibdir=.*@sharedlibdir=${libdir}@' "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc"
  else
    zlib_tag="$(retry wget -qO- --compression=auto https://zlib.net/ \| grep -i "'<FONT.*FONT>'" \| sed -r "'s/.*zlib\s*([^<]+).*/\1/'" \| head -1)"
    zlib_latest_url="https://zlib.net/zlib-${zlib_tag}.tar.xz"
    if [ ! -f "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz.part" "${zlib_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz"
    fi
    mkdir -p "/usr/src/zlib-${zlib_tag}"
    tar -Jxf "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-${zlib_tag}"
    cd "/usr/src/zlib-${zlib_tag}"
    if [ x"${TARGET_HOST}" = xwin ]; then
      make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install
    else
      CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static
      make -j$(nproc)
      make install
    fi
    zlib_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
    echo "- zlib: ${zlib_ver}, source: ${zlib_latest_url:-cached zlib}" >>"${BUILD_INFO}"
  fi
}

prepare_xz() {
  xz_tag="$(retry wget -qO- --compression=auto https://tukaani.org/xz/ \| grep "'was released on'" \| head -1 \| cut -d "' '" -f1)"
  xz_latest_url="https://tukaani.org/xz/xz-${xz_tag}.tar.xz"
  if [ ! -f "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz.part" "${xz_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz.part" "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz"
  fi
  mkdir -p "/usr/src/xz-${xz_tag}"
  tar -Jxf "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz" --strip-components=1 -C "/usr/src/xz-${xz_tag}"
  cd "/usr/src/xz-${xz_tag}"
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --enable-static --disable-shared
  make -j$(nproc)
  make install
  xz_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/liblzma.pc")"
  echo "- xz: ${xz_ver}, source: ${xz_latest_url:-cached xz}" >>"${BUILD_INFO}"
}

prepare_ssl() {
  # Windows will use Wintls, not openssl
  if [ x"${TARGET_HOST}" != xwin ]; then
    if [ x"${USE_LIBRESSL}" = x1 ]; then
      # libressl
      libressl_tag="$(retry wget -qO- --compression=auto https://www.libressl.org/index.html \| grep "'release is'" \| tail -1 \| sed -r "'s/.* (.+)<.*>$/\1/'")" libressl_latest_url="https://cloudflare.cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${libressl_tag}.tar.gz"
      if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
        libressl_latest_url="https://mirror.sjtu.edu.cn/OpenBSD/LibreSSL/libressl-${libressl_tag}.tar.gz"
      fi
      if [ ! -f "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz" ]; then
        retry wget -cT10 -O "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz.part" "${libressl_latest_url}"
        mv -fv "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz.part" "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz"
      fi
      mkdir -p "/usr/src/libressl-${libressl_tag}"
      tar -zxf "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz" --strip-components=1 -C "/usr/src/libressl-${libressl_tag}"
      cd "/usr/src/libressl-${libressl_tag}"
      if [ ! -f "./configure" ]; then
        ./autogen.sh
      fi
      ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --enable-static --disable-shared --with-openssldir=/etc/ssl
      make -j$(nproc)
      make install_sw
      libressl_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/openssl.pc")"
      echo "- libressl: ${libressl_ver}, source: ${libressl_latest_url:-cached libressl}" >>"${BUILD_INFO}"
    else
      # openssl
      openssl_filename="$(retry wget -qO- --compression=auto https://www.openssl.org/source/ \| grep -o "'href=\"openssl-3.*tar.gz\"'" \| grep -o "'[^\"]*.tar.gz'")"
      openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
      openssl_latest_url="https://github.com/openssl/openssl/archive/refs/tags/${openssl_filename}"
      if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
        openssl_latest_url="https://ghproxy.com/${openssl_latest_url}"
      fi
      if [ ! -f "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" ]; then
        retry wget -cT10 -O "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${openssl_latest_url}"
        mv -fv "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz"
      fi
      mkdir -p "/usr/src/openssl-${openssl_ver}"
      tar -zxf "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" --strip-components=1 -C "/usr/src/openssl-${openssl_ver}"
      cd "/usr/src/openssl-${openssl_ver}"
      ./Configure -static --cross-compile-prefix="${CROSS_HOST}-" --prefix="${CROSS_PREFIX}" "${OPENSSL_COMPILER}" --openssldir=/etc/ssl
      make -j$(nproc)
      make install_sw
      openssl_ver="$(grep Version: "${CROSS_PREFIX}"/lib*/pkgconfig/openssl.pc)"
      echo "- openssl: ${openssl_ver}, source: ${openssl_latest_url:-cached openssl}" >>"${BUILD_INFO}"
    fi
  fi
}

prepare_libxml2() {
  libxml2_latest_url="$(retry wget -qO- --compression=auto 'https://gitlab.gnome.org/api/graphql' --header="'Content-Type: application/json'" --post-data="'{\"query\":\"query {project(fullPath:\\\"GNOME/libxml2\\\"){releases(first:1,sort:RELEASED_AT_DESC){nodes{assets{links{nodes{directAssetUrl}}}}}}}\"}'" \| jq -r "'.data.project.releases.nodes[0].assets.links.nodes[0].directAssetUrl'")"
  libxml2_tag="$(echo "${libxml2_latest_url}" | sed -r 's/.*libxml2-(.+).tar.*/\1/')"
  libxml2_filename="$(echo "${libxml2_latest_url}" | sed -r 's/.*(libxml2-(.+).tar.*)/\1/')"
  if [ ! -f "${DOWNLOADS_DIR}/${libxml2_filename}" ]; then
    retry wget -c -O "${DOWNLOADS_DIR}/${libxml2_filename}.part" "${libxml2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/${libxml2_filename}.part" "${DOWNLOADS_DIR}/${libxml2_filename}"
  fi
  mkdir -p "/usr/src/libxml2-${libxml2_tag}"
  tar -axf "${DOWNLOADS_DIR}/${libxml2_filename}" --strip-components=1 -C "/usr/src/libxml2-${libxml2_tag}"
  cd "/usr/src/libxml2-${libxml2_tag}"
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --without-python --without-icu --enable-static --disable-shared
  make -j$(nproc)
  make install
  libxml2_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/"libxml-*.pc)"
  echo "- libxml2: ${libxml2_ver}, source: ${libxml2_latest_url:-cached libxml2}" >>"${BUILD_INFO}"
}

prepare_sqlite() {
  sqlite_tag="$(wget -qO- --compression=auto https://www.sqlite.org/index.html | sed -nr 's/.*>Version (.+)<.*/\1/p')"
  sqlite_latest_url="https://github.com/sqlite/sqlite/archive/release.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    sqlite_latest_url="https://ghproxy.com/${sqlite_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz.part" "${sqlite_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz.part" "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/sqlite-${sqlite_tag}"
  tar -zxf "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz" --strip-components=1 -C "/usr/src/sqlite-${sqlite_tag}"
  cd "/usr/src/sqlite-${sqlite_tag}"
  if [ x"${TARGET_HOST}" = x"win" ]; then
    ln -sf mksourceid.exe mksourceid
    SQLITE_EXT_CONF="config_TARGET_EXEEXT=.exe"
  fi
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared ${SQLITE_EXT_CONF}
  make -j$(nproc)
  make install
  sqlite_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/"sqlite*.pc)"
  echo "- sqlite: ${sqlite_ver}, source: ${sqlite_latest_url:-cached sqlite}" >>"${BUILD_INFO}"
}

prepare_c_ares() {
  cares_tag="$(retry wget -qO- --compression=auto https://c-ares.org/ \| sed -nr "'s@.*<a href=\"/download/.*\">c-ares (.+)</a>.*@\1@p'")"
  cares_latest_url="https://c-ares.org/download/c-ares-${cares_tag}.tar.gz"
  # cares_latest_url="https://github.com/c-ares/c-ares/archive/main.tar.gz"
  if [ ! -f "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz.part" "${cares_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz.part" "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/c-ares-${cares_tag}"
  tar -zxf "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz" --strip-components=1 -C "/usr/src/c-ares-${cares_tag}"
  cd "/usr/src/c-ares-${cares_tag}"
  if [ ! -f "./configure" ]; then
    autoreconf -i
  fi
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules --disable-tests
  make -j$(nproc)
  make install
  cares_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/libcares.pc")"
  echo "- c-ares: ${cares_ver}, source: ${cares_latest_url:-cached c-ares}" >>"${BUILD_INFO}"
}

prepare_libssh2() {
  libssh2_tag="$(retry wget -qO- --compression=auto https://www.libssh2.org/ \| sed -nr "'s@.*The latest release:.*download/libssh2-(.+).tar.gz.*@\1@p'")"
  libssh2_latest_url="https://www.libssh2.org/download/libssh2-${libssh2_tag}.tar.gz"
  if [ ! -f "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz.part" "${libssh2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz.part" "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/libssh2-${libssh2_tag}"
  tar -zxf "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz" --strip-components=1 -C "/usr/src/libssh2-${libssh2_tag}"
  cd "/usr/src/libssh2-${libssh2_tag}"
  # issue: https://github.com/libressl-portable/portable/issues/736
  if [ x"${USE_LIBRESSL}" = x1 -a x"${TARGET_HOST}" != x"win" ]; then
    export CFLAGS='-DHAVE_OPAQUE_STRUCTS=1'
  fi
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules
  make -j$(nproc)
  make install
  unset CFLAGS
  libssh2_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/libssh2.pc")"
  echo "- libssh2: ${libssh2_ver}, source: ${libssh2_latest_url:-cached libssh2}" >>"${BUILD_INFO}"
}

build_aria2() {
#   if [ -n "${ARIA2_VER}" ]; then
#     aria2_tag="${ARIA2_VER}"
#   else
#     aria2_tag=master
#     # Check download cache whether expired
#     if [ -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" ]; then
#       cached_file_ts="$(stat -c '%Y' "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz")"
#       current_ts="$(date +%s)"
#       if [ "$((${current_ts} - "${cached_file_ts}"))" -gt 86400 ]; then
#         echo "Delete expired aria2 archive file cache..."
#         rm -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"
#       fi
#     fi
#   fi

  aria2_tag=master
  rm -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"

  if [ -n "${ARIA2_VER}" ]; then
    aria2_latest_url="https://github.com/ykxVK8yL5L/aria2/releases/download/1.36.0/aria2-1.36.0.tar.gz"
  else
    aria2_latest_url="https://github.com/ykxVK8yL5L/aria2/releases/download/1.36.0/aria2-1.36.0.tar.gz"
  fi
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    aria2_latest_url="https://ghproxy.com/${aria2_latest_url}"
  fi

  if [ ! -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz.part" "${aria2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz.part" "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/aria2-${aria2_tag}"
  tar -zxf "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" --strip-components=1 -C "/usr/src/aria2-${aria2_tag}"
  cd "/usr/src/aria2-${aria2_tag}"
  echo "fuck test======================"
  ls "/usr/src/aria2-${aria2_tag}/src"
  if [ ! -f ./configure ]; then
    autoreconf -i
  fi
  if [ x"${TARGET_HOST}" = xwin ]; then
    ARIA2_EXT_CONF='--without-openssl'
  # else
  #   ARIA2_EXT_CONF='--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt'
  fi
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules ARIA2_STATIC=yes ${ARIA2_EXT_CONF}
  make -j$(nproc)
  make install
  echo "- aria2: source: ${aria2_latest_url:-cached aria2}" >>"${BUILD_INFO}"
  echo "${aria2_latest_url}"
  echo >>"${BUILD_INFO}"
}

get_build_info() {
  echo "============= ARIA2 VER INFO ==================="
  ARIA2_VER_INFO="$("${RUNNER_CHECKER}" "${CROSS_PREFIX}/bin/aria2c"* --version 2>/dev/null)"
  echo "${ARIA2_VER_INFO}"
  echo "================================================"

  echo "aria2 version info:" >>"${BUILD_INFO}"
  echo '```txt' >>"${BUILD_INFO}"
  echo "${ARIA2_VER_INFO}" >>"${BUILD_INFO}"
  echo '```' >>"${BUILD_INFO}"
}

test_build() {
  echo "============= ARIA2 TEST DOWNLOAD =============="
  "${RUNNER_CHECKER}" "${CROSS_PREFIX}/bin/aria2c"* --http-accept-gzip=true https://github.com/ -d /tmp -o test
  echo "================================================"
}

# prepare_toolchain
prepare_zlib
prepare_xz
prepare_ssl
prepare_libxml2
prepare_sqlite
prepare_c_ares
prepare_libssh2
build_aria2

get_build_info
test_build

# get release
cp -fv "${CROSS_PREFIX}/bin/"aria2* "${SELF_DIR}"
