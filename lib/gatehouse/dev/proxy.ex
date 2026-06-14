defmodule Gatehouse.Dev.Proxy do
  @moduledoc """
  Helpers used by Gatehouse development mix tasks.
  """

  alias Gatehouse.Config.Listener
  alias Gatehouse.Dev.CertStore

  @default_proxy_port 4443
  @default_backend_range 40_000..49_999

  @type start_opts :: [
          host: String.t(),
          service: String.t(),
          backend_port: :inet.port_number(),
          proxy_port: :inet.port_number(),
          cert_dir: Path.t(),
          tls: boolean(),
          listener_name: atom()
        ]

  @spec default_host(atom() | String.t()) :: String.t()
  def default_host(app) when is_atom(app), do: default_host(Atom.to_string(app))

  def default_host(app) when is_binary(app) do
    app
    |> String.replace("_", "-")
    |> Kernel.<>(".localhost")
  end

  @spec default_proxy_port() :: pos_integer()
  def default_proxy_port, do: @default_proxy_port

  @spec free_port() :: {:ok, :inet.port_number()} | {:error, term()}
  def free_port do
    Enum.reduce_while(Enum.shuffle(@default_backend_range), {:error, :no_free_port}, fn port,
                                                                                        _acc ->
      case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          {:halt, {:ok, port}}

        {:error, _reason} ->
          {:cont, {:error, :no_free_port}}
      end
    end)
  end

  @spec start(start_opts()) :: {:ok, %{url: String.t(), listener: pid()}} | {:error, term()}
  def start(opts) do
    host = Keyword.fetch!(opts, :host)
    service = Keyword.fetch!(opts, :service)
    backend_port = Keyword.fetch!(opts, :backend_port)
    proxy_port = Keyword.get(opts, :proxy_port, @default_proxy_port)
    tls? = Keyword.get(opts, :tls, true)

    with {:ok, _apps} <- Application.ensure_all_started(:gatehouse),
         {:ok, listener} <- start_listener(host, proxy_port, tls?, opts),
         {:ok, _state} <- deploy(service, host, backend_port) do
      actual_port = Gatehouse.LiveryListener.port(listener)
      {:ok, %{url: url(host, actual_port, tls?), listener: listener}}
    end
  end

  defp start_listener(host, port, true, opts) do
    cert_dir = Keyword.get(opts, :cert_dir) || CertStore.default_dir()

    with {:ok, cert} <- CertStore.ensure_server_cert(host, cert_dir) do
      listeners = [
        %{
          scheme: :http,
          ip: {127, 0, 0, 1},
          port: port,
          transport: :ssl,
          cert_path: cert.cert_path,
          key_path: cert.key_path
        }
      ]

      Gatehouse.LiveryListener.start_link(name: listener_name(opts), listeners: listeners)
    end
  end

  defp start_listener(_host, port, false, opts) do
    listeners = [%Listener{scheme: :http, ip: {127, 0, 0, 1}, port: port}]
    Gatehouse.LiveryListener.start_link(name: listener_name(opts), listeners: listeners)
  end

  defp deploy(service, host, backend_port) do
    Gatehouse.Control.deploy(%{
      service: service,
      hosts: [host],
      target_id: "dev",
      target_url: "http://127.0.0.1:#{backend_port}",
      skip_health_check: true,
      metadata: %{gatehouse_dev?: true}
    })
  end

  defp url(host, port, tls?) do
    scheme = if tls?, do: "https", else: "http"

    case {scheme, port} do
      {"https", 443} -> "https://#{host}"
      {"http", 80} -> "http://#{host}"
      _other -> "#{scheme}://#{host}:#{port}"
    end
  end

  defp listener_name(opts) do
    Keyword.get_lazy(opts, :listener_name, fn ->
      String.to_atom("gatehouse_dev_proxy_#{System.unique_integer([:positive])}")
    end)
  end
end
