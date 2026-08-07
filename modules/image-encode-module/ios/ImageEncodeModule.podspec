require 'json'

package_path = File.join(__dir__, '..', 'package.json')
package = JSON.parse(File.read(package_path))

Pod::Spec.new do |s|
  s.name           = 'ImageEncodeModule'
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
  }

  s.source_files = 'ImageEncodeModule.swift'
  s.frameworks = 'ImageIO', 'CoreGraphics', 'UniformTypeIdentifiers'
end
