#!/usr/bin/env ruby
# Wire the RishiSearch local SwiftPM package into rishi.xcodeproj.
# Idempotent: safe to re-run.
#
# Phase 25 Plan 25-03 scaffold. Mirrors apps/apple/scripts/wire-rishi-audio.rb
# style. Plans 25-07 (RealtimeClientAPI ext.) and 25-09 (BookContextResponder)
# need to `import RishiSearch` from the app target.

require 'xcodeproj'

PROJ_PATH = File.expand_path('../rishi/rishi.xcodeproj', __dir__)
PKG_NAME  = 'RishiSearch'
PKG_PATH  = "../Packages/#{PKG_NAME}"

project = Xcodeproj::Project.open(PROJ_PATH)
app_target = project.targets.find { |t| t.name == 'rishi' } \
  or abort "FATAL: rishi target not found in #{PROJ_PATH}"

ref = project.root_object.package_references.find do |r|
  r.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
    r.relative_path == PKG_PATH
end

if ref.nil?
  ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  ref.relative_path = PKG_PATH
  project.root_object.package_references << ref
  puts "[register-rishi-search] Added local package reference #{PKG_PATH}"
else
  puts "[register-rishi-search] Local package reference #{PKG_PATH} already present"
end

product_dep = app_target.package_product_dependencies.find do |d|
  d.product_name == PKG_NAME
end

if product_dep.nil?
  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.package = ref
  product_dep.product_name = PKG_NAME
  app_target.package_product_dependencies << product_dep
  puts "[register-rishi-search] Added product dependency #{PKG_NAME} to rishi target"
else
  puts "[register-rishi-search] Product dependency #{PKG_NAME} already on rishi target"
end

already_linked = app_target.frameworks_build_phase.files.any? do |bf|
  bf.respond_to?(:product_ref) && bf.product_ref == product_dep
end

unless already_linked
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  app_target.frameworks_build_phase.files << build_file
  puts "[register-rishi-search] Linked #{PKG_NAME} into rishi frameworks build phase"
else
  puts "[register-rishi-search] #{PKG_NAME} already in rishi frameworks build phase"
end

project.save
puts "[register-rishi-search] Saved #{PROJ_PATH}"
