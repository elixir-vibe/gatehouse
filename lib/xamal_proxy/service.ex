defmodule XamalProxy.Service do
  @moduledoc """
  OTP state machine that owns deploy/switch/drain state for one service.
  """

  @behaviour :gen_statem

  alias XamalProxy.HealthCheck
  alias XamalProxy.RouteTable
  alias XamalProxy.Service.State
  alias XamalProxy.Target
  alias XamalProxy.Telemetry

  @default_drain_timeout 30_000
  @default_health_path "/up"
  @default_health_timeout 5_000

  @type deploy_spec :: %{
          required(:service) => String.t(),
          required(:hosts) => [String.t()],
          required(:target_url) => String.t(),
          optional(:target_id) => String.t(),
          optional(:health_path) => String.t(),
          optional(:health_timeout) => timeout(),
          optional(:drain_timeout) => timeout(),
          optional(:metadata) => map(),
          optional(:skip_health_check) => boolean()
        }

  def child_spec(id) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(id) when is_binary(id) do
    :gen_statem.start_link(via(id), __MODULE__, id, [])
  end

  @spec deploy(String.t(), deploy_spec()) :: {:ok, State.t()} | {:error, term()}
  def deploy(id, spec) do
    :gen_statem.call(via(id), {:deploy, spec}, deploy_timeout(spec))
  end

  @spec get(String.t()) :: State.t()
  def get(id) do
    :gen_statem.call(via(id), :get)
  end

  @spec configure(String.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def configure(id, spec) do
    :gen_statem.call(via(id), {:configure, spec})
  end

  @spec checkout(String.t(), String.t() | :select) :: {:ok, Target.t()} | {:error, term()}
  def checkout(id, target_id) do
    :gen_statem.call(via(id), {:checkout, target_id})
  end

  @spec checkin(String.t(), String.t()) :: :ok
  def checkin(id, target_id) do
    :gen_statem.cast(via(id), {:checkin, target_id})
  end

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(id) do
    {:ok, :empty, %State{id: id}}
  end

  @impl :gen_statem
  def handle_event({:call, from}, {:deploy, spec}, _status, %State{} = state) do
    case prepare_deploy(spec) do
      {:ok, target, hosts, drain_timeout} ->
        old_targets = put_old_target(state.old_targets, state.active_target, drain_timeout)

        next_state = %State{
          state
          | hosts: hosts,
            active_target: target,
            active_targets: [target],
            target_cursor: 0,
            old_targets: old_targets,
            status: :serving
        }

        Enum.each(hosts, &RouteTable.put(&1, state.id, target.id))

        schedule_drains(old_targets)
        {:next_state, :serving, next_state, [{:reply, from, {:ok, next_state}}]}

      {:error, reason} ->
        next_state = %{state | status: :failed}
        {:keep_state, next_state, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:configure, spec}, _status, %State{} = state) do
    case prepare_configure(spec) do
      {:ok, targets, hosts, route_target_id} ->
        active_target = List.first(targets)

        next_state = %State{
          state
          | hosts: hosts,
            active_target: active_target,
            active_targets: targets,
            target_cursor: 0,
            status: :serving
        }

        Enum.each(hosts, &RouteTable.put(&1, state.id, route_target_id))
        {:next_state, :serving, next_state, [{:reply, from, {:ok, next_state}}]}

      {:error, reason} ->
        {:keep_state, %{state | status: :failed}, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, :get, _status, %State{} = state) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, {:checkout, target_id}, _status, %State{} = state) do
    case checkout_target(state, target_id) do
      {:ok, target, next_state} ->
        {:keep_state, next_state, [{:reply, from, {:ok, target}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event(:cast, {:checkin, target_id}, _status, %State{} = state) do
    next_state = checkin_target(state, target_id)
    {:keep_state, maybe_finish_drains(next_state)}
  end

  def handle_event(:info, {:drain_timeout, target_id}, _status, %State{} = state) do
    {:keep_state, drop_old_target(state, target_id)}
  end

  def handle_event(_event_type, _event, _status, %State{} = state) do
    {:keep_state, state}
  end

  defp prepare_deploy(spec) do
    with hosts when hosts != [] <- normalize_hosts(Map.fetch!(spec, :hosts)),
         {:ok, target} <- build_target(spec),
         :ok <- maybe_health_check(target, spec) do
      {:ok, target, hosts, Map.get(spec, :drain_timeout, @default_drain_timeout)}
    else
      [] -> {:error, :no_hosts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_configure(spec) do
    with hosts when hosts != [] <- normalize_hosts(Map.fetch!(spec, :hosts)),
         {:ok, targets} <- build_targets(Map.fetch!(spec, :targets)) do
      route_target_id = route_target_id(Map.get(spec, :balance), targets)

      {:ok, targets, hosts, route_target_id}
    else
      [] -> {:error, :no_hosts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route_target_id(:round_robin, [_first, _second | _rest]), do: :select
  defp route_target_id(_balance, [target | _rest]), do: target.id

  defp build_targets(target_specs) do
    target_specs
    |> Enum.map(&Target.new(&1.id, &1.url, target_metadata(&1)))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, target}, {:ok, targets} -> {:cont, {:ok, [target | targets]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, []} -> {:error, :no_targets}
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_target(spec) do
    target_id = Map.get(spec, :target_id, default_target_id())
    metadata = Map.get(spec, :metadata, %{})
    Target.new(target_id, Map.get(spec, :target_url), metadata)
  end

  defp target_metadata(%{kind: kind} = target) do
    target.metadata
    |> Map.put(:kind, kind)
    |> Map.put(:socket, target.socket)
    |> Map.put(:op, target.op)
    |> Map.put(:shards, target.shards)
  end

  defp target_metadata(%{metadata: metadata}), do: metadata

  defp maybe_health_check(_target, %{skip_health_check: true}), do: :ok
  defp maybe_health_check(%Target{kind: :safe_rpc}, _spec), do: :ok

  defp maybe_health_check(%Target{id: target_id, url: url}, spec) do
    start = System.monotonic_time()

    result =
      HealthCheck.check(url,
        path: Map.get(spec, :health_path, @default_health_path),
        timeout: Map.get(spec, :health_timeout, @default_health_timeout)
      )

    Telemetry.execute([:health_check, :stop], %{duration: System.monotonic_time() - start}, %{
      target_id: target_id,
      url: URI.to_string(url),
      result: result
    })

    result
  end

  defp checkout_target(%State{active_targets: targets} = state, :select) when targets != [] do
    index = rem(state.target_cursor, length(targets))
    target = Enum.at(targets, index)
    next_target = increment_target(target)
    next_targets = List.replace_at(targets, index, next_target)

    {:ok, next_target,
     %{state | active_targets: next_targets, target_cursor: state.target_cursor + 1}}
  end

  defp checkout_target(%State{active_targets: targets} = state, target_id) do
    case Enum.find_index(targets, &(&1.id == target_id)) do
      nil ->
        checkout_old_target(state, target_id)

      index ->
        next_target = targets |> Enum.at(index) |> increment_target()
        next_targets = List.replace_at(targets, index, next_target)
        {:ok, next_target, %{state | active_targets: next_targets, active_target: next_target}}
    end
  end

  defp checkout_old_target(%State{old_targets: old_targets} = state, target_id) do
    case Map.fetch(old_targets, target_id) do
      {:ok, %Target{draining?: true} = target} ->
        next_target = increment_target(target)
        {:ok, next_target, %{state | old_targets: Map.put(old_targets, target_id, next_target)}}

      {:ok, _target} ->
        {:error, :not_active}

      :error ->
        {:error, :not_found}
    end
  end

  defp checkin_target(%State{active_targets: targets} = state, target_id) do
    case Enum.find_index(targets, &(&1.id == target_id)) do
      nil ->
        checkin_old_target(state, target_id)

      index ->
        target = targets |> Enum.at(index) |> decrement_target()
        %{state | active_targets: List.replace_at(targets, index, target)}
    end
  end

  defp checkin_old_target(%State{old_targets: old_targets} = state, target_id) do
    case Map.fetch(old_targets, target_id) do
      {:ok, target} ->
        %{state | old_targets: Map.put(old_targets, target_id, decrement_target(target))}

      :error ->
        state
    end
  end

  defp increment_target(%Target{} = target) do
    %{target | active_requests: target.active_requests + 1}
  end

  defp decrement_target(%Target{active_requests: count} = target) do
    %{target | active_requests: max(count - 1, 0)}
  end

  defp maybe_finish_drains(%State{old_targets: old_targets} = state) do
    drained_ids =
      old_targets
      |> Enum.filter(fn {_id, target} -> target.draining? and target.active_requests == 0 end)
      |> Enum.map(fn {id, _target} -> id end)

    Enum.reduce(drained_ids, state, &drop_old_target(&2, &1))
  end

  defp put_old_target(old_targets, nil, _drain_timeout), do: old_targets

  defp put_old_target(old_targets, %Target{id: id} = target, drain_timeout) do
    Map.put(old_targets, id, %{target | draining?: true, drain_deadline: deadline(drain_timeout)})
  end

  defp schedule_drains(old_targets) do
    Enum.each(old_targets, fn {target_id, target} ->
      timeout = max(DateTime.diff(target.drain_deadline, DateTime.utc_now(), :millisecond), 0)
      Process.send_after(self(), {:drain_timeout, target_id}, timeout)
    end)
  end

  defp drop_old_target(%State{old_targets: old_targets} = state, target_id) do
    if Map.has_key?(old_targets, target_id) do
      Telemetry.execute([:drain, :stop], %{}, %{service: state.id, target_id: target_id})
    end

    %{state | old_targets: Map.delete(old_targets, target_id)}
  end

  defp normalize_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.map(&String.downcase(String.trim(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp deadline(:infinity), do: DateTime.add(DateTime.utc_now(), 86_400, :second)
  defp deadline(milliseconds), do: DateTime.add(DateTime.utc_now(), milliseconds, :millisecond)

  defp default_target_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp deploy_timeout(spec) do
    health_timeout = Map.get(spec, :health_timeout, @default_health_timeout)
    health_timeout + 5_000
  end

  defp via(id) do
    {:via, Registry, {XamalProxy.ServiceRegistry, id}}
  end
end
