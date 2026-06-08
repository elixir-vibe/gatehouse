defmodule XamalProxy.Config.Builder do
  @moduledoc false

  alias XamalProxy.Config
  alias XamalProxy.Config.Service

  @config_key {__MODULE__, :config}
  @service_key {__MODULE__, :service}

  def run(fun) when is_function(fun, 0) do
    previous_config = Process.get(@config_key)
    previous_service = Process.get(@service_key)

    try do
      Process.put(@config_key, %Config{})
      Process.delete(@service_key)
      fun.()
      current_config()
    after
      restore(@config_key, previous_config)
      restore(@service_key, previous_service)
    end
  end

  def put_state_path(path) do
    update_config(&%{&1 | state_path: path})
  end

  def add_listener(listener) do
    update_config(&%{&1 | listeners: &1.listeners ++ [listener]})
  end

  def put_acme(opts) do
    update_config(&%{&1 | acme: opts})
  end

  def begin_service(name) do
    if Process.get(@service_key) do
      raise ArgumentError, "nested service blocks are not supported"
    end

    Process.put(@service_key, %Service{name: normalize_name(name)})
    :ok
  end

  def end_service do
    service = current_service!()
    Process.delete(@service_key)
    update_config(&%{&1 | services: &1.services ++ [service]})
  end

  def add_host(host) do
    update_service(&%{&1 | hosts: &1.hosts ++ [normalize_host(host)]})
  end

  def add_target(target) do
    update_service(&%{&1 | targets: &1.targets ++ [target]})
  end

  def put_health(health) do
    update_service(&%{&1 | health: Map.merge(&1.health, health)})
  end

  def put_drain(drain) do
    update_service(&%{&1 | drain: Map.merge(&1.drain, drain)})
  end

  def put_tls(tls) do
    update_service(&%{&1 | tls: tls})
  end

  def put_balance(balance) do
    update_service(&%{&1 | balance: balance})
  end

  defp current_config do
    Process.get(@config_key) ||
      raise ArgumentError, "XamalProxy.Config DSL was used outside eval!/1 or read!/1"
  end

  defp current_service! do
    Process.get(@service_key) ||
      raise ArgumentError, "service directive used outside service block"
  end

  defp update_config(fun) do
    Process.put(@config_key, fun.(current_config()))
    :ok
  end

  defp update_service(fun) do
    Process.put(@service_key, fun.(current_service!()))
    :ok
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.downcase()
  end
end
