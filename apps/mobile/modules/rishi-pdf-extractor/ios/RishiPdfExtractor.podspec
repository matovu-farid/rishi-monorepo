require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'RishiPdfExtractor'
  s.version        = package['version']
  s.summary        = 'Native PDF text + word-rect extraction for Rishi'
  s.description    = package['description'] || s.summary
  s.license        = 'UNLICENSED'
  s.author         = 'Rishi'
  s.homepage       = 'https://example.com'
  s.platforms      = { :ios => '15.1' }
  s.source         = { :git => '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.frameworks = ['PDFKit']

  s.source_files = "**/*.{h,m,swift}"
  # XCTest files are wired into a separate test target by the engineer
  # in Xcode; excluding them from the library's source_files prevents
  # `no such module 'XCTest'` when building the main library.
  s.exclude_files = "Tests/**/*"
end
