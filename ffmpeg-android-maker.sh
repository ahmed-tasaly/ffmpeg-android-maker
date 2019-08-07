#!/usr/bin/env bash

FFMPEG_FALLBACK_VERSION=4.1.4

# Assuming the script is used on macOS or Linux machine
case "$OSTYPE" in
  darwin*)  HOST_TAG="darwin-x86_64" ;;
  linux*)   HOST_TAG="linux-x86_64" ;;
  msys)
    case "$(uname -m)" in
      x86_64) HOST_TAG="windows-x86_64" ;;
      i686)   HOST_TAG="windows" ;;
    esac
  ;;
esac

# Directories used by the script
BASE_DIR="$( cd "$( dirname "$0" )" && pwd )"
SOURCES_DIR=${BASE_DIR}/sources
OUTPUT_DIR=${BASE_DIR}/output
BUILD_DIR=${BASE_DIR}/build
STATS_DIR=${BASE_DIR}/stats

# No incremental compilation here. Just drop what was built previously
rm -rf ${BUILD_DIR}
rm -rf ${STATS_DIR}
rm -rf ${OUTPUT_DIR}
mkdir -p ${STATS_DIR}
mkdir -p ${OUTPUT_DIR}
# Note: the 'source' folder wasn't actually deleted, just ensure it exists
mkdir -p ${SOURCES_DIR}

# Getting sources of a particular ffmpeg release.
# Same argument (ffmpeg version) produces the same source set.
function ensureSourcesTag() {
  FFMPEG_VERSION=$1

  FFMPEG_SOURCES=${SOURCES_DIR}/ffmpeg-${FFMPEG_VERSION}

  if [[ ! -d "$FFMPEG_SOURCES" ]]; then
    TARGET_FILE_NAME=ffmpeg-${FFMPEG_VERSION}.tar.bz2
    TARGET_FILE_PATH=${SOURCES_DIR}/${TARGET_FILE_NAME}

    curl https://www.ffmpeg.org/releases/${TARGET_FILE_NAME} --output ${TARGET_FILE_PATH}
    tar xvjf ${TARGET_FILE_PATH} -C ${SOURCES_DIR}
    rm ${TARGET_FILE_PATH}
  fi
}

# Getting sources of a particular branch of ffmpeg's git repository.
# Same argument (branch name) may produce different source set,
# as the branch in origin repository may be updated in future.
function ensureSourcesBranch() {
  BRANCH=$1

  GIT_DIRECTORY=ffmpeg-git

  FFMPEG_SOURCES=${SOURCES_DIR}/${GIT_DIRECTORY}

  cd ${SOURCES_DIR}

  if [[ ! -d "$FFMPEG_SOURCES" ]]; then
    git clone https://git.ffmpeg.org/ffmpeg.git ${GIT_DIRECTORY}
  fi

  cd ${GIT_DIRECTORY}
  git checkout $BRANCH
  # Forcing the update of a branch
  git pull origin $BRANCH

  # Additional logging to keep track of an exact commit to build
  echo "Commit to build:"
  git rev-parse HEAD

  cd ${BASE_DIR}
}

# Test if sources of the FFmpeg exist. If not - download them
function ensureSources() {
  TYPE=$1
  SECOND_ARGUMENT=$2

  case $TYPE in
  	tag)
      echo "Using FFmpeg ${SECOND_ARGUMENT}"
  		ensureSourcesTag ${SECOND_ARGUMENT}
  		;;
  	branch)
      echo "Using FFmpeg git repository and its branch ${SECOND_ARGUMENT}"
  		ensureSourcesBranch ${SECOND_ARGUMENT}
  		;;
  	*)
  		echo "Using FFmpeg 4.1.4"
      ensureSourcesTag ${FFMPEG_FALLBACK_VERSION}
  		;;
  esac
}

# Actual magic of configuring and compiling of FFmpeg for a certain ABIs.
# Supported ABIs are: armeabi-v7a, arm64-v8a, x86 and x86_64
function assemble() {
  cd ${FFMPEG_SOURCES}

  ABI=$1
  API_LEVEL=$2

  TOOLCHAIN_PATH=${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}
  SYSROOT=${TOOLCHAIN_PATH}/sysroot

  EXTRA_CFLAGS=
  EXTRA_CONFIGURE_FLAGS=

  TARGET_TRIPLE_MACHINE_BINUTILS=
  TARGET_TRIPLE_MACHINE_CC=
  TARGET_TRIPLE_OS="android"

  case $ABI in
  	armeabi-v7a)
      #cc       armv7a-linux-androideabi16-clang
      #binutils arm   -linux-androideabi  -ld
      TARGET_TRIPLE_MACHINE_BINUTILS=arm
      TARGET_TRIPLE_MACHINE_CC=armv7a
      TARGET_TRIPLE_OS=androideabi
  		;;
    arm64-v8a)
      #cc       aarch64-linux-android21-clang
      #binutils aarch64-linux-android  -ld
      TARGET_TRIPLE_MACHINE_BINUTILS=aarch64
  		;;
    x86)
      #cc       i686-linux-android16-clang
      #binutils i686-linux-android  -ld
      TARGET_TRIPLE_MACHINE_BINUTILS=i686

      EXTRA_CFLAGS=-mno-stackrealign
      EXTRA_CONFIGURE_FLAGS=--disable-asm
  		;;
    x86_64)
      #cc       x86_64-linux-android21-clang
      #binutils x86_64-linux-android  -ld
      TARGET_TRIPLE_MACHINE_BINUTILS=x86_64

      EXTRA_CONFIGURE_FLAGS=--x86asmexe=${TOOLCHAIN_PATH}/bin/yasm
  		;;
  esac

  # If the cc-specific variable isn't set, we fallback to binutils version
  [ -z "${TARGET_TRIPLE_MACHINE_CC}" ] && TARGET_TRIPLE_MACHINE_CC=${TARGET_TRIPLE_MACHINE_BINUTILS}

  CROSS_PREFIX=${TOOLCHAIN_PATH}/bin/${TARGET_TRIPLE_MACHINE_BINUTILS}-linux-${TARGET_TRIPLE_OS}-

  CC=${TOOLCHAIN_PATH}/bin/${TARGET_TRIPLE_MACHINE_CC}-linux-${TARGET_TRIPLE_OS}${API_LEVEL}-clang

  DECODERS_TO_ENABLE=
  while IFS= read -r line; do DECODERS_TO_ENABLE="${DECODERS_TO_ENABLE} --enable-decoder=$line"; done < ${BASE_DIR}/video_decoders_list.txt

  ./configure \
    --prefix=${BUILD_DIR}/${ABI} \
    --enable-cross-compile \
    --cross-prefix=${CROSS_PREFIX} \
    --arch=${TARGET_TRIPLE_MACHINE_BINUTILS} \
    --target-os=android \
    --cc=${CC} \
    --extra-cflags="-O3 -fPIC $EXTRA_CFLAGS" \
    --sysroot=${SYSROOT} \
    --enable-shared \
    --disable-static \
    --disable-doc \
    --disable-runtime-cpudetect \
    --disable-debug \
    --disable-programs \
    --disable-muxers \
    --disable-encoders \
    --disable-decoders \
    ${DECODERS_TO_ENABLE} \
    --disable-bsfs \
    --disable-pthreads \
    --disable-avdevice \
    --disable-network \
    --disable-postproc \
    --disable-swresample \
    --disable-avfilter \
    ${EXTRA_CONFIGURE_FLAGS}

    make clean
    make -j8
    make install

    # Saving stats about text relocation presence.
    # If the result file doesn't have 'TEXTREL' at all, then we are good.
    ${CROSS_PREFIX}readelf --dynamic ${BUILD_DIR}/${ABI}/lib/*.so | grep 'TEXTREL\|File' >> ${STATS_DIR}/text-relocations.txt

    cd ${BASE_DIR}
}

# Placing build *.so files into the /bin directory
function installLibs() {
  BUILD_SUBDIR=$1

  OUTPUT_SUBDIR=${OUTPUT_DIR}/lib/${BUILD_SUBDIR}
  CP_DIR=${BUILD_DIR}/${BUILD_SUBDIR}

  mkdir -p ${OUTPUT_SUBDIR}
  cp ${CP_DIR}/lib/*.so ${OUTPUT_SUBDIR}
}

function build() {
  ABI=$1
  ANDROID_API=$2

  assemble ${ABI} ${ANDROID_API}
  installLibs ${ABI}
}

# Placing build header files into the /bin directory.
# Note, there is a only one such a folder since this headers are the same for all ABIs.
# May not be true for different configurations though.
function installHeaders() {
  cd ${BUILD_DIR}
  cd "$(ls -1 | head -n1)"
  cp -r include ${OUTPUT_DIR}
  cd ${BASE_DIR}
}

# Actual work

ensureSources $1 $2

build armeabi-v7a 16
build arm64-v8a 21
build x86 16
build x86_64 21

installHeaders
