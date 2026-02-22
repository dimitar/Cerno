defmodule Cerno.Formatter do
  @moduledoc """
  Behaviour for agent-specific output formatters.

  Different AI agents consume context differently. The formatter
  adapts resolved principles into the format expected by the target
  agent (CLAUDE.md for Claude, system prompts for ChatGPT, etc.).
  """

  @type section :: %{
          heading: String.t(),
          content: String.t(),
          principles: [map()]
        }

  @doc """
  Format a list of resolved principles into agent-specific sections.

  Returns formatted text ready for injection into the agent's context.
  """
  @callback format_sections(principles :: [map()], opts :: keyword()) :: String.t()

  @doc """
  Maximum output size in tokens for this agent type.
  Used to truncate/prioritize when there are too many principles.
  """
  @callback max_output_tokens() :: pos_integer()

  @doc "Get the configured default formatter module."
  @spec default() :: module()
  def default do
    Application.get_env(:cerno, :formatter, Cerno.Formatter.Claude)
  end
end
