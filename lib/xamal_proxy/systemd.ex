defmodule XamalProxy.Systemd do
  @moduledoc """
  Generate systemd unit content for xamal_proxy deployments.
  """

  alias Systemd.UnitFile

  @spec unit(keyword()) :: String.t()
  def unit(opts) do
    opts = normalize_opts(opts)

    unit_file =
      UnitFile.service(
        unit: [
          description: "Xamal Proxy",
          after: "network-online.target",
          wants: "network-online.target"
        ],
        service: [
          user: opts.user,
          group: opts.group,
          environment_file: "-#{opts.env_path}",
          environment: [
            "XAMAL_PROXY_CONFIG=#{opts.config_path}",
            "XAMAL_PROXY_STATE=#{opts.state_path}",
            "RELEASE_VM_ARGS=#{opts.vm_args_path}"
          ],
          exec_start: "#{opts.release_path}/bin/xamal_proxy start",
          exec_stop: "#{opts.release_path}/bin/xamal_proxy stop",
          restart: :always,
          restart_sec: 5
        ],
        install: [wanted_by: "multi-user.target"]
      )

    :ok = UnitFile.validate(unit_file, :service)
    UnitFile.to_string(unit_file)
  end

  defp normalize_opts(opts) do
    user = Keyword.get(opts, :user, "xamal-proxy")

    %{
      user: user,
      group: Keyword.get(opts, :group, user),
      release_path: Keyword.get(opts, :release_path, "/opt/xamal-proxy"),
      config_path: Keyword.get(opts, :config_path, "/etc/xamal-proxy.exs"),
      state_path: Keyword.get(opts, :state_path, "/var/lib/xamal-proxy/state.etf"),
      env_path: Keyword.get(opts, :env_path, "/etc/xamal-proxy/env"),
      vm_args_path: Keyword.get(opts, :vm_args_path, "/etc/xamal-proxy/vm.args")
    }
  end
end
