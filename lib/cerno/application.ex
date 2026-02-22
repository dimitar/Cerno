defmodule Cerno.Application do
  @moduledoc """
  OTP Application for Cerno.

  Supervision tree:
    Cerno.Application
      ├── Cerno.Repo
      ├── {Phoenix.PubSub, name: Cerno.PubSub}
      ├── Cerno.Embedding.Pool
      ├── Cerno.Embedding.Cache
      ├── Cerno.Watcher.Registry
      ├── Cerno.Watcher.Supervisor (DynamicSupervisor)
      │     └── Cerno.Watcher.FileWatcher (per project)
      ├── Cerno.Process.TaskSupervisor
      ├── Cerno.Process.Accumulator
      ├── Cerno.Process.Reconciler
      ├── Cerno.Process.Organiser
      └── Cerno.Process.Resolver
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Database
      Cerno.Repo,

      # PubSub for event flow between processes
      {Phoenix.PubSub, name: Cerno.PubSub},

      # Embedding subsystem
      Cerno.Embedding.Pool,
      Cerno.Embedding.Cache,

      # File watching
      {Registry, keys: :unique, name: Cerno.Watcher.Registry},
      {DynamicSupervisor, name: Cerno.Watcher.Supervisor, strategy: :one_for_one},

      # Task supervisor for async work within processes
      {Task.Supervisor, name: Cerno.Process.TaskSupervisor},

      # Core processes (accumulation pipeline)
      Cerno.Process.Accumulator,
      Cerno.Process.Reconciler,
      Cerno.Process.Organiser,
      Cerno.Process.Resolver
    ]

    opts = [strategy: :one_for_one, name: Cerno.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
