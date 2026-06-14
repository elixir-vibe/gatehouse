defmodule Mix.Tasks.Gatehouse.Run do
  @moduledoc """
  Runs a development command behind a local Gatehouse HTTPS proxy.

      mix gatehouse.run -- mix phx.server
      mix gatehouse.run --open -- mix phx.server
      mix gatehouse.run --host admin.localhost --proxy-port 4443 -- mix phx.server

  Gatehouse chooses a free backend port, exposes it through `PORT`, registers a
  local route, and prints a stable HTTPS URL such as
  `https://my-app.localhost:4443`.
  """

  use Mix.Task

  alias Gatehouse.Dev.Proxy

  @shortdoc "Run a command behind a local Gatehouse HTTPS proxy"

  @switches [
    host: :string,
    name: :string,
    proxy_port: :integer,
    backend_port: :integer,
    cert_dir: :string,
    no_tls: :boolean,
    open: :boolean
  ]

  @aliases [h: :host]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, command} = parse!(args)
    app = Mix.Project.config()[:app] || :app
    service = opts[:name] || Atom.to_string(app)
    host = opts[:host] || Proxy.default_host(service)
    backend_port = opts[:backend_port] || free_port!()
    proxy_port = opts[:proxy_port] || Proxy.default_proxy_port()
    tls? = opts[:no_tls] != true

    proxy =
      start_proxy!(
        host: host,
        service: service,
        backend_port: backend_port,
        proxy_port: proxy_port,
        cert_dir: opts[:cert_dir],
        tls: tls?
      )

    print_banner(proxy.url, backend_port, command, tls?)
    maybe_open_browser(proxy.url, opts[:open])
    run_command(command, backend_port)
  end

  defp parse!(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {proxy_args, ["--" | command]} ->
        {opts, rest, invalid} =
          OptionParser.parse(proxy_args, switches: @switches, aliases: @aliases)

        cond do
          invalid != [] -> Mix.raise("Invalid gatehouse.run option(s): #{inspect(invalid)}")
          rest != [] -> Mix.raise("Unexpected gatehouse.run argument(s): #{Enum.join(rest, " ")}")
          command == [] -> Mix.raise("Expected a command after --")
          true -> {opts, command}
        end

      {_proxy_args, []} ->
        Mix.raise("Expected a command after --, for example: mix gatehouse.run -- mix phx.server")
    end
  end

  defp free_port! do
    case Proxy.free_port() do
      {:ok, port} -> port
      {:error, reason} -> Mix.raise("Could not find a free backend port: #{inspect(reason)}")
    end
  end

  defp start_proxy!(opts) do
    case safe_start_proxy(opts) do
      {:ok, proxy} ->
        proxy

      {:error, {:error, {:badmatch, {:error, {:listen_failed, :eaddrinuse}}}}} ->
        Mix.raise(proxy_port_in_use_message(opts))

      {:error, {:listen_failed, :eaddrinuse}} ->
        Mix.raise(proxy_port_in_use_message(opts))

      {:error, :eaddrinuse} ->
        Mix.raise(proxy_port_in_use_message(opts))

      {:error, reason} ->
        Mix.raise("Could not start Gatehouse dev proxy: #{inspect(reason)}")
    end
  end

  defp proxy_port_in_use_message(opts) do
    "Gatehouse proxy port #{opts[:proxy_port]} is already in use. " <>
      "Stop the other process or pass --proxy-port with a free port."
  end

  defp safe_start_proxy(opts) do
    previous_flag = Process.flag(:trap_exit, true)

    try do
      Proxy.start(opts)
    catch
      :exit, {:error, {:badmatch, {:error, reason}}} -> {:error, reason}
      :exit, {:badmatch, {:error, reason}} -> {:error, reason}
      :exit, reason -> {:error, reason}
    after
      Process.flag(:trap_exit, previous_flag)
    end
  end

  defp print_banner(url, backend_port, command, tls?) do
    Mix.shell().info("""

    Gatehouse dev proxy is running

      #{url}  ->  http://127.0.0.1:#{backend_port}

    Starting:

      PORT=#{backend_port} #{Enum.join(command, " ")}
    """)

    if tls? do
      Mix.shell().info(
        "If your browser does not trust the certificate yet, run: mix gatehouse.trust"
      )
    end

    Mix.shell().info(
      "If Phoenix still prints or serves on a different port, update your dev endpoint to read PORT."
    )
  end

  defp maybe_open_browser(_url, open?) when open? in [nil, false], do: :ok

  defp maybe_open_browser(url, true) do
    opener =
      cond do
        match?({:unix, :darwin}, :os.type()) -> "open"
        System.find_executable("xdg-open") -> "xdg-open"
        true -> nil
      end

    if opener do
      System.cmd(opener, [url], stderr_to_stdout: true)
      :ok
    else
      Mix.shell().error("Could not find a browser opener; please open #{url} manually.")
    end
  end

  defp run_command([executable | args], backend_port) do
    {_output, status} =
      MuonTrap.cmd(executable, args,
        env: [{"PORT", Integer.to_string(backend_port)}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    case status do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
