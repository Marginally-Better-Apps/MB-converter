require 'json'

package_path = File.join(__dir__, '..', 'package.json')
package = JSON.parse(File.read(package_path))

download_script = File.expand_path(File.join(__dir__, '..', '..', '..', 'scripts', 'download-ffmpeg-frameworks.sh'))
frameworks_dir = File.join(__dir__, 'Frameworks')
required_frameworks = %w[
  ffmpegkit
  libavcodec
  libavdevice
  libavfilter
  libavformat
  libavutil
  libswresample
  libswscale
]

missing = required_frameworks.reject { |name| File.directory?(File.join(frameworks_dir, "#{name}.xcframework")) }
if missing.any?
  raise <<~MSG unless File.file?(download_script)
    FFmpeg xcframeworks missing (#{missing.join(', ')}).
    Run: ./scripts/download-ffmpeg-frameworks.sh
  MSG

  puts "[FFmpegModule] Downloading missing frameworks via #{download_script}"
  system('bash', download_script) or raise 'Failed to download FFmpeg frameworks'
end

Pod::Spec.new do |s|
  s.name           = 'FFmpegModule'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author']
  s.homepage       = package['homepage']
  s.platforms      = {
    :ios => '17.0',
  }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
  }

  # Keep vendored headers out of the Expo module umbrella.
  s.source_files = 'FFmpegModule.swift'
  s.vendored_frameworks = required_frameworks.map { |name| "Frameworks/#{name}.xcframework" }
  s.preserve_paths = 'Frameworks/**/*'

  s.frameworks = 'VideoToolbox', 'AudioToolbox', 'AVFoundation'
  s.libraries = 'z', 'bz2', 'iconv', 'lzma'
end
