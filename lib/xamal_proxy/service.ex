defmodule XamalProxy.Service do
  @moduledoc """
  OTP process that owns deploy/switch/drain state for one service.

  This starts as a `GenServer` while the state machine is small. As deploy and
  drain transitions grow, this is the seam to promote to `:gen_statem` without
  changing the public control API.
  """

  use GenServer

  alias XamalProxy.RouteTable
  alias XamalProxy.Service.State
  alias XamalProxy.Target

  @type deploy_spec :: %{
          required(:service) => String.t(),
          required(:hosts) => [String.t()],
          required(:target_url) => String.t(),
          optional(:target_id) => String.t(),
          optional(:metadata) => map()
        }

  def start_link(id) when is_binary(id) do
    GenServer.start_link(__MODULE__, id, name: via(id))
  end

  @spec deploy(String.t(), deploy_spec()) :: {:ok, State.t()} | {:error, term()}
  def deploy(id, spec) do
    GenServer.call(via(id), {:deploy, spec})
  end

  @spec get(String.t()) :: State.t()
  def get(id) do
    GenServer.call(via(id), :get)
  end

  @impl GenServer
  def init(id) do
    {:ok, %State{id: id}}
  end

  @impl GenServer
  def handle_call({:deploy, spec}, _from, %State{} = state) do
    with {:ok, target} <- build_target(spec),
         hosts when hosts != [] <- normalize_hosts(Map.fetch!(spec, :hosts)) do
      old_targets = put_old_target(state.old_targets, state.active_target)

      next_state = %State{
        state
        | hosts: hosts,
          active_target: target,
          old_targets: old_targets,
          status: :serving
      }

      Enum.each(hosts, &RouteTable.put(&1, state.id, target.id))
      {:reply, {:ok, next_state}, next_state}
    else
      [] ->
        {:reply, {:error, :no_hosts}, %{state | status: :failed}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | status: :failed}}
    end
  end

  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  defp build_target(spec) do
    target_id = Map.get(spec, :target_id, default_target_id())
    metadata = Map.get(spec, :metadata, %{})
    Target.new(target_id, Map.fetch!(spec, :target_url), metadata)
  end

  defp normalize_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.map(&String.downcase(String.trim(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp put_old_target(old_targets, nil), do: old_targets
  defp put_old_target(old_targets, %Target{id: id} = target), do: Map.put(old_targets, id, target)

  defp default_target_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp via(id) do
    {:via, Registry, {XamalProxy.ServiceRegistry, id}}
  end
end
