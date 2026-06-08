defmodule XamalProxy.ACME.RenewalScheduler do
  @moduledoc """
  Periodic ACME renewal scheduler placeholder.

  The scheduler emits telemetry and provides the supervised process that will own
  real renewal decisions once certificate persistence is wired to ACME orders.
  """

  use GenServer

  alias XamalProxy.Telemetry

  @default_interval :timer.hours(12)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    Telemetry.execute([:acme, :renewal, :tick], %{}, %{})
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(
      self(),
      :tick,
      Application.get_env(:xamal_proxy, :acme_renewal_interval, @default_interval)
    )
  end
end
