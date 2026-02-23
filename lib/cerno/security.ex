defmodule Cerno.Security do
  @moduledoc """
  Security utilities for path validation and input sanitization.
  """

  @doc """
  Validate that a path is safe to operate on.

  Checks:
  - Path exists after expansion
  - Path is not a symlink (prevents symlink-based traversal)

  Returns `{:ok, expanded_path}` or `{:error, reason}`.
  """
  @spec validate_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate_path(path) do
    expanded = Path.expand(path)

    case File.lstat(expanded) do
      {:ok, %{type: :symlink}} ->
        {:error, :symlink_not_allowed}

      {:ok, _} ->
        {:ok, expanded}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
