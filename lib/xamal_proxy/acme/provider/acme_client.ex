defmodule XamalProxy.Acme.Provider.AcmeClient do
  @moduledoc """
  Prototype adapter boundary for the Erlang `acme_client` package.

  The dependency is intentionally not added yet. This module documents the shape
  of the integration and fails explicitly until the ACME phase begins.
  """

  @behaviour XamalProxy.Acme.Provider

  @impl XamalProxy.Acme.Provider
  def order_certificate(domains, opts) when is_list(domains) and is_list(opts) do
    {:error, {:not_implemented, :acme_client_adapter}}
  end

  @impl XamalProxy.Acme.Provider
  def renew_certificate(certificate, opts) when is_map(certificate) and is_list(opts) do
    {:error, {:not_implemented, :acme_client_adapter}}
  end

  @impl XamalProxy.Acme.Provider
  def revoke_certificate(certificate, opts) when is_map(certificate) and is_list(opts) do
    {:error, {:not_implemented, :acme_client_adapter}}
  end
end
