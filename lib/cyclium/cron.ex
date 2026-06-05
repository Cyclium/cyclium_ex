defmodule Cyclium.Cron do
  @moduledoc """
  Minimal **UTC** cron expression parser and next-occurrence calculator, backing
  the native `{:cron, spec}` expectation trigger.

  ## Supported syntax

  Standard 5-field crontab: `minute hour day-of-month month day-of-week`.

    * `*` — every value
    * `a` — a single value
    * `a-b` — an inclusive range
    * `a,b,c` — a list
    * `*/n`, `a-b/n` — steps

  Day-of-week is `0..6` with Sunday = 0 (`7` is also accepted as Sunday).
  When **both** day-of-month and day-of-week are restricted (neither is `*`), a
  timestamp matches if **either** field matches — the standard Vixie-cron rule.

  ## Macros

      @yearly / @annually   0 0 1 1 *
      @monthly              0 0 1 * *
      @weekly               0 0 * * 0
      @daily / @midnight    0 0 * * *
      @hourly               0 * * * *

  ## Time zone

  All matching and `next/2` math are in **UTC**. There is no time-zone or DST
  handling — `"0 5 * * *"` means 05:00 UTC, every day.

  ## Examples

      iex> {:ok, c} = Cyclium.Cron.parse("0 5 * * *")
      iex> Cyclium.Cron.next(c, ~U[2026-06-05 04:59:30Z])
      ~U[2026-06-05 05:00:00Z]
  """

  # We define our own match?/2; shadow the Kernel macro to avoid the conflict.
  import Kernel, except: [match?: 2]

  @enforce_keys [:minute, :hour, :dom, :month, :dow]
  defstruct [:minute, :hour, :dom, :month, :dow, dom_restricted: false, dow_restricted: false]

  @type t :: %__MODULE__{
          minute: MapSet.t(),
          hour: MapSet.t(),
          dom: MapSet.t(),
          month: MapSet.t(),
          dow: MapSet.t(),
          dom_restricted: boolean(),
          dow_restricted: boolean()
        }

  @macros %{
    "@yearly" => "0 0 1 1 *",
    "@annually" => "0 0 1 1 *",
    "@monthly" => "0 0 1 * *",
    "@weekly" => "0 0 * * 0",
    "@daily" => "0 0 * * *",
    "@midnight" => "0 0 * * *",
    "@hourly" => "0 * * * *"
  }

  @bounds %{minute: {0, 59}, hour: {0, 23}, dom: {1, 31}, month: {1, 12}, dow: {0, 6}}

  # Cover the widest legitimate gap (Feb 29 → ~4 years between occurrences);
  # beyond this we treat the spec as impossible (e.g. Feb 30) and raise.
  @max_search_minutes 4 * 366 * 24 * 60

  @doc """
  Parse a cron expression (or macro) into a `t/0`. Returns `{:error, reason}`
  for malformed input.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(spec) when is_binary(spec) do
    trimmed = String.trim(spec)
    expanded = Map.get(@macros, trimmed, trimmed)

    case String.split(expanded, ~r/\s+/, trim: true) do
      [minute, hour, dom, month, dow] ->
        with {:ok, minutes} <- field(minute, :minute),
             {:ok, hours} <- field(hour, :hour),
             {:ok, doms} <- field(dom, :dom),
             {:ok, months} <- field(month, :month),
             {:ok, dows} <- field(dow, :dow) do
          {:ok,
           %__MODULE__{
             minute: minutes,
             hour: hours,
             dom: doms,
             month: months,
             dow: dows,
             dom_restricted: dom != "*",
             dow_restricted: dow != "*"
           }}
        end

      fields ->
        {:error, {:expected_5_fields, length(fields)}}
    end
  end

  def parse(other), do: {:error, {:not_a_string, other}}

  @doc "Raising variant of `parse/1` — used for boot-time validation."
  @spec parse!(String.t()) :: t()
  def parse!(spec) do
    case parse(spec) do
      {:ok, cron} ->
        cron

      {:error, reason} ->
        raise ArgumentError, "invalid cron expression #{inspect(spec)}: #{inspect(reason)}"
    end
  end

  @doc "Returns true if `dt` (UTC) matches the cron expression."
  @spec match?(t(), DateTime.t()) :: boolean()
  def match?(%__MODULE__{} = cron, %DateTime{} = dt) do
    MapSet.member?(cron.minute, dt.minute) and
      MapSet.member?(cron.hour, dt.hour) and
      MapSet.member?(cron.month, dt.month) and
      day_match?(cron, dt)
  end

  @doc """
  First occurrence strictly after `from` (UTC), at second `:00`. Raises if no
  occurrence falls within 366 days (an impossible spec, e.g. Feb 30).
  """
  @spec next(t(), DateTime.t()) :: DateTime.t()
  def next(%__MODULE__{} = cron, %DateTime{} = from) do
    start = %{from | second: 0, microsecond: {0, 0}} |> DateTime.add(60, :second)
    search(cron, start, 0)
  end

  defp search(_cron, _dt, n) when n > @max_search_minutes do
    raise ArgumentError, "cron expression has no reachable occurrence (impossible date?)"
  end

  defp search(cron, dt, n) do
    if match?(cron, dt), do: dt, else: search(cron, DateTime.add(dt, 60, :second), n + 1)
  end

  defp day_match?(cron, dt) do
    dom_ok = MapSet.member?(cron.dom, dt.day)
    # Elixir: Monday=1..Sunday=7; cron: Sunday=0..Saturday=6.
    dow = rem(Date.day_of_week(DateTime.to_date(dt)), 7)
    dow_ok = MapSet.member?(cron.dow, dow)

    cond do
      cron.dom_restricted and cron.dow_restricted -> dom_ok or dow_ok
      cron.dom_restricted -> dom_ok
      cron.dow_restricted -> dow_ok
      true -> true
    end
  end

  # --- field parsing ---

  defp field("*", kind), do: {:ok, full_set(kind)}

  defp field(expr, kind) do
    expr
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case part_values(part, kind) do
        {:ok, set} -> {:cont, {:ok, MapSet.union(acc, set)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp part_values(part, kind) do
    {base, step_str} =
      case String.split(part, "/", parts: 2) do
        [b] -> {b, "1"}
        [b, s] -> {b, s}
      end

    with {:ok, step} <- positive_int(step_str),
         {:ok, lo, hi} <- base_range(base, kind) do
      {min, max} = @bounds[kind]
      values = lo..hi |> Enum.take_every(step) |> Enum.map(&normalize(&1, kind))

      cond do
        values == [] -> {:error, {:empty_part, part}}
        Enum.all?(values, &(&1 >= min and &1 <= max)) -> {:ok, MapSet.new(values)}
        true -> {:error, {:out_of_range, part, kind}}
      end
    end
  end

  defp base_range("*", kind) do
    {min, max} = @bounds[kind]
    {:ok, min, max}
  end

  defp base_range(base, _kind) do
    case String.split(base, "-", parts: 2) do
      [single] ->
        with {:ok, n} <- to_int(single), do: {:ok, n, n}

      [a, b] ->
        with {:ok, lo} <- to_int(a),
             {:ok, hi} <- to_int(b) do
          if lo <= hi, do: {:ok, lo, hi}, else: {:error, {:reversed_range, base}}
        end
    end
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:not_an_integer, s}}
    end
  end

  defp positive_int(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 1 -> {:ok, n}
      _ -> {:error, {:invalid_step, s}}
    end
  end

  # day-of-week 7 == Sunday == 0; every other value is identity.
  defp normalize(7, :dow), do: 0
  defp normalize(n, _kind), do: n

  defp full_set(kind) do
    {min, max} = @bounds[kind]
    MapSet.new(min..max)
  end
end
