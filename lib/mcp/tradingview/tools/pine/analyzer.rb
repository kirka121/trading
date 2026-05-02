# frozen_string_literal: true

module MCP
  module TradingView
    module Tools
      module Pine
        # Pure-Ruby static analyzer for Pine Script. Catches a small, stable
      # set of bugs cheaply — array out-of-bounds, empty-array first/last,
      # strategy.* without a strategy() declaration. Anything subtler should
      # go through Compiler for the real server-side check.
      #
      # No CDP, no network — safe to call without a TradingView connection.
      module Analyzer
        Diagnostic = Struct.new(:line, :column, :message, :severity, keyword_init: true) do
          def to_h
            { line: line, column: column, message: message, severity: severity }
          end
        end

        ARRAY_FROM_RE   = /(\w+)\s*=\s*array\.from\(([^)]*)\)/
        ARRAY_NEW_RE    = /(\w+)\s*=\s*array\.new(?:<\w+>|_\w+)\((\d+)?/
        ARRAY_ACCESS_RE = /array\.(get|set)\(\s*(\w+)\s*,\s*(-?\d+)/
        FIRST_LAST_RE   = /(\w+)\.(first|last)\(\)/
        VERSION_RE      = %r{//@version=(\d+)}

        ArrayInfo = Struct.new(:name, :size, :line, keyword_init: true)

        module_function

        def analyze(source)
          lines = source.split("\n")
          diagnostics = []
          arrays = collect_arrays(lines)

          diagnostics.concat(check_bounds(lines, arrays))
          diagnostics.concat(check_first_last_on_empty(lines, arrays))
          diagnostics.concat(check_strategy_declaration(lines))
          diagnostics.concat(check_version(source))

          {
            success:     true,
            issue_count: diagnostics.size,
            diagnostics: diagnostics.map(&:to_h),
            note:        diagnostics.empty? ? 'No static analysis issues found. Use pine_compile or pine_smart_compile for a full server-side check.' : nil
          }.compact
        end

        def collect_arrays(lines)
          arrays = {}
          lines.each_with_index do |line, i|
            if (m = line.match(ARRAY_FROM_RE))
              args = m[2].strip
              size = args.empty? ? 0 : args.split(',').size
              arrays[m[1].strip] = ArrayInfo.new(name: m[1].strip, size: size, line: i + 1)
            elsif (m = line.match(ARRAY_NEW_RE))
              size = m[2].nil? ? nil : Integer(m[2])
              arrays[m[1].strip] = ArrayInfo.new(name: m[1].strip, size: size, line: i + 1)
            end
          end
          arrays
        end

        def check_bounds(lines, arrays)
          diagnostics = []
          lines.each_with_index do |line, i|
            line.scan(ARRAY_ACCESS_RE) do |method, name, idx|
              info = arrays[name]
              next if info.nil? || info.size.nil?

              idx_int = Integer(idx)
              next if (0...info.size).cover?(idx_int)

              column = (line =~ ARRAY_ACCESS_RE) + 1
              diagnostics << Diagnostic.new(
                line: i + 1, column: column, severity: 'error',
                message: "array.#{method}(#{name}, #{idx_int}) — index #{idx_int} out of bounds (array size is #{info.size})"
              )
            end
          end
          diagnostics
        end

        def check_first_last_on_empty(lines, arrays)
          diagnostics = []
          lines.each_with_index do |line, i|
            line.scan(FIRST_LAST_RE) do |name, method|
              next if name == 'array'

              info = arrays[name]
              next unless info && info.size&.zero?

              column = (line =~ FIRST_LAST_RE) + 1
              diagnostics << Diagnostic.new(
                line: i + 1, column: column, severity: 'warning',
                message: "#{name}.#{method}() called on possibly empty array (declared with size 0)"
              )
            end
          end
          diagnostics
        end

        def check_strategy_declaration(lines)
          uses_strategy = lines.any? { |l| l.include?('strategy.entry') || l.include?('strategy.close') }
          return [] unless uses_strategy

          declared = lines.any? { |l| l.strip.start_with?('strategy(') }
          return [] if declared

          line = lines.find_index { |l| l.include?('strategy.entry') || l.include?('strategy.close') }
          [
            Diagnostic.new(
              line: (line || 0) + 1, column: 1, severity: 'error',
              message: 'strategy.entry/close used but no strategy() declaration found — did you mean to use indicator()?'
            )
          ]
        end

        def check_version(source)
          version_line = source.lines.find { |l| l.start_with?('//@version=') }
          return [] unless version_line
          return [] unless (m = version_line.match(VERSION_RE))

          version = Integer(m[1])
          return [] if version >= 5

          [Diagnostic.new(line: 1, column: 1, severity: 'info',
                          message: "Script uses Pine v#{version} — consider upgrading to v6 for latest features")]
        end
      end
      end
    end
  end
end
