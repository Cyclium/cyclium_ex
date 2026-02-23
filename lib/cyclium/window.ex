defmodule Cyclium.Window do
  @moduledoc """
  Clock-aligned dedupe bucket helpers.

  All functions are pure — no state, no side effects. Use `bucket/2` to
  generate a deterministic, time-bounded string key for deduplication.

  ## Bucket Sizes

    - `:h4`  — 4-hour windows aligned to 00, 04, 08, 12, 16, 20 UTC
    - `:h24` — daily (midnight UTC boundary)
    - `:h48` — every-other-day by ordinal day of year
    - `:w1`  — ISO week (Monday 00:00 UTC boundary)

  ## Examples

      iex> Cyclium.Window.bucket(:h4, ~U[2026-02-23 13:45:00Z])
      "2026-02-23T12"

      iex> Cyclium.Window.bucket(:h24, ~U[2026-02-23 13:45:00Z])
      "2026-02-23"
  """

  @type window_size :: :h4 | :h24 | :h48 | :w1

  @spec bucket(window_size(), DateTime.t()) :: String.t()
  def bucket(:h4, %DateTime{} = dt) do
    slot = div(dt.hour, 4) * 4
    "#{Date.to_iso8601(DateTime.to_date(dt))}T#{pad(slot)}"
  end

  def bucket(:h24, %DateTime{} = dt) do
    Date.to_iso8601(DateTime.to_date(dt))
  end

  def bucket(:h48, %DateTime{} = dt) do
    date = DateTime.to_date(dt)
    day = Date.day_of_year(date)
    slot = div(day - 1, 2) * 2 + 1
    "#{date.year}-d#{pad(slot, 3)}"
  end

  def bucket(:w1, %DateTime{} = dt) do
    date = DateTime.to_date(dt)
    # Walk back to Monday of this ISO week
    dow = Date.day_of_week(date)
    monday = Date.add(date, -(dow - 1))
    # Compute ISO year and week from the Monday
    {iso_year, iso_week} = iso_week_number(monday)
    "#{iso_year}-W#{pad(iso_week)}"
  end

  defp pad(n, width \\ 2), do: String.pad_leading(to_string(n), width, "0")

  defp iso_week_number(date) do
    # ISO 8601: week 1 contains the first Thursday of the year.
    # The Thursday of the same ISO week as `date`:
    dow = Date.day_of_week(date)
    thursday = Date.add(date, 4 - dow)
    iso_year = thursday.year
    jan1 = Date.new!(iso_year, 1, 1)
    week = div(Date.diff(thursday, jan1), 7) + 1
    {iso_year, week}
  end
end
