#!/usr/bin/env ruby
require 'fileutils'
require 'open3'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
Dir.mktmpdir('innonetwork-changelog-') do |fixture|
  FileUtils.mkdir_p(["#{fixture}/Scripts", "#{fixture}/Sources"])
  FileUtils.cp("#{root}/Scripts/check_changelog_sync.sh", "#{fixture}/Scripts/")
  File.write("#{fixture}/Sources/Fixture.swift", 'struct Fixture {}')
  cases = {
    'empty' => ['', true, 'no [Unreleased] section content'],
    'prose' => ['- Improve endpoint safety.', true, 'no leading symbol bullets'],
    'present' => ['- `Fixture` is available.', true, 'all resolve in source'],
    'missing' => ['- `MissingType` is available.', false, 'MissingType'],
    'mixed' => ["- Improve safety.\n- `MissingType` is available.", false, 'MissingType'],
    'removed' => ["### Removed\n- `MissingType` was deleted.\n### Added\n- `Fixture` is available.", true, 'all resolve in source']
  }
  cases.each do |name, (notes, success, expected)|
    File.write("#{fixture}/CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n#{notes}\n\n## [1.0.0]\n- `OldSymbol`\n")
    output, status = Open3.capture2e('bash', "#{fixture}/Scripts/check_changelog_sync.sh")
    abort "#{name}: unexpected result #{status.exitstatus}\n#{output}" unless status.success? == success && output.include?(expected)
    puts "changelog #{name}: PASS"
  end
  FileUtils.mv("#{fixture}/Sources", "#{fixture}/UnavailableSources")
  output, status = Open3.capture2e('bash', "#{fixture}/Scripts/check_changelog_sync.sh")
  abort 'Missing source directory was silently accepted' if status.success? || !output.include?('Sources/ directory not found')
  puts 'changelog missing-source: PASS'
end
