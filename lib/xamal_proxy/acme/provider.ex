defmodule XamalProxy.ACME.Provider do
  @moduledoc """
  Behaviour for future ACME integrations.

  ACME is intentionally outside the proxy switching core. Implementations can
  wrap `ex_acme` or a different backend without changing routing
  and drain logic.
  """

  @type domain :: String.t()
  @type certificate :: %{
          required(:cert_pem) => binary(),
          required(:key_pem) => binary(),
          optional(:chain_pem) => binary(),
          optional(:expires_at) => DateTime.t()
        }

  @callback order_certificate([domain()], keyword()) :: {:ok, certificate()} | {:error, term()}
  @callback renew_certificate(certificate(), keyword()) :: {:ok, certificate()} | {:error, term()}
  @callback revoke_certificate(certificate(), keyword()) :: :ok | {:error, term()}
end
