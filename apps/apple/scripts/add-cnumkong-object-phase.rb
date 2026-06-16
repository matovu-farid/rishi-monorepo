#!/usr/bin/env ruby
# Work around an Xcode 26 / SwiftPM linker bug affecting the rishi app target.
#
# NumKong's `CNumKong` is a header-only SwiftPM C target (path: "include",
# publicHeadersPath: "."), so it compiles to no object. Xcode's SwiftPM
# integration nonetheless lists `CNumKong.o` in the app's link file list (one
# loose object per static C target in the dependency closure: rishi ->
# RishiSearch -> usearch -> CNumKongDispatch -> CNumKong). The link then fails:
#   Build input file cannot be found: '.../CNumKong.o'
# This breaks every destination (Catalyst/iOS/macOS); `swift test` is unaffected
# because the SwiftPM CLI links the header-only target as an empty static archive.
#
# Dynamic-framework linking only relocates the same error into the framework's
# link step, and disabling the single-object prelink (GENERATE_MASTER_OBJECT_FILE)
# has no effect -- both verified empirically. The remaining fix is to make the
# phantom object exist. This adds a pre-link Run Script phase that synthesizes an
# empty, platform/arch-correct CNumKong.o and declares it as an output, which is
# exactly what the linker error hint asks for.
#
# Idempotent: safe to re-run.

require 'xcodeproj'

PROJ_PATH  = File.expand_path('../rishi/rishi.xcodeproj', __dir__)
PHASE_NAME = 'Synthesize empty CNumKong.o (header-only SwiftPM target workaround)'

SHELL_SCRIPT = <<~'SH'
  # See scripts/add-cnumkong-object-phase.rb for why this exists.
  # User Script Sandboxing (ENABLE_USER_SCRIPT_SANDBOXING) only grants write
  # access to declared output paths, so we must write solely to the declared
  # output (${SCRIPT_OUTPUT_FILE_0}); intermediate files in DERIVED_FILE_DIR are
  # denied. Single arch (the common case: Catalyst/iOS on Apple Silicon, iOS
  # archives) compiles straight to the output. Multi-arch uses $TMPDIR for slices.
  set -eu
  out="${SCRIPT_OUTPUT_FILE_0}"
  set -- ${ARCHS}
  if [ "$#" -eq 1 ]; then
    triple="${1}-apple-${LLVM_TARGET_TRIPLE_OS_VERSION}${LLVM_TARGET_TRIPLE_SUFFIX:-}"
    xcrun --sdk "${PLATFORM_NAME}" clang -target "${triple}" -c -x c /dev/null -o "${out}"
  else
    work="$(mktemp -d "${TMPDIR:-/tmp}/cnumkong.XXXXXX")"
    slices=""
    for arch in ${ARCHS}; do
      triple="${arch}-apple-${LLVM_TARGET_TRIPLE_OS_VERSION}${LLVM_TARGET_TRIPLE_SUFFIX:-}"
      slice="${work}/${arch}.o"
      xcrun --sdk "${PLATFORM_NAME}" clang -target "${triple}" -c -x c /dev/null -o "${slice}"
      slices="${slices} ${slice}"
    done
    lipo -create ${slices} -output "${out}"
    rm -rf "${work}"
  fi
SH

project = Xcodeproj::Project.open(PROJ_PATH)
app_target = project.targets.find { |t| t.name == 'rishi' } \
  or abort "FATAL: rishi target not found in #{PROJ_PATH}"

phase = app_target.build_phases.find do |p|
  p.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && p.name == PHASE_NAME
end

if phase.nil?
  phase = project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
  phase.name = PHASE_NAME
  puts "[add-cnumkong-object-phase] Added shell script phase to rishi target"
else
  app_target.build_phases.delete(phase)
  puts "[add-cnumkong-object-phase] Shell script phase already present; repositioning"
end

# Must run BEFORE Compile Sources. The link step (Ld) depends on the declared
# CNumKong.o output; if the phase sits after Sources, XCBuild makes it depend on
# the compile-sources gate, and AppIntents metadata extraction feeds Ld's output
# back into that gate -> dependency cycle. The script needs no compiled inputs,
# so placing it first keeps the output->Ld ordering edge without the cycle.
app_target.build_phases.unshift(phase)

phase.shell_path = '/bin/sh'
phase.shell_script = SHELL_SCRIPT
phase.input_paths = []
phase.output_paths = ['$(BUILT_PRODUCTS_DIR)/CNumKong.o']
phase.run_only_for_deployment_postprocessing = '0'
# Always run: ARCHS can change between builds in the same DerivedData (e.g.
# universal archive), which would otherwise leave a stale single-arch object.
phase.always_out_of_date = '1'

project.save
puts "[add-cnumkong-object-phase] Saved #{PROJ_PATH}"
