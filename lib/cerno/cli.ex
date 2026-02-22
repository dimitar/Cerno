defmodule Cerno.CLI do
  @moduledoc """
  Command-line interface for Cerno.

  Commands:
    cerno init <path>                Register a project for watching
    cerno scan [<path>]              Scan project(s) for CLAUDE.md changes
    cerno resolve <path> [opts]      Resolve principles into a CLAUDE.md
    cerno status                     Show system status
    cerno insights                   List insights in short-term memory
    cerno principles                 List principles in long-term memory
    cerno reconcile                  Trigger reconciliation
    cerno organise                   Trigger organisation
    cerno daemon start|stop|status   Manage background daemon
  """

  alias Cerno.{Repo, WatchedProject}

  def main(args) do
    case args do
      ["init" | rest] -> cmd_init(rest)
      ["scan" | rest] -> cmd_scan(rest)
      ["resolve" | rest] -> cmd_resolve(rest)
      ["status" | _] -> cmd_status()
      ["insights" | _] -> cmd_insights()
      ["principles" | _] -> cmd_principles()
      ["reconcile" | _] -> cmd_reconcile()
      ["organise" | _] -> cmd_organise()
      ["daemon" | rest] -> cmd_daemon(rest)
      ["help" | _] -> cmd_help()
      [] -> cmd_help()
      _ -> IO.puts("Unknown command. Run 'cerno help' for usage.")
    end
  end

  defp cmd_init([path | _]) do
    path = Path.expand(path)
    name = Path.basename(path)

    case %WatchedProject{}
         |> WatchedProject.changeset(%{name: name, path: path})
         |> Repo.insert() do
      {:ok, _} ->
        IO.puts("Registered project: #{name} (#{path})")

      {:error, changeset} ->
        IO.puts("Error: #{inspect(changeset.errors)}")
    end
  end

  defp cmd_init([]) do
    IO.puts("Usage: cerno init <path>")
  end

  defp cmd_scan([path | _]) do
    IO.puts("Scanning #{path}...")
    Cerno.Process.Accumulator.accumulate(Path.expand(path))
    IO.puts("Scan triggered.")
  end

  defp cmd_scan([]) do
    IO.puts("Scanning all watched projects...")
    Cerno.Process.Accumulator.scan_all()
    IO.puts("Full scan triggered.")
  end

  defp cmd_resolve([path | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        switches: [agent: :string, dry_run: :boolean],
        aliases: [a: :agent, n: :dry_run]
      )

    dry_run? = Keyword.get(opts, :dry_run, false)

    case Cerno.Process.Resolver.resolve(Path.expand(path), dry_run: dry_run?) do
      {:ok, output} ->
        if dry_run? do
          IO.puts(output)
        else
          IO.puts("Resolved principles into #{path}")
        end

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp cmd_resolve([]) do
    IO.puts("Usage: cerno resolve <path> [--agent=claude --dry-run]")
  end

  defp cmd_status do
    projects = Repo.aggregate(WatchedProject, :count)
    IO.puts("Cerno Status")
    IO.puts("  Watched projects: #{projects}")
    IO.puts("  Status: running")
  end

  defp cmd_insights do
    import Ecto.Query

    insights =
      Cerno.ShortTerm.Insight
      |> where([i], i.status == :active)
      |> order_by([i], desc: i.confidence)
      |> limit(20)
      |> Repo.all()

    IO.puts("Active Insights (top 20 by confidence):")

    Enum.each(insights, fn i ->
      IO.puts(
        "  [#{i.category}] #{String.slice(i.content, 0..80)} (conf: #{Float.round(i.confidence, 2)}, obs: #{i.observation_count})"
      )
    end)
  end

  defp cmd_principles do
    import Ecto.Query

    principles =
      Cerno.LongTerm.Principle
      |> where([p], p.status == :active)
      |> order_by([p], desc: p.rank)
      |> limit(20)
      |> Repo.all()

    IO.puts("Active Principles (top 20 by rank):")

    Enum.each(principles, fn p ->
      IO.puts(
        "  [#{p.category}] #{String.slice(p.content, 0..80)} (rank: #{Float.round(p.rank, 2)})"
      )
    end)
  end

  defp cmd_reconcile do
    IO.puts("Triggering reconciliation...")
    Cerno.Process.Reconciler.reconcile()
    IO.puts("Reconciliation triggered.")
  end

  defp cmd_organise do
    IO.puts("Triggering organisation...")
    Cerno.Process.Organiser.organise()
    IO.puts("Organisation triggered.")
  end

  defp cmd_daemon(["start"]) do
    IO.puts("Daemon mode not yet implemented. Run as: mix run --no-halt")
  end

  defp cmd_daemon(["stop"]) do
    IO.puts("Daemon mode not yet implemented.")
  end

  defp cmd_daemon(["status"]) do
    IO.puts("Daemon mode not yet implemented.")
  end

  defp cmd_daemon(_) do
    IO.puts("Usage: cerno daemon start|stop|status")
  end

  defp cmd_help do
    IO.puts(@moduledoc)
  end
end
