#!/usr/bin/env ruby
# Wire Rishi.storekit as the StoreKit Configuration on the rishi scheme's
# Run action. Idempotent: safe to re-run.
#
# Background:
# - Xcode auto-generates per-user schemes under
#     rishi.xcodeproj/xcuserdata/<user>.xcuserdatad/xcschemes/
#   on first open, but those live behind .gitignore. The repo's
#   xcschememanagement.plist refers to rishi.xcscheme_^#shared#^_ — a shared
#   scheme — but the shared scheme file itself is missing on disk.
# - To make the StoreKit Configuration survive a clean checkout we promote the
#   rishi scheme to xcshareddata/xcschemes/rishi.xcscheme here (recreating it
#   if missing) and patch its LaunchAction.
#
# Output: apps/apple/rishi/rishi.xcodeproj/xcshareddata/xcschemes/rishi.xcscheme
require 'xcodeproj'
require 'fileutils'

PROJ_PATH   = File.expand_path('../rishi/rishi.xcodeproj', __dir__)
SCHEME_NAME = 'rishi'

unless File.exist?(PROJ_PATH)
  abort "FATAL: #{PROJ_PATH} not found"
end

project = Xcodeproj::Project.open(PROJ_PATH)
app_target = project.targets.find { |t| t.name == SCHEME_NAME }
abort "FATAL: rishi target not found in #{PROJ_PATH}" if app_target.nil?

shared_dir = Xcodeproj::XCScheme.shared_data_dir(PROJ_PATH)
scheme_path = File.join(shared_dir, "#{SCHEME_NAME}.xcscheme")
FileUtils.mkdir_p(shared_dir)

scheme = nil
if File.exist?(scheme_path)
  scheme = Xcodeproj::XCScheme.new(scheme_path)
  puts "[wire-rishi-storekit-scheme] Using existing shared scheme at #{scheme_path}"
else
  # Recreate a stock scheme rooted at the rishi app target. Mirrors Xcode's
  # default Cmd-R scheme so a clean checkout matches what the IDE would
  # generate. Tests target inclusion is best-effort.
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(app_target)
  scheme.set_launch_target(app_target)
  tests_target = project.targets.find { |t| t.test_target_type? }
  scheme.add_test_target(tests_target) if tests_target
  puts "[wire-rishi-storekit-scheme] Created new shared scheme at #{scheme_path}"
end

launch = scheme.launch_action.xml_element

# Remove any existing StoreKitConfigurationFileReference so the patch is
# idempotent across re-runs (and the LaunchAction never accrues duplicates).
launch.elements.each('StoreKitConfigurationFileReference') do |e|
  launch.delete_element(e)
end

# The xcscheme lives at
#   <PROJ>/xcshareddata/xcschemes/rishi.xcscheme
# The Rishi.storekit lives at
#   <PROJ>/../rishi/Rishi.storekit   (apps/apple/rishi/rishi/Rishi.storekit)
# Xcode resolves the `container:` form relative to the project file (.xcodeproj
# parent), so `container:rishi/Rishi.storekit` walks from
# apps/apple/rishi/  -> rishi/  -> Rishi.storekit. Verified against the
# filesystem layout in this repo.
sk = REXML::Element.new('StoreKitConfigurationFileReference')
sk.attributes['identifier'] = 'container:rishi/Rishi.storekit'
launch.add_element(sk)

scheme.save_as(PROJ_PATH, SCHEME_NAME, true)
puts "[wire-rishi-storekit-scheme] Set Rishi.storekit on rishi scheme Run action"
