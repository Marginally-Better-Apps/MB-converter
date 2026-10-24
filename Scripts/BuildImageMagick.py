#!/usr/bin/env python3
"""Build a pinned ImageMagick runtime (MBImageMagickBridge.xcframework) for iOS.

Every source archive is pinned by SHA-256 in Native/ImageMagick/sources.json. Only
permissively licensed delegates are included (no Ghostscript, no GPL/LGPLv3 code).
Static PIC archives are intermediates; the app dynamically links one framework that
exports only the `mbim_*` bridge functions.

Usage (from the repository root; needs CMake, pkg-config, autoconf, automake, libtool):
    python3 Scripts/BuildImageMagick.py --platform ios --platform ios-simulator
    python3 Scripts/BuildImageMagick.py --platform macos --libraries-only   # host tests
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "build/imagemagick"
PACKAGE = ROOT / "Native/ImageMagick"
BRIDGE = ROOT / "Native/MBImageMagickBridge"
SOURCES = json.loads((PACKAGE / "sources.json").read_text())
FRAMEWORK = "MBImageMagickBridge"
REVISION = 1  # Bump when changing dependency configuration/build recipes.
MAGICK_LIBRARIES = ["MagickWand-7.Q16HDRI", "MagickCore-7.Q16HDRI"]
DELEGATE_LIBRARIES = ["jxl", "jxl_cms", "jxl_threads", "hwy", "brotlienc", "brotlidec", "brotlicommon",
                      "lcms2", "openjp2", "tiff", "webpmux", "webpdemux", "webp", "sharpyuv", "png16", "jpeg"]


def capture(args, env=None):
    return subprocess.check_output([str(x) for x in args], text=True, env=env).strip()


def run(args, cwd, env, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a") as output:
        output.write("\n$ " + shlex.join([str(x) for x in args]) + "\n")
        output.flush()
        result = subprocess.run([str(x) for x in args], cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-45:]), file=sys.stderr)
        raise RuntimeError(f"Build failed; see {log}")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch_sources(offline):
    downloads = CACHE / "downloads"
    source_root = CACHE / "sources"
    downloads.mkdir(parents=True, exist_ok=True)
    source_root.mkdir(parents=True, exist_ok=True)
    result = {}
    for name, spec in SOURCES.items():
        archive = downloads / spec["archive"]
        if not archive.exists():
            if offline:
                raise RuntimeError(f"Missing cached source: {archive}; run without --offline to fetch")
            temporary = archive.with_suffix(archive.suffix + ".part")
            for candidate in [spec["url"]] + spec.get("mirrors", []):
                download = subprocess.run(["curl", "--fail", "--location", "--retry", "5", "--retry-all-errors",
                                           "--retry-delay", "3", "--output", str(temporary), candidate])
                if download.returncode == 0 and digest(temporary) == spec["sha256"]:
                    temporary.replace(archive)
                    break
                temporary.unlink(missing_ok=True)
            else:
                raise RuntimeError(f"Could not download {name} with the pinned checksum")
        if digest(archive) != spec["sha256"]:
            raise RuntimeError(f"Source checksum mismatch: {archive}")
        with tarfile.open(archive) as source:
            top = source.getnames()[0].split("/")[0]
        directory = source_root / top
        marker = directory / ".mb-source-sha256"
        if not marker.exists() or marker.read_text() != spec["sha256"]:
            if directory.exists():
                shutil.rmtree(directory)
            with tarfile.open(archive) as source:
                source.extractall(source_root, filter="data")
            marker.write_text(spec["sha256"])
        result[name] = directory
    return result


def target_settings(platform):
    sdk, target, minimum = {
        "macos": ("macosx", "arm64-apple-macos13.0", "13.0"),
        "ios": ("iphoneos", "arm64-apple-ios17.0", "17.0"),
        "ios-simulator": ("iphonesimulator", "arm64-apple-ios17.0-simulator", "17.0"),
    }[platform]
    sysroot = capture(["xcrun", "--sdk", sdk, "--show-sdk-path"])
    cc = capture(["xcrun", "--sdk", sdk, "--find", "clang"])
    cxx = capture(["xcrun", "--sdk", sdk, "--find", "clang++"])
    return sdk, target, minimum, sysroot, cc, cxx


def build_platform(platform, sources, jobs, libraries_only):
    sdk, target, minimum, sysroot, cc, cxx = target_settings(platform)
    work = CACHE / f"{platform}-arm64"
    prefix = work / "prefix"
    prefix.mkdir(parents=True, exist_ok=True)
    flags = ["-target", target, "-isysroot", sysroot, "-O2", "-fPIC"]
    env = os.environ.copy()
    for variable in ("CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "LIBRARY_PATH",
                     "SDKROOT", "PKG_CONFIG_SYSROOT_DIR", "CMAKE_PREFIX_PATH", "MACOSX_DEPLOYMENT_TARGET",
                     "IPHONEOS_DEPLOYMENT_TARGET", "CONFIG_SITE"):
        env.pop(variable, None)
    env.update(CC=cc, CXX=cxx, AR=capture(["xcrun", "--find", "ar"]), RANLIB=capture(["xcrun", "--find", "ranlib"]),
               CFLAGS=shlex.join(flags), CXXFLAGS=shlex.join(flags + ["-std=c++17"]),
               CPPFLAGS=shlex.join(flags + [f"-I{prefix}/include"]),
               LDFLAGS=shlex.join(flags + [f"-L{prefix}/lib"]),
               PKG_CONFIG_PATH="", PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"),
               PATH=str(ROOT / "build/ffmpeg/tools/bin") + os.pathsep + env["PATH"])
    toolchain = capture(["xcodebuild", "-version"])
    recipe_hash = digest(Path(__file__))
    sdk_build = capture(["xcrun", "--sdk", sdk, "--show-sdk-build-version"])
    stamp_value = hashlib.sha256(json.dumps([REVISION, recipe_hash, SOURCES, target, toolchain, sysroot,
                                             sdk_build, str(ROOT)], sort_keys=True).encode()).hexdigest()
    prefix_stamp = prefix / ".mb-build-identity"
    if not prefix_stamp.exists() or prefix_stamp.read_text() != stamp_value:
        shutil.rmtree(prefix)
        prefix.mkdir(parents=True)
        prefix_stamp.write_text(stamp_value)
        for stamp in work.glob("*/.mb-complete"):
            stamp.unlink()

    def prepare(name):
        build = work / name
        stamp = build / ".mb-complete"
        if stamp.exists() and stamp.read_text() == stamp_value:
            print(f"[{platform}] {name}: cached", flush=True)
            return None
        if build.exists():
            shutil.rmtree(build)
        build.mkdir(parents=True)
        print(f"[{platform}] building {name}", flush=True)
        return build

    def finish(build):
        (build / ".mb-complete").write_text(stamp_value)

    def cmake(name, options):
        build = prepare(name)
        if not build:
            return
        args = ["cmake", "-S", sources[name], "-B", build, "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DCMAKE_INSTALL_LIBDIR=lib",
                f"-DCMAKE_PREFIX_PATH={prefix}", f"-DCMAKE_FIND_ROOT_PATH={prefix};{sysroot}",
                "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY", "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY",
                "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY",
                f"-DCMAKE_C_COMPILER={cc}", f"-DCMAKE_CXX_COMPILER={cxx}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                f"-DCMAKE_OSX_SYSROOT={sysroot}", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={minimum}",
                "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF"] + options
        if platform != "macos":
            args += ["-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_SYSTEM_PROCESSOR=aarch64"]
        run(args, build, env, work / f"{name}.log")
        run(["cmake", "--build", build, "--parallel", str(jobs)], build, env, work / f"{name}.log")
        run(["cmake", "--install", build], build, env, work / f"{name}.log")
        finish(build)

    cmake("libpng", ["-DPNG_SHARED=OFF", "-DPNG_STATIC=ON", "-DPNG_TESTS=OFF", "-DPNG_TOOLS=OFF",
                     "-DPNG_FRAMEWORK=OFF", "-DPNG_ARM_NEON=on"])
    cmake("libjpeg-turbo", ["-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON", "-DWITH_TURBOJPEG=OFF",
                            "-DWITH_TOOLS=OFF", "-DWITH_TESTS=OFF"])
    cmake("libwebp", ["-DWEBP_BUILD_ANIM_UTILS=OFF", "-DWEBP_BUILD_CWEBP=OFF", "-DWEBP_BUILD_DWEBP=OFF",
                      "-DWEBP_BUILD_GIF2WEBP=OFF", "-DWEBP_BUILD_IMG2WEBP=OFF", "-DWEBP_BUILD_VWEBP=OFF",
                      "-DWEBP_BUILD_WEBPINFO=OFF", "-DWEBP_BUILD_WEBPMUX=OFF", "-DWEBP_BUILD_EXTRAS=OFF",
                      "-DWEBP_BUILD_LIBWEBPMUX=ON"])
    cmake("tiff", ["-Dtiff-tools=OFF", "-Dtiff-tests=OFF", "-Dtiff-contrib=OFF", "-Dtiff-docs=OFF",
                   "-Djbig=OFF", "-Dlerc=OFF", "-Dlzma=OFF", "-Dzstd=OFF", "-Dwebp=OFF", "-Dlibdeflate=OFF",
                   "-Djpeg=ON", "-Dzlib=ON", "-Dpixarlog=ON", "-Dtiff-cxx=OFF", "-Dtiff-framework=OFF"])
    cmake("openjpeg", ["-DBUILD_CODEC=OFF", "-DBUILD_STATIC_LIBS=ON", "-DBUILD_DOC=OFF"])
    build = prepare("lcms2")
    if build:
        run([sources["lcms2"] / "configure", f"--prefix={prefix}", "--host=aarch64-apple-darwin",
             "--disable-shared", "--enable-static", "--with-pic", "--without-jpeg", "--without-tiff"],
            build, env, work / "lcms2.log")
        run(["make", "-C", "src", f"-j{jobs}"], build, env, work / "lcms2.log")
        run(["make", "-C", "src", "install"], build, env, work / "lcms2.log")
        run(["make", "-C", "include", "install"], build, env, work / "lcms2.log")
        run(["make", "install-pkgconfigDATA"], build, env, work / "lcms2.log")
        finish(build)
    cmake("brotli", ["-DBROTLI_DISABLE_TESTS=ON", "-DBROTLI_BUILD_TOOLS=OFF"])
    cmake("highway", ["-DHWY_ENABLE_TESTS=OFF", "-DHWY_ENABLE_EXAMPLES=OFF", "-DHWY_ENABLE_CONTRIB=OFF",
                      "-DHWY_ENABLE_INSTALL=ON", "-DHWY_FORCE_STATIC_LIBS=ON"])
    cmake("libjxl", ["-DJPEGXL_ENABLE_TOOLS=OFF", "-DJPEGXL_ENABLE_DOXYGEN=OFF", "-DJPEGXL_ENABLE_MANPAGES=OFF",
                     "-DJPEGXL_ENABLE_BENCHMARK=OFF", "-DJPEGXL_ENABLE_EXAMPLES=OFF", "-DJPEGXL_ENABLE_JNI=OFF",
                     "-DJPEGXL_ENABLE_SJPEG=OFF", "-DJPEGXL_ENABLE_OPENEXR=OFF", "-DJPEGXL_ENABLE_SKCMS=OFF",
                     "-DJPEGXL_ENABLE_JPEGLI=OFF", "-DJPEGXL_ENABLE_TRANSCODE_JPEG=ON",
                     "-DJPEGXL_FORCE_SYSTEM_BROTLI=ON", "-DJPEGXL_FORCE_SYSTEM_HWY=ON",
                     "-DJPEGXL_FORCE_SYSTEM_LCMS2=ON", "-DJPEGXL_BUNDLE_LIBPNG=OFF",
                     "-DJPEGXL_ENABLE_PLUGINS=OFF", "-DJPEGXL_ENABLE_DEVTOOLS=OFF", "-DJPEGXL_STATIC=OFF"])

    build = prepare("ImageMagick")
    if build:
        # The SDK ships zlib without a pkg-config file; describe it so configure enables PNG/TIFF.
        (prefix / "lib/pkgconfig").mkdir(parents=True, exist_ok=True)
        (prefix / "lib/pkgconfig/zlib.pc").write_text(
            "Name: zlib\nDescription: zlib from the Apple SDK\nVersion: 1.2.12\nLibs: -lz\nCflags:\n")
        magick_env = dict(env, LIBS="-lc++")
        args = [sources["ImageMagick"] / "configure", f"--prefix={prefix}", "--host=aarch64-apple-darwin",
                "--disable-shared", "--enable-static", "--with-pic", "--disable-openmp", "--disable-opencl",
                "--without-modules", "--disable-docs", "--disable-installed", "--with-quantum-depth=16",
                "--enable-hdri", "--without-perl", "--without-magick-plus-plus", "--without-x",
                "--without-fontconfig", "--without-freetype", "--without-gslib", "--without-gvc",
                "--without-heic", "--without-lqr", "--without-lzma", "--without-openexr", "--without-raqm",
                "--without-raw", "--without-rsvg", "--without-wmf", "--without-xml", "--without-zstd",
                "--without-djvu", "--without-fftw", "--without-dps", "--without-flif", "--without-jbig",
                "--without-pango", "--without-zip", "--without-uhdr", "--without-utilities",
                "--with-png", "--with-jpeg", "--with-tiff", "--with-webp", "--with-openjp2", "--with-lcms",
                "--with-jxl", "--with-zlib", "--with-bzlib"]
        if platform != "macos":
            # iOS exports getentropy() but its SDK has no <sys/random.h>.
            args.append("ac_cv_func_getentropy=no")
        run(args, build, magick_env, work / "ImageMagick.log")
        config = (build / "MagickCore/magick-baseconfig.h").read_text()
        for feature in ["MAGICKCORE_PNG_DELEGATE", "MAGICKCORE_JPEG_DELEGATE", "MAGICKCORE_TIFF_DELEGATE",
                        "MAGICKCORE_WEBP_DELEGATE", "MAGICKCORE_LIBOPENJP2_DELEGATE", "MAGICKCORE_JXL_DELEGATE",
                        "MAGICKCORE_LCMS_DELEGATE"]:
            if f"#define {feature} 1" not in config and f"#define {feature}  1" not in config:
                raise RuntimeError(f"ImageMagick configure did not enable {feature}; see ImageMagick.log")
        run(["make", f"-j{jobs}", "install-libLTLIBRARIES", "install-MagickCoreincHEADERS",
             "install-MagickCoreincarchHEADERS", "install-MagickWandincHEADERS"], build, magick_env,
            work / "ImageMagick.log")
        finish(build)

    if libraries_only:
        return None
    framework = work / f"{FRAMEWORK}.framework"
    if framework.exists():
        shutil.rmtree(framework)
    (framework / "Headers").mkdir(parents=True)
    (framework / "Modules").mkdir()
    shutil.copy2(BRIDGE / "include/MBImageMagickBridge.h", framework / "Headers")
    (framework / "Modules/module.modulemap").write_text(
        f'framework module {FRAMEWORK} {{\n  umbrella header "MBImageMagickBridge.h"\n  export *\n}}\n')
    include = prefix / "include/ImageMagick-7"
    args = [cc] + flags + ["-dynamiclib", "-std=c11", "-DMAGICKCORE_HDRI_ENABLE=1", "-DMAGICKCORE_QUANTUM_DEPTH=16",
                           "-I" + str(BRIDGE / "include"), "-I" + str(include),
                           "-install_name", f"@rpath/{FRAMEWORK}.framework/{FRAMEWORK}",
                           "-Wl,-dead_strip", "-Wl,-exported_symbol,_mbim_*", "-o", framework / FRAMEWORK,
                           BRIDGE / "MBImageMagickBridge.c"]
    args += [prefix / f"lib/lib{name}.a" for name in MAGICK_LIBRARIES + DELEGATE_LIBRARIES]
    args += ["-lz", "-lbz2", "-lm", "-lc++", "-liconv"]
    run(args, work, env, work / "bridge.log")
    info = {"CFBundleIdentifier": "app.marginallybetter.MBImageMagickBridge", "CFBundleName": FRAMEWORK,
            "CFBundleExecutable": FRAMEWORK, "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
            "CFBundleShortVersionString": SOURCES["ImageMagick"]["version"].replace("-", "."),
            "MinimumOSVersion": minimum,
            "CFBundleSupportedPlatforms": [{"ios": "iPhoneOS", "ios-simulator": "iPhoneSimulator",
                                            "macos": "MacOSX"}[platform]]}
    (framework / "Info.plist").write_bytes(plistlib.dumps(info))
    notices = framework / "Licenses"
    notices.mkdir()
    for name, source in sources.items():
        destination = notices / name
        destination.mkdir()
        for pattern in ("COPYING*", "LICENSE*", "NOTICE*", "PATENTS*", "AUTHORS*", "README.ijg"):
            for license_file in source.glob(pattern):
                if license_file.is_file():
                    shutil.copy2(license_file, destination)
    shutil.copy2(ROOT / "LICENSE", notices / "MBImageMagickBridge-MIT.txt")
    bridge_hash = hashlib.sha256(b"".join(digest(path).encode() for path in sorted(BRIDGE.rglob("*.[ch]")))).hexdigest()
    manifest = {"sources": SOURCES, "platform": platform, "target": target, "toolchain": toolchain,
                "recipe_revision": REVISION, "recipe_sha256": recipe_hash, "bridge_sha256": bridge_hash,
                "sdk_build": sdk_build,
                "license": "ImageMagick License + permissive delegates", "linkage": "dynamic framework"}
    (framework / "BuildManifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[{platform}] framework ready: {framework}", flush=True)
    return framework


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", action="append", choices=["ios", "ios-simulator", "macos"])
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 4, 8))
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--libraries-only", action="store_true")
    args = parser.parse_args()
    sources = fetch_sources(args.offline)
    platforms = list(dict.fromkeys(args.platform or ["ios", "ios-simulator"]))
    if not args.libraries_only and platforms != ["macos"] and "ios" not in platforms:
        parser.error("App XCFramework packaging requires an iOS device slice; add --platform ios")
    frameworks = [build_platform(p, sources, args.jobs, args.libraries_only) for p in platforms]
    if args.libraries_only:
        return
    output = ((CACHE / "host") if platforms == ["macos"] else (PACKAGE / "Artifacts")) / f"{FRAMEWORK}.xcframework"
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        shutil.rmtree(output)
    command = ["xcodebuild", "-create-xcframework"]
    for framework in frameworks:
        command += ["-framework", str(framework)]
    command += ["-output", str(output)]
    subprocess.run(command, check=True)
    print(f"Built {output}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
