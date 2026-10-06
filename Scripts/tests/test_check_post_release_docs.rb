#!/usr/bin/env ruby
require 'fileutils'
require 'open3'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
validator = "#{root}/Scripts/check_post_release_docs.rb"
Dir.mktmpdir('innonetwork-post-release-docs-') do |fixture|
  FileUtils.mkdir_p(["#{fixture}/Scripts", "#{fixture}/docs", "#{fixture}/Sources/Fixture/Fixture.docc"])
  FileUtils.cp("#{root}/Scripts/published-releases.json", "#{fixture}/Scripts/")
  cases = {
    'published' => ['6.0.0 was published. The 6.1 candidate is unpublished.', true],
    'future' => ['Until 6.1.0 is published, use 6.0.0.', true],
    'unicode' => ['한국어 안내: 6.0.0 was published. 새 6.1은 후보입니다.', true],
    'wrapped' => ["Until 6.0.0\n is tagged, retain 5.x.", false],
    'minor-spelling' => ['Until 6.0 is published, retain 5.x.', false],
    'case-insensitive' => ['UNTIL 6.0.0 IS RELEASED, retain 5.x.', false],
    'unpublished' => ['6.0.0 is not yet published.', false],
    'hyphenated' => ['Adopt the not-yet-published 6.0.0 candidate.', false]
  }
  cases.each do |name, (text, success)|
    File.write("#{fixture}/Sources/Fixture/Fixture.docc/Guide.md", text)
    output, status = Open3.capture2e('ruby', validator, fixture)
    abort "#{name}: unexpected result: #{output}" unless status.success? == success
  end
  File.write("#{fixture}/Sources/Fixture/Fixture.docc/Guide.md", '6.0.0 was published.')
  File.write("#{fixture}/docs/ReleaseValidation-6.0.0.md", 'Until 6.0.0 is tagged, this dated evidence is provisional.')
  output, status = Open3.capture2e('ruby', validator, fixture)
  abort "Historical evidence was rewritten by scope: #{output}" unless status.success?
  File.write("#{fixture}/Scripts/published-releases.json", '{}')
  output, status = Open3.capture2e('ruby', validator, fixture)
  abort "Invalid evidence was accepted: #{output}" if status.success?
end
puts 'Post-release adoption doc fixtures: 10 passed.'
