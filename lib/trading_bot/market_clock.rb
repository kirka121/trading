# frozen_string_literal: true

module TradingBot
  # US equity regular session: 9:30am – 4:00pm America/New_York, Mon–Fri.
  # Holidays are not handled — Questrade rejects out-of-session orders anyway.
  module MarketClock
    REGULAR_OPEN_HHMM  = 930
    REGULAR_CLOSE_HHMM = 1600

    module_function

    def open?(now: Time.now)
      weekday, hhmm = ny_weekday_and_hhmm(now)
      return false if weekday.nil? || weekday > 5
      hhmm >= REGULAR_OPEN_HHMM && hhmm < REGULAR_CLOSE_HHMM
    end

    # Shells out to `date` because Ruby stdlib has no IANA tz support without
    # the tzinfo gem. Fast enough for one call per pipeline run.
    def ny_weekday_and_hhmm(now)
      formatted = `TZ=America/New_York date -j -f "%s" #{now.to_i} "+%u %H%M"`.strip
      weekday_str, hhmm_str = formatted.split
      return [nil, nil] if weekday_str.nil? || hhmm_str.nil?

      [weekday_str.to_i, hhmm_str.to_i]
    end
  end
end
