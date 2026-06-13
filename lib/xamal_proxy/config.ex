defmodule XamalProxy.Config do
  @moduledoc """
  Minimal Caddy-like Elixir DSL for static `xamal_proxy` configuration.

  Import this module in a `.exs` config file and use top-level directives:

      import XamalProxy.Config

      state "/var/lib/xamal-proxy/state.etf"
      http port: 80

      service :my_app do
        host "example.com"
        target :blue, "http://127.0.0.1:4000", active: true
        health "/up", timeout: 5_000
        drain 30_000
      end
  """

  alias XamalProxy.Config.{Builder, Listener, Service, Target}
  alias XamalProxy.TLS.SNI

  defstruct state_path: nil, acme: nil, listeners: [], services: []

  @type t :: %__MODULE__{
          state_path: Path.t() | nil,
          acme: keyword() | nil,
          listeners: [Listener.t()],
          services: [Service.t()]
        }

  defmacro service(name, do: block) do
    builder = Builder

    quote do
      unquote(builder).begin_service(unquote(name))
      unquote(block)
      unquote(builder).end_service()
    end
  end

  @spec eval!(String.t()) :: t()
  def eval!(source) when is_binary(source) do
    Builder.run(fn -> Code.eval_string(source, [], file: "xamal_proxy_config.exs") end)
  end

  @spec read!(Path.t()) :: t()
  def read!(path) when is_binary(path) do
    Builder.run(fn -> Code.eval_file(path) end)
  end

  @spec state(Path.t()) :: :ok
  def state(path) when is_binary(path) do
    Builder.put_state_path(path)
  end

  @spec acme(keyword()) :: :ok
  def acme(opts) when is_list(opts) do
    Builder.put_acme(opts)
  end

  @spec http(keyword()) :: :ok
  def http(opts \\ []) when is_list(opts) do
    listener(:http, opts)
  end

  @spec https(keyword()) :: :ok
  def https(opts \\ []) when is_list(opts) do
    listener(:https, opts)
  end

  @spec listener(atom(), keyword()) :: :ok
  def listener(scheme, opts) when scheme in [:http, :https] and is_list(opts) do
    cert_path = Keyword.get(opts, :cert)
    key_path = Keyword.get(opts, :key)
    ssl_opts = Keyword.get(opts, :ssl_opts, []) ++ sni_opts(Keyword.get(opts, :sni))

    Builder.add_listener(%Listener{
      scheme: scheme,
      ip: Keyword.get(opts, :ip, {0, 0, 0, 0}),
      port: Keyword.get(opts, :port, default_port(scheme)),
      cert: read_optional_file(cert_path),
      key: read_optional_file(key_path),
      cert_path: cert_path,
      key_path: key_path,
      ssl_opts: ssl_opts
    })
  end

  @spec host(String.t()) :: :ok
  def host(hostname) when is_binary(hostname) do
    Builder.add_host(hostname)
  end

  @spec target(atom() | String.t(), String.t() | keyword(), keyword()) :: :ok
  def target(name, url_or_opts, opts \\ [])

  def target(name, url, opts) when is_binary(url) and is_list(opts) do
    Builder.add_target(%Target{
      name: normalize_name(name),
      url: url,
      active?: Keyword.get(opts, :active, false),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  def target(name, opts, []) when is_list(opts) do
    safe_rpc = Keyword.fetch!(opts, :safe_rpc)

    Builder.add_target(%Target{
      name: normalize_name(name),
      kind: :safe_rpc,
      socket: Keyword.fetch!(safe_rpc, :socket),
      op: Keyword.get(safe_rpc, :op, :http_request),
      shards: Keyword.get(safe_rpc, :shards, 1),
      active?: Keyword.get(opts, :active, false),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  @spec balance(atom(), keyword()) :: :ok
  def balance(policy, opts \\ []) when policy in [:active, :round_robin] and is_list(opts) do
    Builder.put_balance(%{policy: policy, options: opts})
  end

  @spec health(String.t(), keyword()) :: :ok
  def health(path, opts \\ []) when is_binary(path) and is_list(opts) do
    Builder.put_health(%{
      path: path,
      timeout: Keyword.get(opts, :timeout, 5_000),
      interval: Keyword.get(opts, :interval, 1_000)
    })
  end

  @spec drain(timeout()) :: :ok
  def drain(:infinity) do
    Builder.put_drain(%{timeout: :infinity})
  end

  def drain(timeout) when is_integer(timeout) do
    Builder.put_drain(%{timeout: timeout})
  end

  @spec tls(:auto | false | keyword()) :: :ok
  def tls(:auto), do: Builder.put_tls(:auto)
  def tls(false), do: Builder.put_tls(false)
  def tls(mode) when is_list(mode), do: Builder.put_tls(mode)

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443

  defp sni_opts(nil), do: []
  defp sni_opts(opts) when is_list(opts), do: SNI.ssl_opts(opts)

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp read_optional_file(nil), do: nil
  defp read_optional_file(path) when is_binary(path), do: File.read!(path)
end
