defmodule Cerno.Repo do
  use Ecto.Repo,
    otp_app: :cerno,
    adapter: Ecto.Adapters.Postgres
end
