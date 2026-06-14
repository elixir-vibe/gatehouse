defmodule Gatehouse.Systemd do
  @moduledoc """
  Generate systemd unit content for gatehouse deployments.
  """

  alias Systemd.UnitFile

  @spec unit(keyword()) :: String.t()
  def unit(opts) do
    opts = normalize_opts(opts)

    unit_file =
      UnitFile.service(
        unit: [
          description: "Gatehouse Edge Proxy",
          after: "network-online.target",
          wants: "network-online.target"
        ],
        service: [
          user: opts.user,
          group: opts.group,
          environment_file: "-#{opts.env_path}",
          environment: [
            "GATEHOUSE_CONFIG=#{opts.config_path}",
            "GATEHOUSE_STATE=#{opts.state_path}",
            "RELEASE_VM_ARGS=#{opts.vm_args_path}"
          ],
          exec_start: "#{opts.release_path}/bin/gatehouse start",
          exec_stop: "#{opts.release_path}/bin/gatehouse stop",
          restart: :always,
          restart_sec: 5,
          LimitNOFILE: 1_048_576
        ],
        install: [wanted_by: "multi-user.target"]
      )

    :ok = UnitFile.validate(unit_file, :service)
    UnitFile.to_string(unit_file)
  end

  defp normalize_opts(opts) do
    user = Keyword.get(opts, :user, "gatehouse")

    %{
      user: user,
      group: Keyword.get(opts, :group, user),
      release_path: Keyword.get(opts, :release_path, "/opt/gatehouse"),
      config_path: Keyword.get(opts, :config_path, "/etc/gatehouse.exs"),
      state_path: Keyword.get(opts, :state_path, "/var/lib/gatehouse/state.etf"),
      env_path: Keyword.get(opts, :env_path, "/etc/gatehouse/env"),
      vm_args_path: Keyword.get(opts, :vm_args_path, "/etc/gatehouse/vm.args")
    }
  end
end
