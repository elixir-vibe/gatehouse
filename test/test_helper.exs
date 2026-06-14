excluded = []

excluded =
  if System.get_env("GATEHOUSE_PEBBLE") == "1", do: excluded, else: [:pebble | excluded]

excluded =
  if System.get_env("GATEHOUSE_INTEGRATION") == "1",
    do: excluded,
    else: [:integration | excluded]

ExUnit.start(exclude: excluded)
