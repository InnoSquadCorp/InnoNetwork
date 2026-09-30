#!/usr/bin/env ruby
require 'json'
require 'time'

root = ARGV.shift || File.expand_path('..', __dir__)
abort 'Usage: ruby Scripts/check_post_release_docs.rb [fixture-root]' unless ARGV.empty?
begin
  releases = JSON.parse(File.read("#{root}/Scripts/published-releases.json", encoding: 'UTF-8')).fetch('releases')
  abort 'published releases must be a nonempty array' unless releases.is_a?(Array) && !releases.empty?
  releases.each do |release|
    version = release.fetch('version')
    abort 'invalid published version' unless version.match?(/\A\d+\.\d+\.\d+\z/)
    Time.iso8601(release.fetch('publishedAt'))
    abort 'invalid release evidence URL' unless release.fetch('url') == "https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/#{version}"
  end
rescue JSON::ParserError, KeyError, Errno::ENOENT, ArgumentError => error
  abort "post-release-docs: invalid publication evidence: #{error.message}"
end

# Current adoption guidance only. Historical validation and archived release
# documents retain their original candidate/Ready statements as dated evidence.
paths = %w[README.md API_STABILITY.md CHANGELOG.md docs/CI_Doc.md docs/Migration-6.0.0.md docs/Migration-EncodedRequests.md]
paths += Dir.glob('Sources/**/*.docc/**/*.md', base: root)
failures = []
checked_paths = 0
paths.uniq.each do |path|
  next unless File.file?("#{root}/#{path}")
  checked_paths += 1
  text = File.read("#{root}/#{path}", encoding: 'UTF-8').gsub(/\s+/, ' ')
  releases.each do |release|
    version = release.fetch('version')
    [version, version.sub(/\.0\z/, '')].uniq.each do |spelling|
      escaped = Regexp.escape(spelling)
      patterns = [
        /\buntil #{escaped}\b is (?:tagged|published|released)\b/i,
        /\b#{escaped}\b is (?:not(?: yet)? published|unpublished)\b/i,
        /\bnot[- ]yet[- ]published #{escaped}\b/i
      ]
      failures << "#{path}: published #{version} still described as pending publication" if patterns.any? { |pattern| text.match?(pattern) }
    end
  end
end
abort failures.uniq.join("\n") unless failures.empty?
puts "Post-release adoption docs: #{checked_paths} paths checked against recorded publication evidence."
