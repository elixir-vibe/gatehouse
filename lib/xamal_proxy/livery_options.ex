defmodule XamalProxy.LiveryOptions do
  @moduledoc false

  alias XamalProxy.Config.Listener

  def service_options(handler) do
    listeners = Application.get_env(:xamal_proxy, :listeners, [])

    listeners
    |> Enum.reduce(%{handler: handler}, &put_listener/2)
    |> reject_nil_protocols()
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
    |> reload_tls_files()
    |> Map.take([:ip, :port, :cert, :key])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp reload_tls_files(%{cert_path: cert_path, key_path: key_path} = listener) do
    listener
    |> put_file(:cert, cert_path)
    |> put_file(:key, key_path)
  end

  defp reload_tls_files(listener), do: listener

  defp put_file(listener, _key, nil), do: listener
  defp put_file(listener, key, path), do: Map.put(listener, key, File.read!(path))

  defp reject_nil_protocols(opts) do
    opts
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
