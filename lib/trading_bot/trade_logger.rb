# frozen_string_literal: true

require 'csv'
require 'json'

module TradingBot
  # Persists every pipeline run to two artifacts:
  #   • trades.csv             — tax-ready, one row per decision
  #   • safety-check-log.json  — full structured audit trail
  #
  # The Pipeline calls #record(entry_hash) once per run.
  class TradeLogger
    CSV_HEADERS = [
      'Date', 'Time (UTC)', 'Broker', 'Symbol', 'Side', 'Quantity', 'Price',
      'Total USD', 'Fee (est.)', 'Net Amount', 'Order ID', 'Mode', 'Notes'
    ].freeze

    # Fee placeholder used in tax records — Questrade actual fees vary by plan;
    # this is a rough notional estimate, not a true execution cost.
    ESTIMATED_FEE_RATE = 0.001

    def initialize(csv_path: 'trades.csv', json_path: 'safety-check-log.json')
      @csv_path  = csv_path
      @json_path = json_path
    end

    def load_decision_log
      return { 'trades' => [] } unless File.exist?(@json_path)
      JSON.parse(File.read(@json_path))
    end

    def count_todays_orders(decision_log)
      today = Time.now.utc.strftime('%Y-%m-%d')
      decision_log['trades'].count do |t|
        t['timestamp'].to_s.start_with?(today) && t['order_placed']
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

    def print_tax_summary
      unless File.exist?(@csv_path)
        puts 'No trades.csv found — no trades have been recorded yet.'
        return
      end

      rows = CSV.read(@csv_path, headers: true)
      grouped = rows.group_by { |r| r['Mode'] }
      live    = grouped['LIVE']     || []
      practice= grouped['PRACTICE'] || []
      paper   = grouped['PAPER']    || []
      blocked = grouped['BLOCKED']  || []

      puts "\n── Tax Summary ──────────────────────────────────────────"
      puts "  Total decisions logged : #{rows.length}"
      puts "  Live trades            : #{live.length}"
      puts "  Practice trades        : #{practice.length}"
      puts "  Paper-only             : #{paper.length}"
      puts "  Blocked by safety check: #{blocked.length}"
      puts "  Live volume (USD)      : $#{format('%.2f', live.sum { |r| r['Total USD'].to_f })}"
      puts "  Live fees paid (est.)  : $#{format('%.4f', live.sum { |r| r['Fee (est.)'].to_f })}"
      puts "\n  Full record: #{@csv_path}"
      puts '─────────────────────────────────────────────────────────'
    end

    private

    def append_decision_log(entry)
      log = load_decision_log
      log['trades'] << entry
      File.write(@json_path, JSON.pretty_generate(log))
    end

    def append_csv_row(entry)
      initialize_csv_if_missing
      ts   = Time.parse(entry.fetch('timestamp')).utc
      row  = build_csv_row(entry, ts)
      CSV.open(@csv_path, 'a') { |csv| csv << row }
    end

    def build_csv_row(entry, timestamp)
      date = timestamp.strftime('%Y-%m-%d')
      time = timestamp.strftime('%H:%M:%S')

      if entry['all_pass']
        executed_row(entry, date, time)
      else
        blocked_row(entry, date, time)
      end
    end

    def executed_row(entry, date, time)
      total_usd  = entry['trade_size'].to_f
      fee        = total_usd * ESTIMATED_FEE_RATE
      net_amount = total_usd - fee
      mode       = if entry['paper_trading']
                     'PAPER'
                   elsif entry['practice']
                     'PRACTICE'
                   else
                     'LIVE'
                   end
      notes = entry['error'] ? "Error: #{entry['error']}" : 'All conditions met'

      [
        date, time, 'Questrade', entry['symbol'], entry['side'],
        entry['quantity'], format('%.2f', entry['price']),
        format('%.2f', total_usd), format('%.4f', fee), format('%.2f', net_amount),
        entry['order_id'], mode, notes
      ]
    end

    def blocked_row(entry, date, time)
      failed = entry['conditions'].reject { |c| c['pass'] }.map { |c| c['label'] }.join('; ')
      [
        date, time, 'Questrade', entry['symbol'], '', '', format('%.2f', entry['price']),
        '', '', '', 'BLOCKED', 'BLOCKED', "Failed: #{failed}"
      ]
    end
  end
end
