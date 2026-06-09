#!/usr/bin/env ruby
# Wire the RishiDB local SwiftPM package into rishi.xcodeproj.
# Idempotent: safe to re-run after a concurrent edit clobbered the change.
#
# Mirrors apps/apple/scripts/wire-packages.rb (Phase 0 Plan 00-02).

require 'xcodeproj'

PROJ_PATH = File.expand_path('../rishi/rishi.xcodeproj', __dir__)
PKG_NAME  = 'RishiDB'
PKG_PATH  = "../Packages/#{PKG_NAME}"

project = Xcodeproj::Project.open(PROJ_PATH)
app_target = project.targets.find { |t| t.name == 'rishi' } \
  or abort "FATAL: rishi target not found in #{PROJ_PATH}"

# 1) Add local-path package reference (idempotent)
ref = project.root_object.package_references.find do |r|
  r.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
    r.relative_path == PKG_PATH
end

if ref.nil?
  ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  ref.relative_path = PKG_PATH
  project.root_object.package_references << ref
  puts "[wire-rishi-db] Added local package reference #{PKG_PATH}"
else
  puts "[wire-rishi-db] Local package reference #{PKG_PATH} already present"
end

# 2) Add product dependency on RishiDB to the rishi app target (idempotent)
product_dep = app_target.package_product_dependencies.find do |d|
  d.product_name == PKG_NAME
end

if product_dep.nil?
  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.package = ref
  product_dep.product_name = PKG_NAME
  app_target.package_product_dependencies << product_dep
  puts "[wire-rishi-db] Added product dependency #{PKG_NAME} to rishi target"
else
  puts "[wire-rishi-db] Product dependency #{PKG_NAME} already on rishi target"
end

# 3) Add a PBXBuildFile linking the product into the rishi frameworks build phase (idempotent)
already_linked = app_target.frameworks_build_phase.files.any? do |bf|
  bf.respond_to?(:product_ref) && bf.product_ref == product_dep
end

unless already_linked
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  app_target.frameworks_build_phase.files << build_file
  puts "[wire-rishi-db] Linked #{PKG_NAME} into rishi frameworks build phase"
else
  puts "[wire-rishi-db] #{PKG_NAME} already in rishi frameworks build phase"
end

project.save
puts "[wire-rishi-db] Saved #{PROJ_PATH}"
