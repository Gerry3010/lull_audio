#
# Shared Darwin podspec for iOS + macOS (sharedDarwinSource).
# Run `pod lib lint lull_audio.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'lull_audio'
  s.version          = '0.0.1'
  s.summary          = 'Native audio playback + system Now-Playing.'
  s.description      = <<-DESC
Play any audio source (incl. gapless byte chunks) and show it correctly in the
system Now-Playing surfaces, decoupled from how the audio is produced.
                       DESC
  s.homepage         = 'https://github.com/Gerry3010/lull_audio'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Gerald Hofbauer' => 'noreply@geraldhofbauer.net' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
