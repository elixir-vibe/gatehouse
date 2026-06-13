excluded = []

excluded =
  if System.get_env("XAMAL_PROXY_PEBBLE") == "1", do: excluded, else: [:pebble | excluded]

excluded =
  if System.get_env("XAMAL_PROXY_INTEGRATION") == "1",
    do: excluded,
    else: [:integration | excluded]

ExUnit.start(exclude: excluded)
