# frozen_string_literal: true

require 'mcp'
require 'mcp/server/transports/stdio_transport'

require_relative 'tradingview/cdp/target_finder'
require_relative 'tradingview/cdp/client'
require_relative 'tradingview/known_paths'
require_relative 'tradingview/chart_ready_waiter'
require_relative 'tradingview/session'
require_relative 'tradingview/tools/base'
require_relative 'tradingview/tools/tab'
require_relative 'tradingview/tools/chart'
require_relative 'tradingview/tools/drawing'
require_relative 'tradingview/tools/replay'
require_relative 'tradingview/tools/pine'
require_relative 'tradingview/tools/watchlist'

module MCP
  # TradingView Desktop bridge — exposes ~30 tools (chart, tab, drawing,
  # replay, pine) to MCP clients over stdio. Each tool calls into the
  # singleton CDP Session that talks to the live TradingView page over the
  # Chrome DevTools Protocol.
  #
  # Run via `bin/tradingview-mcp` (or whatever entry script your client
  # configures in .mcp.json).
  module TradingView
    NAME    = 'tradingview'
    VERSION = '0.1.0'

    INSTRUCTIONS = <<~TEXT
      TradingView MCP (Ruby port) — drive a live TradingView Desktop chart.

      Reading the chart:
      - chart_get_state → symbol, timeframe, type, indicators (call first to find entity_ids)

      Changing the chart:
      - chart_set_symbol, chart_set_timeframe, chart_set_type
      - chart_manage_indicator (USE FULL NAMES: "Relative Strength Index", not "RSI")

      Tabs (one per chart): tab_list, tab_new, tab_close, tab_switch

      Pine Script:
      - pine_get_source / pine_set_source — read/write the editor
      - pine_smart_compile — apply + report errors + study-added flag
      - pine_check (offline against pine-facade) and pine_analyze (pure-Ruby static checks)

      Drawings: draw_shape, draw_list, draw_get_properties, draw_remove_one, draw_clear
      Replay:   replay_start, replay_step, replay_autoplay, replay_stop, replay_status, replay_trade

      The bot itself does NOT use this MCP — it pulls market data from Questrade.
    TEXT

    # Every concrete tool subclass we want exposed.
    def self.tools
      [
        Tools::Tab::List, Tools::Tab::New, Tools::Tab::Close, Tools::Tab::Switch,
        Tools::Chart::GetState, Tools::Chart::SetSymbol, Tools::Chart::SetTimeframe,
        Tools::Chart::SetType, Tools::Chart::ManageIndicator,
        Tools::Drawing::Shape, Tools::Drawing::List, Tools::Drawing::GetProperties,
        Tools::Drawing::RemoveOne, Tools::Drawing::Clear,
        Tools::Replay::Start, Tools::Replay::Step, Tools::Replay::Autoplay,
        Tools::Replay::Stop, Tools::Replay::Trade, Tools::Replay::Status,
        Tools::Pine::Analyze, Tools::Pine::Check, Tools::Pine::GetSource,
        Tools::Pine::SetSource, Tools::Pine::GetErrors, Tools::Pine::New,
        Tools::Pine::ListScripts, Tools::Pine::OpenScript,
        Tools::Pine::Compile, Tools::Pine::Save, Tools::Pine::SmartCompile,
        Tools::Pine::GetConsole,
        Tools::Watchlist::Get, Tools::Watchlist::Add,
        Tools::Watchlist::AddCurrentChartSymbol,
        Tools::Watchlist::Remove, Tools::Watchlist::Set,
        Tools::Watchlist::SyncBotSection
      ]
    end

    # Build (but don't start) an MCP::Server with all tools registered.
    # Useful for tests that want to send fake requests in-process without
    # spawning the stdio transport.
    def self.build_server
      ::MCP::Server.new(
        name:         NAME,
        version:      VERSION,
        instructions: INSTRUCTIONS,
        tools:        tools
      )
    end

    # Run the stdio server. Blocks until stdin closes / SIGINT.
    # The "unofficial tool" notice goes to stderr so it doesn't pollute the
    # JSON-RPC stream the MCP client is reading from stdout.
    def self.run!
      $stderr.puts "⚠  tradingview-mcp (Ruby)  |  Unofficial tool. Not affiliated with TradingView Inc. or Anthropic."
      $stderr.puts '   Ensure your usage complies with TradingView\'s Terms of Use.'
      ::MCP::Server::Transports::StdioTransport.new(build_server).open
    end
  end
end
