defmodule Gatehouse.LiveryOptions do
  @moduledoc false

  alias Gatehouse.ACME
  alias Gatehouse.Config
  alias Gatehouse.Config.Listener

  def service_options(handler) do
    :gatehouse
    |> Application.get_env(:listeners, [])
    |> listeners_to_service_options(handler)
  end

  def from_config(%Config{} = config) do
    from_config_listeners(config.listeners, ACME.Config.sni_ssl_opts(config))
  end

  def from_config_listeners(listeners, extra_ssl_opts \\ []) do
    Enum.map(listeners, fn
      %Listener{} = listener ->
        listener
        |> Map.from_struct()
        |> listener_to_opts(extra_ssl_opts)
        |> Map.put(:scheme, listener.scheme)

      %{scheme: scheme} = listener ->
        listener
        |> listener_to_opts(extra_ssl_opts)
        |> Map.put(:scheme, scheme)
    end)
  end

  defp listeners_to_service_options(listeners, handler) do
    listeners
    |> Enum.reduce(%{handler: handler}, &put_listener/2)
    |> reject_nil_protocols()
  end

  defp put_listener(%{scheme: :http} = listener, opts),
    do: Map.put(opts, :http, listener_to_opts(listener))

  defp put_listener(%{scheme: :https} = listener, opts),
    do: Map.put(opts, :https, listener_to_opts(listener))

  defp listener_to_opts(%Listener{} = listener) do
    listener
    |> Map.from_struct()
    |> listener_to_opts()
  end

  defp listener_to_opts(listener, extra_ssl_opts \\ []) do
    listener
    |> maybe_put_extra_ssl_opts(extra_ssl_opts)
    |> prefer_tls_paths()
    |> Map.take([:ip, :port, :cert, :key, :ssl_opts, :transport])
    |> Enum.reject(fn
      {:ssl_opts, []} -> true
      {_key, value} -> is_nil(value)
    end)
    |> Map.new()
  end

  defp maybe_put_extra_ssl_opts(%{scheme: :https, ssl_opts: ssl_opts} = listener, extra_ssl_opts) do
    if Keyword.has_key?(ssl_opts, :sni_fun) do
      listener
    else
      Map.put(listener, :ssl_opts, ssl_opts ++ extra_ssl_opts)
    end
  end

  defp maybe_put_extra_ssl_opts(listener, _extra_ssl_opts), do: listener

  defp prefer_tls_paths(%{cert_path: cert_path, key_path: key_path} = listener) do
    listener
    |> put_path(:cert, cert_path)
    |> put_path(:key, key_path)
  end

  defp prefer_tls_paths(listener), do: listener

  defp put_path(listener, _key, nil), do: listener
  defp put_path(listener, key, path), do: Map.put(listener, key, path)

  defp reject_nil_protocols(opts) do
    opts
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
