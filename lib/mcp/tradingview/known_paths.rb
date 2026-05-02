# frozen_string_literal: true

module MCP
  module TradingView
    # JS expressions for TradingView's internal globals. These were discovered
    # by live probing of the desktop app and may break across app updates;
    # treat them as load-bearing assumptions, not stable API.
    module KnownPaths
      CHART_API              = 'window.TradingViewApi._activeChartWidgetWV.value()'
      CHART_WIDGET_COLLECTION = 'window.TradingViewApi._chartWidgetCollection'
      BOTTOM_WIDGET_BAR      = 'window.TradingView.bottomWidgetBar'
      REPLAY_API             = 'window.TradingViewApi._replayApi'
      MAIN_SERIES_BARS       = 'window.TradingViewApi._activeChartWidgetWV.value()._chartWidget.model().mainSeries().bars()'
      PINE_FACADE            = 'https://pine-facade.tradingview.com/pine-facade'

      module_function

      # Verifies a global path resolves to a non-null value, then returns it
      # as a JS expression string ready for further interpolation. Tools call
      # this so a clear error surfaces if a TV update moves the global.
      def verify(session, path, name = path)
        ok = session.evaluate("typeof (#{path}) !== 'undefined' && (#{path}) !== null")
        raise NotAvailable, "#{name} not available at #{path}" unless ok

        path
      end

      class NotAvailable < StandardError; end
    end
  end
end
