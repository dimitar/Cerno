defmodule Cerno.Tuning do
  @moduledoc """
  Interactive tuning facade for IEx exploration.

  Combines `Tuning.Inspect` (data queries) with `Tuning.Display` (formatting)
  and outputs to stdout. Designed for `alias Cerno.Tuning, as: T` in IEx.
  """

  alias Cerno.Tuning.{Inspect, Display, Promote}

  @config_groups [:dedup, :ranking, :decay, :promotion, :resolution, :embedding]

  def stats do
    Inspect.stats() |> Display.format_stats() |> IO.puts()
  end

  def insights(opts \\ []) do
    Inspect.list_insights(opts) |> Display.format_insight_list() |> IO.puts()
  end

  def insight(id) do
    case Inspect.get_insight(id) do
      {:ok, data} -> Display.format_insight_detail(data) |> IO.puts()
      {:error, :not_found} -> IO.puts("Insight ##{id} not found.")
    end
  end

  def principles(opts \\ []) do
    Inspect.list_principles(opts) |> Display.format_principle_list() |> IO.puts()
  end

  def principle(id) do
    case Inspect.get_principle(id) do
      {:ok, data} -> Display.format_principle_detail(data) |> IO.puts()
      {:error, :not_found} -> IO.puts("Principle ##{id} not found.")
    end
  end

  def fragments(path) do
    case Inspect.list_fragments(path) do
      {:ok, frags} -> Display.format_fragment_list(frags) |> IO.puts()
      {:error, reason} -> IO.puts("Error reading fragments: #{inspect(reason)}")
    end
  end

  def config do
    output =
      Display.header("Configuration") <>
        Enum.map_join(@config_groups, "\n", fn group ->
          values = Application.get_env(:cerno, group, [])
          Display.section(to_string(group), format_config_values(values))
        end)

    IO.puts(output)
  end

  def config(group) when is_atom(group) do
    values = Application.get_env(:cerno, group, [])

    output =
      Display.header("Config: #{group}") <>
        Display.section(to_string(group), format_config_values(values))

    IO.puts(output)
  end

  def eligible?(id) do
    case Promote.explain_eligibility(id) do
      {:error, :not_found} -> IO.puts("Insight ##{id} not found.")
      result -> Display.format_eligibility(result) |> IO.puts()
    end
  end

  def promotion_overview do
    Promote.promotion_summary() |> Display.format_promotion_summary() |> IO.puts()
  end

  def what_if_promote(id) do
    case Promote.what_if_promote(id) do
      {:error, :not_found} -> IO.puts("Insight ##{id} not found.")
      result -> Display.format_what_if(result) |> IO.puts()
    end
  end

  defp format_config_values(values) when is_list(values) do
    Enum.map_join(values, "\n", fn {k, v} ->
      "  #{String.pad_trailing(to_string(k), 30)} #{inspect(v)}"
    end)
  end

  defp format_config_values(other) do
    "  #{inspect(other)}"
  end
end
