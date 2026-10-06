#!/usr/bin/env ruby
require 'fileutils'
require 'open3'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
Dir.mktmpdir('innonetwork-periphery-contract-') do |fixture|
  FileUtils.mkdir_p("#{fixture}/Scripts")
  FileUtils.cp("#{root}/Scripts/check_periphery.sh", "#{fixture}/Scripts/")
  wrapper = "#{fixture}/Scripts/check_periphery.sh"
  stub = "#{fixture}/periphery"
  File.write(stub, <<~'RUBY')
    #!/usr/bin/env ruby
    if ARGV == ['version']
      puts ENV.fetch('FIXTURE_VERSION', '3.8.0')
    else
      expected = ['scan', '--config', '.periphery.yml', '--', '--build-system', 'native']
      abort "Unexpected scan arguments: #{ARGV}" unless ARGV == expected
      File.write(ENV.fetch('FIXTURE_MARKER'), Dir.pwd)
      exit Integer(ENV.fetch('FIXTURE_SCAN_STATUS', '0'))
    end
  RUBY
  FileUtils.chmod(0o755, stub)
  marker = "#{fixture}/scan-marker"
  env = { 'PERIPHERY_BIN' => stub, 'FIXTURE_MARKER' => marker }
  output, status = Open3.capture2e(env, 'bash', wrapper)
  abort "Successful scan failed: #{output}" unless status.success? && File.realpath(File.read(marker)) == File.realpath(fixture)
  FileUtils.rm(marker)

  output, status = Open3.capture2e(env.merge('FIXTURE_SCAN_STATUS' => '1'), 'bash', wrapper)
  abort "Strict failure was lost: #{output}" unless status.exitstatus == 1 && File.exist?(marker)
  FileUtils.rm(marker)
  output, status = Open3.capture2e(env.merge('FIXTURE_VERSION' => '3.7.0'), 'bash', wrapper)
  abort "Version mismatch was ignored: #{output}" unless status.exitstatus == 69 && !File.exist?(marker)
  output, status = Open3.capture2e(env.merge('PERIPHERY_BIN' => "#{fixture}/missing"), 'bash', wrapper)
  abort "Missing tool was ignored: #{output}" unless status.exitstatus == 69 && !File.exist?(marker)
end
ci = File.read("#{root}/.github/workflows/ci.yml")
abort 'CI Periphery version changed without updating the local contract' unless ci.include?('PERIPHERY_VERSION: "3.8.0"')
puts 'Local Periphery contract fixtures: 4 passed.'
