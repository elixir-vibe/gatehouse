defmodule XamalProxy.ACME.RenewalScheduler do
  @moduledoc """
  Periodic ACME certificate renewal scheduler.

  Configure jobs with `:acme_certificates`:

      config :xamal_proxy, :acme_certificates, [
        %{
          name: "example.com",
          domains: ["example.com"],
          provider: XamalProxy.ACME.Provider.AcmeClient,
          provider_opts: [email: "ops@example.com"],
          store: XamalProxy.CertificateStore.File,
          store_opts: [directory: "/var/lib/xamal-proxy/certs"],
          renew_before_days: 30
        }
      ]
  """

  use GenServer

  alias XamalProxy.Telemetry

  @default_interval :timer.hours(12)
  @default_renew_before_days 30

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec renew_now() :: [{String.t(), :ok | {:skip, :not_due} | {:error, term()}}]
  def renew_now do
    GenServer.call(__MODULE__, :renew_now, :infinity)
  end

  @impl GenServer
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:renew_now, _from, state) do
    {:reply, run_jobs(), state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    Telemetry.execute([:acme, :renewal, :tick], %{}, %{})
    run_jobs()
    schedule_tick()
    {:noreply, state}
  end

  defp run_jobs do
    :xamal_proxy
    |> Application.get_env(:acme_certificates, [])
    |> Enum.map(&run_job/1)
  end

  defp run_job(job) do
    name = Map.fetch!(job, :name)
    result = maybe_renew(job)
    Telemetry.execute([:acme, :renewal, :stop], %{}, %{name: name, result: result})
    {name, result}
  end

  defp maybe_renew(job) do
    store = Map.fetch!(job, :store)
    store_opts = Map.get(job, :store_opts, [])

    case store.get(job.name, store_opts) do
      {:ok, cert} -> renew_if_due(job, cert)
      {:error, _reason} -> renew(job)
    end
  end

  defp renew_if_due(job, cert) do
    if due?(cert, Map.get(job, :renew_before_days, @default_renew_before_days)) do
      renew(job)
    else
      {:skip, :not_due}
    end
  end

  defp due?(%{expires_at: %DateTime{} = expires_at}, renew_before_days) do
    DateTime.diff(expires_at, DateTime.utc_now(), :day) <= renew_before_days
  end

  defp due?(_cert, _renew_before_days), do: true

  defp renew(job) do
    provider = Map.fetch!(job, :provider)
    provider_opts = Map.get(job, :provider_opts, [])
    store = Map.fetch!(job, :store)
    store_opts = Map.get(job, :store_opts, [])

    with {:ok, cert} <- provider.order_certificate(Map.fetch!(job, :domains), provider_opts),
         :ok <- store.put(job.name, cert, store_opts) do
      refresh_tls_listener()
    end
  end

  defp refresh_tls_listener do
    case Process.whereis(XamalProxy.LiveryListener) do
      nil -> :ok
      _pid -> XamalProxy.LiveryListener.refresh_tls()
    end
  end

  defp schedule_tick do
    Process.send_after(
      self(),
      :tick,
      Application.get_env(:xamal_proxy, :acme_renewal_interval, @default_interval)
    )
  end
end
