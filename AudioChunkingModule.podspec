Pod::Spec.new do |s|
    s.name         = "AudioChunkingModule"
    s.version      = "1.0.26"
    s.summary      = "Audio chunking native module for React Native"
    s.description  = "A React Native module for chunked audio recording."
    s.homepage     = "https://github.com/isaacg11/react-native-audio-chunking"
    s.license      = { :type => "MIT", :file => "../LICENSE" }
    s.author       = { "Isaac Grey" => "isaac.j.grey@gmail.com" }
    s.platform     = :ios, "11.0"
    s.source       = { :git => "https://github.com/isaacg11/react-native-audio-chunking.git", :tag => "#{s.version}" }
    s.source_files  = "ios/*.{m,swift}"
    s.requires_arc = true
    s.dependency "React-Core"
  end