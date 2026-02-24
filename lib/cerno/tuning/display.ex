defmodule Cerno.Tuning.Display do
  @moduledoc """
  Pure string-building functions for formatting tuning data.

  No IO — returns strings with ANSI codes for terminal display.
  """

  # --- Primitives ---

  @spec truncate(String.t() | nil, pos_integer()) :: String.t()
  def truncate(nil, _max), do: ""
  def truncate("", _max), do: ""

  def truncate(string, max) when byte_size(string) <= max, do: string

  def truncate(string, max) do
    String.slice(string, 0, max - 3) <> "..."
  end

  @spec header(String.t()) :: String.t()
  def header(text) do
    line = String.duplicate("═", String.length(text) + 4)
    IO.ANSI.bright() <> "\n#{line}\n  #{text}\n#{line}\n" <> IO.ANSI.reset()
  end

  @spec section(String.t(), String.t()) :: String.t()
  def section(title, body) do
    IO.ANSI.bright() <> "\n── #{title} ──\n" <> IO.ANSI.reset() <> body <> "\n"
  end

  @spec color_for_confidence(float()) :: String.t()
  def color_for_confidence(conf) when conf >= 0.7, do: IO.ANSI.green()
  def color_for_confidence(conf) when conf >= 0.4, do: IO.ANSI.yellow()
  def color_for_confidence(_conf), do: IO.ANSI.red()

  @spec color_for_status(atom()) :: String.t()
  def color_for_status(:active), do: IO.ANSI.green()
  def color_for_status(:contradicted), do: IO.ANSI.red()
  def color_for_status(:superseded), do: IO.ANSI.faint()
  def color_for_status(:pending_review), do: IO.ANSI.yellow()
  def color_for_status(:decaying), do: IO.ANSI.yellow()
  def color_for_status(:pruned), do: IO.ANSI.faint()
  def color_for_status(_), do: IO.ANSI.reset()

  # --- Table ---

  @spec table([map()], [atom()]) :: String.t()
  def table([], _columns), do: "  No data.\n"

  def table(rows, columns) do
    headers = Enum.map(columns, &humanize_column/1)
    str_rows = Enum.map(rows, fn row ->
      Enum.map(columns, fn col -> format_cell_value(Map.get(row, col)) end)
    end)

    widths =
      Enum.zip(headers, Enum.zip(str_rows))
      |> Enum.map(fn {header, col_vals} ->
        col_vals = Tuple.to_list(col_vals)
        max(String.length(header), Enum.max_by(col_vals, &String.length/1) |> String.length())
      end)

    header_line = format_row(headers, widths)
    separator = Enum.map(widths, &String.duplicate("─", &1)) |> Enum.join("──┼──") |> then(&("  #{&1}"))

    data_lines = Enum.map(str_rows, &format_row(&1, widths))

    Enum.join([header_line, separator | data_lines], "\n") <> "\n"
  end

  defp format_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map(fn {cell, width} -> String.pad_trailing(cell, width) end)
    |> Enum.join("  │  ")
    |> then(&("  #{&1}"))
  end

  defp humanize_column(atom) do
    atom
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_cell_value(nil), do: "—"
  defp format_cell_value(val) when is_atom(val), do: Atom.to_string(val)
  defp format_cell_value(val) when is_float(val), do: :erlang.float_to_binary(val, decimals: 2)
  defp format_cell_value(val) when is_integer(val), do: Integer.to_string(val)
  defp format_cell_value(val) when is_list(val), do: Enum.join(val, ", ")
  defp format_cell_value(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_cell_value(val) when is_binary(val), do: val
  defp format_cell_value(val), do: inspect(val)

  # --- Data-type formatters ---

  @spec format_insight_list([map()]) :: String.t()
  def format_insight_list(insights) do
    rows = Enum.map(insights, fn i ->
      %{
        id: i.id,
        category: i.category,
        status: i.status,
        confidence: i.confidence,
        domain: i.domain,
        content: truncate(i.content, 60)
      }
    end)

    header("Insights") <> table(rows, [:id, :category, :status, :confidence, :domain, :content])
  end

  @spec format_insight_detail(map()) :: String.t()
  def format_insight_detail(insight) do
    fields = [
      {"ID", insight.id},
      {"Category", insight.category},
      {"Status", insight.status},
      {"Confidence", insight.confidence},
      {"Domain", insight.domain || "—"},
      {"Tags", Enum.join(insight.tags || [], ", ")},
      {"Observations", insight.observation_count},
      {"First Seen", insight.first_seen_at},
      {"Last Seen", insight.last_seen_at}
    ]

    field_lines = Enum.map(fields, fn {label, val} ->
      "  #{String.pad_trailing(label, 14)} #{format_cell_value(val)}"
    end) |> Enum.join("\n")

    content_section = section("Content", "  #{insight.content}")

    sources = Map.get(insight, :sources, [])
    sources_section = section("Sources",
      if(sources == [],
        do: "  None",
        else: Enum.map(sources, fn s -> "  • #{s.source_project}: #{s.source_path}" end) |> Enum.join("\n")
      )
    )

    clusters = Map.get(insight, :clusters, [])
    clusters_section = section("Clusters",
      if(clusters == [],
        do: "  None",
        else: Enum.map(clusters, fn c -> "  • #{c.name || "Cluster ##{c.id}"}" end) |> Enum.join("\n")
      )
    )

    contradictions =
      Map.get(insight, :contradictions_as_first, []) ++ Map.get(insight, :contradictions_as_second, [])

    contradictions_section = section("Contradictions",
      if(contradictions == [],
        do: "  None",
        else: Enum.map(contradictions, fn c ->
          "  • [#{c.resolution_status}] #{c.contradiction_type} (similarity: #{format_cell_value(c.similarity_score)})"
        end) |> Enum.join("\n")
      )
    )

    derived = Map.get(insight, :derived_principles, [])
    derived_section = section("Derived Principles",
      if(derived == [],
        do: "  None",
        else: Enum.map(derived, fn p -> "  • ##{p.id} (rank: #{format_cell_value(p.rank)}) #{truncate(p.content, 60)}" end) |> Enum.join("\n")
      )
    )

    header("Insight ##{insight.id}") <>
      field_lines <> "\n" <>
      content_section <>
      sources_section <>
      clusters_section <>
      contradictions_section <>
      derived_section
  end

  @spec format_principle_list([map()]) :: String.t()
  def format_principle_list(principles) do
    rows = Enum.map(principles, fn p ->
      %{
        id: p.id,
        category: p.category,
        status: p.status,
        rank: p.rank,
        domains: Enum.join(p.domains || [], ", "),
        content: truncate(p.content, 60)
      }
    end)

    header("Principles") <> table(rows, [:id, :category, :status, :rank, :domains, :content])
  end

  @spec format_principle_detail(map()) :: String.t()
  def format_principle_detail(principle) do
    fields = [
      {"ID", principle.id},
      {"Category", principle.category},
      {"Status", principle.status},
      {"Rank", principle.rank},
      {"Confidence", principle.confidence},
      {"Frequency", principle.frequency},
      {"Recency", principle.recency_score},
      {"Quality", principle.source_quality},
      {"Domains", Enum.join(principle.domains || [], ", ")},
      {"Tags", Enum.join(principle.tags || [], ", ")}
    ]

    field_lines = Enum.map(fields, fn {label, val} ->
      "  #{String.pad_trailing(label, 14)} #{format_cell_value(val)}"
    end) |> Enum.join("\n")

    content_section = section("Content", "  #{principle.content}")

    elaboration_section =
      if principle.elaboration do
        section("Elaboration", "  #{principle.elaboration}")
      else
        ""
      end

    derivations = Map.get(principle, :derivations, [])
    derivations_section = section("Derivations",
      if(derivations == [],
        do: "  None",
        else: Enum.map(derivations, fn d ->
          insight = Map.get(d, :insight, nil)
          insight_text = if insight, do: truncate(insight.content, 50), else: "Insight ##{d.insight_id}"
          "  • weight: #{format_cell_value(d.contribution_weight)} — #{insight_text}"
        end) |> Enum.join("\n")
      )
    )

    links_out = Map.get(principle, :links_as_source, [])
    links_in = Map.get(principle, :links_as_target, [])

    links_section = section("Links",
      if(links_out == [] and links_in == [],
        do: "  None",
        else:
          (Enum.map(links_out, fn l ->
            target = Map.get(l, :target, nil)
            target_text = if target, do: truncate(target.content, 40), else: "##{l.target_id}"
            "  → #{l.link_type} #{target_text} (#{format_cell_value(l.strength)})"
          end) ++
          Enum.map(links_in, fn l ->
            source = Map.get(l, :source, nil)
            source_text = if source, do: truncate(source.content, 40), else: "##{l.source_id}"
            "  ← #{l.link_type} from #{source_text} (#{format_cell_value(l.strength)})"
          end)) |> Enum.join("\n")
      )
    )

    breakdown = Map.get(principle, :rank_breakdown, %{})
    breakdown_section = section("Rank Breakdown",
      if(breakdown == %{},
        do: "  Not available",
        else: Enum.map(breakdown, fn {k, v} ->
          "  #{String.pad_trailing(to_string(k), 14)} #{format_cell_value(v)}"
        end) |> Enum.join("\n")
      )
    )

    header("Principle ##{principle.id}") <>
      field_lines <> "\n" <>
      content_section <>
      elaboration_section <>
      derivations_section <>
      links_section <>
      breakdown_section
  end

  @spec format_fragment_list([map()]) :: String.t()
  def format_fragment_list(fragments) do
    rows = Enum.map(fragments, fn f ->
      {start_line, end_line} = f.line_range || {0, 0}
      %{
        section_heading: f.section_heading,
        line_range: "L#{start_line}–#{end_line}",
        content: truncate(f.content, 70)
      }
    end)

    header("Fragments") <> table(rows, [:section_heading, :line_range, :content])
  end

  @spec format_stats(map()) :: String.t()
  def format_stats(stats) do
    insights = Map.get(stats, :insights, %{})
    principles = Map.get(stats, :principles, %{})
    contradictions = Map.get(stats, :contradictions, %{})
    clusters = Map.get(stats, :clusters, %{})

    header("Pipeline Stats") <>
      section("Insights (#{Map.get(insights, :total, 0)})",
        format_breakdown("By Status", Map.get(insights, :by_status, %{})) <>
        format_breakdown("By Category", Map.get(insights, :by_category, %{})) <>
        format_breakdown("Top Domains", Map.get(insights, :top_domains, %{}))
      ) <>
      section("Principles (#{Map.get(principles, :total, 0)})",
        format_breakdown("By Status", Map.get(principles, :by_status, %{})) <>
        format_breakdown("By Category", Map.get(principles, :by_category, %{}))
      ) <>
      section("Contradictions (#{Map.get(contradictions, :total, 0)})",
        format_breakdown("By Status", Map.get(contradictions, :by_status, %{}))
      ) <>
      section("Clusters (#{Map.get(clusters, :total, 0)})", "")
  end

  defp format_breakdown(_title, map) when map == %{}, do: ""
  defp format_breakdown(title, map) do
    items = Enum.map(map, fn {k, v} -> "    #{k}: #{v}" end) |> Enum.join("\n")
    "  #{title}:\n#{items}\n"
  end
end
