#!/usr/bin/env python3
"""Build a pinned LGPL2.1 FFmpeg runtime without downloading executable codecs.

Requires Python 3.12+, Xcode, CMake and pkg-config. Meson/Ninja may be provided
on PATH or in build/ffmpeg/tools/bin (see Native/FFmpeg/README.md).
Static PIC archives are build intermediates only: the app dynamically links
the complete MBFFmpegBridge framework, which contains all codec libraries.
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
CACHE = ROOT / "build/ffmpeg"
PACKAGE = ROOT / "Native/FFmpeg"
SOURCES = json.loads((PACKAGE / "sources.json").read_text())
LIBRARIES = ["avfilter", "avformat", "avcodec", "swresample", "swscale", "avutil",
             "mp3lame", "vorbisenc", "vorbis", "ogg", "opus", "vpx", "dav1d", "zimg"]
FRAMEWORK = "MBFFmpegBridge"
REVISION = 2  # Bump when changing dependency configuration/build recipes.


def capture(args, env=None):
    return subprocess.check_output([str(x) for x in args], text=True, env=env).strip()


def run(args, cwd, env, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a") as output:
        output.write("\n$ " + shlex.join([str(x) for x in args]) + "\n")
        output.flush()
        result = subprocess.run([str(x) for x in args], cwd=cwd, env=env,
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-45:]), file=sys.stderr)
        raise RuntimeError(f"Build failed; see {log}")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def tree_digest(directory):
    """Detect edits to extracted cached source, including added files/symlinks."""
    result = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if path.name in (".mb-source-sha256", ".mb-tree-sha256"):
            continue
        if path.is_symlink():
            value = "symlink:" + os.readlink(path)
        elif path.is_file():
            value = digest(path)
        else:
            continue
        result.update((str(path.relative_to(directory)) + "\0" + value + "\n").encode())
    return result.hexdigest()


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
            subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--output",
                            str(temporary), spec["url"]], check=True)
            if digest(temporary) != spec["sha256"]:
                raise RuntimeError(f"Source checksum mismatch: {name}")
            temporary.replace(archive)
        if digest(archive) != spec["sha256"]:
            raise RuntimeError(f"Source checksum mismatch: {archive}")
        directory = source_root / spec.get("directory", f"{name}-{spec['version']}")
        marker = directory / ".mb-source-sha256"
        tree_marker = directory / ".mb-tree-sha256"
        if (not marker.exists() or marker.read_text() != spec["sha256"]
                or not tree_marker.exists() or tree_marker.read_text() != tree_digest(directory)):
            if directory.exists():
                shutil.rmtree(directory)
            with tarfile.open(archive) as source:
                source.extractall(source_root, filter="data")
            marker.write_text(spec["sha256"])
            tree_marker.write_text(tree_digest(directory))
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
    # Prevent host Homebrew codec libraries from silently entering an iOS build.
    for variable in ("CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH",
                     "LIBRARY_PATH", "SDKROOT", "PKG_CONFIG_SYSROOT_DIR", "CMAKE_PREFIX_PATH",
                     "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET", "CONFIG_SITE"):
        env.pop(variable, None)
    env.update(CC=cc, CXX=cxx, AR=capture(["xcrun", "--find", "ar"]),
               RANLIB=capture(["xcrun", "--find", "ranlib"]),
               CFLAGS=shlex.join(flags), CXXFLAGS=shlex.join(flags),
               CPPFLAGS=shlex.join(flags + [f"-I{prefix}/include"]),
               LDFLAGS=shlex.join(flags + [f"-L{prefix}/lib"]),
               PKG_CONFIG_PATH="", PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"),
               PATH=str(CACHE / "tools/bin") + os.pathsep + env["PATH"])
    toolchain = capture(["xcodebuild", "-version"])
    tools = {name: {"path": shutil.which(name, path=env["PATH"]),
                    "version": capture([name, "--version"], env).splitlines()[0]}
             for name in ("cmake", "meson", "ninja", "pkg-config", "autoconf", "automake", "glibtoolize")}
    recipe_hash = digest(Path(__file__))
    patch_hash = tree_digest(PACKAGE / "patches")
    sdk_build = capture(["xcrun", "--sdk", sdk, "--show-sdk-build-version"])
    stamp_value = hashlib.sha256(json.dumps([REVISION, recipe_hash, patch_hash, SOURCES, target, toolchain,
                                           sysroot, sdk_build, tools, str(ROOT)], sort_keys=True).encode()).hexdigest()
    prefix_stamp = prefix / ".mb-build-identity"
    if not prefix_stamp.exists() or prefix_stamp.read_text() != stamp_value:
        shutil.rmtree(prefix)
        prefix.mkdir(parents=True)
        prefix_stamp.write_text(stamp_value)
        # No stale completion stamps may survive a removed installation prefix.
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

    # LAME's frontend/decoder are deliberately excluded; FFmpeg decodes MP3.
    build = prepare("lame")
    if build:
        args = [sources["lame"] / "configure", f"--prefix={prefix}", "--host=aarch64-apple-darwin",
                "--disable-shared", "--enable-static", "--disable-frontend", "--disable-decoder",
                "--disable-nasm", "--with-pic"]
        run(args, build, env, work / "lame.log")
        run(["make", "-C", "libmp3lame", f"-j{jobs}"], build, env, work / "lame.log")
        run(["make", "-C", "libmp3lame", "install"], build, env, work / "lame.log")
        run(["make", "-C", "include", "install"], build, env, work / "lame.log")
        finish(build)

    for name, options in [("libogg", []), ("libvorbis", []),
                          ("opus", ["-DOPUS_BUILD_TESTING=OFF", "-DOPUS_BUILD_PROGRAMS=OFF"])]:
        build = prepare(name)
        if not build:
            continue
        args = ["cmake", "-S", sources[name], "-B", build,
                "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_BUILD_TYPE=Release",
                f"-DCMAKE_INSTALL_PREFIX={prefix}", f"-DCMAKE_PREFIX_PATH={prefix}",
                f"-DCMAKE_C_COMPILER={cc}", f"-DCMAKE_CXX_COMPILER={cxx}",
                "-DCMAKE_OSX_ARCHITECTURES=arm64", f"-DCMAKE_OSX_SYSROOT={sysroot}",
                f"-DCMAKE_OSX_DEPLOYMENT_TARGET={minimum}", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
                "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF", "-DINSTALL_DOCS=OFF"] + options
        if platform != "macos":
            args += ["-DCMAKE_SYSTEM_NAME=iOS"]
        if name == "libvorbis":
            args += [f"-DOGG_LIBRARY={prefix}/lib/libogg.a", f"-DOGG_INCLUDE_DIR={prefix}/include"]
        run(args, build, env, work / f"{name}.log")
        run(["cmake", "--build", build, "--parallel", str(jobs)], build, env, work / f"{name}.log")
        run(["cmake", "--install", build], build, env, work / f"{name}.log")
        finish(build)

    build = prepare("libvpx")
    if build:
        vpx_env = env.copy()
        # libvpx's Darwin toolchain otherwise replaces target flags with host settings.
        args = [sources["libvpx"] / "configure", f"--prefix={prefix}", "--target=arm64-darwin20-gcc",
                "--enable-pic", "--disable-shared", "--enable-static", "--disable-examples",
                "--disable-tools", "--disable-docs", "--disable-unit-tests", "--disable-install-docs"]
        run(args, build, vpx_env, work / "libvpx.log")
        run(["make", f"-j{jobs}"], build, vpx_env, work / "libvpx.log")
        run(["make", "install"], build, vpx_env, work / "libvpx.log")
        finish(build)

    build = prepare("dav1d")
    if build:
        cross = work / "dav1d-cross.ini"
        cross.write_text("[binaries]\n" + f"c = {cc!r}\nar = {env['AR']!r}\nstrip = 'strip'\n"
                         "[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\n"
                         "cpu = 'aarch64'\nendian = 'little'\n[built-in options]\n"
                         f"c_args = {flags!r}\nc_link_args = {flags!r}\n")
        run(["meson", "setup", build, sources["dav1d"], "--cross-file", cross,
             f"--prefix={prefix}", "--libdir=lib", "--default-library=static",
             "--buildtype=release", "-Db_staticpic=true", "-Denable_tools=false",
             "-Denable_tests=false"], work, env, work / "dav1d.log")
        run(["meson", "compile", "-C", build, "-j", str(jobs)], work, env, work / "dav1d.log")
        run(["meson", "install", "-C", build], work, env, work / "dav1d.log")
        finish(build)

    build = prepare("zimg")
    if build:
        # Bootstrap a private copy, keeping the checksummed source cache pristine.
        shutil.copytree(sources["zimg"], build, dirs_exist_ok=True)
        zimg_env = dict(env, LIBTOOLIZE="glibtoolize")
        run(["sh", "autogen.sh"], build, zimg_env, work / "zimg.log")
        run([build / "configure", f"--prefix={prefix}", "--host=aarch64-apple-darwin",
             "--disable-shared", "--enable-static", "--with-pic"], build, zimg_env, work / "zimg.log")
        run(["make", f"-j{jobs}"], build, zimg_env, work / "zimg.log")
        run(["make", "install"], build, zimg_env, work / "zimg.log")
        finish(build)

    build = prepare("ffmpeg")
    if build:
        # The local source overrides the VPATH source for this one object. Require
        # actual hardware for HEVC decoding, matching upstream H.264 behavior.
        (build / "libavcodec").mkdir()
        shutil.copy2(sources["ffmpeg"] / "libavcodec/videotoolbox.c", build / "libavcodec/videotoolbox.c")
        for header in (sources["ffmpeg"] / "libavcodec").rglob("*.h"):
            local = build / header.relative_to(sources["ffmpeg"])
            local.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(header, local)
        run(["patch", "-p1", "-i", PACKAGE / "patches/0001-videotoolbox-hardware-policy.patch"],
            build, env, work / "ffmpeg.log")
        args = [sources["ffmpeg"] / "configure", f"--prefix={prefix}", "--arch=aarch64",
                "--target-os=darwin", "--enable-cross-compile", f"--cc={cc}", f"--cxx={cxx}",
                f"--sysroot={sysroot}", f"--extra-cflags={shlex.join(flags + [f'-I{prefix}/include'])}",
                f"--extra-ldflags={shlex.join(flags + [f'-L{prefix}/lib'])}",
                "--pkg-config-flags=--static", "--disable-gpl", "--disable-nonfree",
                "--disable-version3", "--disable-autodetect", "--disable-shared", "--enable-static",
                "--enable-pic", "--disable-programs", "--disable-doc", "--disable-debug",
                "--disable-network", "--disable-devices", "--disable-avdevice",
                "--enable-libmp3lame", "--enable-libopus", "--enable-libvorbis",
                "--enable-libvpx", "--enable-libdav1d", "--enable-libzimg", "--enable-videotoolbox",
                "--enable-audiotoolbox", "--enable-zlib", "--enable-bzlib", "--enable-iconv"]
        run(args, build, env, work / "ffmpeg.log")
        config = (build / "config.h").read_text()
        for key in ["CONFIG_GPL", "CONFIG_NONFREE", "CONFIG_VERSION3"]:
            if f"#define {key} 0" not in config:
                raise RuntimeError(f"Unexpected license configuration: {key}")
        run(["make", f"-j{jobs}"], build, env, work / "ffmpeg.log")
        run(["make", "install"], build, env, work / "ffmpeg.log")
        finish(build)

    # Validate cached builds too; a completion marker is never a license check.
    config = (work / "ffmpeg/config.h").read_text()
    for key in ["CONFIG_GPL", "CONFIG_NONFREE", "CONFIG_VERSION3"]:
        if f"#define {key} 0" not in config:
            raise RuntimeError(f"Unexpected license configuration: {key}")

    if libraries_only:
        return None
    bridge = ROOT / "Native/MBFFmpegBridge"
    framework = work / f"{FRAMEWORK}.framework"
    if framework.exists():
        shutil.rmtree(framework)
    (framework / "Headers").mkdir(parents=True)
    (framework / "Modules").mkdir()
    shutil.copy2(bridge / "include/MBFFmpegBridge.h", framework / "Headers")
    (framework / "Modules/module.modulemap").write_text(
        f'framework module {FRAMEWORK} {{\n  umbrella header "MBFFmpegBridge.h"\n  export *\n}}\n')
    args = [cc] + flags + ["-dynamiclib", "-std=c11", "-fvisibility=hidden",
            "-I" + str(bridge / "include"), "-I" + str(prefix / "include"),
            "-install_name", f"@rpath/{FRAMEWORK}.framework/{FRAMEWORK}",
            "-Wl,-dead_strip", "-o", framework / FRAMEWORK]
    args += sorted(bridge.glob("*.c"))
    args += [prefix / f"lib/lib{name}.a" for name in LIBRARIES]
    args += ["-framework", "AudioToolbox", "-framework", "VideoToolbox", "-framework", "CoreMedia",
             "-framework", "CoreVideo", "-framework", "CoreFoundation", "-framework", "Security",
             "-lz", "-lbz2", "-liconv", "-lm", "-lc++"]
    run(args, work, env, work / "bridge.log")
    info = {"CFBundleIdentifier": "app.marginallybetter.MBFFmpegBridge",
            "CFBundleName": FRAMEWORK, "CFBundleExecutable": FRAMEWORK,
            "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
            "CFBundleShortVersionString": SOURCES["ffmpeg"]["version"],
            "MinimumOSVersion": minimum,
            "CFBundleSupportedPlatforms": [{"ios": "iPhoneOS", "ios-simulator": "iPhoneSimulator",
                                            "macos": "MacOSX"}[platform]]}
    (framework / "Info.plist").write_bytes(plistlib.dumps(info))
    notices = framework / "Licenses"
    notices.mkdir()
    for name, source in sources.items():
        destination = notices / name
        destination.mkdir()
        for pattern in ("COPYING*", "LICENSE*", "PATENTS*", "AUTHORS*"):
            for license_file in source.glob(pattern):
                if license_file.is_file():
                    shutil.copy2(license_file, destination)
    shutil.copy2(ROOT / "LICENSE", notices / "MBFFmpegBridge-MIT.txt")
    manifest = {"sources": SOURCES, "platform": platform, "target": target,
                "toolchain": toolchain, "recipe_revision": REVISION,
                "recipe_sha256": recipe_hash, "patches_sha256": patch_hash, "bridge_sha256": tree_digest(bridge),
                "sdk_build": sdk_build, "tools": tools,
                "license": "LGPL-2.1-or-later", "linkage": "dynamic framework; static PIC intermediates"}
    (framework / "BuildManifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[{platform}] framework ready: {framework}", flush=True)
    return framework


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", action="append", choices=["ios", "ios-simulator", "macos"])
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 4, 8))
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--fetch-only", action="store_true")
    parser.add_argument("--libraries-only", action="store_true")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    sources = fetch_sources(args.offline)
    if args.fetch_only:
        return
    platforms = list(dict.fromkeys(args.platform or ["ios", "ios-simulator"]))
    if not args.libraries_only and platforms != ["macos"] and "ios" not in platforms:
        parser.error("App XCFramework packaging requires an iOS device slice; add --platform ios")
    frameworks = [build_platform(p, sources, args.jobs, args.libraries_only) for p in platforms]
    if args.libraries_only:
        return
    # A host-only build must not overwrite the app's iOS artifact.
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
