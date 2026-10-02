#!/usr/bin/env ruby
# Keep the protected aggregate fail-closed and all former smoke checks blocking.
require 'yaml'

module ConsumerCIContract
  LANES = %w[consumer-examples consumer-macros consumer-openapi].freeze
  COMMANDS = {
    'consumer-examples' => [
      'bash Scripts/check_macro_trait_graphs.sh',
      'bash Scripts/check_core_trait_build.sh',
      'bash Scripts/build_consumer_examples.sh',
      'xcrun swift run --package-path Examples/MacroAdopterSmoke',
      'xcrun swift run --package-path Examples/OpenAPIAdopterSmoke'
    ],
    'consumer-macros' => [
      'xcrun swift test --disable-experimental-prebuilts --filter InnoNetworkMacroTests --enable-code-coverage',
      'bash Scripts/check_macro_compile_failures.sh',
      'bash Scripts/generate_coverage_report.sh .build .build/coverage-macros Sources/InnoNetworkMacros'
    ],
    'consumer-openapi' => ['xcrun swift build', 'xcrun swift test',
                           'bash Scripts/test_openapi_generated_output.sh']
  }.freeze

  def self.require!(condition, message)
    raise ArgumentError, message unless condition
  end

  def self.command(step)
    step.fetch('run', '').gsub("\\\n", ' ').split.join(' ')
  end

  def self.validate(workflow, action)
    jobs = workflow.fetch('jobs')
    gate = jobs.fetch('consumer-smoke')
    require!(gate['name'] == "${{ (github.event_name == 'pull_request' && (((github.event.action == 'labeled' || github.event.action == 'unlabeled') && github.event.label.name && github.event.label.name != 'release-validation' && github.event.label.name != 'concurrency-review') || (github.event.action == 'edited' && !github.event.changes.base))) && 'Consumer Metadata Only' || 'Consumer Smoke' }}", 'protected check name changed')
    require!(gate['needs'].is_a?(Array) && gate['needs'].sort == (LANES + ['ci-plan']).sort,
             'aggregate must need exactly all three lanes')
    require!(gate['if'] == "${{ always() && !(github.event_name == 'pull_request' && (((github.event.action == 'labeled' || github.event.action == 'unlabeled') && github.event.label.name && github.event.label.name != 'release-validation' && github.event.label.name != 'concurrency-review') || (github.event.action == 'edited' && !github.event.changes.base))) && fromJSON(needs.ci-plan.outputs.plan).jobs.consumer-smoke }}", 'aggregate must run even after child failure')
    require!(gate['runs-on'] == 'ubuntu-latest', 'aggregate must not occupy a macOS runner')
    require!(!gate.key?('continue-on-error'), 'aggregate may not ignore failure')
    check = gate.fetch('steps').find { |s| command(s) == 'python3 Scripts/check_consumer_ci_results.py' }
    require!(check && !check.key?('if') && !check.key?('continue-on-error') &&
             check.dig('env', 'CONSUMER_JOB_RESULTS') == '{"consumer-examples": ${{ toJSON(needs.consumer-examples) }}, "consumer-macros": ${{ toJSON(needs.consumer-macros) }}, "consumer-openapi": ${{ toJSON(needs.consumer-openapi) }}}' ,
             'aggregate must validate actual needs without skipping')

    COMMANDS.each do |id, required|
      job = jobs.fetch(id)
      require!(job['runs-on'] == 'macos-15', "#{id}: pinned runner changed")
      require!(job['if'] == "fromJSON(needs.ci-plan.outputs.plan).jobs.#{id}" && job['needs'] == 'ci-plan' && !job.key?('continue-on-error'),
               "#{id}: lane must be independent and unconditional")
      steps = job.fetch('steps')
      require!(steps.none? { |s| s.key?('continue-on-error') }, "#{id}: soft failure is forbidden")
      required.each do |expected|
        matches = steps.select { |s| command(s) == expected }
        require!(matches.length == 1 && !matches.first.key?('if'),
                 "#{id}: missing, duplicate or conditional command #{expected}")
      end
      select = steps.index { |s| command(s) == 'sudo xcode-select -s /Applications/Xcode_26.0.1.app' }
      cache = steps.index { |s| s['uses'] == './.github/actions/consumer-cache' }
      require!(select && cache && select < cache, "#{id}: fingerprint must follow Xcode selection")
      require!(steps[cache].dig('with', 'lane') == id.delete_prefix('consumer-'), "#{id}: wrong cache lane")
    end

    %w[xcrun\ swift\ build xcrun\ swift\ test].each do |cmd|
      step = jobs['consumer-openapi']['steps'].find { |s| command(s) == cmd }
      require!(step['working-directory'] == 'Tools/openapi-to-innonetwork', 'OpenAPI tool working directory changed')
    end
    artifact = jobs['consumer-macros']['steps'].find { |s| s.dig('with', 'name') == 'innonetwork-coverage-macros' }
    require!(artifact && artifact['if'] == 'always()' &&
             artifact.dig('with', 'if-no-files-found') == 'error' &&
             artifact.dig('with', 'path') == '.build/coverage-macros/' &&
             artifact.fetch('uses', '').start_with?('actions/upload-artifact@'),
             'macro artifact must fail if missing')
    require!(jobs.dig('upload-macro-coverage', 'needs') == ['ci-plan', 'consumer-macros'], 'coverage must depend on its producer')

    require!(action.dig('runs', 'using') == 'composite' &&
             action.dig('inputs', 'lane', 'required') == true, 'cache action must require a lane')
    cache_steps = action.fetch('runs').fetch('steps')
    require!(cache_steps.length == 3 && cache_steps.none? { |s| s.key?('if') || s.key?('continue-on-error') },
             'cache action must fingerprint and restore without bypassing validation')
    require!(cache_steps[0]['id'] == 'fingerprint' &&
             cache_steps[0]['run'] == 'python3 Scripts/consumer_ci_cache.py "$CONSUMER_CACHE_LANE" --github-output' &&
             cache_steps[0].dig('env', 'CONSUMER_CACHE_LANE') == '${{ inputs.lane }}', 'cache fingerprint missing')
    cache = cache_steps[1]
    require!(cache.fetch('uses', '').match?(/\Aactions\/cache@[0-9a-f]{40}\z/), 'cache action must stay pinned')
    require!(cache['with'] == {
      'path' => '${{ steps.fingerprint.outputs.dependency-paths }}',
      'key' => '${{ steps.fingerprint.outputs.dependency-key }}'
    }, 'cache must not fall back across toolchain/dependency/lane boundaries')
    require!(cache['id'] == 'dependency-cache', 'exact dependency cache observation source changed')
    observed = cache_steps[2]
    require!(observed['shell'] == 'bash' &&
             observed['run'] == 'python3 -B Scripts/ci-cache.py restored --profile "consumer-$CONSUMER_CACHE_LANE"' &&
             observed['env'] == {
               'CONSUMER_CACHE_LANE' => '${{ inputs.lane }}',
               'DEPENDENCY_CACHE_HIT' => '${{ steps.dependency-cache.outputs.cache-hit }}'
             }, 'consumer cache must observe the matching exact dependency restore')
    true
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('..', __dir__)
  ConsumerCIContract.validate(
    YAML.safe_load(File.read("#{root}/.github/workflows/ci.yml")),
    YAML.safe_load(File.read("#{root}/.github/actions/consumer-cache/action.yml"))
  )
  puts 'consumer-ci-contract: OK (three blocking lanes, protected aggregate, isolated cache)'
end
