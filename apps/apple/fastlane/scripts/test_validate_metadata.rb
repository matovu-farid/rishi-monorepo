#!/usr/bin/env ruby
# Self-tests for fastlane/scripts/validate_metadata.rb.
# No external dependencies — pure Ruby asserts.
#
# Each test builds a fresh fixture tree under a tmpdir, mutates one field,
# and asserts the validator reports (or does not report) the expected error.

require 'fileutils'
require 'tmpdir'

require_relative 'validate_metadata'

def with_fixture
  Dir.mktmpdir do |root|
    locale = File.join(root, 'metadata', 'en-US')
    review = File.join(root, 'metadata', 'review_information')
    FileUtils.mkdir_p(locale)
    FileUtils.mkdir_p(review)

    File.write(File.join(locale, 'name.txt'), 'Rishi')
    File.write(File.join(locale, 'subtitle.txt'), 'Books that talk back.')
    File.write(File.join(locale, 'description.txt'), 'a' * 200)
    File.write(File.join(locale, 'keywords.txt'), 'epub,pdf,reader')
    File.write(File.join(locale, 'promotional_text.txt'), 'New release.')
    File.write(File.join(locale, 'release_notes.txt'), 'First release.')
    File.write(File.join(locale, 'marketing_url.txt'), 'https://rishi.fidexa.org')
    File.write(File.join(locale, 'support_url.txt'), 'https://rishi.fidexa.org/support')
    File.write(File.join(locale, 'privacy_url.txt'), 'https://rishi.fidexa.org/privacy')

    %w[first_name.txt last_name.txt email_address.txt phone_number.txt notes.txt].each do |f|
      File.write(File.join(review, f), 'x')
    end

    yield root, locale, review
  end
end

def assert(cond, msg)
  raise "ASSERT FAILED: #{msg}" unless cond
end

# Test 1: clean fixture passes
with_fixture do |root, _, _|
  errs = validate(root)
  assert(errs.empty?, "clean fixture should pass — got: #{errs.inspect}")
end
puts 'OK: clean fixture passes'

# Test 2: missing description fails
with_fixture do |root, locale, _|
  File.delete(File.join(locale, 'description.txt'))
  errs = validate(root)
  assert(errs.any? { |e| e.include?('description.txt') }, 'should flag missing description')
end
puts 'OK: missing description fails'

# Test 3: oversized name fails
with_fixture do |root, locale, _|
  File.write(File.join(locale, 'name.txt'), 'x' * 31)
  errs = validate(root)
  assert(errs.any? { |e| e.include?('exceeds 30 char limit') }, 'should flag oversize name')
end
puts 'OK: oversize name fails'

# Test 4: non-https marketing URL fails
with_fixture do |root, locale, _|
  File.write(File.join(locale, 'marketing_url.txt'), 'ftp://rishi.fidexa.org')
  errs = validate(root)
  assert(errs.any? { |e| e.include?('must be http(s)') }, 'should flag non-http url')
end
puts 'OK: non-http url fails'

# Test 5: keywords overflow fails
with_fixture do |root, locale, _|
  File.write(File.join(locale, 'keywords.txt'), 'a' * 101)
  errs = validate(root)
  assert(errs.any? { |e| e.include?('keywords.txt') }, 'should flag oversize keywords')
end
puts 'OK: oversize keywords fails'

puts 'All metadata validator tests passed.'
