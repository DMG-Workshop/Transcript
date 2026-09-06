#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint transcript_whisper_native.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'transcript_whisper_native'
  s.version          = '0.0.1'
  s.summary          = 'On-device whisper.cpp speech-to-text FFI plugin.'
  s.description      = <<-DESC
Vendors ggml/whisper.cpp (CPU backend only) behind a minimal FFI shim used
by transcript_core's WhisperEngine seam. No ffmpeg or any other audio
re-encoding dependency: callers must already supply 16 kHz mono 16-bit PCM
WAV, which is exactly what transcript_core's own WAV builder produces.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  # CocoaPods' source_files glob cannot reach outside this podspec's own
  # directory (a glob like '../src/**' silently matches nothing — it is not
  # an error, the files are just never added to the Xcode target, which
  # then fails to *link*, not to compile). So Classes/ carries a forwarder
  # for the shim itself (a relative #include of ../src/*.cpp, which *does*
  # resolve — #include paths are not glob-restricted) plus its own full copy
  # of the vendored ggml/whisper.cpp tree (Classes/whisper_cpp/), since that
  # needs to be compiled as real separate translation units, not merely
  # included as text.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  # Only our own entry point is public; the vendored ggml/whisper.cpp tree
  # has headers with colliding basenames (e.g. common.h) once flattened into
  # the framework's public header directory, so keep those private.
  s.public_header_files = 'Classes/transcript_whisper_native.h'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/Classes/whisper_cpp/include"',
      '"$(PODS_TARGET_SRCROOT)/Classes/whisper_cpp/ggml/include"',
      '"$(PODS_TARGET_SRCROOT)/Classes/whisper_cpp/ggml/src"',
      '"$(PODS_TARGET_SRCROOT)/Classes/whisper_cpp/ggml/src/ggml-cpu"',
      '"$(PODS_TARGET_SRCROOT)/Classes/whisper_cpp/src"',
    ].join(' '),
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GGML_USE_CPU=1 GGML_USE_ACCELERATE=1 ACCELERATE_NEW_LAPACK=1 ACCELERATE_LAPACK_ILP64=1 GGML_VERSION=\"1.9.1\" GGML_COMMIT=\"transcript_whisper_native-vendored\" WHISPER_VERSION=\"1.9.1\"',
    'GCC_OPTIMIZATION_LEVEL' => '3',
  }
  s.library = 'c++'
  s.frameworks = 'Accelerate'
  s.swift_version = '5.0'
end
