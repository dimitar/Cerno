defmodule Cerno.LLM.ClaudeCli do
  @moduledoc """
  Evaluates fragment quality by shelling out to the `claude` CLI.

  Extracts multiple distilled learnings from CLAUDE.md fragments, filtering out
  structural/metadata content (headings, directory trees, config blocks) and
  producing focused, concise knowledge items with category, tags, and domain.

  Falls back to the heuristic `Cerno.ShortTerm.Classifier` when the CLI is
  unavailable or returns an error.
  """

  require Logger

  @valid_categories ~w(convention principle technique warning preference fact pattern)

  @type learning :: %{
          content: String.t(),
          category: atom(),
          tags: [String.t()],
          domain: String.t() | nil,
          source_sections: [String.t()]
        }

  @doc """
  Evaluate all fragments from a file in a single CLI call.

  Sends the full file context so the LLM can infer cross-cutting principles
  that span multiple sections. Each returned learning is tagged with its
  source section heading(s) for linking back to fragments.

  Returns:
  - `{:ok, [learning]}` — list of distilled learnings
  - `{:error, reason}` — CLI failure; caller should fall back to heuristic
  """
  @spec evaluate_file([map()]) :: {:ok, [learning()]} | {:error, term()}
  def evaluate_file(fragments) when is_list(fragments) do
    prompt = build_file_prompt(fragments)

    case run_cli(prompt) do
      {:ok, json_string} ->
        parse_response(json_string)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def build_file_prompt(fragments) do
    sections =
      fragments
      |> Enum.with_index(1)
      |> Enum.map(fn {f, i} ->
        heading = f.section_heading || "(preamble)"
        "### Section #{i}: #{heading}\n#{f.content}"
      end)
      |> Enum.join("\n\n---\n\n")

    """
    You are reading the full contents of a CLAUDE.md project context file, split into sections.
    Your job is to infer the IMPLICIT working knowledge — the rules, gotchas, and principles
    that an experienced developer on this project would have internalized.

    DO NOT just summarize or rephrase what the text says. Instead, ask yourself:
    - What mistakes could someone make if they didn't deeply understand this project?
    - What cross-cutting concerns connect different sections? (e.g. if there are both Windows
      and macOS build scripts, the principle is "always update both platforms when changing builds")
    - What invariants or constraints does the project establish?
    - What workflow rules are implied but not stated as explicit rules?

    Each learning should be an imperative directive that prevents a real mistake or captures
    essential project knowledge. Skip purely structural content (file listings, constant tables,
    directory trees) unless they imply a principle.

    For each learning, include which section(s) it was inferred from.

    #{sections}

    Respond with ONLY a JSON object, no markdown fences:
    {"learnings": [{"content": "<imperative directive — what to do/avoid and why>", "category": "<convention|principle|technique|warning|preference|fact|pattern>", "tags": ["tag1", "tag2"], "domain": "<cpp|elixir|javascript|python|...or null>", "source_sections": ["Section heading 1", "Section heading 2"]}, ...]}
    """
  end

  @cli_timeout_ms 30_000

  defp run_cli(prompt) do
    tmp_path = Path.join(System.tmp_dir!(), "cerno_prompt_#{:erlang.unique_integer([:positive])}.txt")
    File.write!(tmp_path, prompt)

    # Use shell piping to avoid command-line length limits
    shell_cmd =
      case :os.type() do
        {:win32, _} ->
          win_path = String.replace(tmp_path, "/", "\\")
          ~c'type "#{win_path}" | claude -p --output-format json 2>&1'

        _ ->
          ~c'cat "#{tmp_path}" | claude -p --output-format json 2>&1'
      end

    task =
      Task.async(fn ->
        try do
          output = :os.cmd(shell_cmd) |> List.to_string()
          {output, 0}
        rescue
          e -> {"Error: #{inspect(e)}", 1}
        after
          File.rm(tmp_path)
        end
      end)

    case Task.yield(task, @cli_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, exit_code}} ->
        Logger.warning("Claude CLI exited with code #{exit_code}: #{String.slice(output, 0, 200)}")
        {:error, {:exit_code, exit_code, output}}

      nil ->
        File.rm(tmp_path)
        Logger.warning("Claude CLI timed out after #{@cli_timeout_ms}ms")
        {:error, :timeout}
    end
  rescue
    e in ErlangError ->
      Logger.warning("Claude CLI not available: #{inspect(e)}")
      {:error, :cli_not_found}
  end

  @doc false
  def parse_response(json_string) do
    # The CLI with --output-format json wraps the response — extract the inner result
    with {:ok, decoded} <- decode_json(json_string),
         {:ok, result} <- extract_result(decoded) do
      case result do
        %{"learnings" => learnings} when is_list(learnings) ->
          {:ok, normalize_learnings(learnings)}

        # Backwards-compat: actionable/non-actionable per-fragment format
        %{"actionable" => true, "learnings" => learnings} when is_list(learnings) ->
          {:ok, normalize_learnings(learnings)}

        %{"actionable" => true} = classification ->
          {:ok, [normalize_classification(classification)]}

        %{"actionable" => false, "reason" => reason} ->
          {:skip, reason}

        %{"actionable" => false} ->
          {:skip, "not actionable"}

        _ ->
          {:error, :unexpected_format}
      end
    end
  end

  defp decode_json(string) do
    # Try to parse the string directly, or extract JSON from it
    string = String.trim(string)

    case Jason.decode(string) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, _} ->
        # Try extracting JSON object from the string (CLI may include extra text)
        case Regex.run(~r/\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/s, string) do
          [json] -> Jason.decode(json)
          _ -> {:error, :no_json_found}
        end
    end
  end

  defp extract_result(%{"result" => result}) when is_binary(result) do
    # --output-format json wraps text in {"result": "..."} — parse inner JSON
    decode_json(result)
  end

  defp extract_result(%{"result" => result}) when is_map(result) do
    {:ok, result}
  end

  defp extract_result(result) when is_map(result) do
    # Direct JSON response (no wrapper)
    {:ok, result}
  end

  defp extract_result(_), do: {:error, :unexpected_format}

  defp normalize_learnings(learnings) do
    learnings
    |> Enum.map(&normalize_learning/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_learning(learning) when is_map(learning) do
    content = Map.get(learning, "content")

    if is_binary(content) and content != "" do
      category = normalize_category(Map.get(learning, "category", "fact"))
      tags = Map.get(learning, "tags", []) |> Enum.map(&to_string/1) |> Enum.take(5)
      domain = Map.get(learning, "domain")
      domain = if domain in [nil, "null", ""], do: nil, else: to_string(domain)
      source_sections = Map.get(learning, "source_sections", []) |> Enum.map(&to_string/1)

      %{content: content, category: category, tags: tags, domain: domain, source_sections: source_sections}
    else
      nil
    end
  end

  defp normalize_learning(_), do: nil

  # Backwards-compat: single classification without content/learnings array
  defp normalize_classification(classification) do
    category = normalize_category(Map.get(classification, "category", "fact"))
    tags = Map.get(classification, "tags", []) |> Enum.map(&to_string/1) |> Enum.take(5)
    domain = Map.get(classification, "domain")
    domain = if domain in [nil, "null", ""], do: nil, else: to_string(domain)
    content = Map.get(classification, "summary")

    %{content: content, category: category, tags: tags, domain: domain, source_sections: []}
  end

  defp normalize_category(category) when is_binary(category) do
    if category in @valid_categories do
      # Safe: values are from the known @valid_categories allowlist
      String.to_atom(category)
    else
      :fact
    end
  end

  defp normalize_category(_), do: :fact
end
