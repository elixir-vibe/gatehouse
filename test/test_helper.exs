unless System.get_env("XAMAL_PROXY_PEBBLE") == "1" do
  ExUnit.configure(exclude: [:pebble])
end

ExUnit.start()
