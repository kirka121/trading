# frozen_string_literal: true

require 'csv'
require 'json'

module TradingBot
  # Persists every pipeline run to two artifacts:
  #   • trades.csv             — one row per decision, human-readable
  #   • safety-check-log.json  — full structured audit trail
  #
  # The bot never executes orders — these files record what the strategies
  # *decided*, not what was filled.
  class TradeLogger
    CSV_HEADERS = [
      'Date', 'Time (UTC)', 'Symbol', 'Strategy', 'Timeframe',
      'Status', 'Side', 'Quantity', 'Entry', 'Stop', 'Target',
      'Hold Horizon', 'Notes'
    ].freeze

    def initialize(csv_path: 'trades.csv', json_path: 'safety-check-log.json')
      @csv_path  = csv_path
      @json_path = json_path
    end

    # Resilient load: missing file, empty file, or malformed JSON all resolve
    # to an empty log instead of crashing the bot. Malformed content gets a
    # one-line warning to stderr so the user notices without losing the run.
    def load_decision_log
      return { 'trades' => [] } unless File.exist?(@json_path)

      raw = File.read(@json_path)
      return { 'trades' => [] } if raw.strip.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) && parsed['trades'].is_a?(Array) ? parsed : { 'trades' => [] }
    rescue JSON::ParserError => e
      warn "decision log unreadable (#{e.message[0, 80]}) — starting fresh"
      { 'trades' => [] }
    end

    # Count today's finalized BUY/SELL decisions (`all_pass: true` with a
    # non-nil side). The bot caps how many of these get logged per day so a
    # mis-specified strategy doesn't fire repeatedly on every poll.
    def count_todays_decisions(decision_log)
      today = Time.now.utc.strftime('%Y-%m-%d')
      decision_log['trades'].count do |t|
        t['timestamp'].to_s.start_with?(today) && t['all_pass'] && t['side']
      end
    end

    def initialize_csv_if_missing
      return if File.exist?(@csv_path)

      CSV.open(@csv_path, 'w') { |csv| csv << CSV_HEADERS }
    end

    # Append one decision to both the JSON log and the CSV.
    def record(entry)
      append_decision_log(entry)
      append_csv_row(entry)
    end

    private

    def append_decision_log(entry)
      log = load_decision_log
      log['trades'] << entry
      File.write(@json_path, JSON.pretty_generate(log))
    end

    def append_csv_row(entry)
      initialize_csv_if_missing
      ts  = Time.parse(entry.fetch('timestamp')).utc
      row = build_csv_row(entry, ts)
      CSV.open(@csv_path, 'a') { |csv| csv << row }
    end

    def build_csv_row(entry, timestamp)
      date = timestamp.strftime('%Y-%m-%d')
      time = timestamp.strftime('%H:%M:%S')
      entry['all_pass'] ? finalized_row(entry, date, time) : blocked_row(entry, date, time)
    end

    def finalized_row(entry, date, time)
      levels = entry['levels'] || {}
      [
        date, time, entry['symbol'], entry['strategy'], entry['timeframe'],
        'FINALIZED', entry['side'], entry['quantity'],
        fmt(levels['entry']), fmt(levels['stop']), fmt(levels['target']),
        entry['hold_horizon'], 'All conditions met'
      ]
    end

    def blocked_row(entry, date, time)
      failed = (entry['conditions'] || []).reject { |c| c['pass'] }.map { |c| c['label'] }.join('; ')
      [
        date, time, entry['symbol'], entry['strategy'], entry['timeframe'],
        'BLOCKED', '', '', fmt(entry['price']), '', '', '',
        "Failed: #{failed}"
      ]
    end

    def fmt(value)
      return '' if value.nil?

      format('%.2f', value)
    end
  end
end
