defmodule XamalProxy.LiveryOptions do
  @moduledoc false

  alias XamalProxy.Config
  alias XamalProxy.Config.Listener

  def service_options(handler) do
    :xamal_proxy
    |> Application.get_env(:listeners, [])
    |> listeners_to_service_options(handler)
  end

  def from_config(%Config{} = config) do
    from_config_listeners(config.listeners)
  end

  def from_config_listeners(listeners) do
    Enum.map(listeners, fn
      %Listener{} = listener ->
        listener
        |> Map.from_struct()
        |> listener_to_opts()
        |> Map.put(:scheme, listener.scheme)

      %{scheme: scheme} = listener ->
        listener
        |> listener_to_opts()
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

  defp listener_to_opts(listener) do
    listener
    |> prefer_tls_paths()
    |> Map.take([:ip, :port, :cert, :key, :ssl_opts])
    |> Enum.reject(fn
      {:ssl_opts, []} -> true
      {_key, value} -> is_nil(value)
    end)
    |> Map.new()
  end

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
