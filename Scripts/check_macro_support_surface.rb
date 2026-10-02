#!/usr/bin/env ruby
require 'json'
root = File.expand_path('..', __dir__)
graph_dir = Dir.glob(File.join(root, '.build', '*', 'symbolgraph')).max_by { |path| File.mtime(path) }
abort 'Run the docs symbol-graph extraction first' unless graph_dir
graph = File.join(graph_dir, 'InnoNetworkMacroSupport.symbols.json')
abort 'Shared compiler-host symbol graph is missing' unless File.file?(graph)
symbols = JSON.parse(File.read(graph)).fetch('symbols')
actual = symbols.select { |symbol| symbol['accessLevel'] == 'public' && symbol.dig('identifier', 'precise').start_with?('s:23InnoNetworkMacroSupport') }
                .map { |symbol| [symbol.dig('kind', 'identifier'), symbol.fetch('pathComponents').join('.')].join("\t") }.uniq.sort
expected = File.readlines(File.join(root, 'Scripts/symbols/macro-support.tsv'), chomp: true).sort
abort "Compiler-host API drift: added=#{actual - expected}; removed=#{expected - actual}" unless actual == expected
puts "Compiler-host API: #{actual.length} declarations (separate from runtime budget)"
