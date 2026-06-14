import Config

if config_path = System.get_env("GATEHOUSE_CONFIG") do
  config :gatehouse, config_path: config_path
end

if state_path = System.get_env("GATEHOUSE_STATE") do
  config :gatehouse, persistence_path: state_path
end
