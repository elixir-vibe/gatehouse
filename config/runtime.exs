import Config

if config_path = System.get_env("XAMAL_PROXY_CONFIG") do
  config :xamal_proxy, config_path: config_path
end

if state_path = System.get_env("XAMAL_PROXY_STATE") do
  config :xamal_proxy, persistence_path: state_path
end
