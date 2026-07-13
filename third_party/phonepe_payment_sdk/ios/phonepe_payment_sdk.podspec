#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint phonepe_payment_sdk.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'phonepe_payment_sdk'
  s.version          = '3.0.2'
  s.summary          = 'A flutter Plugin for PhonePe Payment SDK'
  s.description      = <<-DESC
    A flutter Plugin for PhonePe Payment SDK
                       DESC
  s.homepage         = 'https://github.com/PhonePe/PhonePePayment'
  s.license          = { :type => 'Proprietary', :text => 'Copyright 2021 PhonePe. All rights reserved.' }
  s.author           = { 'PhonePe' => 'ios-support@phonepe.com' }
  s.source           = { :git => 'https://github.com/PhonePe/PhonePePayment.git' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '9.0'

  s.dependency 'PhonePePayment', '4.0.0'
end