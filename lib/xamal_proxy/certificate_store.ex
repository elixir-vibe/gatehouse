defmodule XamalProxy.CertificateStore do
  @moduledoc """
  Behaviour for certificate storage used by TLS and future ACME automation.
  """

  @type cert :: %{required(:cert) => binary(), required(:key) => binary()}

  @callback get(String.t(), keyword()) :: {:ok, cert()} | {:error, term()}
  @callback put(String.t(), cert(), keyword()) :: :ok | {:error, term()}
end
