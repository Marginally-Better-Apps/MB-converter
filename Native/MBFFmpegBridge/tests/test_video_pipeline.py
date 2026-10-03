#!/usr/bin/env python3
"""Color and hardware pipeline regressions against independent FFmpeg output.
Run with --hardware on an Apple Silicon host with VideoToolbox service access.
No iOS simulator is used. Fixtures/results are retained under build/ffmpeg/video-tests.
"""
import argparse
import ctypes as C
import json
import math
import hashlib
from pathlib import Path
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[3]
PREFIX = ROOT / 'build/ffmpeg/macos-arm64/prefix'
WORK = ROOT / 'build/ffmpeg/video-tests'
LIBS = ['avfilter', 'avformat', 'avcodec', 'swresample', 'swscale', 'avutil',
        'mp3lame', 'vorbisenc', 'vorbis', 'ogg', 'opus', 'vpx', 'dav1d', 'zimg']


def command(*args):
    result = subprocess.run([str(x) for x in args], capture_output=True)
    if result.returncode:
        raise AssertionError(result.stderr.decode(errors='replace')[-8000:])
    return result.stdout


def ffmpeg(*args):
    return command('ffmpeg', '-v', 'error', '-y', *args)


def probe(path):
    return json.loads(command('ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path))


def build_library():
    WORK.mkdir(parents=True, exist_ok=True)
    library = WORK / 'libmbftest.dylib'
    args = ['cc', '-dynamiclib', '-std=c11', '-DMBF_TESTING', '-Wall', '-Wextra', '-Werror',
            '-I', ROOT / 'Native/MBFFmpegBridge/include', '-I', PREFIX / 'include',
            ROOT / 'Native/MBFFmpegBridge/MBFFmpegBridge.c', '-L', PREFIX / 'lib']
    args += ['-l' + lib for lib in LIBS]
    for framework in ['AudioToolbox', 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'CoreFoundation', 'Security']:
        args += ['-framework', framework]
    command(*args, '-lz', '-lbz2', '-liconv', '-lm', '-lc++', '-o', library)
    policy_args = [x for x in args if x != '-dynamiclib']
    policy_args[policy_args.index(ROOT / 'Native/MBFFmpegBridge/MBFFmpegBridge.c')] = Path(__file__).with_name('video_policy_tests.c')
    policy = WORK / 'video_policy_tests'
    command(*policy_args, '-lz', '-lbz2', '-liconv', '-lm', '-lc++', '-o', policy)
    print(command(policy).decode().strip())
    return C.CDLL(str(library))


LOG = C.CFUNCTYPE(None, C.c_void_p, C.c_char_p)
PROGRESS = C.CFUNCTYPE(None, C.c_void_p, C.c_int64, C.c_int64, C.c_int64)
CANCEL = C.CFUNCTYPE(C.c_int, C.c_void_p)


def execute(lib, args, cancel=False):
    logs, progress = [], []
    log_cb = LOG(lambda _, text: logs.append(text.decode()))
    progress_cb = PROGRESS(lambda _, time, size, frames: progress.append((time, size, frames)))
    cancel_cb = CANCEL(lambda _: int(cancel and bool(progress)))
    argv = (C.c_char_p * len(args))(*(str(x).encode() for x in args))
    lib.mbf_execute.argtypes = [C.c_int, C.POINTER(C.c_char_p), LOG, PROGRESS, CANCEL, C.c_void_p]
    result = lib.mbf_execute(len(args), argv, log_cb, progress_cb, cancel_cb, None)
    (WORK / 'last-conversion.log').write_text('\n'.join(logs))
    for before, after in zip(progress, progress[1:]):
        assert before[0] <= after[0] and before[2] <= after[2], 'progress regressed'
    return result, '\n'.join(logs), progress


def fixtures():
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=160x96:rate=12', '-f', 'lavfi', '-i', 'sine=frequency=440',
           '-t', '0.75', '-c:v', 'libx264', '-color_primaries', 'bt709', '-color_trc', 'bt709',
           '-colorspace', 'bt709', '-c:a', 'aac', WORK / 'sdr.mp4')
    for name, transfer, primaries, matrix in [('pq', 'smpte2084', 'bt2020', 'bt2020nc'),
        ('hlg', 'arib-std-b67', 'bt2020', 'bt2020nc'), ('sdr10', 'bt709', 'bt709', 'bt709')]:
        params = 'log-level=error:pools=1:frame-threads=1'
        params += ':colorprim=' + ('1' if name == 'sdr10' else '9')
        params += ':transfer=' + {'pq':'16', 'hlg':'18', 'sdr10':'1'}[name]
        params += ':colormatrix=' + ('1' if name == 'sdr10' else '9')
        if name == 'pq':
            params += ':master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400'
        ffmpeg('-i', WORK / 'sdr.mp4', '-vf', 'format=yuv420p10le', '-c:v', 'libx265', '-preset', 'ultrafast',
               '-x265-params', params, '-color_primaries', primaries, '-color_trc', transfer,
               '-colorspace', matrix, '-color_range', 'tv', '-c:a', 'copy', WORK / f'{name}.mp4')
    ffmpeg('-display_rotation:v:0', '90', '-i', WORK / 'sdr.mp4', '-c', 'copy', WORK / 'rotated.mp4')


def conversion(lib, name, output, mode='off', filters=None, extra=(), fail=False, cancel=False):
    args = ['-y', '-mb-acceleration', mode, '-i', WORK / f'{name}.mp4']
    if filters: args += ['-vf', filters]
    args += list(extra)
    args += ['-c:v', 'libvpx-vp9' if output.endswith('.webm') else 'hevc_videotoolbox' if 'hevc' in output else 'h264_videotoolbox',
             '-b:v', '700k', '-c:a', 'libopus' if output.endswith('.webm') else 'aac', '-b:a', '64k', WORK / output]
    result, logs, progress = execute(lib, args, cancel=cancel)
    assert (result < 0) == fail, (args, result, logs)
    if not fail: assert progress and probe(WORK / output)['streams'], logs
    return logs


def reference(name):
    # Match the source peak and color policy, but use the independent FFmpeg CLI
    # and software decoder/encoder for pixel verification.
    return ('zscale=transfer=linear:npl=100,format=gbrpf32le,zscale=primaries=bt709,'
            'tonemap=mobius:param=0.3:desat=2:peak=10,'
            'zscale=transfer=bt709:matrix=bt709:range=limited:dither=error_diffusion,format=yuv420p')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--hardware', action='store_true')
    parser.add_argument('--dolby-fixture', type=Path, help='Dolby Laboratories Profile 8.4 1080p Sol Levante sample (see validation report)')
    args = parser.parse_args()
    lib = build_library()
    fixtures()
    for name in ['pq', 'hlg']:
        conversion(lib, name, f'{name}-sdr.webm')
        stream = probe(WORK / f'{name}-sdr.webm')['streams'][0]
        assert stream['pix_fmt'] == 'yuv420p' and stream['color_transfer'] == 'bt709', stream
        assert stream['color_space'] == 'bt709' and stream['color_primaries'] == 'bt709', stream
        assert not any('Mastering' in x['side_data_type'] or 'Content light' in x['side_data_type'] for x in stream.get('side_data_list', []))
        expected = ffmpeg('-i', WORK / f'{name}.mp4', '-vf', reference(name), '-an', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-')
        actual = ffmpeg('-i', WORK / f'{name}-sdr.webm', '-an', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-')
        assert len(expected) == len(actual), (name, len(expected), len(actual))
        mse = sum((a-b)**2 for a, b in zip(expected, actual)) / len(actual)
        psnr = 10 * math.log10(255**2 / max(mse, 1e-12))
        assert psnr > 35, (name, psnr)
        print(f'PASS: {name} to SDR signaling, metadata removal, software-reference PSNR={psnr:.2f}dB')
    conversion(lib, 'sdr10', 'sdr10.webm')
    # Malformed inputs and output I/O errors must never trigger hardware retry.
    (WORK / 'broken.mp4').write_bytes(b'not a media file')
    logs = conversion(lib, 'broken', 'broken.webm', 'auto', fail=True)
    assert 'MBF_RETRY' not in logs
    # Initialization failure can be tested without permission to use hardware.
    logs = conversion(lib, 'sdr', 'init-retry.webm', 'auto', extra=['-mb-test-failure', 'init'])
    assert logs.count('MBF_RETRY') == 1 and 'attempts=2' in logs
    conversion(lib, 'sdr', 'required-reject.webm', 'required', fail=True)
    conversion(lib, 'sdr', 'cancel.webm', 'off', fail=True, cancel=True)
    assert not (WORK / 'cancel.webm').exists()
    conversion(lib, 'sdr', 'invalid.webm', filters='not_a_filter', fail=True)
    conversion(lib, 'sdr', 'crop.webm', filters='transpose=clock,crop=80:140,scale=64:112')
    stream = probe(WORK / 'crop.webm')['streams'][0]
    assert (stream['width'], stream['height']) == (64, 112)
    print('PASS: software pipeline, crop/rotation, fallback, strict mode, cancellation and cleanup')
    if args.hardware:
        for name in ['sdr', 'sdr10', 'pq', 'hlg']:
            logs = conversion(lib, name, f'{name}-hevc.mp4', 'required', filters='scale=80:48')
            assert 'filter=VideoToolbox' in logs and 'hardware required' in logs
            stream = probe(WORK / f'{name}-hevc.mp4')['streams'][0]
            assert (stream['width'], stream['height']) == (80, 48)
            if name != 'sdr': assert stream['pix_fmt'] == 'yuv420p10le' and stream['profile'] == 'Main 10', stream
            if name in ['pq', 'hlg']:
                assert stream['color_transfer'] == ('smpte2084' if name == 'pq' else 'arib-std-b67'), stream
            if name == 'pq': assert any('Mastering' in x['side_data_type'] for x in stream.get('side_data_list', [])), stream
        for rotation in ['transpose=clock', 'transpose=cclock', 'hflip,vflip', 'hflip', 'vflip']:
            conversion(lib, 'sdr', 'rotation-hevc.mp4', 'required', filters=rotation)
            expected = ffmpeg('-i', WORK / 'sdr.mp4', '-vf', rotation, '-an', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-')
            actual = ffmpeg('-i', WORK / 'rotation-hevc.mp4', '-an', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-')
            assert len(expected) == len(actual)
            mse = sum((a-b)**2 for a, b in zip(expected, actual)) / len(actual)
            assert 10 * math.log10(255**2 / max(mse, 1e-12)) > 32, rotation
        conversion(lib, 'sdr', 'fps-hevc.mp4', 'required', extra=['-r', '6'])
        assert probe(WORK / 'fps-hevc.mp4')['streams'][0]['avg_frame_rate'] == '6/1'
        conversion(lib, 'rotated', 'display-rotation-hevc.mp4', 'required')
        assert probe(WORK / 'display-rotation-hevc.mp4')['streams'][0]['width'] == 96
        conversion(lib, 'pq', 'pq-h264.mp4', 'auto')
        assert probe(WORK / 'pq-h264.mp4')['streams'][0]['color_transfer'] == 'bt709'
        logs = conversion(lib, 'hlg', 'retry-hevc.mp4', 'auto', extra=['-mb-test-failure', 'mid'])
        assert logs.count('MBF_RETRY') == 1 and 'attempts=2' in logs
        assert probe(WORK / 'retry-hevc.mp4')['streams'][0]['pix_fmt'] == 'yuv420p10le'
        logs = conversion(lib, 'sdr', 'cpu-crop-hevc.mp4', 'auto', filters='crop=80:48')
        assert 'filter=CPU' in logs
        logs = conversion(lib, 'sdr', 'missing-directory/output-hevc.mp4', 'auto', fail=True)
        assert 'MBF_RETRY' not in logs
        logs = conversion(lib, 'hlg', 'cancel-hevc.mp4', 'auto', fail=True, cancel=True)
        assert 'MBF_RETRY' not in logs and not (WORK / 'cancel-hevc.mp4').exists()
        # Exercise isolated contexts and bounded first-frame audio retention.
        def parallel_job(index):
            return conversion(lib, 'hlg', f'concurrent-{index}-hevc.mp4', 'auto', filters='scale=80:48')
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(parallel_job, range(4)))
        for index in range(4):
            streams = probe(WORK / f'concurrent-{index}-hevc.mp4')['streams']
            video, audio = streams[0], streams[1]
            assert abs(float(video['duration']) - float(audio['duration'])) < 0.1
            assert abs(float(video['start_time']) - float(audio['start_time'])) < 0.1
        print('PASS: VideoToolbox decode/filter/encode, Main10/HDR, all rotations, CPU filter fallback and mid-conversion retry')
    if args.dolby_fixture:
        assert hashlib.sha256(args.dolby_fixture.read_bytes()).hexdigest() == 'd81d4c17958946796f30ca28a57776cee187a421649058767c8496cbc1e469bf'
        ffmpeg('-ss', '15', '-i', args.dolby_fixture, '-t', '1', '-c', 'copy', '-strict', 'unofficial', WORK / 'dovi.mp4')
        stream = probe(WORK / 'dovi.mp4')['streams'][0]
        assert any(x.get('dv_bl_signal_compatibility_id') == 4 for x in stream.get('side_data_list', []))
        for mode in ['off', 'required'] if args.hardware else ['off']:
            logs = conversion(lib, 'dovi', f'dovi-{mode}-hevc.mp4', mode, filters='scale=640:360')
            assert 'Dolby Vision: using compatible base layer' in logs
            stream = probe(WORK / f'dovi-{mode}-hevc.mp4')['streams'][0]
            assert stream['pix_fmt'] == 'yuv420p10le' and stream['color_transfer'] == 'arib-std-b67'
            assert not any('DOVI' in x['side_data_type'] for x in stream.get('side_data_list', []))
        conversion(lib, 'dovi', 'dovi-sdr.webm', filters='scale=320:180')
        stream = probe(WORK / 'dovi-sdr.webm')['streams'][0]
        assert stream['color_transfer'] == 'bt709' and stream['pix_fmt'] == 'yuv420p'
        expected = ffmpeg('-i', WORK / 'dovi.mp4', '-vf', 'scale=320:180,' + reference('hlg'),
                          '-an', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-')
        actual = ffmpeg('-i', WORK / 'dovi-sdr.webm', '-an', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-')
        assert len(expected) == len(actual), (len(expected), len(actual))
        mse = sum((a-b)**2 for a, b in zip(expected, actual)) / len(actual)
        psnr = 10 * math.log10(255**2 / max(mse, 1e-12))
        assert psnr > 30, psnr
        result, logs, _ = execute(lib, ['-y', '-i', WORK / 'dovi.mp4', '-c:v', 'copy', '-an', WORK / 'dovi-copy.mp4'])
        assert result == 0, logs
        stream = probe(WORK / 'dovi-copy.mp4')['streams'][0]
        assert any(x.get('dv_bl_signal_compatibility_id') == 4 for x in stream.get('side_data_list', []))
        print(f'PASS: real Dolby Profile 8.4 base-layer HDR/SDR conversion (PSNR={psnr:.2f}dB), stale DV removal and DV stream copy')


if __name__ == '__main__':
    main()
