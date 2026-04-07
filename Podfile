# Kyomiru CocoaPods dependencies

platform :ios, '16.0'

target 'Kyomiru' do
  use_frameworks!

end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)']
      config.build_settings['OTHER_CFLAGS'] ||= ['$(inherited)', '-fPIC']
    end
  end
end
