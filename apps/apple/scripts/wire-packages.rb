#!/usr/bin/env ruby
# wire-packages.rb
#
# One-off scaffolding script for Phase 0 / Plan 00-02.
#
# Adds the four foundation SwiftPM packages under apps/apple/Packages/ to
# apps/apple/rishi/rishi.xcodeproj as local-path package references, and
# links their library products into the appropriate targets:
#
#   RishiCore     -> rishi (app target)
#   RishiUIKit    -> rishi (app target)
#   RishiLogging  -> rishi (app target)
#   RishiTesting  -> rishiTests (test target only, never linked into release)
#
# Safe to re-run: skips packages already wired (idempotent).
#
# Usage:
#   ruby apps/apple/scripts/wire-packages.rb
#
# Requires the `xcodeproj` gem (>= 1.27).
#
# Per ARCHITECTURE.md "RishiTesting" is "Test-target-only dependency,
# never linked into release."

require 'xcodeproj'

repo_root = File.expand_path(File.join(__dir__, '..', '..', '..'))
proj_path = File.join(repo_root, 'apps', 'apple', 'rishi', 'rishi.xcodeproj')

unless Dir.exist?(proj_path)
  abort "ERROR: xcodeproj not found at #{proj_path}"
end

project = Xcodeproj::Project.open(proj_path)

app_target  = project.targets.find { |t| t.name == 'rishi' }
test_target = project.targets.find { |t| t.name == 'rishiTests' }

abort 'ERROR: rishi app target not found' unless app_target
abort 'ERROR: rishiTests target not found' unless test_target

APP_PACKAGES  = %w[RishiCore RishiUIKit RishiLogging].freeze
TEST_PACKAGES = %w[RishiTesting].freeze

# Map of package name -> existing XCLocalSwiftPackageReference (if any).
existing_refs = {}
project.root_object.package_references.each do |ref|
  next unless ref.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  rel = ref.relative_path.to_s
  name = File.basename(rel)
  existing_refs[name] = ref
end

def ensure_local_ref(project, existing_refs, pkg)
  return existing_refs[pkg] if existing_refs.key?(pkg)

  ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  ref.relative_path = "../Packages/#{pkg}"
  project.root_object.package_references << ref
  existing_refs[pkg] = ref
  ref
end

def ensure_product_dep(project, target, ref, pkg)
  existing = target.package_product_dependencies.find do |dep|
    dep.product_name == pkg
  end
  return existing if existing

  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.package = ref
  product_dep.product_name = pkg
  target.package_product_dependencies << product_dep
  product_dep
end

def ensure_frameworks_link(project, target, product_dep, pkg)
  already_linked = target.frameworks_build_phase.files.any? do |bf|
    bf.product_ref && bf.product_ref.product_name == pkg
  end
  return if already_linked

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  target.frameworks_build_phase.files << build_file
end

APP_PACKAGES.each do |pkg|
  ref = ensure_local_ref(project, existing_refs, pkg)
  dep = ensure_product_dep(project, app_target, ref, pkg)
  ensure_frameworks_link(project, app_target, dep, pkg)
  puts "Wired #{pkg} -> rishi (app)"
end

# Enable Mac Catalyst on the rishi app target.
# ARCHITECTURE.md requires the four packages compile against the Catalyst SDK,
# which means the app target itself must opt in to Catalyst.
app_target.build_configurations.each do |bc|
  next if bc.build_settings['SUPPORTS_MACCATALYST'] == 'YES'
  bc.build_settings['SUPPORTS_MACCATALYST'] = 'YES'
  # Designed-for-iPad and Catalyst are mutually exclusive; explicitly opt out
  # so the destination 'platform=macOS,variant=Mac Catalyst' resolves.
  bc.build_settings['SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD'] = 'NO'
  puts "Enabled SUPPORTS_MACCATALYST on rishi (#{bc.name})"
end

TEST_PACKAGES.each do |pkg|
  ref = ensure_local_ref(project, existing_refs, pkg)
  dep = ensure_product_dep(project, test_target, ref, pkg)
  ensure_frameworks_link(project, test_target, dep, pkg)
  puts "Wired #{pkg} -> rishiTests (test only)"
end

project.save
puts "Saved #{proj_path}"
