defmodule Cerno.Process.Resolver do
  @moduledoc """
  GenServer that handles resolution (Long-Term → Atomic).

  Resolution steps:
  1. Parse current CLAUDE.md, compute embeddings
  2. Retrieve relevant principles: 50% semantic + 30% rank + 20% domain
  3. Filter already-represented principles, flag contradictions
  4. Format per agent type (pluggable formatter)
  5. Inject into dedicated section — never overwrite human content
  """

  use GenServer
  require Logger

  alias Cerno.LongTerm.Retriever
  alias Cerno.{ResolutionRun, Security}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolve principles into a CLAUDE.md file.

  Options:
  - `:agent` - formatter module (default: Cerno.Formatter.Claude)
  - `:dry_run` - if true, returns formatted text without writing (default: false)
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(path, opts \\ []) do
    GenServer.call(__MODULE__, {:resolve, path, opts}, 60_000)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cerno.PubSub, "resolution:requested")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:resolve, path, opts}, _from, state) do
    result = run_resolution(path, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:resolve_requested, path, opts}, state) do
    run_resolution(path, opts)
    {:noreply, state}
  end

  defp run_resolution(path, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      do_resolution(path, opts)
    else
      with {:ok, validated} <- Security.validate_path(path) do
        do_resolution(validated, opts)
      end
    end
  end

  defp do_resolution(path, opts) do
    formatter = Keyword.get(opts, :agent, Cerno.Formatter.default())
    dry_run? = Keyword.get(opts, :dry_run, false)
    agent_type = formatter |> Module.split() |> List.last() |> String.downcase()

    Logger.info("Resolving principles into #{path}")

    # Step 1: Start audit log
    {:ok, run} = ResolutionRun.start(path, agent_type)

    try do
      # Step 2: Read current file content (for domain detection and filtering)
      file_content = read_file_content(path)

      # Step 3: Retrieve relevant principles
      {:ok, scored} = Retriever.retrieve_for_file(file_content, opts)

      # Step 4: Filter already-represented and detect conflicts
      {kept, conflicts} =
        case Retriever.embed_file_sections(file_content) do
          {:ok, section_embeddings} when section_embeddings != [] ->
            Retriever.filter_already_represented(scored, section_embeddings, opts)

          _ ->
            {scored, []}
        end

      # Step 5: Build final principles list (conflicts get [CONFLICT] prefix)
      all_principles = build_principle_list(kept, conflicts)

      # Step 6: Format
      formatted = formatter.format_sections(all_principles, opts)

      # Step 7: Complete audit log
      ResolutionRun.complete(run, %{
        principles_resolved: length(kept),
        conflicts_detected: length(conflicts)
      })

      Logger.info("Resolution complete: #{length(kept)} principles, #{length(conflicts)} conflicts")

      # Step 8: Write or return
      if dry_run? do
        {:ok, formatted}
      else
        inject_into_file(path, formatted)
      end
    rescue
      e ->
        ResolutionRun.fail(run)
        Logger.error("Resolution failed: #{inspect(e)}")
        {:error, e}
    end
  end

  defp read_file_content(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp build_principle_list(kept, conflicts) do
    kept_principles = Enum.map(kept, fn {p, _score} -> p end)

    conflict_principles =
      Enum.map(conflicts, fn {p, _score} ->
        %{p | content: "[CONFLICT] #{p.content}"}
      end)

    kept_principles ++ conflict_principles
  end

  defp inject_into_file(path, formatted_section) do
    case File.read(path) do
      {:ok, content} ->
        new_content = replace_or_append_section(content, formatted_section)

        case File.write(path, new_content) do
          :ok -> {:ok, new_content}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        case File.write(path, formatted_section) do
          :ok -> {:ok, formatted_section}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @section_marker "## Resolved Knowledge from Cerno"

  defp replace_or_append_section(content, new_section) do
    if String.contains?(content, @section_marker) do
      # Replace existing section (from marker to next H2 or end of file)
      parts = String.split(content, @section_marker, parts: 2)
      before = String.trim_trailing(Enum.at(parts, 0))

      after_section =
        case parts do
          [_, rest] ->
            case Regex.run(~r/\n(## [^#])/s, rest) do
              [_, _next_heading] ->
                idx = :binary.match(rest, "\n## ") |> elem(0)
                String.slice(rest, idx..-1//1)

              nil ->
                ""
            end

          _ ->
            ""
        end

      "#{before}\n\n#{new_section}#{after_section}"
    else
      "#{String.trim_trailing(content)}\n\n#{new_section}\n"
    end
  end
end
