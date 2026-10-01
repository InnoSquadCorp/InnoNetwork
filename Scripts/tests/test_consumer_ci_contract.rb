#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../check_consumer_ci_contract'

class ConsumerCIContractTest < Minitest::Test
  def setup
    root = File.expand_path('../..', __dir__)
    @workflow = YAML.safe_load(File.read("#{root}/.github/workflows/ci.yml"))
    @action = YAML.safe_load(File.read("#{root}/.github/actions/consumer-cache/action.yml"))
  end

  def validate
    ConsumerCIContract.validate(@workflow, @action)
  end

  def test_current_workflow
    assert validate
  end

  def test_missing_lane
    @workflow['jobs']['consumer-smoke']['needs'].pop
    assert_raises(ArgumentError) { validate }
  end

  def test_gate_skips_after_failure
    @workflow['jobs']['consumer-smoke'].delete('if')
    assert_raises(ArgumentError) { validate }
  end

  def test_lanes_cannot_skip_or_ignore_failure
    ConsumerCIContract::LANES.each do |id|
      %w[if continue-on-error needs].each do |key|
        old = @workflow['jobs'][id][key]
        @workflow['jobs'][id][key] = true
        assert_raises(ArgumentError) { validate }
        old.nil? ? @workflow['jobs'][id].delete(key) : @workflow['jobs'][id][key] = old
      end
    end
  end

  def test_every_required_command_remains_unconditional
    ConsumerCIContract::COMMANDS.each do |id, commands|
      commands.each do |cmd|
        steps = @workflow['jobs'][id]['steps']
        index = steps.index { |s| ConsumerCIContract.command(s) == cmd }
        step = steps.delete_at(index)
        assert_raises(ArgumentError) { validate }
        steps.insert(index, step)
        step['if'] = "steps.cache.outputs.cache-hit != 'true'"
        assert_raises(ArgumentError) { validate }
        step.delete('if')
      end
    end
  end

  def test_coverage_does_not_depend_on_aggregate
    @workflow['jobs']['upload-macro-coverage']['needs'] = 'consumer-smoke'
    assert_raises(ArgumentError) { validate }
  end

  def test_missing_coverage_is_not_ignored
    step = @workflow['jobs']['consumer-macros']['steps'].find { |s| s.dig('with', 'name') == 'innonetwork-coverage-macros' }
    step['with']['if-no-files-found'] = 'ignore'
    assert_raises(ArgumentError) { validate }
  end

  def test_cache_source_and_immutable_commit_are_required
    ['actions/cache@v6', 'attacker/cache@' + 'a' * 40, 'actions/cache@' + 'a' * 39].each do |source|
      @action['runs']['steps'][1]['uses'] = source
      assert_raises(ArgumentError) { validate }
    end
  end

  def test_no_broad_cache_fallback
    @action['runs']['steps'][1]['with']['restore-keys'] = 'consumer-'
    assert_raises(ArgumentError) { validate }
  end

  def test_cache_key_is_exact_without_commit_suffix
    @action['runs']['steps'][1]['with']['key'] += '${{ github.sha }}'
    assert_raises(ArgumentError) { validate }
  end

  def test_restore_observation_is_mandatory_and_bound_to_lane
    observation = @action['runs']['steps'][2]
    original = observation['env']['CONSUMER_CACHE_LANE']
    observation['env']['CONSUMER_CACHE_LANE'] = 'examples'
    assert_raises(ArgumentError) { validate }
    observation['env']['CONSUMER_CACHE_LANE'] = original
    observation['if'] = "steps.dependency-cache.outputs.cache-hit == 'true'"
    assert_raises(ArgumentError) { validate }
  end

  def test_no_early_cache_restore
    steps = @workflow['jobs']['consumer-macros']['steps']
    steps[1], steps[2] = steps[2], steps[1]
    assert_raises(ArgumentError) { validate }
  end
end
