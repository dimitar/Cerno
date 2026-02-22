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
    formatter = Keyword.get(opts, :agent, Cerno.Formatter.default())
    dry_run? = Keyword.get(opts, :dry_run, false)

    Logger.info("Resolving principles into #{path}")

    # TODO Phase 5: implement full resolution pipeline
    # For now, return a placeholder
    principles = []
    formatted = formatter.format_sections(principles, opts)

    if dry_run? do
      {:ok, formatted}
    else
      inject_into_file(path, formatted)
    end
  end

  defp inject_into_file(path, formatted_section) do
    case File.read(path) do
      {:ok, content} ->
        new_content = replace_or_append_section(content, formatted_section)
        File.write(path, new_content)

      {:error, :enoent} ->
        File.write(path, formatted_section)

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
